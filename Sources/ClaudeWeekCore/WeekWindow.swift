import Foundation

/// Одни сутки недельного окна.
public struct WeekDaySlot: Sendable, Equatable {
    public let index: Int
    public let start: Date
    public let end: Date
    /// План на опорной точке суток (`planAnchor`), в процентах.
    public let planPercent: Double
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
            anchor: config.planAnchor
        )
    }

    public init(start: Date, end: Date, calendar: Calendar, anchor: PlanAnchor) {
        self.start = start
        self.end = end
        self.calendar = calendar
        self.anchor = anchor
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Доля прожитого окна: 0 в момент сброса, 1 в момент следующего.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// Непрерывный план на момент `date`, в процентах: сколько допустимо
    /// потратить к этой секунде при равномерном темпе.
    public func planPercent(at date: Date) -> Double {
        progress(at: date) * 100
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    public func dayStart(_ index: Int) -> Date {
        calendar.date(byAdding: .day, value: index, to: start) ?? start
    }

    /// План строки дня: середина суток (ряд 7/21/36/50/64/79/93) или их конец
    /// (14/29/43/57/71/86/100). Считается по номеру суток, а не по абсолютному
    /// времени, поэтому ряд не плывёт в неделю с переводом часов.
    public func planPercent(forDay index: Int, anchor: PlanAnchor? = nil) -> Double {
        let offset = (anchor ?? self.anchor) == .midDay ? 0.5 : 1.0
        return (Double(index) + offset) / Double(WeekWindow.daysInWeek) * 100
    }

    public var days: [WeekDaySlot] {
        (0..<WeekWindow.daysInWeek).map { index in
            WeekDaySlot(
                index: index,
                start: dayStart(index),
                end: dayStart(index + 1),
                planPercent: planPercent(forDay: index)
            )
        }
    }

    /// Номер суток окна, в которые попадает `date`; nil — момент вне окна.
    /// Сутки окна начинаются в час сброса, а не в полночь, поэтому идём по
    /// границам слотов, а не по календарным дням.
    public func dayIndex(for date: Date) -> Int? {
        guard contains(date) else { return nil }
        for index in 0..<WeekWindow.daysInWeek where date < dayStart(index + 1) {
            return index
        }
        return WeekWindow.daysInWeek - 1
    }

    public func timeLeft(from date: Date) -> TimeInterval {
        max(end.timeIntervalSince(date), 0)
    }
}
