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

    /// Индекс текущих суток окна — строку подсвечиваем.
    var todayIndex: Int? {
        snapshot?.window.dayIndex(for: now)
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

    /// Подпись под заголовком панели: пометка об источнике и свежести.
    var sourceNote: String? {
        switch status {
        case .loading: "получаю данные…"
        case .failed(let text): text
        case .stale(let text): text
        case .ready: readyNote
        }
    }

    /// У официального источника точен итог, но не форма недели: разбивка по
    /// суткам восстановлена из транскриптов. Молчать об этом нельзя — иначе
    /// приблизительные полосы выглядят как официальные.
    private var readyNote: String? {
        guard let snapshot else { return nil }
        if snapshot.isEstimate {
            return "оценка по локальным транскриптам, не официальные данные"
        }
        return snapshot.shapeIsEstimate ? "официальный итог, разбивка по суткам — оценка" : nil
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
