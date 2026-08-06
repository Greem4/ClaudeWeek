import Foundation
import ClaudeWeekCore

func runFormattingTests(_ t: Harness) {
    t.suite("форматирование: длительность") {
        t.equal(Formatting.duration(3 * 86400 + 6 * 3600), "3 дн 6 ч", "дни и часы")
        t.equal(Formatting.duration(3600 + 12 * 60), "1 ч 12 мин", "часы и минуты")
        t.equal(Formatting.duration(12 * 60), "12 мин", "только минуты")
        t.equal(Formatting.duration(30), "меньше минуты", "полминуты")
        t.equal(Formatting.duration(0), "меньше минуты", "ноль")
        t.equal(Formatting.duration(-100), "меньше минуты", "отрицательное время не показываем")
        t.equal(Formatting.duration(86400), "1 дн 0 ч", "ровно сутки")
    }

    t.suite("форматирование: проценты") {
        t.equal(Formatting.percent(63.6), "64 %", "округление вверх")
        t.equal(Formatting.percent(64.4), "64 %", "округление вниз")
        t.equal(Formatting.percent(0), "0 %", "ноль")
        t.equal(Formatting.percent(7.142857), "7 %", "первые сутки плана")
        t.equal(Formatting.percent(50, withSign: false), "50", "без знака процента")
    }

    t.suite("форматирование: дни недели") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Saratov")!
        t.equal(Formatting.weekdayShort(at(2026, 8, 7, 15, 0), calendar: calendar), "ПТ", "пятница коротко")
        t.equal(Formatting.weekdayFull(at(2026, 8, 4, 12, 0), calendar: calendar), "Вторник", "вторник полностью")
        t.equal(Formatting.clock(at(2026, 8, 7, 15, 0), calendar: calendar), "15:00", "время сброса")
        t.equal(Formatting.clock(at(2026, 8, 7, 9, 5), calendar: calendar), "9:05", "минуты с ведущим нулём")
    }

    t.suite("форматирование: сброс сессии") {
        let calendar = config(tz: "Europe/Saratov").calendar
        let now = at(2026, 8, 4, 13, 23)
        let reset = at(2026, 8, 4, 14, 35)

        t.equal(
            Formatting.sessionReset(at: reset, now: now, display: .relative, calendar: calendar),
            "через 1 ч 12 мин", "сколько осталось"
        )
        t.equal(
            Formatting.sessionReset(at: reset, now: now, display: .absolute, calendar: calendar),
            "в 14:35", "во сколько сбросится"
        )
        t.equal(
            Formatting.sessionReset(at: reset, now: now, display: .both, calendar: calendar),
            "через 1 ч 12 мин (14:35)", "и то, и другое"
        )

        // Окно, перешагнувшее полночь: голое «в 2:15» ночью читается как
        // «уже прошло», поэтому чужие сутки подписаны днём недели.
        let overnight = at(2026, 8, 5, 2, 15)
        let night = at(2026, 8, 4, 23, 15)
        t.equal(
            Formatting.sessionReset(at: overnight, now: night, display: .absolute, calendar: calendar),
            "в СР 2:15", "сброс за полночь — с днём недели"
        )
        t.equal(
            Formatting.sessionReset(at: overnight, now: night, display: .both, calendar: calendar),
            "через 3 ч 0 мин (СР 2:15)", "оба конца для сброса за полночь"
        )

        // Сессия истекла, а панель ещё не перерисовалась: отрицательного
        // остатка человек видеть не должен.
        t.equal(
            Formatting.sessionReset(at: now, now: reset, display: .relative, calendar: calendar),
            "через меньше минуты", "просроченное окно не уходит в минус"
        )
    }
}
