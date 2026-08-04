import Foundation

// MARK: - Веса моделей

/// Цены за 1 Mtok, проверены 2026‑08‑04. Токены разных типов и моделей стоят
/// по-разному, поэтому суммируем не «штуки», а условную стоимость.
public struct ModelWeights: Sendable, Equatable {
    public let input: Double
    public let output: Double

    /// Запись пятиминутного кеша — ×1.25 от входа, часового — ×2,
    /// чтение кеша — ×0.1.
    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2 }
    public var cacheRead: Double { input * 0.1 }

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

public enum ModelPricing {
    public static let opus = ModelWeights(input: 5, output: 25)
    public static let sonnet = ModelWeights(input: 3, output: 15)
    public static let haiku = ModelWeights(input: 1, output: 5)

    /// Сопоставление по префиксу: в транскриптах встречаются и голые имена
    /// (`claude-opus-5`), и с датой (`claude-haiku-4-5-20251001`).
    private static let table: [(prefix: String, weights: ModelWeights)] = [
        ("claude-opus", opus),
        ("claude-sonnet", sonnet),
        ("claude-haiku", haiku),
        ("claude-fable", ModelWeights(input: 10, output: 50)),
        ("claude-mythos", ModelWeights(input: 10, output: 50)),
    ]

    /// Локально сгенерированные сообщения — не вызовы API, в расход не идут.
    public static let syntheticModel = "<synthetic>"

    nonisolated(unsafe) private static var reportedUnknown: Set<String> = []

    public static func weights(for model: String?) -> ModelWeights? {
        guard let model, model != syntheticModel else { return nil }
        for entry in table where model.hasPrefix(entry.prefix) {
            return entry.weights
        }
        if reportedUnknown.insert(model).inserted {
            Log.warn("незнакомая модель «\(model)», считаю по весам Sonnet")
        }
        return sonnet
    }
}

// MARK: - Строка транскрипта

/// Ровно те поля, которые нужны для расчёта. Всё остальное в файле
/// игнорируется, незнакомые ключи не ломают разбор.
struct TranscriptLine: Decodable {
    let uuid: String?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }
    }

    struct CacheCreation: Decodable {
        let ephemeral5m: Int?
        let ephemeral1h: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens"
            case ephemeral1h = "ephemeral_1h_input_tokens"
        }
    }

    /// Условная стоимость сообщения в долларах; nil — строка без расхода.
    func cost() -> Double? {
        guard let usage = message?.usage,
              let weights = ModelPricing.weights(for: message?.model)
        else { return nil }

        let input = Double(usage.inputTokens ?? 0)
        let output = Double(usage.outputTokens ?? 0)
        let read = Double(usage.cacheReadInputTokens ?? 0)

        // Разбивка по TTL есть не всегда: без неё всю запись считаем
        // пятиминутной — это дешевле, чем приписать лишнее.
        let write5m: Double
        let write1h: Double
        if let creation = usage.cacheCreation,
           creation.ephemeral5m != nil || creation.ephemeral1h != nil {
            write5m = Double(creation.ephemeral5m ?? 0)
            write1h = Double(creation.ephemeral1h ?? 0)
        } else {
            write5m = Double(usage.cacheCreationInputTokens ?? 0)
            write1h = 0
        }

        let total = input * weights.input
            + output * weights.output
            + write5m * weights.cacheWrite5m
            + write1h * weights.cacheWrite1h
            + read * weights.cacheRead
        return total > 0 ? total / 1_000_000 : nil
    }
}

// MARK: - Результат обхода

public struct LocalUsage: Sendable {
    /// Условная стоимость недели в долларах.
    public let totalCost: Double
    /// Стоимость по суткам окна; nil — сутки ещё не наступили.
    public let costByDay: [Double?]
    public let recordCount: Int
    public let duplicatesSkipped: Int
    public let filesRead: Int
    public let window: WeekWindow
}

// MARK: - Провайдер

/// Считает расход по локальным транскриптам. Работает офлайн, результат —
/// оценка: веса моделей приближают реальную формулу лимита.
public actor LocalProvider: UsageProvider {
    nonisolated public let kind: SourceKind = .local

    /// Сколько времени держим записи в индексе: с запасом на неделю окна,
    /// чтобы пересчёт после сброса не требовал полного перечитывания.
    static let retention: TimeInterval = 10 * 86_400

    private let config: Config
    private let root: URL
    private let indexURL: URL
    private let clock: @Sendable () -> Date

    public init(
        config: Config,
        root: URL = LocalProvider.defaultRoot,
        indexURL: URL = Store.indexURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.root = root
        self.indexURL = indexURL
        self.clock = clock
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func fetch() async throws -> UsageSnapshot {
        let now = clock()
        let window = WeekWindow(containing: now, config: config)
        let usage = try scan(window: window, now: now)
        let budget = try budget(for: usage)

        var running = 0.0
        let cumulative: [Double?] = usage.costByDay.map { cost in
            guard let cost else { return nil }
            running += cost
            return running / budget * 100
        }

        return UsageSnapshot.make(
            usedPercent: usage.totalCost / budget * 100,
            cumulativeByDay: cumulative,
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
    }

    /// Бюджет из конфига, а если его нет — пересчитанный по одному
    /// наблюдению официального процента.
    public func budget(for usage: LocalUsage) throws -> Double {
        if config.weeklyBudget > 0 { return config.weeklyBudget }
        guard let observed = config.calibration.observedPercent, observed > 0,
              let at = config.calibration.at
        else { throw UsageError.notCalibrated }

        let calibrationWindow = WeekWindow(containing: at, config: config)
        let spent = try scan(window: calibrationWindow, now: at).totalCost
        guard spent > 0 else { throw UsageError.notCalibrated }
        return spent / (observed / 100)
    }

    // MARK: Обход транскриптов

    public func scan(window: WeekWindow, now: Date) throws -> LocalUsage {
        var index = Store.loadIndex(from: indexURL)
        let cutoff = now.addingTimeInterval(-LocalProvider.retention)
        var seenPaths: Set<String> = []
        var filesRead = 0

        for url in transcriptFiles() {
            let path = url.path
            seenPaths.insert(path)
            guard let stat = try? fileStat(url) else { continue }

            // Файл, дописанный раньше начала окна, целиком вне интереса.
            if stat.mtime < min(window.start, cutoff) {
                index.files[path] = nil
                seenPaths.remove(path)
                continue
            }

            let known = index.files[path]
            if let known, known.inode == stat.inode, known.size == stat.size, known.mtime == stat.mtime {
                continue
            }

            // Смена inode или уменьшившийся размер — файл пересоздали,
            // читаем целиком.
            let sameFile = known?.inode == stat.inode && (known?.offset ?? 0) <= stat.size
            let startOffset = sameFile ? (known?.offset ?? 0) : 0
            var records = sameFile ? (known?.records ?? []) : []

            let (parsed, consumed) = try parse(url: url, from: startOffset)
            records.append(contentsOf: parsed)
            records.removeAll { $0.timestamp < cutoff }
            filesRead += 1

            index.files[path] = FileIndexEntry(
                inode: stat.inode,
                size: stat.size,
                mtime: stat.mtime,
                offset: startOffset + consumed,
                records: records
            )
        }

        // Пропавшие файлы из индекса убираем, иначе он растёт вечно.
        index.files = index.files.filter { seenPaths.contains($0.key) }

        do {
            try Store.saveIndex(index, to: indexURL)
        } catch {
            Log.warn("не сохранил индекс: \(error)")
        }

        return aggregate(index: index, window: window, now: now, filesRead: filesRead)
    }

    private func aggregate(
        index: UsageIndex,
        window: WeekWindow,
        now: Date,
        filesRead: Int
    ) -> LocalUsage {
        var seen: Set<String> = []
        var duplicates = 0
        var perDay = [Double](repeating: 0, count: WeekWindow.daysInWeek)
        var total = 0.0
        var counted = 0

        for entry in index.files.values {
            for record in entry.records {
                guard seen.insert(record.uuid).inserted else {
                    duplicates += 1
                    continue
                }
                // Записи позже `now` бывают при калибровке: она смотрит
                // на прошлый момент, а индекс уже знает про более свежие.
                guard record.timestamp <= now,
                      let day = window.dayIndex(for: record.timestamp)
                else { continue }
                perDay[day] += record.cost
                total += record.cost
                counted += 1
            }
        }

        let costByDay: [Double?] = (0..<WeekWindow.daysInWeek).map { day in
            window.dayStart(day) > now ? nil : perDay[day]
        }

        return LocalUsage(
            totalCost: total,
            costByDay: costByDay,
            recordCount: counted,
            duplicatesSkipped: duplicates,
            filesRead: filesRead,
            window: window
        )
    }

    // MARK: Файлы

    private func transcriptFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Log.warn("не нашёл каталог транскриптов \(root.path)")
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private struct FileStat {
        let inode: UInt64
        let size: UInt64
        let mtime: Date
    }

    private func fileStat(_ url: URL) throws -> FileStat {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        return FileStat(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            // Индекс хранит время в ISO 8601, а он режет доли секунды.
            // Без усечения сравнение с сохранённым mtime не совпадает никогда,
            // и инкрементальное чтение вырождается в полное.
            mtime: Date(timeIntervalSinceReferenceDate: mtime.timeIntervalSinceReferenceDate.rounded(.down))
        )
    }

    /// Читает хвост файла и возвращает разобранные записи вместе с числом
    /// полностью обработанных байт. Незавершённая последняя строка остаётся
    /// на следующий раз — файл могли поймать в момент записи.
    private func parse(url: URL, from offset: UInt64) throws -> ([UsageRecord], UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }
        guard let data = try handle.readToEnd(), !data.isEmpty else { return ([], 0) }

        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let complete = data[data.startIndex...lastNewline]
        let consumed = UInt64(complete.count)

        var records: [UsageRecord] = []
        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let record = record(from: Data(line)) else { continue }
            records.append(record)
        }
        return (records, consumed)
    }

    private func record(from line: Data) -> UsageRecord? {
        guard let parsed = try? JSONDecoder().decode(TranscriptLine.self, from: line) else {
            // Битая строка в середине файла — пропускаем, остальное считаем.
            return nil
        }
        guard let uuid = parsed.uuid,
              let stamp = parsed.timestamp,
              let date = LocalProvider.parseTimestamp(stamp),
              let cost = parsed.cost()
        else { return nil }
        return UsageRecord(uuid: uuid, timestamp: date, cost: cost)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        if let date = fractionalFormatter.date(from: text) { return date }
        return plainFormatter.date(from: text)
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
