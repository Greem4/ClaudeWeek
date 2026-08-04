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
        t.equal(d.resetWeekday, 6, "сброс в пятницу")
        t.equal(d.resetHour, 15, "сброс в 15:00")
        t.equal(d.planAnchor, .midDay, "план на середину суток")
        t.equal(ConfigStore.load(from: URL(fileURLWithPath: "/nope/нет-такого.json")),
                Config.default.validated(), "отсутствующий файл — дефолты")
    }

    t.suite("конфиг: частичный файл") {
        // Задано одно поле — остальные должны остаться дефолтными.
        let url = tempFile(#"{ "planAnchor": "endOfDay" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ConfigStore.load(from: url)
        t.equal(c.planAnchor, .endOfDay, "своё значение прочиталось")
        t.equal(c.resetHour, 15, "остальное осталось дефолтным")
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
        c.thresholds = Thresholds(warn: 0, critical: 5)
        let v = c.validated()
        t.equal(v.resetWeekday, 6, "день недели вне 1…7 чинится")
        t.equal(v.resetHour, 15, "час вне 0…23 чинится")
        t.equal(v.resetMinute, 0, "минуты вне 0…59 чинятся")
        t.equal(v.refreshInterval, Config.minimumRefreshInterval, "интервал не ниже минимума")
        t.equal(v.timeZone, "", "неизвестная таймзона — системная")
        t.equal(v.resolvedTimeZone, TimeZone.current, "пустая таймзона разворачивается в системную")
        t.equal(v.weeklyBudget, 0, "отрицательный бюджет обнуляется")
        t.equal(v.thresholds.warn, 1.0, "нулевой порог предупреждения чинится")
        t.equal(v.thresholds.critical, 0.9, "порог критичности вне 0…1 чинится")
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

    t.suite("конфиг: календарь") {
        let calendar = config(tz: "Europe/Saratov").calendar
        t.equal(calendar.timeZone.identifier, "Europe/Saratov", "таймзона из конфига")
        t.equal(calendar.identifier, .gregorian, "григорианский календарь")
    }
}
