import Foundation
import ClaudeWeekCore

/// Снимок недели с заданным расходом — всё остальное для уведомлений неважно.
private func snapshot(
    week: Double,
    session: SessionUsage? = nil,
    isEstimate: Bool = false,
    at now: Date
) -> UsageSnapshot {
    let c = config()
    return UsageSnapshot.make(
        usedPercent: week,
        cumulativeByDay: [],
        window: WeekWindow(containing: now, config: c),
        source: isEstimate ? .local : .official,
        fetchedAt: now,
        isEstimate: isEstimate,
        session: session
    )
}

func runAlertTests(_ t: Harness) {
    let now = at(2026, 8, 12, 14, 0)

    t.suite("уведомления: пороги") {
        let points = LimitNotifications(first: 80, second: 95)
        t.equal(points.reached(79), nil, "до порога молчим")
        t.equal(points.reached(80), 80, "порог берётся включительно")
        t.equal(points.reached(94), 80, "между порогами — нижний")
        t.equal(points.reached(100), 95, "выше второго — верхний")
        t.equal(LimitNotifications(enabled: false, first: 80, second: 95).reached(99), nil,
                "выключенный лимит не даёт поводов")
        t.equal(LimitNotifications(first: 90, second: 90).points, [90],
                "совпавшие пороги — один, а не два одинаковых баннера")
    }

    t.suite("уведомления: приведение значений") {
        let fixed = LimitNotifications(first: 95, second: 80).validated()
        t.equal(fixed.first, 80, "порядок чинится, а не отвергается")
        t.equal(fixed.second, 95, "второй порог остаётся верхним")
        t.equal(LimitNotifications(first: 0, second: 140).validated().first, 80,
                "ноль процентов — не порог, берём заводской")
        t.equal(LimitNotifications(first: 0, second: 140).validated().second, 95,
                "выше ста тоже не бывает")
    }

    t.suite("уведомления: конфиг") {
        let d = Config.default.notifications
        t.check(d.enabled, "по умолчанию включены")
        t.equal(d.week.first, 80, "первый недельный порог")
        t.equal(d.session.first, 75, "сессия предупреждает раньше недели")

        // Конфиг прошлой версии про уведомления не знает — читаться он должен
        // как обычно, с заводскими значениями вместо недостающих.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-alerts-\(UUID().uuidString).json")
        try? #"{ "notifications": { "week": { "first": 60 } } }"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ConfigStore.load(from: url)
        t.equal(c.notifications.week.first, 60, "своё значение прочиталось")
        t.equal(c.notifications.week.second, 95, "недостающее взято из дефолтов")
        t.check(c.notifications.session.enabled, "сессия осталась включённой")

        // Окно настроек пишет конфиг целиком — пороги обязаны вернуться теми же.
        var edited = Config.default
        edited.notifications = NotificationsConfig(
            enabled: true, sound: false,
            week: LimitNotifications(first: 50, second: 90),
            session: LimitNotifications(enabled: false, first: 70, second: 90)
        )
        try? ConfigStore.save(edited, to: url)
        t.equal(ConfigStore.load(from: url).notifications, edited.notifications,
                "правки уведомлений переживают запись и чтение")
    }

    t.suite("уведомления: один порог — один раз") {
        var log = AlertLog()
        let config = NotificationsConfig()

        let first = AlertPlanner.alerts(
            for: snapshot(week: 82, at: now), config: config, log: &log, now: now
        )
        t.equal(first.count, 1, "порог пробит — один баннер")
        t.equal(first.first?.threshold, 80, "тот, что настроен")
        t.close(first.first?.percent ?? 0, 82, "в тексте живое число, а не порог")

        // Прошло время, расход подрос, но следующий порог ещё не достигнут.
        let later = now.addingTimeInterval(3600)
        let again = AlertPlanner.alerts(
            for: snapshot(week: 90, at: later), config: config, log: &log, now: later
        )
        t.equal(again.count, 0, "о том же пороге второй раз не говорим")

        let high = AlertPlanner.alerts(
            for: snapshot(week: 96, at: later), config: config, log: &log, now: later
        )
        t.equal(high.first?.threshold, 95, "следующий порог — новый повод")
    }

    t.suite("уведомления: только на ухудшении") {
        var log = AlertLog()
        let config = NotificationsConfig()
        _ = AlertPlanner.alerts(for: snapshot(week: 96, at: now), config: config, log: &log, now: now)

        // Расход откатился (сервер пересчитал неделю) и снова подрос до
        // нижнего порога — это не повод объявлять пройденное заново.
        let later = now.addingTimeInterval(2 * 3600)
        let back = AlertPlanner.alerts(
            for: snapshot(week: 84, at: later), config: config, log: &log, now: later
        )
        t.equal(back.count, 0, "откат назад молчит")
    }

    t.suite("уведомления: новое окно начинает заново") {
        var log = AlertLog()
        let config = NotificationsConfig()
        _ = AlertPlanner.alerts(for: snapshot(week: 82, at: now), config: config, log: &log, now: now)

        // Неделя сбросилась: следующее окно — другое, и его 82 % свои.
        let next = now.addingTimeInterval(8 * 86_400)
        let fresh = AlertPlanner.alerts(
            for: snapshot(week: 82, at: next), config: config, log: &log, now: next
        )
        t.equal(fresh.count, 1, "в новом окне о том же пороге говорим снова")
    }

    t.suite("уведомления: остывание") {
        var log = AlertLog()
        let config = NotificationsConfig()
        let session = SessionUsage(usedPercent: 20, resetsAt: now.addingTimeInterval(3600))
        _ = AlertPlanner.alerts(
            for: snapshot(week: 82, session: session, at: now), config: config, log: &log, now: now
        )

        // Сессия пробила свой порог через минуту после недельного баннера.
        let soon = now.addingTimeInterval(60)
        let hot = SessionUsage(usedPercent: 96, resetsAt: now.addingTimeInterval(3600))
        let held = AlertPlanner.alerts(
            for: snapshot(week: 82, session: hot, at: soon), config: config, log: &log, now: soon
        )
        t.equal(held.count, 0, "внутри остывания молчим")

        // Через круг остывания тот же повод доходит: он не потерян, а отложен.
        let cool = now.addingTimeInterval(AlertPlanner.cooldown + 60)
        let late = AlertPlanner.alerts(
            for: snapshot(week: 82, session: hot, at: cool), config: config, log: &log, now: cool
        )
        t.equal(late.first?.kind, .session, "отложенный повод доходит следующим кругом")
    }

    t.suite("уведомления: истёкшая сессия") {
        var log = AlertLog()
        let config = NotificationsConfig()
        // Число из кеша прошлого запуска: окно давно закрылось.
        let stale = SessionUsage(usedPercent: 98, resetsAt: now.addingTimeInterval(-600))
        let alerts = AlertPlanner.alerts(
            for: snapshot(week: 10, session: stale, at: now), config: config, log: &log, now: now
        )
        t.equal(alerts.count, 0, "по истёкшей сессии не будим")
    }

    t.suite("уведомления: общий выключатель") {
        var log = AlertLog()
        var config = NotificationsConfig()
        config.enabled = false
        let off = AlertPlanner.alerts(
            for: snapshot(week: 99, at: now), config: config, log: &log, now: now
        )
        t.equal(off.count, 0, "выключенные уведомления молчат")
        t.equal(log, AlertLog(), "и лога не трогают: включив их, человек ждёт разговора")

        config.enabled = true
        let on = AlertPlanner.alerts(
            for: snapshot(week: 99, at: now), config: config, log: &log, now: now
        )
        t.equal(on.count, 1, "включённые говорят про сегодняшний расход")
    }

    t.suite("уведомления: оба лимита разом") {
        var log = AlertLog()
        let session = SessionUsage(usedPercent: 97, resetsAt: now.addingTimeInterval(1800))
        let alerts = AlertPlanner.alerts(
            for: snapshot(week: 96, session: session, at: now),
            config: NotificationsConfig(), log: &log, now: now
        )
        t.equal(alerts.count, 2, "неделя и сессия пробиты — говорим про оба")
        t.equal(alerts.map(\.kind), [.week, .session], "неделя первой")
    }

    t.suite("уведомления: слова") {
        // Две строки: сколько потрачено и сколько ждать. Какой это лимит,
        // говорит картинка — сессия дугой, неделя числом.
        let session = LimitAlert(
            kind: .session, threshold: 75, percent: 75,
            resetsAt: now.addingTimeInterval(72 * 60), isEstimate: false
        ).message(now: now)
        t.equal(session.title, "Израсходовано 75 %", "первая строка — расход")
        t.equal(session.body, "Сброс через 1 час 12 минут", "вторая — сколько ждать")

        let week = LimitAlert(
            kind: .week, threshold: 80, percent: 84,
            resetsAt: at(2026, 8, 14, 16, 0), isEstimate: false
        ).message(now: now)
        t.equal(week.title, "Израсходовано 84 %", "у недели те же слова")
        t.equal(week.body, "Сброс через 2 дня 2 часа", "и тот же шаблон срока")

        let estimate = LimitAlert(
            kind: .week, threshold: 80, percent: 84,
            resetsAt: now.addingTimeInterval(3600), isEstimate: true
        ).message(now: now)
        t.equal(estimate.title, "Израсходовано ≈84 %", "оценка помечена так же, как в панели")

        let done = LimitAlert(
            kind: .session, threshold: 95, percent: 100,
            resetsAt: now.addingTimeInterval(2700), isEstimate: false
        ).message(now: now)
        t.equal(done.title, "Лимит исчерпан", "исчерпанному лимиту своя первая строка")
        t.equal(done.body, "Сброс через 45 минут", "срок остаётся на месте")
    }

    t.suite("уведомления: длительность словами") {
        t.equal(Formatting.longDuration(72 * 60), "1 час 12 минут", "часы и минуты")
        t.equal(Formatting.longDuration(3 * 3600), "3 часа", "ровный остаток без нулевых минут")
        t.equal(Formatting.longDuration(2 * 86_400 + 4 * 3600), "2 дня 4 часа", "дни и часы")
        t.equal(Formatting.longDuration(86_400), "1 день", "ровные сутки")
        t.equal(Formatting.longDuration(11 * 3600), "11 часов", "11 — не «11 часа»")
        t.equal(Formatting.longDuration(21 * 60), "21 минута", "21 — «минута», как и 1")
        t.equal(Formatting.longDuration(45 * 60), "45 минут", "минуты без часов")
        t.equal(Formatting.longDuration(30), "меньше минуты", "полминуты не называем числом")
    }

    t.suite("уведомления: лог переживает перезапуск") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var log = AlertLog()
        _ = AlertPlanner.alerts(
            for: snapshot(week: 82, at: now), config: NotificationsConfig(), log: &log, now: now
        )
        try? Store.saveAlerts(log, to: url)

        // Программу перезапустили: лог читается с диска, и тот же порог
        // объявляться заново не должен.
        var restored = Store.loadAlerts(from: url)
        t.equal(restored, log, "лог прочитался тем же")
        let later = now.addingTimeInterval(2 * 3600)
        let repeated = AlertPlanner.alerts(
            for: snapshot(week: 85, at: later),
            config: NotificationsConfig(), log: &restored, now: later
        )
        t.equal(repeated.count, 0, "после перезапуска о пройденном пороге молчим")
        t.equal(Store.loadAlerts(from: URL(fileURLWithPath: "/nope/нет-такого.json")), AlertLog(),
                "отсутствующий файл — пустой лог, а не отказ от уведомлений")
    }

    t.suite("уведомления: статистика окна") {
        let now = at(2026, 8, 4, 12, 0)
        let calendar = config().calendar
        let opus = ModelUsage(
            family: ModelFamily.opus, cost: 62, tokens: TokenCounts(), messages: 10,
            sharePercent: 62
        )
        let week = LimitAlert(
            kind: .week, threshold: 80, percent: 81, resetsAt: now.addingTimeInterval(86_400),
            isEstimate: false, startedAt: at(2026, 8, 1, 0, 0), topModel: opus
        )
        let stats = week.statistics(calendar: calendar) ?? ""
        t.check(stats.hasPrefix("Неделя с "), "недельная статистика начинается с дня начала окна")
        t.check(stats.contains("больше всего Opus 62 %"), "и называет главную модель с её долей")

        // Третья строка живёт в теле баннера — там, где картинку могут и не
        // показать.
        let body = week.message(now: now, calendar: calendar).body
        t.equal(body.components(separatedBy: "\n").count, 2, "в теле две строки: сброс и статистика")
        t.check(body.hasSuffix(stats), "статистика идёт последней")

        // Сессия: опора — час начала, а модели у неё может не быть вовсе.
        let session = LimitAlert(
            kind: .session, threshold: 80, percent: 95, resetsAt: now.addingTimeInterval(3600),
            isEstimate: false, startedAt: now.addingTimeInterval(-4 * 3600)
        )
        let sessionStats = session.statistics(calendar: calendar) ?? ""
        t.check(sessionStats.hasPrefix("Сессия с "), "у сессии в опоре час, а не день недели")
        t.check(!sessionStats.contains("больше всего"), "без разбивки про модель молчим")

        // Ничего не знаем об окне — молчим целиком, а не пишем «неделя с ?».
        let bare = LimitAlert(
            kind: .week, threshold: 80, percent: 81, resetsAt: now, isEstimate: false
        )
        t.check(bare.statistics(calendar: calendar) == nil, "без начала окна статистики нет")
        t.equal(bare.message(now: now, calendar: calendar).body.components(separatedBy: "\n").count, 1,
                "и тело баннера остаётся одной строкой")
    }

    t.suite("уведомления: модель из снимка попадает в повод") {
        let now = at(2026, 8, 4, 12, 0)
        var log = AlertLog()
        let alerts = AlertPlanner.alerts(
            for: snapshot(week: 82, at: now), config: NotificationsConfig(), log: &log, now: now
        )
        t.equal(alerts.count, 1, "порог пробит — один повод")
        t.equal(alerts.first?.startedAt, snapshot(week: 82, at: now).window.start,
                "начало окна берётся из снимка")
    }
}
