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

        // Строка меняется в местную полночь, а не в час сброса: воскресный
        // полдень — это воскресенье, а не «субботние сутки окна».
        t.equal(window.slotCount, 8, "восемь строк: сброс в 15:00 режет пятницу надвое")
        t.equal(window.dayIndex(for: at(2026, 8, 9, 12, 0)), 2, "воскресный полдень — воскресная строка")
        t.equal(window.dayIndex(for: at(2026, 8, 9, 15, 0)), 2, "в 15:00 строка не меняется")
        t.equal(window.dayIndex(for: at(2026, 8, 10, 0, 0)), 3, "меняется в полночь")
        t.equal(window.dayIndex(for: at(2026, 8, 7, 15, 0)), 0, "первые сутки — вечер пятницы")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 0, 0)), 7, "последние сутки — утро пятницы")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 14, 59)), 7, "и весь час до сброса — они же")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 15, 0)), nil, "момент сброса уже вне окна")
        t.equal(window.dayIndex(for: at(2026, 8, 1, 12, 0)), nil, "прошлая неделя вне окна")

        let labels = window.days.map { Formatting.weekdayShort($0.start, calendar: window.calendar) }
        t.equal(labels, ["ПТ", "СБ", "ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ"], "подписи дней")
        t.check(window.days[0].isPartial && window.days[7].isPartial, "крайние сутки обрезаны")
        t.check(window.days[1...6].allSatisfy { !$0.isPartial }, "середина недели — полные сутки")
        t.equal(Formatting.resetLabel(window), "сброс ПТ 15:00 · 14:00 МСК", "подпись сброса с московским временем")
    }

    t.suite("окно недели: сброс в полночь") {
        // Ровно в полночь календарные сутки и сутки окна совпадают —
        // восьмой строке взяться неоткуда.
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(hour: 0))
        t.equal(window.slotCount, 7, "семь строк")
        t.equal(window.days[0].start, window.start, "первая строка начинается со сбросом")
        t.check(window.days.allSatisfy { !$0.isPartial }, "обрезанных суток нет")
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
        t.equal(autumn.days.count, 8, "всё те же восемь строк")
        // Сутки с переводом длятся 25 часов и остаются одной календарной датой.
        let shifted = autumn.days[2]
        t.equal(shifted.start, at(2026, 10, 25, 0, 0, tz: "Europe/Berlin"), "воскресенье перевода")
        t.close(shifted.end.timeIntervalSince(shifted.start), 25 * 3600, "сутки перевода — 25 часов")
        // Ряд плана всё равно приходит ровно к 100 %: он считается временем.
        t.close(autumn.planPercent(forDay: autumn.slotCount - 1, anchor: .endOfDay), 100,
                "последняя строка — 100 % даже в неделю с переводом часов")
    }

    t.suite("окно недели: другой день сброса") {
        // Конфиг переставляется на понедельник 09:00 без правок кода.
        let window = WeekWindow(containing: at(2026, 8, 5, 12, 0), config: config(weekday: 2, hour: 9))
        t.equal(window.start, at(2026, 8, 3, 9, 0), "старт — понедельник 09:00")
        t.equal(window.end, at(2026, 8, 10, 9, 0), "конец — следующий понедельник")
    }
}
