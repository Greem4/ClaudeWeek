import Foundation
import ClaudeWeekCore

func runAccountTests(_ t: Harness) {
    t.suite("пути аккаунта") {
        var config = Config.default
        config.accounts = AccountsConfig(primaryHome: "~/.claude", secondaryHome: "~/.claude-b")

        let primary = AccountLocation(account: .primary, config: config)
        let secondary = AccountLocation(account: .secondary, config: config)

        t.equal(primary.home.path, NSHomeDirectory() + "/.claude", "тильда первого дома раскрыта")
        t.equal(secondary.home.path, NSHomeDirectory() + "/.claude-b", "тильда второго дома раскрыта")
        t.equal(
            primary.projectsRoot.path,
            NSHomeDirectory() + "/.claude/projects",
            "транскрипты первого аккаунта"
        )
        t.equal(
            secondary.projectsRoot.path,
            NSHomeDirectory() + "/.claude-b/projects",
            "транскрипты второго аккаунта берутся из его дома, а не из общего"
        )

        // Первый аккаунт обязан сохранить прежние имена файлов: у работающей
        // установки в них лежит накопленный счёт, и переезд обнулил бы его.
        t.equal(primary.cacheURL.lastPathComponent, "cache.json", "кеш первого аккаунта не переименован")
        t.equal(primary.alertsURL.lastPathComponent, "alerts.json", "журнал первого не переименован")
        t.equal(primary.countingStateURL.lastPathComponent, "state.json", "счёт первого не переименован")
        t.equal(primary.indexURL.lastPathComponent, "index.json", "индекс первого не переименован")

        t.equal(secondary.cacheURL.lastPathComponent, "secondary-cache.json", "кеш второго отдельный")
        t.equal(secondary.alertsURL.lastPathComponent, "secondary-alerts.json", "журнал второго отдельный")
        t.equal(secondary.countingStateURL.lastPathComponent, "secondary-state.json", "счёт второго отдельный")
        t.equal(secondary.indexURL.lastPathComponent, "secondary-index.json", "индекс второго отдельный")

        t.check(primary.cacheURL != secondary.cacheURL, "снимки аккаунтов не в одном файле")
        t.check(
            primary.credentialsFileURL != secondary.credentialsFileURL,
            "запасной файл кредов у каждого аккаунта свой"
        )

        // Стандартный дом надо уметь отличать: про него `claude auth status`
        // спрашивают БЕЗ CLAUDE_CONFIG_DIR. С переменной, выставленной в тот
        // же самый путь, он отвечает «не вошли» — ячейку учётных данных
        // выбирает не путь, а факт установки переменной (проверено на 2.1.251).
        t.check(primary.isDefaultHome, "~/.claude опознан как стандартный дом")
        t.check(!secondary.isDefaultHome, "~/.claude-b стандартным не считается")
        t.equal(
            AccountLocation.defaultHome.path,
            NSHomeDirectory() + "/.claude",
            "стандартный дом — тот, что Claude Code берёт сам"
        )
        // Путь с хвостовым слешем — тот же дом: сравнение идёт по
        // приведённому виду, иначе запись в конфиге решала бы, вошли мы или нет.
        let slashed = AccountLocation(account: .primary, home: AccountLocation.expand("~/.claude/"))
        t.check(slashed.isDefaultHome, "хвостовой слеш не делает дом нестандартным")

        // Пустой путь не должен превращаться в каталог с именем «~» или в
        // корень: такой дом просто не существует, и переключатель не покажем.
        let empty = AccountLocation(account: .secondary, home: AccountLocation.expand("  "))
        t.equal(empty.home.path, NSHomeDirectory(), "пустой путь сводится к домашнему каталогу")
    }

    t.suite("состояние аккаунта") {
        let signedIn = Data("""
        {"loggedIn": true, "authMethod": "claude.ai", "email": "kto@to.ru",
         "orgId": "2a420a73-2872-4640-a99e-ed027d474338", "subscriptionType": "pro"}
        """.utf8)
        let status = AccountDirectory.parse(signedIn)
        t.check(status.loggedIn, "вход распознан")
        t.equal(status.email, "kto@to.ru", "адрес разобран")
        t.equal(status.organizationId, "2a420a73-2872-4640-a99e-ed027d474338", "организация разобрана")
        t.equal(status.title(fallback: "Второй"), "kto@to.ru", "подписью служит адрес")

        let signedOut = AccountDirectory.parse(Data(#"{"loggedIn": false, "authMethod": "none"}"#.utf8))
        t.check(!signedOut.loggedIn, "выход распознан")
        t.equal(signedOut.organizationId, nil, "у вышедшего нет организации")
        t.equal(signedOut.title(fallback: "Второй"), "Второй", "без адреса подпись порядковая")

        // Мусор вместо ответа не должен читаться как удачный вход: иначе
        // второй аккаунт пошёл бы искать запись Keychain с организацией nil.
        t.check(!AccountDirectory.parse(Data("не json".utf8)).loggedIn, "мусор — не вход")
        t.check(!AccountDirectory.parse(Data()).loggedIn, "пустой ответ — не вход")

        // Тариф выручает, когда адреса в ответе не оказалось.
        let noEmail = AccountDirectory.parse(Data(#"{"loggedIn": true, "subscriptionType": "max"}"#.utf8))
        t.equal(noEmail.title(fallback: "Второй"), "max", "без адреса подписью служит тариф")
    }

    t.suite("поиск записи Keychain") {
        // Форма вывода `security dump-keychain`: имя сервиса среди прочих
        // атрибутов. Берём только записи Claude Code — в связке пользователя
        // лежат сотни чужих.
        let dump = """
            "svce"<blob>="Claude Code-credentials"
            "acct"<blob>="greem4"
            "svce"<blob>="Claude Safe Storage"
            "svce"<blob>="GitHub-credentials"
            "svce"<blob>="Claude Code-a1b2c3-credentials"
            "svce"<blob>="Claude Code-credentials"
        """
        let found = ResolvedKeychainCredentials.services(in: dump)
        t.equal(found.count, 2, "нашлись обе записи Claude Code и ни одной лишней")
        t.check(found.contains("Claude Code-credentials"), "запись первого аккаунта найдена")
        t.check(found.contains("Claude Code-a1b2c3-credentials"), "запись второго аккаунта найдена")
        t.check(!found.contains("Claude Safe Storage"), "запись без -credentials отброшена")
        t.check(!found.contains("GitHub-credentials"), "чужая запись отброшена")
        t.equal(ResolvedKeychainCredentials.services(in: "").count, 0, "пустой вывод — пустой список")
    }

    t.suite("креды аккаунта") {
        var config = Config.default
        config.accounts = AccountsConfig(primaryHome: "~/.claude", secondaryHome: "~/.claude-b")

        // Второй аккаунт без входа обязан отдавать «нет авторизации», а не
        // молча читать запись первого: иначе панель показала бы чужие цифры
        // под его именем — худшее из возможных поведений.
        let signedOut = ResolvingProvider.credentials(
            for: .secondary,
            config: config,
            status: .signedOut
        )
        var refused = false
        do {
            _ = try signedOut.load()
        } catch {
            refused = true
        }
        t.check(refused, "невошедший второй аккаунт не отдаёт чужой токен")
        t.check(signedOut is SignedOutCredentials, "и делает это явным типом, а не nil")

        let signedIn = ResolvingProvider.credentials(
            for: .secondary,
            config: config,
            status: AccountStatus(loggedIn: true, organizationId: "org-2")
        )
        t.check(signedIn is ResolvedKeychainCredentials, "вошедший второй ищет свою запись по организации")

        let primary = ResolvingProvider.credentials(
            for: .primary,
            config: config,
            status: .signedOut
        )
        t.check(primary is KeychainCredentials, "первый аккаунт читает запись с известным именем")
    }

    t.suite("аккаунт в конфиге") {
        // Конфиг без новых ключей — обычный случай при обновлении: аккаунт
        // должен оказаться первым, а дома — стандартными.
        let old = Data(#"{"resetHour": 16, "provider": "auto"}"#.utf8)
        let decoded = try JSONDecoder().decode(Config.self, from: old)
        t.equal(decoded.activeAccount, .primary, "старый конфиг открывается на первом аккаунте")
        t.equal(decoded.accounts.primaryHome, "~/.claude", "дом первого по умолчанию")
        t.equal(decoded.accounts.secondaryHome, "~/.claude-b", "дом второго по умолчанию")

        // Сборка с Codex писала сюда `claude`, и такие файлы лежат на дисках.
        // Незнакомое значение обязано стоить только самого поля: бросок здесь
        // обрывает разбор всего файла, и человек молча теряет все настройки.
        let fromCodexBuild = Data(#"{"activeAccount": "claude", "resetHour": 9, "weeklyBudget": 42}"#.utf8)
        let survived = try JSONDecoder().decode(Config.self, from: fromCodexBuild)
        t.equal(survived.activeAccount, .primary, "незнакомый аккаунт сводится к первому")
        t.equal(survived.resetHour, 9, "соседние настройки пережили незнакомое значение")
        t.close(survived.weeklyBudget, 42, "бюджет пережил незнакомое значение")

        let brokenHomes = Data(#"{"accounts": "не объект", "resetHour": 7}"#.utf8)
        let repaired = try JSONDecoder().decode(Config.self, from: brokenHomes)
        t.equal(repaired.accounts.primaryHome, "~/.claude", "битые дома сводятся к умолчанию")
        t.equal(repaired.resetHour, 7, "и не уносят с собой остальной конфиг")

        // И обратно: выбранный аккаунт обязан пережить перезапуск.
        var config = Config.default
        config.activeAccount = .secondary
        config.accounts = AccountsConfig(primaryHome: "~/.claude", secondaryHome: "~/.work")
        let roundTrip = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        t.equal(roundTrip.activeAccount, .secondary, "выбранный аккаунт пережил запись и чтение")
        t.equal(roundTrip.accounts.secondaryHome, "~/.work", "дом второго пережил запись и чтение")

        t.equal(config.accounts.home(.primary), "~/.claude", "дом первого берётся по имени аккаунта")
        t.equal(config.accounts.home(.secondary), "~/.work", "дом второго берётся по имени аккаунта")
    }
}
