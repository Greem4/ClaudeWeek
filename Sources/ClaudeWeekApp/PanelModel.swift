import Foundation
import Observation
import ClaudeWeekCore

/// Что именно показывает панель прямо сейчас.
enum PanelStatus: Equatable {
    /// Данных ещё нет и кеша тоже — первый запуск.
    case loading
    case ready
    /// Данные есть, но они из кеша и устарели.
    case stale
    /// Данных нет вовсе.
    case failed
}

/// Откуда пришли цифры — то, что раньше говорила строка под заголовком, а
/// теперь показывает кружок в строке сессии. Различаются не только цветом:
/// зелёный и красный при дейтеранопии почти сливаются, поэтому свои цифры
/// панель заливает кружок целиком, а чужие обводит контуром.
enum SourceState {
    /// Свежий ответ сервера — то же число, что в /usage.
    case synced
    /// Цифры официальные, но из кеша: сеть или авторизация отвалились.
    case stale
    /// Локальная оценка по транскриптам ~/.claude/projects.
    case local
    /// Данных ещё нет — первый запуск, ответ в пути.
    case pending
    /// Данных нет и взять негде — отказ без кеша.
    case missing
}

@MainActor
@Observable
final class PanelModel {
    var config: Config
    var snapshot: UsageSnapshot?
    var status: PanelStatus = .loading
    var isRefreshing = false
    /// Тикает раз в минуту, чтобы «до сброса» не врало.
    var now: Date = Date()

    /// Компактный ряд раскрыт кликом по строке дня — на один показ панели.
    /// В отличие от текста источника, это состояние живёт в модели, а не в
    /// самом виде: сбрасывает раскрытие открытие панели, а его вид не видит —
    /// закрывают панель щелчком мимо и по Esc, минуя SwiftUI.
    var expandsWeek = false

    /// На месте строк дней — разбивка по моделям: щёлкнули по цифрам процента.
    /// Живёт здесь и сбрасывается открытием панели по той же причине, что и
    /// раскрытие недели: панель открывают ради недели, и оставлять её в другом
    /// виде до следующего клика нельзя.
    var showsModels = false

    /// Насколько снимок может отстать от «сейчас», прежде чем панель назовёт
    /// его возраст. Официальный источник во время паузы после отказа отдаёт
    /// последнее удачное число — молчать об этом нельзя, иначе позавчерашние
    /// 50 % выглядят как сегодняшние.
    static let freshFor: TimeInterval = 120

    init(config: Config) {
        self.config = config
    }

    var metrics: UsageMetrics? {
        snapshot?.metrics(at: now, thresholds: config.thresholds)
    }

    /// Состояние недели — по потраченному проценту.
    var state: LimitState {
        metrics?.state ?? .normal
    }

    /// Состояние пятичасовой сессии по её собственным порогам.
    var sessionState: LimitState {
        session?.state(thresholds: config.thresholds) ?? .normal
    }

    /// Процент сессии для кольца в строке меню. Сессии нет — ноль, а не
    /// недельное число: кольцо всегда про одно и то же, иначе его не читать.
    var sessionPercent: Double {
        session?.usedPercent ?? 0
    }

    /// Процент и состояние того лимита, что назначен на место в кольце.
    /// Дуга и цифра берут его одинаково, отличаясь только ролью из настройки:
    /// так расклад меняется местами, а не двумя разными ветками кода.
    ///
    /// Недели без снимка не бывает 0 % — бывает «нечего показывать», но
    /// кольцо всё равно рисуется, и ноль здесь честнее пустоты.
    func ringLimit(_ arc: RingArc) -> (percent: Double, state: LimitState) {
        switch arc {
        case .session: (sessionPercent, sessionState)
        case .week: (snapshot?.usedPercent ?? 0, state)
        }
    }

    /// Красить ли значок в строке меню по порогам. Выключенный тумблер гасит
    /// цвет в самой отрисовке, а не подменой состояния на `.normal`: у полосы
    /// `.normal` — зелёный, и «нейтрально» подменой не получалось, выходило
    /// «всегда зелёная». Состояния выше при этом остаются настоящими —
    /// заполнение и цифры от тумблера не зависят.
    var colorizesMenuBar: Bool {
        config.thresholds.colorizeMenuBar
    }

    /// Номер суток, чью строку подсвечиваем как сегодняшнюю. Совпадает с
    /// `DayUsage.index`: строки нумеруются сутками окна, а не позицией в ряду.
    /// Считает окно, а не панель: в день сброса в ряд попадает лишь одна из
    /// двух его половин, и «сегодня» ищется по дню недели (см.
    /// `WeekWindow.highlightedRow(at:)`).
    var todayIndex: Int? {
        snapshot?.window.highlightedRow(at: now)
    }

    /// Показывать весь недельный ряд: так настроено или так раскрыли кликом.
    var showsWholeWeek: Bool {
        config.appearance.panelLayout == .week || expandsWeek
    }

    /// Строки дней на панели: весь ряд или одни текущие сутки.
    ///
    /// Если «сейчас» вне окна снимка — просроченный кеш, до которого ещё не
    /// дошло обновление, — выделять нечего, и компактный вид показывает ряд
    /// целиком: одна наугад выбранная полоса выдавала бы за сегодня чужие сутки.
    func dayRows(_ snapshot: UsageSnapshot) -> [DayUsage] {
        let rows = snapshot.rows(at: now)
        guard !showsWholeWeek,
              let today = rows.first(where: { $0.index == todayIndex })
        else { return rows }
        return [today]
    }

    /// Сколько строк рисовать до прихода данных: столько же, сколько потом,
    /// иначе панель дёрнется в высоте, когда данные наконец придут.
    ///
    /// Дневной план выключен — на месте дней всегда одна полоса недели, и
    /// плейсхолдер-заглушка тоже одна: считать дни окна незачем.
    var placeholderRows: Int {
        guard config.appearance.showsPlan else { return 1 }
        return showsWholeWeek ? WeekWindow(containing: now, config: config).rowCount : 1
    }

    /// Пятичасовая сессия — только пока её окно не истекло. После сброса от
    /// прежнего процента не остаётся ничего, и строка просто исчезает: лучше
    /// не показать лимит, чем показать вчерашние 95 % как сегодняшние.
    var session: SessionUsage? {
        guard let session = snapshot?.session, session.isFresh(at: now) else { return nil }
        return session
    }

    /// Заголовок в строке меню: «64 %» или «≈64 %» для оценки.
    var menuBarTitle: String {
        guard let snapshot else { return "—" }
        let value = Formatting.percent(snapshot.usedPercent, withSign: false)
        return snapshot.isEstimate ? "≈\(value)%" : "\(value)%"
    }

    /// Цвет и форма кружка источника. Устаревшие официальные цифры — это всё
    /// ещё цифры сервера, поэтому кружок остаётся залитым и лишь желтеет:
    /// контур означает «посчитано здесь», а не «давно».
    var sourceState: SourceState {
        guard let snapshot else { return status == .loading ? .pending : .missing }
        if snapshot.isEstimate { return .local }
        if case .ready = status { return .synced }
        return .stale
    }

    /// То же словами — подпись у кружка и подсказка при наведении. Четыре
    /// состояния одной формой «данные …», по одному на цвет кружка.
    ///
    /// Причины здесь нет намеренно: «официальный источник недоступен
    /// (unauthorized)» — строчка лога, а не панели. Читающему хватает того,
    /// свежие перед ним цифры сервера или посчитанные на месте.
    var sourceHint: String {
        switch sourceState {
        case .synced: strings.pick("данные online", "data online")
        case .stale, .local: strings.pick("данные offline", "data offline")
        case .pending: strings.pick("данные загружаются", "loading data")
        case .missing: strings.pick("данные недоступны", "no data available")
        }
    }

    /// Строки панели на выбранном языке. Одно место на всю панель: строки,
    /// подписи для VoiceOver и подсказки берут язык отсюда, а не каждый свой.
    var strings: L10n { config.strings }

    var isEstimate: Bool { snapshot?.isEstimate ?? false }

    /// Меньше двух часов до сброса — футер получает акцент.
    var resetIsClose: Bool {
        guard let metrics else { return false }
        return metrics.timeLeft < 2 * 3600
    }

    /// `at` — момент, относительно которого снимок считается свежим. По
    /// умолчанию системные часы; отрисовка макетов (`--screenshot`) задаёт
    /// свой, иначе демо-снимок «протухал» бы прямо на картинке для README.
    func apply(_ snapshot: UsageSnapshot, at moment: Date = Date()) {
        self.snapshot = snapshot
        now = moment
        let age = moment.timeIntervalSince(snapshot.fetchedAt)
        status = age > PanelModel.freshFor ? .stale : .ready
    }

    /// Что именно случилось, панель не показывает — это уже написано в лог
    /// там, где отказ поймали. Здесь остаётся одно: есть ли что показывать.
    func apply(error: Error) {
        status = snapshot == nil ? .failed : .stale
    }
}
