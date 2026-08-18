import Foundation

/// Одни сутки недельного окна — календарные, от местной полуночи до местной
/// полуночи. Крайние сутки короче: сброс приходится на середину суток.
public struct WeekDaySlot: Sendable, Equatable {
    public let index: Int
    public let start: Date
    public let end: Date
    /// Накопительный план к концу этих суток, в процентах от недельного лимита.
    public let planPercent: Double
    /// Сутки урезаны границей окна: вечер дня сброса после него или утро того
    /// же дня недели перед следующим. На панели эти две половины делят одну
    /// строку — показывается та, что идёт сейчас.
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
    /// Часы, в которые план растёт. Всё остальное время он стоит.
    public let workHours: WorkHours
    /// С какого дня недели ложится ряд строк. Границы окна от этого не
    /// двигаются: сброс задаёт сервер, а здесь только порядок.
    public let weekStart: WeekStart
    /// Границы суток окна: старт окна, каждая местная полночь внутри него,
    /// конец окна. Отсюда и число суток, и их план.
    public let dayBounds: [Date]
    /// Рабочих секунд во всём окне — знаменатель плана.
    private let workTotal: TimeInterval

    /// Длина окна в сутках. Календарных дат неделя накрывает больше: сброс
    /// редко попадает в полночь, и тогда день сброса разрезан надвое.
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
            workHours: config.workHours,
            weekStart: config.weekStart
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
            workHours: config.workHours,
            weekStart: config.weekStart
        )
    }

    public init(
        start: Date,
        end: Date,
        calendar: Calendar,
        workHours: WorkHours = WorkHours.default,
        weekStart: WeekStart = .reset
    ) {
        self.start = start
        self.end = end
        self.calendar = calendar
        self.workHours = workHours
        self.weekStart = weekStart
        self.dayBounds = WeekWindow.bounds(from: start, to: end, calendar: calendar)
        self.workTotal = workHours.seconds(from: start, to: end, calendar: calendar)
    }

    /// Границы суток окна. Сутки календарные, а не «от сброса до сброса»:
    /// человек живёт по местной полуночи, и строка «СР» должна подсветиться
    /// в среду утром, а не в 16:00, когда начинаются сутки окна с этой датой.
    ///
    /// Плата за это — края: при сбросе в 16:00 неделя начинается вечером
    /// пятницы (8 часов) и заканчивается её же утром (16 часов), так что
    /// календарных суток выходит восемь, а не семь. На панель они всё равно
    /// ложатся семью строками (см. `rows(at:)`), а проценты плана считаются
    /// по времени, а не по номеру суток, — обрезанные получают свою долю честно.
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

    /// Сколько календарных суток накрывает окно: семь при сбросе ровно
    /// в полночь, иначе восемь — день сброса попадает в него дважды.
    public var slotCount: Int { max(dayBounds.count - 1, 0) }

    /// Начало суток `index`; на `slotCount` возвращает конец окна — так
    /// проверяется «эти сутки ещё не наступили».
    public func dayStart(_ index: Int) -> Date {
        guard index >= 0, index < dayBounds.count else { return index < 0 ? start : end }
        return dayBounds[index]
    }

    /// Накопительный план суток: сколько всего допустимо потратить к их концу.
    ///
    /// Считается по рабочим часам, а не по номеру суток: они бывают неполными
    /// (края окна) и удлинёнными (перевод часов), и только так ряд приходит
    /// ровно к 100 % в момент сброса.
    public func planPercent(forDay index: Int) -> Double {
        guard index >= 0, index < slotCount else { return 0 }
        return planPercent(at: dayBounds[index + 1])
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

    /// Номер суток окна, в которые попадает `date`; nil — момент вне окна.
    public func dayIndex(for date: Date) -> Int? {
        guard contains(date) else { return nil }
        for index in 0..<slotCount where date < dayBounds[index + 1] {
            return index
        }
        return slotCount - 1
    }

    // MARK: - Строки панели

    /// Сброс пришёлся не на полночь, и день сброса разрезан надвое: вечер
    /// открывает окно, утро того же дня недели через семь суток его закрывает.
    public var splitsResetDay: Bool { slotCount > WeekWindow.daysInWeek }

    /// Строк на панели всегда семь: день сброса занимает одну, а не две.
    public var rowCount: Int { min(slotCount, WeekWindow.daysInWeek) }

    /// Какие сутки окна показывать строками на момент `date`.
    ///
    /// Двух пятниц в списке быть не должно: это один день недели, просто
    /// разрезанный сбросом, и рядом они спорят несопоставимыми процентами.
    /// Поэтому показывается та половина, которая идёт сейчас: пока неделя
    /// катится, строка пятницы — её вечер после сброса (первая строка ряда,
    /// ~9 %), а с полуночи последних суток окна она превращается в утро перед
    /// следующим сбросом и встаёт в конец ряда, доводя план до 100 %.
    public func rowSlots(at date: Date) -> Range<Int> {
        guard splitsResetDay else { return 0..<slotCount }
        let lastDayStart = dayBounds[slotCount - 1]
        let offset = date >= lastDayStart ? 1 : 0
        return offset..<(offset + rowCount)
    }

    /// Номера суток окна в том порядке, в каком они лягут строками панели.
    ///
    /// При `weekStart == .reset` это подряд идущие сутки от сброса — как
    /// неделя и катится. При `.monday` ряд повёрнут к понедельнику, и сутки
    /// начала окна (выходные сразу после сброса) уезжают вниз: они уже
    /// прошли, и место им под текущей неделей.
    public func rowOrder(at date: Date) -> [Int] {
        switch weekStart {
        case .reset: return Array(rowSlots(at: date))
        case .monday: return mondayFirstOrder()
        }
    }

    /// Порядок строк от понедельника. Половина дня сброса здесь выбирается
    /// не по текущему моменту, а по месту в ряду: когда неделя начинается не
    /// в день сброса, ему достаётся утро перед следующим сбросом — тогда
    /// план в его строке доходит ровно до 100 %, и ряд от понедельника до
    /// дня сброса читается сверху вниз. Начнись неделя в сам день сброса —
    /// наоборот, вечер после него, иначе ряд открывался бы сотней процентов.
    private func mondayFirstOrder() -> [Int] {
        var order = Array(0..<slotCount)
        guard !order.isEmpty else { return [] }
        if splitsResetDay {
            order.remove(at: isWeekStart(dayBounds[0]) ? slotCount - 1 : 0)
        }
        guard let pivot = order.firstIndex(where: { isWeekStart(dayBounds[$0]) }) else { return order }
        return Array(order[pivot...] + order[..<pivot])
    }

    /// Начинается ли с этих суток неделя по настройке. Понедельник — 2
    /// в нумерации `Calendar`, где 1 — воскресенье.
    private func isWeekStart(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == 2
    }

    /// Первые сутки ряда, когда он живёт в своей шкале, — иначе nil.
    ///
    /// Неделя, начатая понедельником, отсчитывает план от него: строка
    /// понедельника открывается нулём, пятница приходит к 100 % в момент
    /// сброса. Ряд от дня сброса и ряд, который и так начинается сутками
    /// сброса, живут в общей с окном шкале — перешкаливать там нечего.
    public func scaleBase(at date: Date) -> Int? {
        guard weekStart == .monday else { return nil }
        guard let first = rowOrder(at: date).first, first > 0 else { return nil }
        return first
    }

    /// План к концу суток `index` в шкале ряда, открытого сутками `base`:
    /// 0 в их полночь, 100 % в момент сброса.
    ///
    /// Считается заново по рабочим часам отрезка, а не сжатием недельного
    /// плана: у выходных, оставшихся за скобкой, свой вес, и вычитать его
    /// из общей шкалы значило бы гадать, сколько их часов «принадлежит»
    /// рабочей неделе.
    public func planPercent(forDay index: Int, from base: Int) -> Double {
        guard dayBounds.indices.contains(base), dayBounds.indices.contains(index + 1) else { return 0 }
        let from = dayBounds[base]
        let total = workHours.seconds(from: from, to: end, calendar: calendar)
        guard total > 0 else { return 0 }
        let worked = workHours.seconds(from: from, to: dayBounds[index + 1], calendar: calendar)
        return min(max(worked / total, 0), 1) * 100
    }

    /// Строки панели на момент `date`. Номера суток сохраняются: по ним
    /// подтягивается факт и подсвечивается текущая строка.
    public func rows(at date: Date) -> [WeekDaySlot] {
        let days = days
        let base = scaleBase(at: date)
        return rowOrder(at: date).compactMap { index in
            guard days.indices.contains(index) else { return nil }
            let day = days[index]
            // Сутки за скобкой — те, что прошли до начала недели, — остаются
            // в недельной шкале: они и правда съели свою долю лимита.
            guard let base, index >= base else { return day }
            return WeekDaySlot(
                index: day.index,
                start: day.start,
                end: day.end,
                planPercent: planPercent(forDay: index, from: base),
                isPartial: day.isPartial
            )
        }
    }

    /// Номер суток, чья строка в ряду отвечает за «сегодня».
    ///
    /// Обычно это сами текущие сутки, но в день сброса их половина может не
    /// попасть в ряд: при `.monday` день сброса представлен утренней
    /// половиной, а человек смотрит на панель вечером того же дня. Строка у
    /// этого дня недели всё равно одна — её и подсвечиваем, иначе в день
    /// сброса панель осталась бы вовсе без «сегодня».
    public func highlightedRow(at date: Date) -> Int? {
        guard let today = dayIndex(for: date) else { return nil }
        let order = rowOrder(at: date)
        if order.contains(today) { return today }
        let weekday = calendar.component(.weekday, from: dayBounds[today])
        return order.first { calendar.component(.weekday, from: dayBounds[$0]) == weekday }
    }

    public func timeLeft(from date: Date) -> TimeInterval {
        max(end.timeIntervalSince(date), 0)
    }
}
