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
        t.equal(Formatting.rate(1.42), "1.4×", "темп")
    }

    t.suite("форматирование: возраст данных") {
        let now = at(2026, 8, 4, 12, 0)
        t.equal(Formatting.age(now.addingTimeInterval(-30), now: now), "только что", "полминуты назад")
        t.equal(Formatting.age(now.addingTimeInterval(-180), now: now), "3 мин назад", "три минуты назад")
        t.equal(Formatting.age(now.addingTimeInterval(-7200), now: now), "2 ч 0 мин назад", "два часа назад")
    }

    t.suite("форматирование: дни недели") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Saratov")!
        t.equal(Formatting.weekdayShort(at(2026, 8, 7, 15, 0), calendar: calendar), "ПТ", "пятница коротко")
        t.equal(Formatting.weekdayFull(at(2026, 8, 4, 12, 0), calendar: calendar), "Вторник", "вторник полностью")
        t.equal(Formatting.clock(at(2026, 8, 7, 15, 0), calendar: calendar), "15:00", "время сброса")
        t.equal(Formatting.clock(at(2026, 8, 7, 9, 5), calendar: calendar), "9:05", "минуты с ведущим нулём")
    }
}
