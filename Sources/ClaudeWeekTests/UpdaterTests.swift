import Foundation
import ClaudeWeekCore

/// Отдаёт заготовленный ответ и запоминает, о чём его спросили.
private actor FakeGitHub: UsageTransport {
    private let code: Int
    private let body: Data
    private let failure: Error?
    private(set) var seenHeaders: [String: String] = [:]

    init(code: Int = 200, body: String = "", failure: Error? = nil) {
        self.code = code
        self.body = Data(body.utf8)
        self.failure = failure
    }

    func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
        seenHeaders = headers
        if let failure { throw failure }
        return (code, body)
    }

    func headers() -> [String: String] { seenHeaders }
}

/// Ответ `GET /repos/Greem4/ClaudeWeek/releases/latest` в том виде, в каком его
/// отдаёт GitHub (проверено на v0.1.2), — лишние ключи оставлены нарочно:
/// разбор обязан их пережить.
private let latestResponse = """
{
  "url": "https://api.github.com/repos/Greem4/ClaudeWeek/releases/1",
  "html_url": "https://github.com/Greem4/ClaudeWeek/releases/tag/v0.1.2",
  "id": 1,
  "tag_name": "v0.1.2",
  "target_commitish": "main",
  "name": "ClaudeWeek 0.1.2",
  "draft": false,
  "prerelease": false,
  "created_at": "2026-08-07T19:18:02Z",
  "published_at": "2026-08-07T19:21:10Z",
  "assets": [
    {
      "name": "ClaudeWeek-0.1.2-arm64.dmg",
      "size": 672069,
      "content_type": "application/x-apple-diskimage",
      "browser_download_url": "https://github.com/Greem4/ClaudeWeek/releases/download/v0.1.2/ClaudeWeek-0.1.2-arm64.dmg"
    },
    {
      "name": "SHA256SUMS.txt",
      "size": 93,
      "content_type": "text/plain",
      "browser_download_url": "https://github.com/Greem4/ClaudeWeek/releases/download/v0.1.2/SHA256SUMS.txt"
    }
  ],
  "body": "## Установка\\n\\nСкачайте образ."
}
"""

func runUpdaterTests(_ t: Harness) async {
    t.suite("версия: разбор") {
        t.check(Version("0.1.3") == Version(0, 1, 3), "три числа")
        t.check(Version("v0.1.3") == Version(0, 1, 3), "ведущая v из тега")
        t.check(Version("1") == Version(1, 0, 0), "недостающие части — нули")
        t.check(Version("1.2") == Version(1, 2, 0), "две части тоже читаются")
        t.check(Version("0.2.0-rc1") == Version(0, 2, 0), "предвыпуск — та же версия")
        t.check(Version("") == nil, "пустая строка — не версия")
        t.check(Version("латиница") == nil, "мусор — не версия")
        t.check(Version("0.1.2.3") == nil, "четыре части — не версия")
        t.check(Version("-1.0.0") == nil, "отрицательных версий не бывает")
    }

    t.suite("версия: сравнение") {
        // Ровно та ошибка, ради которой версия не строка: посимвольно
        // «0.1.10» меньше «0.1.9».
        t.check(Version(0, 1, 9) < Version(0, 1, 10), "десятая новее девятой")
        t.check(Version(0, 2, 0) > Version(0, 1, 99), "минор важнее патча")
        t.check(Version(1, 0, 0) > Version(0, 99, 99), "мажор важнее всего")
        t.check(!(Version(0, 1, 3) > Version(0, 1, 3)), "равные версии не новее друг друга")
    }

    t.suite("релиз: разбор ответа") {
        do {
            let release = try Updater.release(from: Data(latestResponse.utf8), architecture: "arm64")
            t.check(release.version == Version(0, 1, 2), "версия из тега")
            t.equal(release.tag, "v0.1.2", "тег как есть — им подписан релиз")
            t.equal(release.imageName, "ClaudeWeek-0.1.2-arm64.dmg", "образ под свою архитектуру")
            t.check(release.checksums != nil, "нашёлся файл контрольных сумм")
            t.check(release.page.absoluteString.hasSuffix("/tag/v0.1.2"), "страница релиза")
            t.check(release.publishedAt != nil, "дата выпуска разобралась")
        } catch {
            t.fail("разбор живого ответа бросил \(error)")
        }
    }

    t.suite("релиз: нет образа под архитектуру") {
        // Intel-образов проект не выпускает — под x86_64 честная ошибка
        // с советом собрать из исходников, а не молчаливое «обновлений нет».
        do {
            _ = try Updater.release(from: Data(latestResponse.utf8), architecture: "x86_64")
            t.fail("образа под x86_64 в релизе нет, а разбор его нашёл")
        } catch let error as UpdateError {
            t.equal(error, UpdateError.noImage("x86_64"), "сказано, какой архитектуры не хватает")
        } catch {
            t.fail("ждали UpdateError, получили \(error)")
        }
    }

    t.suite("контрольные суммы") {
        let sums = """
        1f0c9e2a5c4d3b8e7a6f5d4c3b2a1908172635445362718293a4b5c6d7e8f900  ClaudeWeek-0.1.2-arm64.dmg
        aaaa9e2a5c4d3b8e7a6f5d4c3b2a1908172635445362718293a4b5c6d7e8f9ff *ClaudeWeek-0.1.2-x86_64.dmg
        """
        t.equal(
            Updater.checksum(for: "ClaudeWeek-0.1.2-arm64.dmg", in: sums),
            "1f0c9e2a5c4d3b8e7a6f5d4c3b2a1908172635445362718293a4b5c6d7e8f900",
            "сумма нашлась по имени файла"
        )
        t.equal(
            Updater.checksum(for: "ClaudeWeek-0.1.2-x86_64.dmg", in: sums),
            "aaaa9e2a5c4d3b8e7a6f5d4c3b2a1908172635445362718293a4b5c6d7e8f9ff",
            "звёздочка бинарного режима не мешает"
        )
        t.check(Updater.checksum(for: "чужой.dmg", in: sums) == nil, "чужого файла в списке нет")
        t.check(Updater.checksum(for: "ClaudeWeek-0.1.2-arm64.dmg", in: "") == nil, "пустой файл сумм")
    }

    await t.suite("проверка: есть что новее") {
        let github = FakeGitHub(body: latestResponse)
        let updater = Updater(transport: github, current: Version(0, 1, 1), architecture: "arm64")
        let check = try await updater.check()
        t.check(check.release?.version == Version(0, 1, 2), "0.1.2 новее нашей 0.1.1")

        // Без User-Agent GitHub отвечает 403 — заголовок обязателен.
        let headers = await github.headers()
        t.check(headers["User-Agent"]?.hasPrefix("ClaudeWeek/") == true, "представились")
    }

    await t.suite("проверка: своя версия новее выпущенной") {
        // Сборка из исходников обгоняет последний релиз — предлагать «0.1.2»
        // владельцу 0.1.3 значит звать его на откат.
        let updater = Updater(
            transport: FakeGitHub(body: latestResponse),
            current: Version(0, 1, 3),
            architecture: "arm64"
        )
        t.equal(try await updater.check(), UpdateCheck.upToDate, "обновляться некуда")
    }

    await t.suite("проверка: та же версия") {
        let updater = Updater(
            transport: FakeGitHub(body: latestResponse),
            current: Version(0, 1, 2),
            architecture: "arm64"
        )
        t.equal(try await updater.check(), UpdateCheck.upToDate, "равная версия — не обновление")
    }

    await t.suite("проверка: GitHub отказал") {
        let updater = Updater(
            transport: FakeGitHub(code: 403, body: "{}"),
            current: Version(0, 1, 0),
            architecture: "arm64"
        )
        do {
            _ = try await updater.check()
            t.fail("403 прошёл как удачная проверка")
        } catch let error as UpdateError {
            t.equal(error, UpdateError.http(403), "код ответа доехал до ошибки")
        } catch {
            t.fail("ждали UpdateError, получили \(error)")
        }
    }

    await t.suite("установка: запущено не из бандла") {
        // Отладочный `swift run` подменять нечем — и сказать это надо до
        // скачивания, а не после.
        let release = try Updater.release(from: Data(latestResponse.utf8), architecture: "arm64")
        let installer = UpdateInstaller(
            bundle: URL(fileURLWithPath: "/tmp/ClaudeWeekApp"),
            transport: FakeGitHub()
        )
        do {
            _ = try await installer.install(release)
            t.fail("установка в не-бандл не остановилась")
        } catch let error as UpdateError {
            t.equal(error, UpdateError.notBundled, "отказ назван своим именем")
        }
    }

    await t.suite("установка: некуда писать") {
        let release = try Updater.release(from: Data(latestResponse.utf8), architecture: "arm64")
        // Каталог под защитой системы: прав на запись там нет ни у кого.
        let app = URL(fileURLWithPath: "/System/Library/ClaudeWeek.app")
        let installer = UpdateInstaller(bundle: app, transport: FakeGitHub())
        do {
            _ = try await installer.install(release)
            t.fail("установка без прав на запись не остановилась")
        } catch let error as UpdateError {
            t.equal(error, UpdateError.notWritable(app.path), "в ошибке назван путь")
        }
    }

    t.suite("подпись: разбор find-identity") {
        // Вывод `security find-identity -v -p codesigning` в том виде, в каком
        // он приходит: отступы, нумерация, кавычки вокруг имени.
        let listing = """
          1) 8F19A7106BFAC7B25F11654C2E3994901C3A0724 "ClaudeWeek Signing"
          2) 1AF3C2D4E5B6978012345678901234567890ABCD "Apple Development: кто-то (TEAMID)"
             2 valid identities found
        """
        t.equal(
            UpdateInstaller.identity(named: "ClaudeWeek Signing", in: listing),
            "8F19A7106BFAC7B25F11654C2E3994901C3A0724",
            "хеш взят у нужного сертификата, а не у первой строки"
        )
        t.equal(
            UpdateInstaller.identity(named: "ClaudeWeek Signing", in: "     0 valid identities found"),
            nil,
            "пустая связка — nil, а не пустая строка"
        )
        // Формат вывода — не контракт: сместится колонка, и подписывать надо
        // не тем, что оказалось вторым словом, а ничем.
        t.equal(
            UpdateInstaller.identity(named: "ClaudeWeek Signing", in: "  1) короткий \"ClaudeWeek Signing\""),
            nil,
            "на месте хеша не хеш — не подписываем"
        )
    }

    await t.suite("проверка: сети нет") {
        let updater = Updater(
            transport: FakeGitHub(failure: URLError(.notConnectedToInternet)),
            current: Version(0, 1, 0),
            architecture: "arm64"
        )
        do {
            _ = try await updater.check()
            t.fail("без сети проверка не могла удаться")
        } catch is UpdateError {
            t.check(true, "ошибка сети завёрнута в UpdateError")
        } catch {
            t.fail("ждали UpdateError, получили \(error)")
        }
    }
}
