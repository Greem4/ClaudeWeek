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

    var state: LimitState {
        metrics?.state ?? .onTrack
    }

    /// Номер текущих суток окна — их строку подсвечиваем. Совпадает с
    /// `DayUsage.index`: строки нумеруются сутками окна, а не позицией в ряду.
    var todayIndex: Int? {
        snapshot?.window.dayIndex(for: now)
    }

    /// Сколько строк рисовать до прихода данных: столько же, сколько потом,
    /// иначе панель дёрнется в высоте, когда данные наконец придут.
    var placeholderRows: Int {
        WeekWindow(containing: now, config: config).rowCount
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
        case .synced: "данные online"
        case .stale, .local: "данные offline"
        case .pending: "данные загружаются"
        case .missing: "данные недоступны"
        }
    }

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
