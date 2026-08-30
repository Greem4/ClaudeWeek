import Foundation

/// Форматирование для UI. Имена дней заданы таблицей, а не DateFormatter:
/// результат не зависит от установленных в системе локалей и проверяется тестами.
///
/// Язык приходит параметром и по умолчанию русский — тот, на котором программа
/// говорила до появления второго. Панель и настройки передают выбранный явно.
public enum Formatting {
    /// Короткая метка окна для левой колонки панели: «5 Ч», «15 МИН».
    public static func limitWindow(_ minutes: Int, lang: Lang = .ru) -> String {
        let safe = max(minutes, 1)
        if safe.isMultiple(of: 24 * 60) {
            let days = safe / (24 * 60)
            return L10n(lang).pick("\(days) Д", "\(days) D")
        }
        if safe.isMultiple(of: 60) {
            let hours = safe / 60
            return L10n(lang).pick("\(hours) Ч", "\(hours) H")
        }
        return L10n(lang).pick("\(safe) МИН", "\(safe) MIN")
    }

    /// Полное название того же окна для VoiceOver.
    public static func limitWindowSpoken(_ minutes: Int, lang: Lang = .ru) -> String {
        let safe = max(minutes, 1)
        if safe.isMultiple(of: 24 * 60) {
            let days = safe / (24 * 60)
            return L10n(lang).pick("окно \(days) дн.", "\(days)-day window")
        }
        if safe.isMultiple(of: 60) {
            let hours = safe / 60
            return L10n(lang).pick("окно \(hours) ч.", "\(hours)-hour window")
        }
        return L10n(lang).pick("окно \(safe) мин.", "\(safe)-minute window")
    }

    static let shortWeekdays = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"]
    static let fullWeekdays = [
        "Воскресенье", "Понедельник", "Вторник", "Среда",
        "Четверг", "Пятница", "Суббота",
    ]
    /// Английские сокращения — двухбуквенные, как в русской таблице: колонка
    /// дня в панели рассчитана на две буквы, и «Wed» её распирает.
    static let shortWeekdaysEN = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static let fullWeekdaysEN = [
        "Sunday", "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday",
    ]

    public static func weekdayShort(_ date: Date, calendar: Calendar, lang: Lang = .ru) -> String {
        let index = (calendar.component(.weekday, from: date) - 1 + 7) % 7
        return lang == .ru ? shortWeekdays[index] : shortWeekdaysEN[index]
    }

    public static func weekdayFull(_ date: Date, calendar: Calendar, lang: Lang = .ru) -> String {
        let index = (calendar.component(.weekday, from: date) - 1 + 7) % 7
        return lang == .ru ? fullWeekdays[index] : fullWeekdaysEN[index]
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
    public static func duration(_ interval: TimeInterval, lang: Lang = .ru) -> String {
        let total = Int(max(interval, 0).rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let l = L10n(lang)

        if days > 0 { return "\(days) \(l.pick("дн", "d")) \(hours) \(l.pick("ч", "h"))" }
        if hours > 0 { return "\(hours) \(l.pick("ч", "h")) \(minutes) \(l.pick("мин", "m"))" }
        if minutes > 0 { return "\(minutes) \(l.pick("мин", "m"))" }
        return l.pick("меньше минуты", "under a minute")
    }

    /// «2 дня 4 часа», «1 час 12 минут», «42 минуты» — та же длительность, что
    /// у `duration`, но словами. В панели место дорого и «2 дн 4 ч» там
    /// уместно; в уведомлении строка одна, места хватает, а сокращения
    /// читаются телеграммой.
    public static func longDuration(_ interval: TimeInterval, lang: Lang = .ru) -> String {
        let total = Int(max(interval, 0).rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let l = L10n(lang)

        // Ровный остаток называем одним словом: «3 часа», а не «3 часа
        // 0 минут» — ноль в строке читается как опечатка.
        if days > 0 {
            let head = l.plural(days, "день", "дня", "дней", "day", "days")
            return hours > 0
                ? "\(head) \(l.plural(hours, "час", "часа", "часов", "hour", "hours"))"
                : head
        }
        if hours > 0 {
            let head = l.plural(hours, "час", "часа", "часов", "hour", "hours")
            return minutes > 0
                ? "\(head) \(l.plural(minutes, "минута", "минуты", "минут", "minute", "minutes"))"
                : head
        }
        if minutes > 0 { return l.plural(minutes, "минута", "минуты", "минут", "minute", "minutes") }
        return l.pick("меньше минуты", "under a minute")
    }

    /// Проценты без дрожания знаков: всегда целое число.
    public static func percent(_ value: Double, withSign sign: Bool = true) -> String {
        let rounded = Int(value.rounded())
        return sign ? "\(rounded) %" : "\(rounded)"
    }

    /// «12,4 млн», «812 тыс», «431». Токенов за неделю набегают миллионы, и
    /// точное их число не значит ничего — читается порядок.
    ///
    /// Дробный разделитель идёт за языком: «12,4 млн» по-русски и «12.4M»
    /// по-английски — запятая там читается как разделитель тысяч.
    public static func tokens(_ count: Int, lang: Lang = .ru) -> String {
        let value = Double(count)
        if value >= 1_000_000 {
            let millions = String(format: "%.1f", value / 1_000_000)
            return lang == .ru
                ? "\(millions.replacingOccurrences(of: ".", with: ",")) млн"
                : "\(millions)M"
        }
        if value >= 1_000 {
            let thousands = Int((value / 1_000).rounded())
            return lang == .ru ? "\(thousands) тыс" : "\(thousands)K"
        }
        return "\(count)"
    }

    /// Условная стоимость: те же доллары, которыми меряется недельный бюджет.
    /// Настоящих денег это не значит — подписка списывает своё независимо.
    public static func cost(_ value: Double, lang: Lang = .ru) -> String {
        let text = String(format: "%.2f", value)
        return lang == .ru
            ? "\(text.replacingOccurrences(of: ".", with: ",")) $"
            : "$\(text)"
    }

    /// «сброс 14 ПТ 16:00» — число, день недели и час сброса в зоне окна, той
    /// же, по которой панель считает сутки. Московского хвоста для сверки
    /// здесь больше нет: два часа подряд читались как спорящие, а нужен
    /// всегда только свой.
    ///
    /// Число месяца добавлено к дню недели не для устранения неоднозначности
    /// — сброс всегда в пределах недели вперёд, и «ПТ» одно на всё окно, —
    /// а потому что голый день недели требует знать, какое сегодня число,
    /// чтобы посчитать разницу; число рядом с ним читается сразу.
    public static func resetLabel(_ window: WeekWindow, lang: Lang = .ru) -> String {
        let end = window.end
        let date = dayOfMonth(end, calendar: window.calendar)
        let day = weekdayShort(end, calendar: window.calendar, lang: lang)
        let time = clock(end, calendar: window.calendar)
        return L10n(lang).pick("сброс \(date) \(day) \(time)", "resets \(date) \(day) \(time)")
    }

    /// Число месяца без ведущего нуля — «7», «29». Один и тот же формат для
    /// обоих языков: число само по себе локали не требует.
    public static func dayOfMonth(_ date: Date, calendar: Calendar) -> String {
        "\(calendar.component(.day, from: date))"
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
        calendar: Calendar,
        lang: Lang = .ru
    ) -> String {
        let l = L10n(lang)
        let remaining = duration(max(resetsAt.timeIntervalSince(now), 0), lang: lang)
        let left = l.pick("через \(remaining)", "in \(remaining)")
        let sameDay = calendar.isDate(resetsAt, inSameDayAs: now)
        let day = sameDay ? "" : "\(weekdayShort(resetsAt, calendar: calendar, lang: lang)) "
        let moment = "\(day)\(clock(resetsAt, calendar: calendar))"

        switch display {
        case .relative: return left
        case .absolute: return l.pick("в \(moment)", "at \(moment)")
        case .both: return "\(left) (\(moment))"
        }
    }
}
