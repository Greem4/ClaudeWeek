import Foundation

/// Одно ассистентское сообщение: сколько оно стоило и когда случилось.
/// `uuid` нужен для дедупликации — записи попадают и в основной транскрипт,
/// и в `subagents/*.jsonl` (проверено: 373 дубля на 13 508 записей).
public struct UsageRecord: Codable, Sendable, Equatable {
    public let uuid: String
    public let timestamp: Date
    public let cost: Double

    public init(uuid: String, timestamp: Date, cost: Double) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.cost = cost
    }
}

/// Состояние одного файла транскрипта: по нему решаем, читать хвост,
/// перечитывать целиком или не трогать вовсе.
public struct FileIndexEntry: Codable, Sendable, Equatable {
    public var inode: UInt64
    public var size: UInt64
    public var mtime: Date
    /// Сколько байт уже разобрано.
    public var offset: UInt64
    public var records: [UsageRecord]

    public init(inode: UInt64, size: UInt64, mtime: Date, offset: UInt64, records: [UsageRecord]) {
        self.inode = inode
        self.size = size
        self.mtime = mtime
        self.offset = offset
        self.records = records
    }
}

public struct UsageIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var files: [String: FileIndexEntry]

    public init(version: Int = UsageIndex.currentVersion, files: [String: FileIndexEntry] = [:]) {
        self.version = version
        self.files = files
    }
}

/// Снимок официального процента: показываем его мгновенно при старте,
/// пока не пришёл свежий ответ.
public struct CachedUsage: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var byDay: [Double?]
    public var windowStart: Date
    public var windowEnd: Date
    public var source: SourceKind
    public var fetchedAt: Date
    /// Бюджет недели, подобранный по официальному проценту: сколько условных
    /// долларов соответствует 100 %. Держим здесь, а не в `config.json`, —
    /// приложению не место в пользовательском конфиге без спроса.
    public var weeklyBudget: Double?
    /// Последний момент сброса, названный сервером. Живёт отдельно от
    /// `windowEnd`, потому что кеш перезаписывается и локальными снимками —
    /// а их окно построено по конфигу и настоящего сброса не знает.
    public var officialWindowEnd: Date?

    public init(
        usedPercent: Double,
        byDay: [Double?],
        windowStart: Date,
        windowEnd: Date,
        source: SourceKind,
        fetchedAt: Date,
        weeklyBudget: Double? = nil,
        officialWindowEnd: Date? = nil
    ) {
        self.usedPercent = usedPercent
        self.byDay = byDay
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.source = source
        self.fetchedAt = fetchedAt
        self.weeklyBudget = weeklyBudget
        self.officialWindowEnd = officialWindowEnd
    }
}

/// Файлы состояния в `~/.config/claude-week/`. Битый файл — не повод падать:
/// индекс отстроится заново, кеш просто окажется пустым.
public enum Store {
    public static var directory: URL { ConfigStore.directory }
    public static var indexURL: URL { directory.appendingPathComponent("index.json") }
    public static var cacheURL: URL { directory.appendingPathComponent("cache.json") }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func loadIndex(from url: URL = Store.indexURL) -> UsageIndex {
        guard let data = try? Data(contentsOf: url) else { return UsageIndex() }
        do {
            let index = try decoder().decode(UsageIndex.self, from: data)
            guard index.version == UsageIndex.currentVersion else {
                Log.info("индекс версии \(index.version) не подходит, строю заново")
                return UsageIndex()
            }
            return index
        } catch {
            Log.warn("не разобрал индекс \(url.path): \(error). Строю заново")
            return UsageIndex()
        }
    }

    public static func saveIndex(_ index: UsageIndex, to url: URL = Store.indexURL) throws {
        try write(encoder().encode(index), to: url)
    }

    public static func loadCache(from url: URL = Store.cacheURL) -> CachedUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder().decode(CachedUsage.self, from: data)
        } catch {
            Log.warn("не разобрал кеш \(url.path): \(error)")
            return nil
        }
    }

    public static func saveCache(_ cache: CachedUsage, to url: URL = Store.cacheURL) throws {
        try write(encoder().encode(cache), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
