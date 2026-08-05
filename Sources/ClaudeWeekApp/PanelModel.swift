import Foundation
import Observation
import ClaudeWeekCore

/// Что именно показывает панель прямо сейчас.
enum PanelStatus: Equatable {
    /// Данных ещё нет и кеша тоже — первый запуск.
    case loading
    case ready
    /// Данные есть, но они из кеша и устарели.
    case stale(String)
    /// Данных нет вовсе; текст — что случилось.
    case failed(String)
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
    /// Данных нет вовсе — первый запуск или отказ без кеша.
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
        guard let snapshot else { return .missing }
        if snapshot.isEstimate { return .local }
        if case .ready = status { return .synced }
        return .stale
    }

    /// То же словами — подсказка при наведении на кружок. Строки под
    /// заголовком больше нет, и «нет сети», возраст кеша и оговорка про
    /// разбивку по суткам живут только здесь.
    var sourceHint: String {
        switch status {
        case .loading: return "получаю данные…"
        case .failed(let text): return text
        case .stale(let text): return text
        case .ready:
            guard let snapshot else { return "нет данных" }
            if snapshot.isEstimate {
                return "оценка по локальным транскриптам, не официальные данные"
            }
            return snapshot.shapeIsEstimate
                ? "официальный итог, разбивка по суткам — оценка"
                : "официальные данные, как в /usage"
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
        status = age > PanelModel.freshFor
            ? .stale("данные \(Formatting.age(snapshot.fetchedAt, now: moment))")
            : .ready
    }

    func apply(error: Error) {
        let text = (error as? UsageError)?.errorDescription ?? error.localizedDescription
        if let snapshot {
            let age = Formatting.age(snapshot.fetchedAt, now: Date())
            status = .stale("\(text) · данные \(age)")
        } else {
            status = .failed(text)
        }
    }
}
