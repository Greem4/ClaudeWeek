import Foundation

/// Токены одного сообщения, разложенные по видам: стоят они по-разному, и
/// складывать их в одно число нельзя — запись кеша дороже входа, чтение
/// вдесятеро дешевле.
public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    /// Ключи однобуквенные: индекс держит десятки тысяч записей (13 508 за
    /// неделю на этой машине), и полные имена стоили бы там мегабайта на
    /// ровном месте. Читаемость файла отдана размеру осознанно — снаружи с
    /// этими полями всё равно работают через свойства.
    enum CodingKeys: String, CodingKey {
        case input = "i"
        case output = "o"
        case cacheWrite = "w"
        case cacheRead = "r"
    }

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

/// Одно ассистентское сообщение: сколько оно стоило и когда случилось.
/// `uuid` нужен для дедупликации — записи попадают и в основной транскрипт,
/// и в `subagents/*.jsonl` (проверено: 373 дубля на 13 508 записей).
public struct UsageRecord: Codable, Sendable, Equatable {
    public let uuid: String
    public let timestamp: Date
    public let cost: Double
    /// Семейство модели — `opus`, `sonnet`, `haiku`. Именно семейство, а не
    /// полное имя: по нему заданы веса, по нему же считает лимиты Anthropic,
    /// и разбивку в окне человек читает теми же словами.
    public let model: String
    public let tokens: TokenCounts

    /// Те же однобуквенные ключи и по той же причине, что у `TokenCounts`.
    enum CodingKeys: String, CodingKey {
        case uuid, timestamp, cost
        case model = "m"
        case tokens = "t"
    }

    public init(
        uuid: String,
        timestamp: Date,
        cost: Double,
        model: String = ModelFamily.unknown,
        tokens: TokenCounts = TokenCounts()
    ) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.cost = cost
        self.model = model
        self.tokens = tokens
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
    /// 2 — записи знают модель и токены. Версия 1 их не хранила, и разбивка по
    /// моделям из неё не восстанавливается: индекс отбрасывается целиком и
    /// отстраивается по транскриптам за один проход.
    public static let currentVersion = 2

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
    /// Пятичасовая сессия из последнего официального ответа. Хранится вместе
    /// со своим `resetsAt`, так что при чтении видно, не истекла ли она.
    public var session: SessionUsage?

    public init(
        usedPercent: Double,
        byDay: [Double?],
        windowStart: Date,
        windowEnd: Date,
        source: SourceKind,
        fetchedAt: Date,
        weeklyBudget: Double? = nil,
        officialWindowEnd: Date? = nil,
        session: SessionUsage? = nil
    ) {
        self.usedPercent = usedPercent
        self.byDay = byDay
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.source = source
        self.fetchedAt = fetchedAt
        self.weeklyBudget = weeklyBudget
        self.officialWindowEnd = officialWindowEnd
        self.session = session
    }
}

/// Файлы состояния в `~/.config/claude-week/`. Битый файл — не повод падать:
/// индекс отстроится заново, кеш просто окажется пустым.
public enum Store {
    public static var directory: URL { ConfigStore.directory }
    public static var indexURL: URL { directory.appendingPathComponent("index.json") }
    public static var cacheURL: URL { directory.appendingPathComponent("cache.json") }
    /// Что уже сказано уведомлениями. Отдельно от кеша: тот перезаписывается
    /// каждым обновлением и целиком описывает расход, а это — память о
    /// разговоре с человеком, и терять её вместе с протухшим снимком нельзя.
    public static var alertsURL: URL { directory.appendingPathComponent("alerts.json") }

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

    /// Только номер схемы — чтобы спросить его до разбора самих записей.
    private struct IndexVersion: Decodable {
        let version: Int
    }

    public static func loadIndex(from url: URL = Store.indexURL) -> UsageIndex {
        guard let data = try? Data(contentsOf: url) else { return UsageIndex() }
        // Версию читаем первой и отдельно: у прошлой схемы записи другой формы,
        // и целиком такой файл не разбирается вовсе. Без этой проверки штатная
        // смена схемы выглядела бы в логе испорченным файлом.
        if let stamp = try? decoder().decode(IndexVersion.self, from: data),
           stamp.version != UsageIndex.currentVersion {
            Log.info("индекс версии \(stamp.version) не подходит, строю заново")
            return UsageIndex()
        }
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

    /// Битый или отсутствующий файл — пустой лог: худшее, что случится, это
    /// одно повторное уведомление о пороге, который уже проходили. Молчать
    /// из-за нечитаемого файла было бы хуже.
    public static func loadAlerts(from url: URL = Store.alertsURL) -> AlertLog {
        guard let data = try? Data(contentsOf: url) else { return AlertLog() }
        do {
            return try decoder().decode(AlertLog.self, from: data)
        } catch {
            Log.warn("не разобрал \(url.path): \(error). Начинаю уведомления заново")
            return AlertLog()
        }
    }

    public static func saveAlerts(_ log: AlertLog, to url: URL = Store.alertsURL) throws {
        try write(encoder().encode(log), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
