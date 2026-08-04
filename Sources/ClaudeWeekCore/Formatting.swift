import Foundation

/// Форматирование для UI. Имена дней заданы таблицей, а не DateFormatter:
/// результат не зависит от установленных в системе локалей и проверяется тестами.
public enum Formatting {
    static let shortWeekdays = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"]
    static let fullWeekdays = [
        "Воскресенье", "Понедельник", "Вторник", "Среда",
        "Четверг", "Пятница", "Суббота",
    ]

    public static func weekdayShort(_ date: Date, calendar: Calendar) -> String {
        shortWeekdays[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    public static func weekdayFull(_ date: Date, calendar: Calendar) -> String {
        fullWeekdays[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    public static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// «3 дн 6 ч», «1 ч 12 мин», «12 мин».
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return "\(days) дн \(hours) ч" }
        if hours > 0 { return "\(hours) ч \(minutes) мин" }
        if minutes > 0 { return "\(minutes) мин" }
        return "меньше минуты"
    }

    /// Проценты без дрожания знаков: всегда целое число.
    public static func percent(_ value: Double, withSign sign: Bool = true) -> String {
        let rounded = Int(value.rounded())
        return sign ? "\(rounded) %" : "\(rounded)"
    }

    /// «1.4×» — темп относительно плана.
    public static func rate(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    /// «обновлено 3 мин назад», «обновлено только что».
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "только что" }
        return "\(duration(seconds)) назад"
    }

    /// «сброс ПТ 15:00».
    public static func resetLabel(_ window: WeekWindow) -> String {
        "сброс \(weekdayShort(window.end, calendar: window.calendar)) \(clock(window.end, calendar: window.calendar))"
    }
}
