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

    /// «16:00 → 0:00» — часы, которые сутки занимают в недельном окне.
    /// Нужны обрезанным суткам на его краях: подпись дня у них та же, что
    /// у полных, а часов меньше.
    public static func interval(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        "\(clock(start, calendar: calendar)) → \(clock(end, calendar: calendar))"
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

    /// «обновлено 3 мин назад», «обновлено только что».
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "только что" }
        return "\(duration(seconds)) назад"
    }

    /// «сброс ПТ 16:00» — час сброса в зоне окна, той же, по которой панель
    /// считает сутки. Московского хвоста для сверки здесь больше нет: два часа
    /// подряд читались как спорящие, а нужен всегда только свой.
    public static func resetLabel(_ window: WeekWindow) -> String {
        let end = window.end
        return "сброс \(weekdayShort(end, calendar: window.calendar)) \(clock(end, calendar: window.calendar))"
    }

    /// Хвост подписи сессии: «через 1 ч 12 мин», «в 14:35» или «через 1 ч 12
    /// мин (14:35)». Глагол остаётся снаружи — у исчерпанной сессии он свой
    /// («отпустит»), а число одно и то же.
    ///
    /// Час сброса, попавший на другие сутки, показывается с днём недели:
    /// пятичасовое окно легко перешагивает полночь, и голое «в 2:15» ночью
    /// читается как «уже прошло».
    public static func sessionReset(
        at resetsAt: Date,
        now: Date,
        display: SessionResetDisplay,
        calendar: Calendar
    ) -> String {
        let left = "через \(duration(max(resetsAt.timeIntervalSince(now), 0)))"
        let sameDay = calendar.isDate(resetsAt, inSameDayAs: now)
        let day = sameDay ? "" : "\(weekdayShort(resetsAt, calendar: calendar)) "
        let moment = "\(day)\(clock(resetsAt, calendar: calendar))"

        switch display {
        case .relative: return left
        case .absolute: return "в \(moment)"
        case .both: return "\(left) (\(moment))"
        }
    }
}
