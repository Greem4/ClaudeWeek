import Foundation
import ClaudeWeekCore

/// Момент времени в конкретной таймзоне — чтобы тесты не зависели от того,
/// где стоит машина.
func at(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
    tz: String = "Europe/Saratov"
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: tz)!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second
    ))!
}

func config(
    weekday: Int = 6,
    hour: Int = 15,
    minute: Int = 0,
    tz: String = "Europe/Saratov",
    anchor: PlanAnchor = .midDay
) -> Config {
    var c = Config.default
    c.resetWeekday = weekday
    c.resetHour = hour
    c.resetMinute = minute
    c.timeZone = tz
    c.planAnchor = anchor
    return c
}

/// Часы, которые можно двигать: нужны там, где проверяется поведение во
/// времени — троттлинг, паузы после отказа, возраст данных.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

extension Date {
    func parts(tz: String) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
    }
}
