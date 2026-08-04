import Foundation

/// Выбирает источник по `config.provider` и переживает его отказ.
///
/// В режиме `auto` официальный источник — основной, локальная оценка —
/// запасной: виджет продолжает показывать цифру офлайн, в самолёте и после
/// разлогина из Claude Code, просто помечает её как приблизительную.
public actor ResolvingProvider: UsageProvider {
    nonisolated public let kind: SourceKind

    private let config: Config
    private let preference: ProviderPreference
    private let official: OfficialProvider?
    private let local: LocalProvider
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date

    public init(
        config: Config,
        credentials: CredentialsSource = KeychainCredentials(),
        transport: UsageTransport = URLSessionTransport(),
        cacheURL: URL? = Store.cacheURL,
        localRoot: URL = LocalProvider.defaultRoot,
        indexURL: URL = Store.indexURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let local = LocalProvider(config: config, root: localRoot, indexURL: indexURL, clock: clock)
        self.config = config
        self.clock = clock
        self.preference = config.provider
        self.local = local
        self.cacheURL = cacheURL
        self.official = config.provider == .local
            ? nil
            : OfficialProvider(
                config: config,
                credentials: credentials,
                transport: transport,
                shape: local,
                clock: clock
            )
        self.kind = config.provider == .local ? .local : .official
    }

    public func fetch() async throws -> UsageSnapshot {
        if let official {
            do {
                let snapshot = withStoredSession(try await official.fetch())
                save(snapshot, weeklyBudget: await calibrate(to: snapshot))
                return snapshot
            } catch {
                guard preference == .auto else { throw error }
                Log.info("официальный источник не ответил (\(error)), беру локальную оценку")
                do {
                    let snapshot = withStoredSession(try await local.fetch(
                        budgetOverride: storedBudget(),
                        windowOverride: storedWindow()
                    ))
                    save(snapshot, weeklyBudget: storedBudget())
                    return snapshot
                } catch {
                    // Ошибка официального источника информативнее: локальная
                    // сводится к «не откалибровано», а причина отказа — там.
                    Log.warn("локальная оценка тоже не вышла: \(error)")
                }
                throw error
            }
        }

        let snapshot = withStoredSession(try await local.fetch(
            budgetOverride: storedBudget(),
            windowOverride: storedWindow()
        ))
        save(snapshot, weeklyBudget: storedBudget())
        return snapshot
    }

    /// Подставляет в снимок последнюю официальную сессию, пока её пятичасовое
    /// окно не истекло. Без этого строка сессии пропадала бы из панели при
    /// первом же обрыве сети, хотя сам лимит никуда не делся; истёкшую же
    /// не подставляем никогда — она не «слегка устарела», а обнулилась.
    private func withStoredSession(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        guard snapshot.session == nil,
              let cacheURL,
              let stored = Store.loadCache(from: cacheURL)?.session,
              stored.isFresh(at: snapshot.fetchedAt)
        else { return snapshot }
        return snapshot.with(session: stored)
    }

    /// Подбирает бюджет недели по официальному проценту: сколько условных
    /// долларов по транскриптам приходится на 100 % лимита.
    ///
    /// Это та же калибровка, что делает `--calibrate`, только выполняется сама
    /// и на каждом успешном ответе. Смысл — чтобы падение на локальный источник
    /// давало осмысленную цифру, а не прочерк «не откалибровано».
    private func calibrate(to snapshot: UsageSnapshot) async -> Double? {
        guard snapshot.usedPercent > 0 else { return storedBudget() }
        guard let usage = try? await local.scan(window: snapshot.window, now: snapshot.fetchedAt),
              usage.totalCost > 0
        else { return storedBudget() }
        return usage.totalCost / (snapshot.usedPercent / 100)
    }

    /// Бюджет из прошлого успешного официального ответа.
    private func storedBudget() -> Double? {
        guard let cacheURL else { return nil }
        return Store.loadCache(from: cacheURL)?.weeklyBudget
    }

    /// Окно с настоящим моментом сброса — из прошлого официального ответа.
    /// Кеш, записанный локальным источником, здесь не годится: он сам построен
    /// по конфигу, и опираться на него значило бы закреплять догадку.
    private func storedWindow() -> WeekWindow? {
        guard let cacheURL, let cache = Store.loadCache(from: cacheURL) else { return nil }
        return cache.projectedWindow(at: clock(), config: config)
    }

    /// Снимок на диск, чтобы следующий запуск показал цифру мгновенно,
    /// не дожидаясь ответа сети.
    private func save(_ snapshot: UsageSnapshot, weeklyBudget: Double?) {
        guard let cacheURL else { return }
        // Момент сброса от сервера переживает локальные перезаписи кеша:
        // потеряв его, офлайн-режим вернулся бы к догадке из конфига.
        let officialEnd = snapshot.source == .official
            ? snapshot.window.end
            : Store.loadCache(from: cacheURL)?.officialWindowEnd

        let cache = CachedUsage(
            usedPercent: snapshot.usedPercent,
            byDay: snapshot.byDay.map(\.usedPercent),
            windowStart: snapshot.window.start,
            windowEnd: snapshot.window.end,
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            weeklyBudget: weeklyBudget,
            officialWindowEnd: officialEnd,
            // Уже отфильтрована по сроку в `withStoredSession`: истёкшая
            // сюда не доходит и тем самым стирается из кеша.
            session: snapshot.session
        )
        do {
            try Store.saveCache(cache, to: cacheURL)
        } catch {
            Log.warn("не сохранил кеш: \(error)")
        }
    }
}

public extension CachedUsage {
    /// Восстанавливает снимок из кеша: окно берём как есть, чтобы полосы
    /// совпадали с тем, что было на момент записи.
    func snapshot(config: Config) -> UsageSnapshot {
        let window = WeekWindow(
            start: windowStart,
            end: windowEnd,
            calendar: config.calendar,
            anchor: config.planAnchor
        )
        return UsageSnapshot.make(
            usedPercent: usedPercent,
            cumulativeByDay: byDay,
            window: window,
            source: source,
            fetchedAt: fetchedAt,
            isEstimate: source == .local,
            shapeIsEstimate: true,
            // Отдаём как есть, не проверяя срок: годна ли сессия — решает тот,
            // кто знает текущий момент, а у восстановления его нет.
            session: session
        )
    }

    /// Кеш от прошлой недели показывать нельзя — он врёт вдвойне.
    func isFresh(at date: Date) -> Bool {
        date >= windowStart && date < windowEnd
    }

    /// Окно текущей недели по последнему моменту сброса, названному сервером.
    ///
    /// Сдвиг целыми неделями — не догадка: лимит и сбрасывается раз в 7 суток,
    /// так что даже месячный офлайн даёт окно точнее, чем `resetHour` из
    /// конфига, который на этой машине расходился с настоящим сбросом на час.
    func projectedWindow(at date: Date, config: Config) -> WeekWindow? {
        guard var end = officialWindowEnd else { return nil }
        let calendar = config.calendar

        while end <= date {
            guard let next = calendar.date(byAdding: .day, value: WeekWindow.daysInWeek, to: end),
                  next > end
            else { return nil }
            end = next
        }
        return WeekWindow(endingAt: end, config: config)
    }
}
