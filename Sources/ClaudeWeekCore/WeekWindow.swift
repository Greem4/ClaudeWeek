import Foundation

/// Одни сутки недельного окна — календарные, от местной полуночи до местной
/// полуночи. Крайние строки окна короче: сброс приходится на середину суток.
public struct WeekDaySlot: Sendable, Equatable {
    public let index: Int
    public let start: Date
    public let end: Date
    /// План на опорной точке суток (`planAnchor`), в процентах.
    public let planPercent: Double
    /// Сутки урезаны границей окна: вечер пятницы после сброса или её утро
    /// до следующего. Полосе это не мешает, но подпись без пояснения
    /// показывала бы два одинаковых «ПТ» с несопоставимыми процентами.
    public let isPartial: Bool

    public init(index: Int, start: Date, end: Date, planPercent: Double, isPartial: Bool = false) {
        self.index = index
        self.start = start
        self.end = end
        self.planPercent = planPercent
        self.isPartial = isPartial
    }
}

/// Окно недельного лимита: от последнего сброса до следующего.
///
/// Прибавление недели — календарное (`byAdding: .day, value: 7`), а не
/// «+604800 секунд»: в неделю с переводом часов сутки бывают 23 или 25 часов,
/// и сброс должен остаться в 15:00 локального времени.
public struct WeekWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let calendar: Calendar
    public let anchor: PlanAnchor
    /// Часы, в которые план растёт. Всё остальное время он стоит.
    public let workHours: WorkHours
    /// Границы строк панели: старт окна, каждая местная полночь внутри него,
    /// конец окна. Отсюда и число строк, и их план.
    public let dayBounds: [Date]
    /// Рабочих секунд во всём окне — знаменатель плана.
    private let workTotal: TimeInterval

    /// Длина окна в сутках. Строк на панели может быть больше: сброс редко
    /// попадает в полночь, и тогда неделя накрывает восемь местных дат.
    public static let daysInWeek = 7

    public init(containing date: Date, config: Config) {
        let calendar = config.calendar
        var match = DateComponents()
        match.weekday = config.resetWeekday
        match.hour = config.resetHour
        match.minute = config.resetMinute
        match.second = 0

        // nextDate ищет строго раньше `date`, поэтому момент ровно на сбросе
        // сначала уходит в прошлую неделю — возвращаем его шагом вперёд.
        var start = calendar.nextDate(
            after: date,
            matching: match,
            matchingPolicy: .nextTime,
            direction: .backward
        ) ?? date
        if let exact = calendar.nextDate(
            after: start,
            matching: match,
            matchingPolicy: .nextTime,
            direction: .forward
        ), exact <= date {
            start = exact
        }

        self.init(
            start: start,
            end: calendar.date(byAdding: .day, value: WeekWindow.daysInWeek, to: start) ?? start,
            calendar: calendar,
            anchor: config.planAnchor,
            workHours: config.workHours
        )
    }

    /// Окно по моменту сброса из официального ответа (`resets_at`).
    ///
    /// Это источник правды, когда он доступен: `resetWeekday`/`resetHour` в
    /// конфиге — всего лишь догадка пользователя, а сервер знает точно.
    /// Начало отсчитывается календарным шагом назад, чтобы неделя с переводом
    /// часов не съезжала на час.
    public init(endingAt end: Date, config: Config) {
        let calendar = config.calendar
        self.init(
            start: calendar.date(byAdding: .day, value: -WeekWindow.daysInWeek, to: end) ?? end,
            end: end,
            calendar: calendar,
            anchor: config.planAnchor,
            workHours: config.workHours
        )
    }

    public init(
        start: Date,
        end: Date,
        calendar: Calendar,
        anchor: PlanAnchor,
        workHours: WorkHours = WorkHours.default
    ) {
        self.start = start
        self.end = end
        self.calendar = calendar
        self.anchor = anchor
        self.workHours = workHours
        self.dayBounds = WeekWindow.bounds(from: start, to: end, calendar: calendar)
        self.workTotal = workHours.seconds(from: start, to: end, calendar: calendar)
    }

    /// Границы суток панели. Сутки календарные, а не «от сброса до сброса»:
    /// человек живёт по местной полуночи, и строка «СР» должна подсветиться
    /// в среду утром, а не в 16:00, когда начинаются сутки окна с этой датой.
    ///
    /// Плата за это — крайние строки: при сбросе в 16:00 неделя начинается
    /// вечером пятницы (8 часов) и заканчивается её же утром (16 часов), так
    /// что строк восемь, а не семь. Проценты плана считаются по времени, а не
    /// по номеру строки, поэтому обрезанные сутки получают свою долю честно.
    private static func bounds(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        guard end > start else { return [start, end] }
        var result = [start]
        var cursor = calendar.startOfDay(for: start)

        // Шагов заведомо больше, чем дат в окне: страховка на случай, когда
        // календарь вернёт ту же полночь (перевод часов ровно в полночь).
        for _ in 0..<(daysInWeek + 2) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let midnight = calendar.startOfDay(for: next)
            guard midnight > cursor, midnight < end else { break }
            cursor = midnight
            if midnight > start { result.append(midnight) }
        }

        result.append(end)
        return result
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Доля отработанного окна: 0 в момент сброса, 1 в момент следующего.
    ///
    /// Считается по рабочим часам, а не по календарным: ночью план стоит.
    /// Иначе треть недельного бюджета доставалась бы сну, а на краях окна
    /// это выходило боком — вечеру пятницы после сброса (8 часов, все
    /// рабочие) плана начислялось вдвое меньше, чем её утру (16 часов,
    /// из которых 11 человек спит).
    public func progress(at date: Date) -> Double {
        guard workTotal > 0 else {
            guard duration > 0 else { return 0 }
            return min(max(date.timeIntervalSince(start) / duration, 0), 1)
        }
        let worked = workHours.seconds(from: start, to: min(max(date, start), end), calendar: calendar)
        return min(max(worked / workTotal, 0), 1)
    }

    /// Непрерывный план на момент `date`, в процентах: сколько допустимо
    /// потратить к этой секунде при ровном темпе в рабочие часы.
    public func planPercent(at date: Date) -> Double {
        progress(at: date) * 100
    }

    /// Момент, к которому план дорастёт до доли `progress` (0…1). Обратная
    /// к `progress(at:)`: нужна прогнозу «при таком темпе кончится в …»,
    /// потому что с рабочими часами время течёт неравномерно и делением
    /// такой момент больше не находится.
    public func date(atProgress progress: Double) -> Date {
        let target = min(max(progress, 0), 1) * workTotal
        guard workTotal > 0 else {
            return start.addingTimeInterval(duration * min(max(progress, 0), 1))
        }

        var worked: TimeInterval = 0
        var cursor = start

        // Идём по строкам: внутри одних суток рабочий отрезок непрерывен,
        // и остаток добирается пропорционально.
        for index in 0..<slotCount {
            let next = dayBounds[index + 1]
            let step = workHours.seconds(from: cursor, to: next, calendar: calendar)
            if worked + step >= target {
                return moment(after: target - worked, from: cursor, notLaterThan: next)
            }
            worked += step
            cursor = next
        }

        return end
    }

    /// Момент внутри одних суток, к которому накопится `seconds` рабочего
    /// времени. Шаг — минута: панель всё равно показывает часы и минуты,
    /// а секундная точность стоила бы вдвое больше проходов.
    private func moment(after seconds: TimeInterval, from: Date, notLaterThan limit: Date) -> Date {
        guard seconds > 0 else { return from }
        var low = from
        var high = limit

        while high.timeIntervalSince(low) > 60 {
            let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            if workHours.seconds(from: from, to: middle, calendar: calendar) < seconds {
                low = middle
            } else {
                high = middle
            }
        }
        return high
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Сколько строк на панели: семь при сбросе ровно в полночь, иначе восемь.
    public var slotCount: Int { max(dayBounds.count - 1, 0) }

    /// Начало строки `index`; на `slotCount` возвращает конец окна — так
    /// проверяется «эти сутки ещё не наступили».
    public func dayStart(_ index: Int) -> Date {
        guard index >= 0, index < dayBounds.count else { return index < 0 ? start : end }
        return dayBounds[index]
    }

    /// План строки: сколько всего допустимо потратить к концу её суток
    /// (`endOfDay`) или к их середине (`midDay`). Середина — половина
    /// рабочего времени строки, а не полдень: у суток с двумя рабочими
    /// часами и у суток с тринадцатью середина плана разная.
    ///
    /// Считается по рабочим часам, а не по номеру строки: сутки бывают
    /// неполными (края окна) и удлинёнными (перевод часов), и только так ряд
    /// приходит ровно к 100 % в момент сброса.
    public func planPercent(forDay index: Int, anchor: PlanAnchor? = nil) -> Double {
        guard index >= 0, index < slotCount else { return 0 }
        let to = planPercent(at: dayBounds[index + 1])
        guard (anchor ?? self.anchor) == .midDay else { return to }
        return (planPercent(at: dayBounds[index]) + to) / 2
    }

    public var days: [WeekDaySlot] {
        (0..<slotCount).map { index in
            let from = dayBounds[index]
            let to = dayBounds[index + 1]
            return WeekDaySlot(
                index: index,
                start: from,
                end: to,
                planPercent: planPercent(forDay: index),
                isPartial: from != calendar.startOfDay(for: from) || to != calendar.startOfDay(for: to)
            )
        }
    }

    /// Номер строки, в которую попадает `date`; nil — момент вне окна.
    public func dayIndex(for date: Date) -> Int? {
        guard contains(date) else { return nil }
        for index in 0..<slotCount where date < dayBounds[index + 1] {
            return index
        }
        return slotCount - 1
    }

    public func timeLeft(from date: Date) -> TimeInterval {
        max(end.timeIntervalSince(date), 0)
    }
}
