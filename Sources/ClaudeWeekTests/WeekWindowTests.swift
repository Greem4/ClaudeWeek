import Foundation
import ClaudeWeekCore

func runWeekWindowTests(_ t: Harness) {
    // 2026-08-07 — пятница; сброс в 15:00 Europe/Saratov.
    t.suite("окно недели: границы") {
        let reset = at(2026, 8, 7, 15, 0)

        // Момент ровно на сбросе принадлежит новой неделе, а не старой.
        let onReset = WeekWindow(containing: reset, config: config())
        t.equal(onReset.start, reset, "старт в момент сброса")
        t.equal(onReset.end, at(2026, 8, 14, 15, 0), "конец через 7 суток")
        t.close(onReset.progress(at: reset), 0, "прогресс в момент сброса")

        // За минуту до — ещё прошлая неделя.
        let before = WeekWindow(containing: at(2026, 8, 7, 14, 59), config: config())
        t.equal(before.start, at(2026, 7, 31, 15, 0), "за минуту до сброса — прошлая неделя")
        t.equal(before.end, reset, "её конец — момент сброса")

        // За минуту после — уже новая.
        let after = WeekWindow(containing: at(2026, 8, 7, 15, 1), config: config())
        t.equal(after.start, reset, "через минуту после сброса — новая неделя")

        // Полсекунды до сброса не должны перебросить в новое окно.
        let almost = WeekWindow(containing: reset.addingTimeInterval(-0.5), config: config())
        t.equal(almost.start, at(2026, 7, 31, 15, 0), "полсекунды до сброса — ещё прошлая неделя")
    }

    t.suite("окно недели: воскресный полдень") {
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config())
        t.equal(window.start, at(2026, 8, 7, 15, 0), "старт — пятница до него")
        // Сутки окна идут от 15:00 до 15:00, поэтому воскресный полдень —
        // это ещё «субботние» сутки окна, индекс 1.
        t.equal(window.dayIndex(for: at(2026, 8, 9, 12, 0)), 1, "номер суток")
        t.equal(window.dayIndex(for: at(2026, 8, 9, 15, 0)), 2, "переход на следующие сутки в 15:00")
        t.equal(window.dayIndex(for: at(2026, 8, 7, 15, 0)), 0, "первые сутки")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 14, 59)), 6, "последние сутки")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 15, 0)), nil, "момент сброса уже вне окна")
        t.equal(window.dayIndex(for: at(2026, 8, 1, 12, 0)), nil, "прошлая неделя вне окна")

        let labels = window.days.map { Formatting.weekdayShort($0.start, calendar: window.calendar) }
        t.equal(labels, ["ПТ", "СБ", "ВС", "ПН", "ВТ", "СР", "ЧТ"], "подписи дней")
        t.equal(Formatting.resetLabel(window), "сброс ПТ 15:00", "подпись сброса")
    }

    t.suite("окно недели: смена таймзоны") {
        // Один и тот же момент времени в разных таймзонах даёт разные окна:
        // ПТ 15:00 в Саратове — это ПТ 11:00 UTC.
        let moment = at(2026, 8, 9, 12, 0)
        let saratov = WeekWindow(containing: moment, config: config(tz: "Europe/Saratov"))
        let utc = WeekWindow(containing: moment, config: config(tz: "UTC"))
        t.check(saratov.start != utc.start, "окна в разных таймзонах не совпадают")
        t.equal(saratov.start.parts(tz: "Europe/Saratov").hour, 15, "сброс в 15:00 по Саратову")
        t.equal(utc.start.parts(tz: "UTC").hour, 15, "сброс в 15:00 по UTC")
        t.equal(utc.start, at(2026, 8, 7, 15, 0, tz: "UTC"), "старт UTC-окна")
    }

    t.suite("окно недели: перевод часов") {
        // Весна: в ночь на 29 марта 2026 Берлин теряет час → 167 часов в окне.
        let spring = WeekWindow(containing: at(2026, 3, 30, 12, 0, tz: "Europe/Berlin"),
                                config: config(tz: "Europe/Berlin"))
        t.equal(spring.start, at(2026, 3, 27, 15, 0, tz: "Europe/Berlin"), "старт весенней недели")
        t.close(spring.duration, 167 * 3600, "весенняя неделя короче на час")
        t.equal(spring.start.parts(tz: "Europe/Berlin").hour, 15, "старт остаётся в 15:00")
        t.equal(spring.end.parts(tz: "Europe/Berlin").hour, 15, "конец остаётся в 15:00")

        // Осень: в ночь на 25 октября 2026 Берлин получает час → 169 часов.
        let autumn = WeekWindow(containing: at(2026, 10, 26, 12, 0, tz: "Europe/Berlin"),
                                config: config(tz: "Europe/Berlin"))
        t.equal(autumn.start, at(2026, 10, 23, 15, 0, tz: "Europe/Berlin"), "старт осенней недели")
        t.close(autumn.duration, 169 * 3600, "осенняя неделя длиннее на час")
        t.equal(autumn.end.parts(tz: "Europe/Berlin").hour, 15, "конец остаётся в 15:00")
        t.equal(autumn.days.count, 7, "всё те же семеро суток")
        // Сутки с переводом длятся 25 часов, но остаются одними сутками окна.
        let shifted = autumn.days[1]
        t.close(shifted.end.timeIntervalSince(shifted.start), 25 * 3600, "сутки перевода — 25 часов")
    }

    t.suite("окно недели: другой день сброса") {
        // Конфиг переставляется на понедельник 09:00 без правок кода.
        let window = WeekWindow(containing: at(2026, 8, 5, 12, 0), config: config(weekday: 2, hour: 9))
        t.equal(window.start, at(2026, 8, 3, 9, 0), "старт — понедельник 09:00")
        t.equal(window.end, at(2026, 8, 10, 9, 0), "конец — следующий понедельник")
    }
}
