import Foundation

public enum SourceKind: String, Codable, Sendable {
    case official
    case local
}

/// Одни сутки окна: накопительный план к их концу и такой же накопительный
/// факт. На панель попадают семь из них — см. `rows(at:)`.
public struct DayUsage: Sendable, Equatable {
    public let index: Int
    public let start: Date
    public let end: Date
    public let planPercent: Double
    /// Накопительный расход от начала недели; nil — сутки ещё не наступили.
    public let usedPercent: Double?
    /// Сутки обрезаны краем недельного окна: это половина дня сброса —
    /// у неё та же подпись дня, что у полных суток, но меньше часов и плана.
    public let isPartial: Bool

    public init(
        index: Int,
        start: Date,
        end: Date,
        planPercent: Double,
        usedPercent: Double?,
        isPartial: Bool = false
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.planPercent = planPercent
        self.usedPercent = usedPercent
        self.isPartial = isPartial
    }

    /// Часть факта, вышедшая за план этих суток.
    public var overspendPercent: Double {
        guard let used = usedPercent else { return 0 }
        return max(used - planPercent, 0)
    }
}

/// Пятичасовая сессия — второй лимит, живущий рядом с недельным и ничем с ним
/// не связанный: неделя может быть на 20 %, а сессия на 95 %, и упрётесь вы
/// именно в неё. Плана внутри сессии нет: пятичасовое окно не обязано
/// расходоваться равномерно, поэтому здесь только факт и момент сброса.
public struct SessionUsage: Codable, Sendable, Equatable {
    /// Расход лимита сессии, 0…100.
    public let usedPercent: Double
    public let resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Окно сессии ещё не истекло. Проверять обязательно: сессия короче суток,
    /// и число из кеша прошлого запуска устаревает не «немного», а полностью —
    /// после сброса от него остаётся ноль, а показали бы мы 95 %.
    public func isFresh(at now: Date) -> Bool { now < resetsAt }

    public func timeLeft(from now: Date) -> TimeInterval {
        max(resetsAt.timeIntervalSince(now), 0)
    }

    public var isExhausted: Bool { usedPercent >= 100 }
}

/// Состояние лимита — единственная точка, к которой подключаются уведомления,
/// если они когда-нибудь понадобятся (сейчас их нет, см. §10 плана).
public enum LimitState: String, Sendable {
    /// Идём в графике.
    case onTrack
    /// Обгоняем план.
    case overPlan
    /// Лимит на исходе.
    case critical
    /// Лимит недели исчерпан.
    case exhausted
}

public struct UsageMetrics: Sendable, Equatable {
    public let usedPercent: Double
    public let remainingPercent: Double
    public let planNowPercent: Double
    public let timeLeft: TimeInterval
    /// Во сколько раз факт обгоняет план: 1.0 — ровно по плану.
    /// nil сразу после сброса, когда план ещё нулевой.
    public let burnRate: Double?
    /// Прогноз расхода к моменту сброса при сохранении темпа.
    public let projectedPercent: Double?
    /// Когда лимит кончится при текущем темпе; nil — если не кончится до сброса.
    public let exhaustionDate: Date?
    public let state: LimitState
}

public struct UsageSnapshot: Sendable {
    public let usedPercent: Double
    public let byDay: [DayUsage]
    public let window: WeekWindow
    public let source: SourceKind
    public let fetchedAt: Date
    /// Приблизителен ли сам итог недели.
    public let isEstimate: Bool
    /// Приблизительна ли разбивка по суткам. У официального источника итог
    /// точный, а форма всё равно восстановлена по локальным транскриптам —
    /// смешивать эти два вида приблизительности в одном флаге нельзя.
    public let shapeIsEstimate: Bool
    /// Пятичасовой лимит; nil — его не сообщили. Локальный источник его не
    /// считает: веса моделей приближают недельную формулу, а не сессионную,
    /// и выдумывать второе число по тем же данным значило бы врать точнее,
    /// чем мы знаем.
    public let session: SessionUsage?

    public init(
        usedPercent: Double,
        byDay: [DayUsage],
        window: WeekWindow,
        source: SourceKind,
        fetchedAt: Date,
        isEstimate: Bool,
        shapeIsEstimate: Bool = false,
        session: SessionUsage? = nil
    ) {
        self.usedPercent = usedPercent
        self.byDay = byDay
        self.window = window
        self.source = source
        self.fetchedAt = fetchedAt
        self.isEstimate = isEstimate
        self.shapeIsEstimate = shapeIsEstimate
        self.session = session
    }

    /// Собирает строки дней из накопительных процентов: `cumulative[i]` —
    /// расход от начала недели до конца i-х суток, nil для будущего.
    public static func make(
        usedPercent: Double,
        cumulativeByDay: [Double?],
        window: WeekWindow,
        source: SourceKind,
        fetchedAt: Date,
        isEstimate: Bool,
        shapeIsEstimate: Bool = false,
        session: SessionUsage? = nil
    ) -> UsageSnapshot {
        let days = window.days.map { slot in
            DayUsage(
                index: slot.index,
                start: slot.start,
                end: slot.end,
                planPercent: slot.planPercent,
                usedPercent: slot.index < cumulativeByDay.count ? cumulativeByDay[slot.index] : nil,
                isPartial: slot.isPartial
            )
        }
        return UsageSnapshot(
            usedPercent: usedPercent,
            byDay: days,
            window: window,
            source: source,
            fetchedAt: fetchedAt,
            isEstimate: isEstimate,
            shapeIsEstimate: shapeIsEstimate,
            session: session
        )
    }

    /// Строки панели на момент `now`: семь суток, где день сброса представлен
    /// той своей половиной, которая идёт сейчас. До полуночи последних суток
    /// окна это вечер после сброса, дальше — утро перед следующим.
    public func rows(at now: Date) -> [DayUsage] {
        window.rowSlots(at: now).compactMap { index in
            byDay.indices.contains(index) ? byDay[index] : nil
        }
    }

    /// Тот же снимок с другой сессией. Нужна потому, что считает неделю один
    /// источник, а помнит сессию — другой: локальная оценка про пятичасовой
    /// лимит не знает ничего, и его подставляет тот, у кого есть кеш.
    public func with(session: SessionUsage?) -> UsageSnapshot {
        UsageSnapshot(
            usedPercent: usedPercent,
            byDay: byDay,
            window: window,
            source: source,
            fetchedAt: fetchedAt,
            isEstimate: isEstimate,
            shapeIsEstimate: shapeIsEstimate,
            session: session
        )
    }

    public func metrics(at now: Date, thresholds: Thresholds = Thresholds()) -> UsageMetrics {
        let progress = window.progress(at: now)
        let planNow = progress * 100
        let burnRate: Double? = planNow > 0 ? usedPercent / planNow : nil
        let projected: Double? = progress > 0 ? usedPercent / progress : nil

        // Момент, к которому при нынешнем темпе натечёт 100 %. Ищется по
        // рабочему времени: ночью план стоит, и делить календарные часы
        // пропорционально расходу больше нельзя — прогноз обещал бы
        // исчерпание в четыре утра, когда никто не работает.
        var exhaustion: Date?
        if let projected, projected > 100, usedPercent > 0 {
            exhaustion = window.date(atProgress: progress * 100 / usedPercent)
        }

        return UsageMetrics(
            usedPercent: usedPercent,
            remainingPercent: max(100 - usedPercent, 0),
            planNowPercent: planNow,
            timeLeft: window.timeLeft(from: now),
            burnRate: burnRate,
            projectedPercent: projected,
            exhaustionDate: exhaustion,
            state: state(at: now, thresholds: thresholds)
        )
    }

    /// Жёлтое состояние требует двух условий сразу: факт обгоняет план И уже
    /// израсходован ощутимый кусок недели (`warnFloor`). Одного обгона мало —
    /// в первые часы после сброса план околонулевой, и три процента обгоняют
    /// его в разы, хотя тревожиться не о чем.
    public func state(at now: Date, thresholds: Thresholds = Thresholds()) -> LimitState {
        if usedPercent >= 100 { return .exhausted }
        if usedPercent >= thresholds.critical * 100 { return .critical }
        let planNow = window.planPercent(at: now)
        if usedPercent >= thresholds.warnFloor,
           planNow > 0,
           usedPercent > planNow * thresholds.warn {
            return .overPlan
        }
        return .onTrack
    }
}
