import Foundation
import ClaudeWeekCore

private func tempFile(_ contents: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-week-test-\(UUID().uuidString).json")
    try? contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func runConfigTests(_ t: Harness) {
    t.suite("конфиг: дефолты") {
        let d = Config.default
        t.equal(d.weekStart, .monday, "неделя по умолчанию начинается понедельником")
        t.equal(d.resetWeekday, 6, "сброс в пятницу")
        t.equal(d.resetHour, 16, "сброс в 16:00 — это 15:00 по Москве")
        t.equal(d.workHours, WorkHours(start: 10, end: 18), "рабочий день 10–18")
        t.equal(ConfigStore.load(from: URL(fileURLWithPath: "/nope/нет-такого.json")),
                Config.default.validated(), "отсутствующий файл — дефолты")
    }

    t.suite("конфиг: частичный файл") {
        // Задано одно поле — остальные должны остаться дефолтными. Ключи от
        // прошлых версий (тот же `planAnchor`) просто игнорируются: настройка
        // ушла, а конфиг с ней должен читаться как ни в чём не бывало.
        let url = tempFile(#"{ "workHours": { "start": 10, "end": 18 }, "planAnchor": "midDay" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ConfigStore.load(from: url)
        t.equal(c.workHours, WorkHours(start: 10, end: 18), "своё значение прочиталось")
        t.equal(c.resetHour, 16, "остальное осталось дефолтным")
        t.equal(c.weekStart, .monday, "конфиг прошлой версии не знает о начале недели — берётся дефолт")
    }

    t.suite("конфиг: комментарии в JSON") {
        let url = tempFile("""
        {
          "resetWeekday": 2,   // понедельник
          "resetHour": 9
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ConfigStore.load(from: url)
        t.equal(c.resetWeekday, 2, "комментарии не мешают разбору")
        t.equal(c.resetHour, 9, "второе поле тоже прочиталось")
    }

    t.suite("конфиг: битый файл") {
        let url = tempFile("{ это не json")
        defer { try? FileManager.default.removeItem(at: url) }
        t.equal(ConfigStore.load(from: url), Config.default.validated(),
                "опечатка в JSON не должна ронять приложение")
    }

    t.suite("конфиг: приведение значений") {
        var c = Config.default
        c.resetWeekday = 99
        c.resetHour = -1
        c.resetMinute = 77
        c.refreshInterval = 5
        c.timeZone = "Europe/Тьмутаракань"
        c.weeklyBudget = -10
        c.thresholds = Thresholds(
            weekWarn: 500, weekCritical: -1,
            sessionWarn: 90, sessionCritical: 60
        )
        let v = c.validated()
        t.equal(v.resetWeekday, 6, "день недели вне 1…7 чинится")
        t.equal(v.resetHour, 16, "час вне 0…23 чинится")
        t.equal(v.resetMinute, 0, "минуты вне 0…59 чинятся")
        t.equal(v.refreshInterval, Config.minimumRefreshInterval, "интервал не ниже минимума")
        t.equal(v.timeZone, "", "неизвестная таймзона — системная")
        t.equal(v.resolvedTimeZone, TimeZone.current, "пустая таймзона разворачивается в системную")
        t.equal(v.weeklyBudget, 0, "отрицательный бюджет обнуляется")
        t.equal(v.thresholds.weekWarn, 81, "жёлтый порог вне 0…100 чинится")
        t.equal(v.thresholds.weekCritical, 93, "красный порог вне 0…100 чинится")
        t.equal(v.thresholds.sessionCritical, 90, "красный ниже жёлтого подтягивается к нему")
        t.equal(v.thresholds.sessionWarn, 90, "…а сам жёлтый остаётся как задан")
    }

    t.suite("конфиг: запись и чтение") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-test-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var c = Config.default
        c.weeklyBudget = 42.5
        c.calibration = Calibration(observedPercent: 64, at: at(2026, 8, 4, 12, 0))
        do {
            try ConfigStore.save(c, to: url)
        } catch {
            t.fail("запись конфига упала: \(error)")
            return
        }
        let back = ConfigStore.load(from: url)
        t.equal(back.weeklyBudget, 42.5, "бюджет пережил запись и чтение")
        t.equal(back.calibration.observedPercent, 64, "калибровка пережила запись и чтение")
        t.equal(back.calibration.at, at(2026, 8, 4, 12, 0), "дата калибровки пережила запись")
    }

    t.suite("конфиг: внешний вид") {
        let d = Config.default
        t.equal(d.appearance.theme, .contrast, "тема по умолчанию — контрастная")
        t.equal(d.appearance.transparentPanel, true, "панель по умолчанию прозрачная")

        var c = Config.default
        c.appearance.panelTintOpacity = 3
        c.appearance.cornerRadius = 99
        let v = c.validated()
        t.equal(v.appearance.panelTintOpacity, 1, "плотность фона зажимается в 0…1")
        t.equal(v.appearance.cornerRadius, 24, "скругление зажимается в 0…24")

        var negative = Config.default
        negative.appearance.panelTintOpacity = -0.5
        t.equal(negative.validated().appearance.panelTintOpacity, 0, "отрицательная плотность обнуляется")
    }

    t.suite("конфиг: внешний вид переживает файл") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-test-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var c = Config.default
        c.appearance = AppearanceConfig(
            theme: .midnight,
            transparentPanel: false,
            panelTintOpacity: 0.7,
            cornerRadius: 6,
            showSession: false,
            showForecast: false
        )
        do {
            try ConfigStore.save(c, to: url)
        } catch {
            t.fail("запись конфига упала: \(error)")
            return
        }
        let back = ConfigStore.load(from: url)
        t.equal(back.appearance.theme, .midnight, "тема пережила запись")
        t.equal(back.appearance.transparentPanel, false, "выключенная прозрачность пережила запись")
        t.equal(back.appearance.panelTintOpacity, 0.7, "плотность пережила запись")
        t.equal(back.appearance.showSession, false, "скрытая сессия пережила запись")
    }

    t.suite("конфиг: подпись сброса сессии") {
        t.equal(Config.default.appearance.sessionReset, .both,
                "по умолчанию — и остаток, и время")

        let url = tempFile(#"{ "appearance": { "sessionReset": "absolute" } }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        t.equal(ConfigStore.load(from: url).appearance.sessionReset, .absolute,
                "своё значение прочиталось")

        // Внешний вид, записанный прошлой версией: ключа sessionReset в нём
        // нет. Раньше это ронять не могло — теперь может, и не должно:
        // одна новая настройка не имеет права сбросить человеку остальные.
        let old = tempFile(#"{ "appearance": { "theme": "midnight", "cornerRadius": 4 } }"#)
        defer { try? FileManager.default.removeItem(at: old) }
        let c = ConfigStore.load(from: old)
        t.equal(c.appearance.theme, .midnight, "старый внешний вид уцелел")
        t.equal(c.appearance.cornerRadius, 4, "и второе его поле тоже")
        t.equal(c.appearance.sessionReset, .both, "новый ключ взялся из дефолтов")
    }

    t.suite("конфиг: пороги окраски") {
        let d = Config.default.thresholds
        t.equal(d.weekWarn, 81, "неделя желтеет с 81 %")
        t.equal(d.weekCritical, 93, "и краснеет с 93 %")
        t.equal(d.sessionWarn, 81, "у сессии тот же жёлтый порог")
        t.equal(d.sessionCritical, 95, "а красный у неё выше: сессия сбросится сама")
        t.check(d.colorizeMenuBar, "строка меню красится по умолчанию")

        let url = tempFile(#"{ "thresholds": { "weekWarn": 50, "colorizeMenuBar": false } }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = ConfigStore.load(from: url).thresholds
        t.equal(mine.weekWarn, 50, "своё значение прочиталось")
        t.check(!mine.colorizeMenuBar, "выключенная окраска прочиталась")
        t.equal(mine.sessionWarn, 81, "нетронутый порог взялся из дефолтов")

        // Пороги прошлой версии считались от плана и в долях. Переносить их
        // нельзя — 0.9 доли превратились бы в 0.9 %, — и падать на них тоже.
        let old = tempFile(#"{ "thresholds": { "warn": 1.3, "warnFloor": 50, "critical": 0.85 } }"#)
        defer { try? FileManager.default.removeItem(at: old) }
        let legacy = ConfigStore.load(from: old)
        t.equal(legacy.thresholds, Thresholds(), "старые ключи игнорируются, берутся дефолты")
        t.equal(legacy.resetWeekday, Config.default.resetWeekday, "остальной конфиг цел")
    }

    t.suite("конфиг: расклад кольца") {
        t.equal(Config.default.ringArc, .session, "по умолчанию дуга — сессия")
        t.equal(RingArc.session.label, .week, "тогда цифра внутри — неделя")
        t.equal(RingArc.week.label, .session, "и наоборот при обратном раскладе")

        let url = tempFile(#"{ "ringArc": "week" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        t.equal(ConfigStore.load(from: url).ringArc, .week, "обратный расклад прочитался")

        // Конфиг прошлой версии про кольцо ничего не знал — там, где ключа
        // нет, расклад обязан остаться прежним, иначе обновление молча
        // переставит людям значок.
        let old = tempFile(#"{ "menuBarStyle": "ring" }"#)
        defer { try? FileManager.default.removeItem(at: old) }
        t.equal(ConfigStore.load(from: old).ringArc, .session,
                "без ключа расклад прежний")
    }

    t.suite("конфиг: вид панели") {
        t.equal(Config.default.appearance.panelLayout, .compact, "по умолчанию — только сегодня")

        let url = tempFile(#"{ "appearance": { "panelLayout": "week" } }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        t.equal(ConfigStore.load(from: url).appearance.panelLayout, .week,
                "вся неделя прочиталась")

        // Ключа panelLayout в конфиге прошлой версии нет, и появиться он должен
        // дефолтным — не тронув остальной внешний вид.
        let old = tempFile(#"{ "appearance": { "theme": "paper", "showSession": false } }"#)
        defer { try? FileManager.default.removeItem(at: old) }
        let c = ConfigStore.load(from: old)
        t.equal(c.appearance.panelLayout, .compact, "новый ключ взялся из дефолтов")
        t.equal(c.appearance.theme, .paper, "прежний внешний вид уцелел")
        t.equal(c.appearance.showSession, false, "и второе его поле тоже")

        let mistake = tempFile(#"{ "appearance": { "panelLayout": "неделя" } }"#)
        defer { try? FileManager.default.removeItem(at: mistake) }
        t.equal(ConfigStore.load(from: mistake), Config.default.validated(),
                "непонятное значение — дефолты, а не падение")
    }

    t.suite("конфиг: дневной план") {
        t.check(!Config.default.appearance.showsPlan, "по умолчанию дневной план выключен")

        let url = tempFile(#"{ "appearance": { "showsPlan": true } }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        t.check(ConfigStore.load(from: url).appearance.showsPlan, "включённый план прочитался")

        // Ключа showsPlan в конфиге прошлой версии нет — берётся дефолт,
        // а всё остальное в том конфиге остаётся как записано.
        let old = tempFile(#"{ "appearance": { "theme": "graphite" } }"#)
        defer { try? FileManager.default.removeItem(at: old) }
        let c = ConfigStore.load(from: old)
        t.check(!c.appearance.showsPlan, "новый ключ взялся из дефолтов")
        t.equal(c.appearance.theme, .graphite, "прежний внешний вид уцелел")
    }

    t.suite("конфиг: старый файл без внешнего вида") {
        // Конфиг, написанный прошлой версией: новых ключей в нём нет,
        // и появиться они должны дефолтными, а не уронить разбор.
        // Заодно authSource: ключ убран вместе с ручным токеном, и оставшийся
        // в чужом конфиге он должен молча игнорироваться, а не ронять разбор.
        let url = tempFile(#"{ "resetHour": 9, "provider": "local", "authSource": "manual" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ConfigStore.load(from: url)
        t.equal(c.resetHour, 9, "старое поле прочиталось")
        t.equal(c.appearance, AppearanceConfig(), "внешний вид взялся из дефолтов")
        t.equal(c.provider, .local, "исчезнувший authSource не помешал разбору")
    }

    t.suite("конфиг: календарь") {
        let calendar = config(tz: "Europe/Saratov").calendar
        t.equal(calendar.timeZone.identifier, "Europe/Saratov", "таймзона из конфига")
        t.equal(calendar.identifier, .gregorian, "григорианский календарь")
    }
}
