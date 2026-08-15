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

/// Чем потрачена неделя: одна модель — одна строка. Считается по локальным
/// транскриптам и только по ним: официальный `/api/oauth/usage` разбивки не
/// отдаёт вовсе — там один процент на всю неделю (см. `docs/API.md`).
/// Поэтому доля здесь — оценка по весам моделей, даже когда итог недели
/// пришёл от сервера точным.
public struct ModelUsage: Sendable, Equatable {
    /// Семейство модели — ключ, каким его знает `ModelFamily`.
    public let family: String
    /// Условная стоимость в долларах — та же величина, которой меряется вся
    /// локальная оценка.
    public let cost: Double
    public let tokens: TokenCounts
    /// Сколько ответов модели попало в окно.
    public let messages: Int
    /// Доля этой модели в стоимости недели, 0…100.
    public let sharePercent: Double

    public init(
        family: String,
        cost: Double,
        tokens: TokenCounts,
        messages: Int,
        sharePercent: Double
    ) {
        self.family = family
        self.cost = cost
        self.tokens = tokens
        self.messages = messages
        self.sharePercent = sharePercent
    }

    public var title: String { ModelFamily.title(family) }
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

    /// Состояние сессии по её собственным порогам.
    public func state(thresholds: Thresholds = Thresholds()) -> LimitState {
        LimitState.forPercent(
            usedPercent,
            warn: thresholds.sessionWarn,
            critical: thresholds.sessionCritical
        )
    }
}

/// Состояние лимита — то, чем красятся значок и панель.
///
/// Уведомления живут рядом, но по своим порогам (`NotificationsConfig`): цвет
/// замечают, только глядя на значок, а баннер приходит сам, и отметки у этих
/// двух разговоров разные.
///
/// Считается по одному только факту: сколько потрачено сейчас. Недельный
/// лимит и пятичасовая сессия проходят через одну и ту же лестницу порогов,
/// каждый со своими значениями.
public enum LimitState: String, Sendable {
    /// Расхода ещё немного.
    case normal
    /// Пора приглядывать.
    case warning
    /// Лимит на исходе.
    case critical
    /// Лимит исчерпан.
    case exhausted

    /// Порог берётся включительно: настроенные 80 % загораются ровно на 80 %,
    /// а не на 80.1 — человек читает шкалу именно так.
    public static func forPercent(_ percent: Double, warn: Double, critical: Double) -> LimitState {
        if percent >= 100 { return .exhausted }
        if percent >= critical { return .critical }
        if percent >= warn { return .warning }
        return .normal
    }
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
    /// Чем потрачена неделя; пусто — транскриптов не нашлось. Всегда оценка,
    /// даже при точном итоге: разбивку считают локальные транскрипты.
    public let byModel: [ModelUsage]

    public init(
        usedPercent: Double,
        byDay: [DayUsage],
        window: WeekWindow,
        source: SourceKind,
        fetchedAt: Date,
        isEstimate: Bool,
        shapeIsEstimate: Bool = false,
        session: SessionUsage? = nil,
        byModel: [ModelUsage] = []
    ) {
        self.usedPercent = usedPercent
        self.byDay = byDay
        self.window = window
        self.source = source
        self.fetchedAt = fetchedAt
        self.isEstimate = isEstimate
        self.shapeIsEstimate = shapeIsEstimate
        self.session = session
        self.byModel = byModel
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
        session: SessionUsage? = nil,
        byModel: [ModelUsage] = []
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
            session: session,
            byModel: byModel
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
            session: session,
            byModel: byModel
        )
    }

    /// Сколько недельного лимита пришлось на эту модель: её доля от итога
    /// недели. У официального источника итог точный, доля — оценка, поэтому
    /// произведение честнее всего называть «примерно столько».
    public func limitPercent(of model: ModelUsage) -> Double {
        model.sharePercent / 100 * usedPercent
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
            state: state(thresholds: thresholds)
        )
    }

    /// Состояние недели — по потраченному проценту, без оглядки на план.
    /// Обгон плана виден в панели темпом и прогнозом; цвет он больше не трогает.
    public func state(thresholds: Thresholds = Thresholds()) -> LimitState {
        LimitState.forPercent(
            usedPercent,
            warn: thresholds.weekWarn,
            critical: thresholds.weekCritical
        )
    }
}
