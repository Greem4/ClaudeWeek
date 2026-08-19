import Foundation
import ClaudeWeekCore

// MARK: - Дублёры

/// Отдаёт заранее заготовленные ответы и считает, сколько раз в него сходили.
private actor FakeTransport: UsageTransport {
    private var answers: [(Int, Data)]
    private(set) var calls = 0
    private let failure: Error?

    init(answers: [(Int, String)], failure: Error? = nil) {
        self.answers = answers.map { ($0.0, Data($0.1.utf8)) }
        self.failure = failure
    }

    func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
        calls += 1
        if let failure { throw failure }
        // Последний ответ повторяется: тесту редко нужен ровно один вызов.
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? (0, Data()))
    }

    func callCount() -> Int { calls }
}

private struct FakeCredentials: CredentialsSource {
    var token = "sk-ant-oat01-тест"
    var error: Error?
    /// Организация: по ней провайдер и отличает вход другим аккаунтом.
    var organization: String?

    func load() throws -> OAuthCredentials {
        if let error { throw error }
        return OAuthCredentials(
            accessToken: token,
            expiresAt: nil,
            subscriptionType: "max",
            organizationUuid: organization
        )
    }
}

/// Ответ в том виде, в каком его отдаёт api.anthropic.com (проверено 2026-08-04).
/// Половина ключей приходит null — это норма, а не поломка.
private let realResponse = """
{
  "five_hour": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-08-04T20:19:59.357955+00:00",
                "used_dollars": null, "utilization": 41},
  "seven_day": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-08-07T12:00:00.357993+00:00",
                "used_dollars": null, "utilization": 50},
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    {"group": "session", "is_active": false, "kind": "session", "percent": 41,
     "resets_at": "2026-08-04T20:19:59.357955+00:00", "scope": null, "severity": "normal"},
    {"group": "weekly", "is_active": true, "kind": "weekly_all", "percent": 50,
     "resets_at": "2026-08-07T12:00:00.357993+00:00", "scope": null, "severity": "normal"}
  ],
  "member_dashboard_available": false
}
"""

/// Каталог транскриптов со своим индексом и кешем — чтобы тест не трогал
/// настоящие данные пользователя.
private struct TranscriptSandbox {
    let base: URL
    let root: URL
    let indexURL: URL
    let cacheURL: URL
    let stateURL: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-official-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        indexURL = base.appendingPathComponent("index.json")
        cacheURL = base.appendingPathComponent("cache.json")
        stateURL = base.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// Одно сообщение Opus заданной условной стоимости: вход $5 за Mtok.
    func write(cost: Double, at timestamp: String) {
        let tokens = Int(cost / 5 * 1_000_000)
        let line = """
        {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(timestamp)",\
        "message":{"model":"claude-opus-5","usage":{"input_tokens":\(tokens),"output_tokens":0}}}
        """
        try? (line + "\n").write(
            to: root.appendingPathComponent("сессия.jsonl"), atomically: true, encoding: .utf8
        )
    }
}

private let testNow = at(2026, 8, 4, 12, 0)

/// Сравнение дат с допуском в секунду: там, где проверяется не округление, а
/// сам факт разбора, привязываться к тому, срезаны доли секунды или нет,
/// незачем — этим занят отдельный набор «округление момента сброса».
private func same(_ t: Harness, _ got: Date?, _ want: Date, _ what: String) {
    guard let got else { return t.fail("\(what): даты нет вовсе") }
    t.close(got.timeIntervalSince(want), 0, what, tolerance: 1)
}

private func provider(
    answers: [(Int, String)] = [(200, realResponse)],
    credentials: FakeCredentials = FakeCredentials(),
    transportFailure: Error? = nil,
    config c: Config = config(),
    now: Date = testNow
) -> (OfficialProvider, FakeTransport) {
    let transport = FakeTransport(answers: answers, failure: transportFailure)
    let provider = OfficialProvider(
        config: c,
        credentials: credentials,
        transport: transport,
        shape: nil,
        clock: { now }
    )
    return (provider, transport)
}

func runOfficialProviderTests(_ t: Harness) async {
    await t.suite("разбор ответа /api/oauth/usage") {
        let (official, _) = provider()
        let usage = try await official.usage(at: testNow)

        t.close(usage.weekPercent, 50, "недельный процент из seven_day")
        same(t, usage.weekResetsAt, at(2026, 8, 7, 16, 0), "resets_at с микросекундами разобран")
        t.close(usage.sessionPercent ?? -1, 41, "пятичасовой лимит тоже разобран")
        t.equal(usage.sessionResetsAt, at(2026, 8, 5, 0, 20),
                "и его момент сброса, округлённый до минуты")
    }

    await t.suite("пятичасовая сессия") {
        let (official, _) = provider()
        let snapshot = try await official.fetch()

        guard let session = snapshot.session else {
            return t.fail("сессии нет в снимке, хотя в ответе она есть")
        }
        t.close(session.usedPercent, 41, "процент сессии доехал до снимка")
        t.equal(session.resetsAt, at(2026, 8, 5, 0, 20), "вместе с моментом сброса")
        t.close(session.timeLeft(from: testNow), 12 * 3600 + 20 * 60, "до сброса 12 ч 20 мин")
        t.check(!session.isExhausted, "41 % — ещё не исчерпана")
        t.check(SessionUsage(usedPercent: 100, resetsAt: testNow).isExhausted,
                "а 100 % — исчерпана")

        // После сброса прежний процент не «слегка устарел», а обнулился:
        // показывать его нельзя ни в каком виде.
        t.check(session.isFresh(at: testNow), "до сброса окно сессии годно")
        t.check(!session.isFresh(at: at(2026, 8, 5, 1, 0)), "после — уже нет")

        // Пятичасовой строки в ответе может не быть — нулевую сессию из этого
        // выдумывать нельзя.
        let weekOnly = """
        {"seven_day": {"utilization": 50, "resets_at": "2026-08-07T12:00:00.357993+00:00"}}
        """
        let (bare, _) = provider(answers: [(200, weekOnly)])
        t.check(try await bare.fetch().session == nil, "нет five_hour — нет и сессии")
    }

    await t.suite("сессия переживает падение на локальный источник") {
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")

        func resolving(offline: Bool, now: Date) -> ResolvingProvider {
            ResolvingProvider(
                config: config(),
                credentials: offline ? FakeCredentials(error: UsageError.unauthorized) : FakeCredentials(),
                transport: FakeTransport(answers: [(200, realResponse)]),
                cacheURL: sandbox.cacheURL,
                localRoot: sandbox.root,
                indexURL: sandbox.indexURL,
                stateURL: sandbox.stateURL,
                clock: { now }
            )
        }

        _ = try await resolving(offline: false, now: testNow).fetch()
        t.close(Store.loadCache(from: sandbox.cacheURL)?.session?.usedPercent ?? -1, 41,
                "сессия сохранена в кеш")

        // Сеть отвалилась: локальная оценка про сессию не знает ничего, но
        // лимит-то никуда не делся — берём его из кеша.
        let fallback = try await resolving(offline: true, now: testNow).fetch()
        t.equal(fallback.source, .local, "снимок локальный")
        t.close(fallback.session?.usedPercent ?? -1, 41, "и всё же с сессией из кеша")

        // А сутки спустя её окно давно закрыто — кеш обязан её забыть.
        let stale = try await resolving(offline: true, now: at(2026, 8, 5, 12, 0)).fetch()
        t.check(stale.session == nil, "истёкшую сессию в снимок не подставляем")
        t.check(Store.loadCache(from: sandbox.cacheURL)?.session == nil,
                "и из кеша её стираем, а не держим до следующего выхода в сеть")
    }

    await t.suite("запасной путь: seven_day пропал") {
        // Ключ есть, но null — недельная строка должна найтись в limits.
        let onlyLimits = """
        {"seven_day": null, "five_hour": null,
         "limits": [{"kind": "weekly_all", "percent": 73,
                     "resets_at": "2026-08-07T12:00:00.357993+00:00"}]}
        """
        let (official, _) = provider(answers: [(200, onlyLimits)])
        let usage = try await official.usage(at: testNow)
        t.close(usage.weekPercent, 73, "процент взят из limits по kind")
        same(t, usage.weekResetsAt, at(2026, 8, 7, 16, 0), "и момент сброса тоже")
    }

    await t.suite("ответ без недельного лимита") {
        let (official, _) = provider(answers: [(200, #"{"five_hour": {"utilization": 10}}"#)])
        do {
            _ = try await official.usage(at: testNow)
            t.fail("ждали ошибку разбора")
        } catch UsageError.decoding {
            t.check(true, "пропажа недельного процента — явная ошибка, а не ноль")
        }
    }

    await t.suite("коды ответа") {
        for code in [401, 403] {
            let (official, _) = provider(answers: [(code, "")])
            do {
                _ = try await official.usage(at: testNow)
                t.fail("ждали unauthorized на \(code)")
            } catch UsageError.unauthorized {
                t.check(true, "\(code) — нужна авторизация")
            }
        }

        for code in [429, 500, 503] {
            let (official, _) = provider(answers: [(code, "")])
            do {
                _ = try await official.usage(at: testNow)
                t.fail("ждали unavailable на \(code)")
            } catch UsageError.unavailable {
                t.check(true, "\(code) — источник временно недоступен")
            }
        }
    }

    await t.suite("нет кред — нет запроса") {
        let (official, transport) = provider(
            credentials: FakeCredentials(error: UsageError.unauthorized)
        )
        do {
            _ = try await official.usage(at: testNow)
            t.fail("ждали unauthorized")
        } catch UsageError.unauthorized {
            t.equal(await transport.callCount(), 0, "без токена в сеть не ходим")
        }
    }

    await t.suite("троттлинг: не чаще раза в минуту") {
        let (official, transport) = provider()
        _ = try await official.usage(at: testNow)
        _ = try await official.usage(at: testNow.addingTimeInterval(30))
        t.equal(await transport.callCount(), 1, "повтор через 30 с берётся из памяти")

        _ = try await official.usage(at: testNow.addingTimeInterval(61))
        t.equal(await transport.callCount(), 2, "через 61 с идём в сеть заново")
    }

    await t.suite("пауза после неудачи") {
        let (official, transport) = provider(answers: [(500, "")])
        do { _ = try await official.usage(at: testNow) } catch {}
        t.equal(await transport.callCount(), 1, "первая попытка сделана")

        // Минуту после отказа в сеть не лезем.
        do { _ = try await official.usage(at: testNow.addingTimeInterval(30)) } catch {}
        t.equal(await transport.callCount(), 1, "во время паузы запроса нет")

        do { _ = try await official.usage(at: testNow.addingTimeInterval(61)) } catch {}
        t.equal(await transport.callCount(), 2, "после паузы пробуем снова")
    }

    await t.suite("устаревшее число не выдаётся вечно") {
        // Одна удача, дальше сеть молчит. Пока пауза после отказа держится,
        // последнее удачное число ещё годится — но не сутки же.
        let (official, _) = provider(answers: [(200, realResponse), (500, "")])
        _ = try await official.usage(at: testNow)

        let soon = testNow.addingTimeInterval(61)
        do { _ = try await official.usage(at: soon) } catch {}
        let duringPause = try await official.usage(at: soon.addingTimeInterval(10))
        t.close(duringPause.weekPercent, 50, "во время паузы отдаётся последнее удачное число")

        // Прошло больше staleLimit с момента последнего удачного ответа:
        // держаться за него больше нельзя, наружу должна уйти ошибка.
        do {
            _ = try await official.usage(at: testNow.addingTimeInterval(OfficialProvider.staleLimit + 120))
            t.fail("ждали отказ вместо просроченного числа")
        } catch UsageError.unavailable {
            t.check(true, "просроченное число не выдаётся — вызывающий уйдёт на локальную оценку")
        }
    }

    await t.suite("сброс недели обесценивает число из памяти") {
        // В ответе неделя сбрасывается 2026-08-07 в 16:00 по Саратову.
        let reset = at(2026, 8, 7, 16, 0)
        let usage = OfficialUsage(weekPercent: 100, weekResetsAt: reset)
        t.check(usage.isFresh(at: reset.addingTimeInterval(-1)), "до сброса число годно")
        t.check(!usage.isFresh(at: reset), "ровно на сбросе — уже нет")

        // Троттлинг: внутри минуты в сеть не ходим — но не тогда, когда за эту
        // минуту неделя успела обнулиться.
        let (throttled, transport) = provider()
        _ = try await throttled.usage(at: reset.addingTimeInterval(-30))
        _ = try await throttled.usage(at: reset.addingTimeInterval(10))
        t.equal(await transport.callCount(), 2,
                "после сброса идём в сеть, не дожидаясь конца минуты")

        // Пауза после отказа: последнее удачное число держится до staleLimit,
        // но и оно живёт не дольше собственной недели. Иначе панель показывала
        // исчерпанный лимит ещё четверть часа после обнуления.
        let (paused, _) = provider(answers: [(200, realResponse), (500, "")])
        _ = try await paused.usage(at: at(2026, 8, 7, 15, 50))
        do { _ = try await paused.usage(at: at(2026, 8, 7, 15, 59, 30)) } catch {}

        let duringPause = try await paused.usage(at: at(2026, 8, 7, 15, 59, 40))
        t.close(duringPause.weekPercent, 50, "до сброса пауза отдаёт последнее удачное число")

        do {
            _ = try await paused.usage(at: reset.addingTimeInterval(10))
            t.fail("ждали отказ вместо процента прошлой недели")
        } catch UsageError.unavailable {
            t.check(true, "после сброса — отказ, и вызывающий уйдёт на локальную оценку")
        }
    }

    await t.suite("снимок помнит момент наблюдения") {
        // Число, взятое из памяти, нельзя метить текущим моментом: по этой
        // метке панель решает, свежие перед ней данные или уже «offline».
        let clock = MutableClock(testNow)
        let transport = FakeTransport(answers: [(200, realResponse)])
        let official = OfficialProvider(
            config: config(), credentials: FakeCredentials(),
            transport: transport, shape: nil, clock: { clock.now }
        )

        let fresh = try await official.fetch()
        t.equal(fresh.fetchedAt, testNow, "свежий ответ помечен моментом ответа")

        clock.advance(30)
        let cached = try await official.fetch()
        t.equal(await transport.callCount(), 1, "внутри минуты в сеть не ходим")
        t.equal(cached.fetchedAt, testNow, "и снимок помечен прежним моментом, а не текущим")
    }

    await t.suite("калибровка не идёт по крохотному проценту") {
        // Официальный процент целый: на 2 % ошибка округления — четверть
        // значения, и бюджет из неё вышел бы перекошенным вдвое.
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")

        func resolving(_ response: String) -> ResolvingProvider {
            ResolvingProvider(
                config: config(),
                credentials: FakeCredentials(),
                transport: FakeTransport(answers: [(200, response)]),
                cacheURL: sandbox.cacheURL,
                localRoot: sandbox.root,
                indexURL: sandbox.indexURL,
                stateURL: sandbox.stateURL,
                clock: { testNow }
            )
        }

        _ = try await resolving(realResponse).fetch()
        t.close(Store.loadCache(from: sandbox.cacheURL)?.weeklyBudget ?? 0, 20,
                "по 50 % бюджет подобран: $10 — половина недели", tolerance: 1e-9)

        let tiny = """
        {"seven_day": {"utilization": 2, "resets_at": "2026-08-07T12:00:00.357993+00:00"}}
        """
        _ = try await resolving(tiny).fetch()
        t.close(Store.loadCache(from: sandbox.cacheURL)?.weeklyBudget ?? 0, 20,
                "по 2 % бюджет не перетирается — держим прежний", tolerance: 1e-9)
    }

    await t.suite("снимок официального источника") {
        let (official, _) = provider()
        let snapshot = try await official.fetch()

        t.close(snapshot.usedPercent, 50, "итог недели")
        t.equal(snapshot.source, .official, "источник официальный")
        t.check(!snapshot.isEstimate, "итог не помечен оценкой")
        t.check(snapshot.shapeIsEstimate, "а форма недели — помечена")
        same(t, snapshot.window.end, at(2026, 8, 7, 16, 0), "конец окна взят из ответа")
        same(t, snapshot.window.start, at(2026, 7, 31, 16, 0), "начало — неделей раньше")
    }

    t.suite("окно от resets_at") {
        let window = WeekWindow(endingAt: at(2026, 8, 7, 16, 0), config: config())
        t.equal(window.start, at(2026, 7, 31, 16, 0), "начало на семь суток раньше конца")
        t.close(window.duration, 7 * 86_400, "окно длиной в неделю")
        t.equal(window.days.count, 8, "восемь строк: сброс в 16:00 делит пятницу")
        t.equal(window.dayIndex(for: at(2026, 8, 4, 12, 0)), 4, "вторник до 16:00 — вторник")
        t.equal(window.dayIndex(for: at(2026, 8, 4, 17, 0)), 4,
                "и после 16:00 он же: строка меняется в полночь")

        // Конфиг говорит одно, сервер — другое; выигрывает сервер.
        t.check(WeekWindow(containing: at(2026, 8, 4, 12, 0), config: config()).end != window.end,
                "окно из конфига и окно из API — разные, и это ожидаемо")
    }

    await t.suite("выбор источника: official падает на local") {
        // Официальный отказывает, локальный не откалиброван — наружу должна
        // уйти причина отказа официального, она информативнее.
        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(error: UsageError.unauthorized),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: nil,
            stateURL: nil,
            clock: { testNow }
        )
        do {
            _ = try await resolving.fetch()
            t.fail("ждали ошибку")
        } catch UsageError.unauthorized {
            t.check(true, "в режиме auto наружу идёт причина отказа официального источника")
        } catch UsageError.notCalibrated {
            t.check(true, "или причина отказа локального — обе честные")
        }
    }

    await t.suite("режим local не ходит в сеть") {
        var localOnly = config()
        localOnly.provider = .local
        let transport = FakeTransport(answers: [(200, realResponse)])
        let resolving = ResolvingProvider(
            config: localOnly,
            credentials: FakeCredentials(),
            transport: transport,
            cacheURL: nil,
            stateURL: nil,
            clock: { testNow }
        )
        _ = try? await resolving.fetch()
        t.equal(await transport.callCount(), 0, "provider=local отключает сеть целиком")
    }

    t.suite("округление момента сброса") {
        // Сервер отдаёт то 12:00:00.357, то 11:59:59.9 — один и тот же сброс.
        let late = ISO8601.parse("2026-08-07T12:00:00.357993+00:00")!
        let early = ISO8601.parse("2026-08-07T11:59:59.900000+00:00")!
        t.equal(OfficialUsage.roundToMinute(late), OfficialUsage.roundToMinute(early),
                "секундный дрейф ответа даёт один и тот же момент")
        t.equal(OfficialUsage.roundToMinute(late), at(2026, 8, 7, 16, 0),
                "и это ровные 16:00 по Саратову")
    }

    await t.suite("автокалибровка бюджета по официальному проценту") {
        // Официальный источник сказал 50 %; локально за то же окно насчитано
        // $10 — значит неделя стоит $20, и офлайн-оценка это подхватит.
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")

        let cacheURL = sandbox.cacheURL
        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            clock: { testNow }
        )

        let snapshot = try await resolving.fetch()
        t.close(snapshot.usedPercent, 50, "показан официальный процент")
        let budget = Store.loadCache(from: cacheURL)?.weeklyBudget ?? 0
        t.close(budget, 20, "бюджет недели подобран: $10 при 50 %", tolerance: 1e-9)

        // Теперь сеть отказала — оценка должна опереться на подобранный бюджет,
        // а не выдать «не откалибровано».
        let offline = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(error: UsageError.unauthorized),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            clock: { testNow }
        )
        let fallback = try await offline.fetch()
        t.close(fallback.usedPercent, 50, "офлайн-оценка совпала с последним официальным числом")
        t.equal(fallback.source, .local, "источник при этом локальный")
        t.check(fallback.isEstimate, "и честно помечен оценкой")
        same(t, fallback.window.end, at(2026, 8, 7, 16, 0),
             "и окно взято от настоящего сброса, а не от resetHour из конфига")

        // Локальная перезапись кеша не должна стереть момент сброса от сервера.
        t.check(Store.loadCache(from: cacheURL)?.officialWindowEnd != nil,
                "официальный момент сброса пережил локальную запись кеша")
    }

    t.suite("окно из кеша сдвигается целыми неделями") {
        let cache = CachedUsage(
            usedPercent: 50, byDay: [], windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0), source: .official, fetchedAt: testNow,
            weeklyBudget: 20, officialWindowEnd: at(2026, 8, 7, 16, 0)
        )
        // Три недели офлайна: окно должно доехать до актуального, сохранив час.
        let later = at(2026, 8, 25, 12, 0)
        let window = cache.projectedWindow(at: later, config: config())
        t.check(window?.contains(later) == true, "окно накрывает текущий момент")
        same(t, window?.end, at(2026, 8, 28, 16, 0), "сброс остался в 16:00, сдвинувшись на три недели")

        let withoutOfficial = CachedUsage(
            usedPercent: 50, byDay: [], windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0), source: .local, fetchedAt: testNow
        )
        t.check(withoutOfficial.projectedWindow(at: testNow, config: config()) == nil,
                "без официального момента сброса окно не выдумываем")
    }

    t.suite("кеш: свежесть по окну") {
        let cache = CachedUsage(
            usedPercent: 50,
            byDay: [10, 20, nil, nil, nil, nil, nil],
            windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0),
            source: .official,
            fetchedAt: testNow
        )
        t.check(cache.isFresh(at: testNow), "кеш текущей недели годен")
        t.check(!cache.isFresh(at: at(2026, 8, 8, 12, 0)), "кеш прошлой недели негоден")
        t.check(!cache.isFresh(at: at(2026, 7, 30, 12, 0)), "и будущей тоже")

        let snapshot = cache.snapshot(config: config())
        t.close(snapshot.usedPercent, 50, "процент восстановлен")
        t.equal(snapshot.window.end, at(2026, 8, 7, 16, 0), "окно восстановлено как было")
        t.check(!snapshot.isEstimate, "официальный кеш остаётся официальным")
    }

    t.suite("креды: разбор записи Keychain") {
        let nested: [String: Any] = ["claudeAiOauth": ["accessToken": "sk-ant-oat01-x"]]
        t.equal(KeychainCredentials.findToken(nested), "sk-ant-oat01-x", "токен найден во вложенном объекте")
        t.equal(KeychainCredentials.findToken(["access_token": "sk-x"]), "sk-x", "и в змеиной записи тоже")
        t.check(KeychainCredentials.findToken(["nope": 1]) == nil, "чужая запись не даёт токена")

        // Claude Code пишет миллисекунды; секунды тоже должны разбираться.
        let millis = KeychainCredentials.date(from: NSNumber(value: 1_786_000_000_000))
        let seconds = KeychainCredentials.date(from: NSNumber(value: 1_786_000_000))
        t.equal(millis, seconds, "миллисекунды и секунды дают один момент")
        t.check(KeychainCredentials.date(from: nil) == nil, "нет поля — нет даты")

        let expired = OAuthCredentials(
            accessToken: "x", expiresAt: testNow.addingTimeInterval(-60), subscriptionType: nil
        )
        t.check(expired.isExpired(at: testNow), "истёкший токен виден")
        t.check(!OAuthCredentials(accessToken: "x", expiresAt: nil, subscriptionType: nil)
            .isExpired(at: testNow), "без срока считаем годным")
    }

    await t.suite("смена аккаунта: счёт начинается заново") {
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")
        // Счёт вёлся на прежнем аккаунте, и от него остался снимок.
        try Store.saveState(CountingState(account: "старая01·max"), to: sandbox.stateURL)
        try Store.saveCache(
            CachedUsage(usedPercent: 50, byDay: [], windowStart: testNow, windowEnd: testNow,
                        source: .official, fetchedAt: testNow),
            to: sandbox.cacheURL
        )

        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(organization: "новая0123-4567"),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: sandbox.cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            stateURL: sandbox.stateURL,
            clock: { testNow }
        )
        _ = try? await resolving.fetch()

        let state = Store.loadState(from: sandbox.stateURL)
        t.equal(state.account, "новая012·max", "запомнен аккаунт, который в ключе сейчас")
        t.equal(state.countFrom, testNow, "отсечка поставлена моментом, когда заметили смену")
    }

    await t.suite("первое знакомство сбросом не считается") {
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")

        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(organization: "первая01-2345"),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: sandbox.cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            stateURL: sandbox.stateURL,
            clock: { testNow }
        )
        _ = try? await resolving.fetch()

        let state = Store.loadState(from: sandbox.stateURL)
        t.equal(state.account, "первая01·max", "аккаунт запомнен")
        t.check(state.countFrom == nil, "но накопленное не выброшено: сменить было не с чего")
    }

    t.suite("метка аккаунта") {
        let creds = OAuthCredentials(
            accessToken: "x", expiresAt: nil, subscriptionType: "max",
            organizationUuid: "0123abcd-89ef-4321-0000-000000000000"
        )
        t.equal(creds.accountMark, "0123abcd·max", "метка — начало UUID организации и тариф")
        t.check(OAuthCredentials(accessToken: "x", expiresAt: nil, subscriptionType: "max")
            .accountMark == nil, "без организации сравнивать не с чем")
    }

    t.suite("разбор меток времени") {
        same(t, ISO8601.parse("2026-08-07T12:00:00.357993+00:00"), at(2026, 8, 7, 16, 0),
             "микросекунды и смещение вместо Z")
        t.equal(ISO8601.parse("2026-08-07T12:00:00Z"), at(2026, 8, 7, 16, 0),
                "без долей секунды")
        t.equal(ISO8601.parse("2026-08-07T12:00:00.000Z"), at(2026, 8, 7, 16, 0),
                "миллисекунды из транскриптов")
        t.check(ISO8601.parse("кривая дата") == nil, "мусор не превращается в дату")
    }
}
