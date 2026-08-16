import Foundation

/// Номер версии — три числа и ничего больше. Сравниваем именно числами:
/// строкой «0.1.10» меньше «0.1.9», и с девятой версии на десятую обновление
/// никогда бы не предложилось.
public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Терпит ведущую `v`: в git тег пишется `v0.1.3`, а в `Version.swift` и в
    /// `Info.plist` то же число живёт без буквы. Недостающие части — нули,
    /// поэтому «1» и «1.0» читаются как 1.0.0.
    public init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.first == "v" || raw.first == "V" { raw.removeFirst() }
        // Всё после `-` или `+` — предвыпуск и метаданные сборки. Мы их не
        // выпускаем, но встреченный `0.2.0-rc1` должен читаться как 0.2.0,
        // а не отбрасываться целиком.
        raw = String(raw.prefix { $0 != "-" && $0 != "+" })

        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers = [0, 0, 0]
        for (place, part) in parts.enumerated() {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers[place] = number
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// Версия работающей программы.
    public static let current = Version(ClaudeWeek.version) ?? Version(0, 0, 0)

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Выпуск на GitHub — ровно то, что нужно, чтобы поставить его без браузера.
public struct Release: Sendable, Equatable {
    public let version: Version
    /// Имя тега как есть (`v0.1.3`) — им подписан релиз на странице.
    public let tag: String
    /// Страница релиза: её открывает «Что нового».
    public let page: URL
    /// Образ под свою архитектуру.
    public let image: URL
    public let imageName: String
    /// Файл контрольных сумм рядом с образом. Его отсутствие — повод
    /// остановиться: скачанное будет нечем сверить.
    public let checksums: URL?
    public let publishedAt: Date?
    /// Заметки к релизу как их написал workflow — Markdown.
    public let notes: String

    public init(
        version: Version,
        tag: String,
        page: URL,
        image: URL,
        imageName: String,
        checksums: URL?,
        publishedAt: Date?,
        notes: String
    ) {
        self.version = version
        self.tag = tag
        self.page = page
        self.image = image
        self.imageName = imageName
        self.checksums = checksums
        self.publishedAt = publishedAt
        self.notes = notes
    }
}

/// Итог проверки. Отдельный тип, а не `Release?`: «у вас последняя» — это
/// ответ, который окно настроек показывает словами, а не пустотой.
public enum UpdateCheck: Sendable, Equatable {
    case upToDate
    case available(Release)

    public var release: Release? {
        if case .available(let release) = self { return release }
        return nil
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case network(String)
    case http(Int)
    case decoding(String)
    /// В релизе нет образа под эту архитектуру.
    case noImage(String)
    case checksumMissing(String)
    case checksumMismatch(expected: String, got: String)
    /// Запущено не из бандла — обновлять нечего.
    case notBundled
    case notWritable(String)
    case install(String)

    /// Русский текст: он же уходит в лог, который читают при разборе поломки.
    public var errorDescription: String? { message(.ru) }

    /// То же самое на языке интерфейса — для панели и окон, где это читает
    /// не автор, а тот, у кого обновление не встало.
    public func message(_ lang: Lang) -> String {
        let l = L10n(lang)
        switch self {
        case .network(let text):
            return l.pick("не дозвонился до GitHub: \(text)", "could not reach GitHub: \(text)")
        case .http(let code):
            return code == 403 || code == 429
                ? l.pick("GitHub не пустил (\(code)) — слишком часто спрашивали, попробуйте позже",
                         "GitHub turned us away (\(code)) — too many requests, try later")
                : l.pick("GitHub ответил \(code)", "GitHub replied \(code)")
        case .decoding(let text):
            return l.pick("не разобрал ответ GitHub: \(text)", "could not parse GitHub’s reply: \(text)")
        case .noImage(let arch):
            return l.pick("в релизе нет образа под \(arch) — соберите из исходников: ./scripts/install.sh",
                          "the release has no image for \(arch) — build from source: ./scripts/install.sh")
        case .checksumMissing(let name):
            return l.pick("в SHA256SUMS.txt нет строки про \(name)",
                          "SHA256SUMS.txt has no line for \(name)")
        case .checksumMismatch(let expected, let got):
            return l.pick("образ скачался повреждённым: сумма \(got.prefix(12))… вместо \(expected.prefix(12))…",
                          "the image downloaded corrupted: \(got.prefix(12))… instead of \(expected.prefix(12))…")
        case .notBundled:
            return l.pick("обновлять нечего: программа запущена не из ClaudeWeek.app",
                          "nothing to update: the app was not launched from ClaudeWeek.app")
        case .notWritable(let path):
            return l.pick("нет прав переписать \(path) — перетащите новую версию руками",
                          "no permission to overwrite \(path) — drag the new version in by hand")
        case .install(let text):
            return l.pick("не поставил обновление: \(text)", "could not install the update: \(text)")
        }
    }
}

/// Проверка новой версии по GitHub Releases. Скачиванием и установкой
/// занимается `UpdateInstaller` — здесь только вопрос «а есть ли что новее».
public struct Updater: Sendable {
    /// Последний полноценный релиз: черновики и предвыпуски GitHub сюда не
    /// отдаёт, поэтому отсеивать их отдельно не нужно.
    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(ClaudeWeek.repository)/releases/latest")!
    }

    /// Срез, которым исполняется код, а не тот, что стоит в железе: под Rosetta
    /// нам нужен x86_64-образ, хотя процессор при этом arm64.
    public static var architecture: String {
        #if arch(x86_64)
        "x86_64"
        #else
        "arm64"
        #endif
    }

    /// GitHub отвергает запросы без User-Agent — 403 вместо ответа.
    static var headers: [String: String] {
        [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ClaudeWeek/\(ClaudeWeek.version)",
        ]
    }

    /// Тот же GET-транспорт, что у официального источника: в тестах он
    /// подменяется дублёром, и второй такой же протокол заводить незачем.
    private let transport: UsageTransport
    private let current: Version
    private let architecture: String

    public init(
        transport: UsageTransport = URLSessionTransport(),
        current: Version = .current,
        architecture: String = Updater.architecture
    ) {
        self.transport = transport
        self.current = current
        self.architecture = architecture
    }

    public func check() async throws -> UpdateCheck {
        let (code, body): (Int, Data)
        do {
            (code, body) = try await transport.get(url: Updater.latestReleaseURL, headers: Updater.headers)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard code == 200 else { throw UpdateError.http(code) }

        let release = try Updater.release(from: body, architecture: architecture)
        // Строго новее: собранная из исходников версия обгоняет последний
        // релиз (0.1.3 против 0.1.2), и предлагать ей «обновиться» до
        // прошлого выпуска — это откат, а не обновление.
        guard release.version > current else { return .upToDate }
        return .available(release)
    }

    // MARK: Разбор ответа

    private struct Payload: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let publishedAt: Date?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    /// Публичный ради проверок: разбор чужого JSON — первое, что ломается при
    /// смене схемы ответа, и гонять его тестами надо без похода в сеть.
    public static func release(from data: Data, architecture: String) throws -> Release {
        let payload: Payload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw UpdateError.decoding("\(error)")
        }

        guard let version = Version(payload.tagName) else {
            throw UpdateError.decoding("тег «\(payload.tagName)» не похож на версию")
        }
        guard let page = URL(string: payload.htmlUrl) else {
            throw UpdateError.decoding("страница релиза без адреса")
        }

        // Ищем по суффиксу имени, а не собираем его из версии: схема
        // именования образа живёт в make-dmg.sh, и повторять её здесь значит
        // завести второе место, которое обязано меняться синхронно.
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix("-\(architecture).dmg") }),
              let image = URL(string: asset.browserDownloadUrl)
        else {
            throw UpdateError.noImage(architecture)
        }

        let checksums = payload.assets
            .first { $0.name == "SHA256SUMS.txt" }
            .flatMap { URL(string: $0.browserDownloadUrl) }

        return Release(
            version: version,
            tag: payload.tagName,
            page: page,
            image: image,
            imageName: asset.name,
            checksums: checksums,
            publishedAt: payload.publishedAt,
            notes: payload.body ?? ""
        )
    }

    /// Достаёт сумму нужного файла из `SHA256SUMS.txt`. Формат — вывод
    /// `shasum -a 256`: сумма, два пробела, имя файла; у бинарного режима
    /// имя ещё и со звёздочкой.
    public static func checksum(for name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let listed = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            guard listed == name else { continue }
            return String(parts[0]).lowercased()
        }
        return nil
    }
}
