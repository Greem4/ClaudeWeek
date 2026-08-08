import Foundation
import CryptoKit

/// Ставит выпуск, найденный `Updater`: качает образ, сверяет сумму, достаёт
/// из него бандл и заменяет им работающий.
///
/// Актор, а не struct с async-методами: внутри `hdiutil` и копирование
/// каталога — секунды блокирующей работы, и делать её на главном акторе
/// значит подвесить строку меню ровно на время установки.
///
/// Порядок шагов выбран так, чтобы неудача на любом из них оставляла
/// работающую версию нетронутой: скачали → сверили → распаковали → и только
/// последним движением подменили бандл.
public actor UpdateInstaller {
    /// Что происходит прямо сейчас — для подписи под кнопкой.
    public enum Stage: Sendable, Equatable {
        case downloading
        case verifying
        case installing

        public var title: String {
            switch self {
            case .downloading: "качаю образ…"
            case .verifying: "сверяю контрольную сумму…"
            case .installing: "ставлю…"
            }
        }
    }

    private let bundle: URL
    private let transport: UsageTransport

    /// `bundle` — приложение, которое заменяем: обычно `Bundle.main.bundleURL`.
    /// Таймаут больше обычного: образ хоть и меньше мегабайта, но качается он
    /// с медленного канала так же, как всё остальное.
    public init(bundle: URL, transport: UsageTransport = URLSessionTransport(timeout: 120)) {
        self.bundle = bundle
        self.transport = transport
    }

    /// Ставит выпуск на место работающего бандла. Возвращает путь, по которому
    /// теперь лежит новая версия, — его же и перезапускать.
    @discardableResult
    public func install(
        _ release: Release,
        progress: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> URL {
        try check(destination: bundle)

        progress(.downloading)
        let image = try await download(release.image)

        progress(.verifying)
        try await verify(image, of: release)

        progress(.installing)
        return try put(image, of: release)
    }

    // MARK: Куда ставим

    /// Отладочный `swift run` обновлять нечего, а на бандл в /Applications
    /// без прав администратора не хватит замаха — и то и другое честнее
    /// сказать до скачивания, а не после.
    private func check(destination: URL) throws {
        guard destination.pathExtension == "app" else { throw UpdateError.notBundled }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(destination.path)
        }
    }

    // MARK: Скачивание и сверка

    private func download(_ url: URL) async throws -> Data {
        let (code, data): (Int, Data)
        do {
            // `browser_download_url` уводит редиректом на хранилище — URLSession
            // ходит по нему сам, отдельного шага на это не нужно.
            (code, data) = try await transport.get(
                url: url,
                headers: [
                    "Accept": "application/octet-stream",
                    "User-Agent": "ClaudeWeek/\(ClaudeWeek.version)",
                ]
            )
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard code == 200 else { throw UpdateError.http(code) }
        guard !data.isEmpty else { throw UpdateError.install("образ скачался пустым") }
        return data
    }

    /// Образ без сверенной суммы не монтируем вовсе. Подписи Developer ID у
    /// сборки нет, Gatekeeper за нас не поручится — SHA256 из релиза остаётся
    /// единственным доказательством, что скачалось именно то, что выложено.
    private func verify(_ image: Data, of release: Release) async throws {
        guard let checksums = release.checksums else {
            throw UpdateError.checksumMissing(release.imageName)
        }
        let (code, listing) = try await downloadChecksums(checksums)
        guard code == 200 else { throw UpdateError.http(code) }
        guard let expected = Updater.checksum(
            for: release.imageName,
            in: String(decoding: listing, as: UTF8.self)
        ) else {
            throw UpdateError.checksumMissing(release.imageName)
        }

        let got = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard got == expected else {
            throw UpdateError.checksumMismatch(expected: expected, got: got)
        }
    }

    private func downloadChecksums(_ url: URL) async throws -> (Int, Data) {
        do {
            return try await transport.get(
                url: url,
                headers: [
                    "Accept": "text/plain",
                    "User-Agent": "ClaudeWeek/\(ClaudeWeek.version)",
                ]
            )
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }

    // MARK: Установка

    private func put(_ image: Data, of release: Release) throws -> URL {
        let manager = FileManager.default
        let work = manager.temporaryDirectory
            .appendingPathComponent("claude-week-update-\(UUID().uuidString)", isDirectory: true)
        // Промежуточную копию кладём рядом с целевым бандлом, а не во временный
        // каталог: `replaceItemAt` подменяет каталог одним движением только в
        // пределах тома, а /tmp у macOS — том отдельный.
        let staging = bundle.deletingLastPathComponent()
            .appendingPathComponent(".ClaudeWeek-update-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? manager.removeItem(at: work)
            try? manager.removeItem(at: staging)
        }

        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let dmg = work.appendingPathComponent(release.imageName)
        try image.write(to: dmg, options: .atomic)

        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try mountImage(dmg, at: mount)
        defer { detach(mount) }

        guard let source = try appBundle(in: mount) else {
            throw UpdateError.install("в образе нет ClaudeWeek.app")
        }

        let staged = staging.appendingPathComponent(source.lastPathComponent)
        try manager.copyItem(at: source, to: staged)
        try accept(staged, expecting: release.version)

        // Единственное необратимое движение за всю установку — и оно
        // атомарное: либо на месте старый бандл, либо целиком новый.
        _ = try manager.replaceItemAt(bundle, withItemAt: staged)
        Log.info("поставил ClaudeWeek \(release.version) в \(bundle.path)")
        return bundle
    }

    private func mountImage(_ dmg: URL, at mount: URL) throws {
        // -nobrowse: том не мелькает в Finder и на рабочем столе;
        // -readonly: своими руками мы в нём ничего не меняем.
        let result = Self.run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-mountpoint", mount.path,
            "-nobrowse", "-readonly", "-noverify", "-quiet",
        ])
        guard result.code == 0 else {
            throw UpdateError.install("hdiutil attach: \(result.output)")
        }
    }

    private func detach(_ mount: URL) {
        let result = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        guard result.code != 0 else { return }
        // Том иногда занят на секунду дольше, чем нужно нам; оставлять его
        // висеть нельзя — при следующей установке он помешает.
        _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
    }

    private func appBundle(in mount: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return contents.first { $0.pathExtension == "app" }
    }

    /// Три вещи, которые обязаны сойтись до подмены: карантин снят, подпись
    /// цела, версия внутри та самая, о которой говорил релиз. Последнее —
    /// та же сверка, что делает release.yml на выпуске: образ, чья цифра
    /// разошлась с тегом, хуже отсутствующего обновления.
    private func accept(_ app: URL, expecting version: Version) throws {
        // Скачанное из сети macOS метит карантином, и приложение с ним
        // Gatekeeper встретит вопросом при каждом запуске.
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        let signature = Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        guard signature.code == 0 else {
            throw UpdateError.install("подпись образа не сошлась: \(signature.output)")
        }

        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let raw = info["CFBundleShortVersionString"] as? String,
              let inside = Version(raw)
        else {
            throw UpdateError.install("в образе не читается версия")
        }
        guard inside == version else {
            throw UpdateError.install("в образе версия \(inside), а релиз обещал \(version)")
        }
    }

    /// Запускает утилиту и отдаёт код возврата с выводом. Вывод нужен целиком:
    /// он идёт человеку в текст ошибки, и «не получилось» без причины
    /// разбирать потом будет нечем.
    private static func run(_ tool: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(tool) не запустился: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
