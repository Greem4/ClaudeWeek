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
        case .ready:
            snapshot?.isEstimate == true ? "оценка по локальным транскриптам, не официальные данные" : nil
        }
    }

    var isEstimate: Bool { snapshot?.isEstimate ?? false }

    /// Меньше двух часов до сброса — футер получает акцент.
    var resetIsClose: Bool {
        guard let metrics else { return false }
        return metrics.timeLeft < 2 * 3600
    }

    func apply(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        status = .ready
        now = Date()
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
