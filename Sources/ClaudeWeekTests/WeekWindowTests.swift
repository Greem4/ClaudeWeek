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
        t.equal(window.slotCount, 8, "восемь календарных суток: сброс в 15:00 режет пятницу надвое")
        t.equal(window.dayIndex(for: at(2026, 8, 9, 12, 0)), 2, "воскресный полдень — воскресная строка")
        t.equal(window.dayIndex(for: at(2026, 8, 9, 15, 0)), 2, "в 15:00 строка не меняется")
        t.equal(window.dayIndex(for: at(2026, 8, 10, 0, 0)), 3, "меняется в полночь")
        t.equal(window.dayIndex(for: at(2026, 8, 7, 15, 0)), 0, "первые сутки — вечер пятницы")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 0, 0)), 7, "последние сутки — утро пятницы")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 14, 59)), 7, "и весь час до сброса — они же")
        t.equal(window.dayIndex(for: at(2026, 8, 14, 15, 0)), nil, "момент сброса уже вне окна")
        t.equal(window.dayIndex(for: at(2026, 8, 1, 12, 0)), nil, "прошлая неделя вне окна")

        let labels = window.days.map { Formatting.weekdayShort($0.start, calendar: window.calendar) }
        t.equal(labels, ["ПТ", "СБ", "ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ"], "подписи суток окна")
        t.check(window.days[0].isPartial && window.days[7].isPartial, "крайние сутки обрезаны")
        t.check(window.days[1...6].allSatisfy { !$0.isPartial }, "середина недели — полные сутки")
        t.equal(Formatting.resetLabel(window), "сброс ПТ 15:00", "подпись сброса в своей зоне")
    }

    // Двух пятниц на панели быть не должно: это один день недели, разрезанный
    // сбросом. Строк всегда семь, и пятница показывает ту свою половину,
    // которая идёт сейчас.
    t.suite("окно недели: строки панели") {
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config())
        t.check(window.splitsResetDay, "сброс в 15:00 режет день сброса надвое")
        t.equal(window.rowCount, 7, "строк на панели семь")

        let labels: (Date) -> [String] = { moment in
            window.rows(at: moment).map { Formatting.weekdayShort($0.start, calendar: window.calendar) }
        }
        t.equal(labels(at(2026, 8, 9, 12, 0)), ["ПТ", "СБ", "ВС", "ПН", "ВТ", "СР", "ЧТ"],
                "пока неделя катится, пятница — её вечер в начале ряда")
        t.equal(labels(at(2026, 8, 14, 9, 0)), ["СБ", "ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ"],
                "с полуночи последних суток пятница уходит в конец ряда")
        t.equal(window.rows(at: at(2026, 8, 13, 23, 59)).last?.index, 6,
                "до полуночи ряд заканчивается четвергом")
        t.equal(window.rows(at: at(2026, 8, 14, 0, 0)).last?.index, 7,
                "после — утром пятницы")
        t.close(window.rows(at: at(2026, 8, 14, 9, 0)).last?.planPercent ?? 0, 100,
                "и его план доводит неделю до 100 %")
        t.check(window.rows(at: at(2026, 8, 9, 12, 0)).allSatisfy { $0.index != 7 },
                "утро будущей пятницы в ряд не попадает")

        // Сутки нумеруются окном, а не позицией в ряду: по этим номерам
        // подтягивается факт и подсвечивается текущая строка.
        t.equal(window.rows(at: at(2026, 8, 14, 9, 0)).map(\.index), [1, 2, 3, 4, 5, 6, 7],
                "номера суток сохраняются")
    }

    // Неделя, начинающаяся понедельником: ряд повёрнут к нему, а сутки окна,
    // прошедшие до понедельника, стоят под текущей неделей — они уже позади.
    t.suite("окно недели: начало в понедельник") {
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(weekStart: .monday))
        let labels: (Date) -> [String] = { moment in
            window.rows(at: moment).map { Formatting.weekdayShort($0.start, calendar: window.calendar) }
        }
        let monday = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]

        t.equal(labels(at(2026, 8, 9, 12, 0)), monday, "ряд открывает понедельник, выходные — в конце")
        t.equal(labels(at(2026, 8, 14, 9, 0)), monday,
                "и в последние сутки окна порядок тот же: он не зависит от момента")
        t.equal(window.rows(at: at(2026, 8, 9, 12, 0)).map(\.index), [3, 4, 5, 6, 7, 1, 2],
                "номера суток окна сохраняются, меняется только порядок строк")
        t.equal(window.rows(at: at(2026, 8, 9, 12, 0)).count, 7, "строк всё те же семь")

        // У ряда своя шкала: понедельник открывается нулём, пятница приходит
        // к 100 % в момент сброса. 56 рабочих часов от полуночи понедельника
        // до него: четверо полных суток по 13 и четыре часа утра пятницы.
        let plan = window.rows(at: at(2026, 8, 9, 12, 0)).map { Int($0.planPercent.rounded()) }
        t.equal(plan, [23, 46, 70, 93, 100, 24, 38],
                "неделя от понедельника до сброса, выходные — в недельной шкале")
        t.close(window.planPercent(forDay: 3, from: 3), 100 * 13 / 56, "понедельник — 13 часов из 56")
        t.equal(window.scaleBase(at: at(2026, 8, 9, 12, 0)), 3, "шкала открывается понедельником")

        // Вечер пятницы в ряд не попал, но «сегодня» на панели быть обязано:
        // у этого дня недели строка одна, её и подсвечиваем.
        t.equal(window.highlightedRow(at: at(2026, 8, 7, 20, 0)), 7,
                "вечером дня сброса подсвечена его строка")
        t.equal(window.highlightedRow(at: at(2026, 8, 9, 12, 0)), 2, "обычные сутки подсвечивают себя")
        t.equal(window.highlightedRow(at: at(2026, 8, 1, 12, 0)), nil, "вне окна подсвечивать нечего")
    }

    t.suite("окно недели: понедельник и есть день сброса") {
        // Сброс в понедельник 15:00 — тогда разрезан надвое сам понедельник.
        // Ряд должна открывать его вечерняя половина: иначе панель начиналась
        // бы со ста процентов и дальше падала к десяти.
        let window = WeekWindow(
            containing: at(2026, 8, 12, 12, 0),
            config: config(weekday: 2, weekStart: .monday)
        )
        t.equal(window.start, at(2026, 8, 10, 15, 0), "старт — понедельник до него")
        t.equal(window.rows(at: at(2026, 8, 12, 12, 0)).map(\.index), [0, 1, 2, 3, 4, 5, 6],
                "ряд открывает вечер понедельника, а не его утро через неделю")
        let plan = window.rows(at: at(2026, 8, 12, 12, 0)).map { Int($0.planPercent.rounded()) }
        t.equal(plan, [10, 24, 38, 53, 67, 81, 96], "план растёт сверху вниз")
    }

    t.suite("окно недели: сброс в полночь") {
        // Ровно в полночь календарные сутки и сутки окна совпадают —
        // резать день сброса не на что.
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(hour: 0))
        t.equal(window.slotCount, 7, "семь суток")
        t.equal(window.days[0].start, window.start, "первые сутки начинаются со сбросом")
        t.check(window.days.allSatisfy { !$0.isPartial }, "обрезанных суток нет")
        t.check(!window.splitsResetDay, "делить нечего")
        t.equal(window.rows(at: at(2026, 8, 13, 23, 59)).map(\.index), [0, 1, 2, 3, 4, 5, 6],
                "ряд не сдвигается ни в какой момент недели")

        // Делить нечего и поворачивать нечего не мешает: ряд от понедельника
        // здесь просто крутится по кругу, все семь суток целы.
        let fromMonday = WeekWindow(
            containing: at(2026, 8, 9, 12, 0),
            config: config(hour: 0, weekStart: .monday)
        )
        t.equal(fromMonday.rows(at: at(2026, 8, 9, 12, 0)).map(\.index), [3, 4, 5, 6, 0, 1, 2],
                "семь суток повёрнуты к понедельнику")
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
        t.equal(autumn.days.count, 8, "всё те же восемь суток")
        // Сутки с переводом длятся 25 часов и остаются одной календарной датой.
        let shifted = autumn.days[2]
        t.equal(shifted.start, at(2026, 10, 25, 0, 0, tz: "Europe/Berlin"), "воскресенье перевода")
        t.close(shifted.end.timeIntervalSince(shifted.start), 25 * 3600, "сутки перевода — 25 часов")
        // Ряд плана всё равно приходит ровно к 100 %: он считается временем.
        t.close(autumn.planPercent(forDay: autumn.slotCount - 1), 100,
                "последние сутки — 100 % даже в неделю с переводом часов")
    }

    // Рабочий день — правило циферблата, а не «полночь плюс столько-то часов».
    // Пока границы искались прибавлением часов, в сутки перевода план начинал
    // расти в 10:00 осенью и в 12:00 весной — вместо 11:00 в оба дня.
    t.suite("окно недели: рабочий день в сутки перевода часов") {
        let berlin = "Europe/Berlin"
        let autumn = WeekWindow(containing: at(2026, 10, 26, 12, 0, tz: berlin),
                                config: config(tz: berlin))
        let plan: (WeekWindow, Int, Int, Int) -> Double = { window, month, day, hour in
            window.planPercent(at: at(2026, month, day, hour, 0, tz: berlin))
        }

        // 25 октября сутки длятся 25 часов, и лишний час приходится на ночь.
        // Час недели тут весит 100/91: 9 рабочих часов вечера пятницы, по 13
        // в шести полных сутках и 4 в её утро.
        t.close(plan(autumn, 10, 25, 11), plan(autumn, 10, 25, 0),
                "осенью в 11:00 план ещё на ночной отметке")
        t.close(plan(autumn, 10, 25, 12) - plan(autumn, 10, 25, 11), 100 / 91,
                "первый рабочий час — с 11:00 до 12:00", tolerance: 1e-9)
        // Полные сутки весят одинаково: перевод часов рабочего дня не двигает.
        t.close(autumn.planPercent(forDay: 2) - autumn.planPercent(forDay: 1),
                autumn.planPercent(forDay: 4) - autumn.planPercent(forDay: 3),
                "сутки перевода весят столько же, сколько обычные", tolerance: 1e-9)

        // 29 марта суток на час меньше, и пропадает он ночью, до работы.
        let spring = WeekWindow(containing: at(2026, 3, 30, 12, 0, tz: berlin),
                                config: config(tz: berlin))
        t.close(plan(spring, 3, 29, 11), plan(spring, 3, 29, 0),
                "весной в 11:00 план ещё на нуле суток")
        t.close(plan(spring, 3, 29, 12) - plan(spring, 3, 29, 11), 100 / 91,
                "а первый рабочий час — тот же, с 11:00 до 12:00", tolerance: 1e-9)
        t.close(spring.planPercent(forDay: 2) - spring.planPercent(forDay: 1),
                spring.planPercent(forDay: 4) - spring.planPercent(forDay: 3),
                "и весенние сутки перевода тоже весят как обычные", tolerance: 1e-9)
    }

    t.suite("рабочий день: починка недопустимых значений") {
        t.equal(WorkHours(start: 30, end: 24).validated().start, WorkHours.default.start,
                "час начала вне 0…23 чинится")
        t.equal(WorkHours(start: 11, end: 30).validated().end, WorkHours.default.end,
                "час конца вне 1…24 чинится")
        // Пустой день оставил бы неделю вовсе без плана — делить было бы не на что.
        t.equal(WorkHours(start: 18, end: 10).validated(), WorkHours(start: 0, end: 24),
                "вывернутый день чинится на круглосуточный")
        t.equal(WorkHours(start: 12, end: 12).validated(), WorkHours(start: 0, end: 24),
                "и пустой тоже")
        t.check(WorkHours(start: 0, end: 24).isAllDay, "0…24 — круглые сутки")
    }

    t.suite("окно недели: другой день сброса") {
        // Конфиг переставляется на понедельник 09:00 без правок кода.
        let window = WeekWindow(containing: at(2026, 8, 5, 12, 0), config: config(weekday: 2, hour: 9))
        t.equal(window.start, at(2026, 8, 3, 9, 0), "старт — понедельник 09:00")
        t.equal(window.end, at(2026, 8, 10, 9, 0), "конец — следующий понедельник")
    }
}
