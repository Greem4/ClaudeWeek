import Foundation
import ClaudeWeekCore

/// Транспорт без процесса и настоящего аккаунта: провайдер получает ровно
/// тот официальный ответ, который проверяет сценарий, и тесты остаются
/// полностью офлайн.
private actor FakeCodexTransport: CodexUsageTransport {
    private let answer: CodexAccountUsage
    private(set) var calls = 0

    init(_ answer: CodexAccountUsage) {
        self.answer = answer
    }

    func fetch() async throws -> CodexAccountUsage {
        calls += 1
        return answer
    }

    func callCount() -> Int { calls }
}

private let codexNow = at(2026, 8, 4, 12, 0)
private let codexWeekReset = at(2026, 8, 7, 16, 0)

private func executableScript(_ body: String) throws -> (file: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-week-app-server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("fake-codex")
    try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return (file, directory)
}

private func codexUsage(
    weekPercent: Double = 18,
    sessionPercent: Double = 40,
    daily: [CodexDailyUsage]? = [
        CodexDailyUsage(startDate: "2026-08-01", tokens: 100),
        CodexDailyUsage(startDate: "2026-08-02", tokens: 200),
        CodexDailyUsage(startDate: "2026-08-03", tokens: 300),
        CodexDailyUsage(startDate: "2026-08-04", tokens: 400),
    ]
) -> CodexAccountUsage {
    let bucket = CodexRateLimitBucket(
        limitId: "codex",
        primary: CodexRateLimitWindow(
            usedPercent: sessionPercent,
            windowDurationMinutes: 300,
            resetsAt: at(2026, 8, 4, 14, 0)
        ),
        secondary: CodexRateLimitWindow(
            usedPercent: weekPercent,
            windowDurationMinutes: 7 * 24 * 60,
            resetsAt: codexWeekReset
        )
    )
    return CodexAccountUsage(
        limits: CodexRateLimits(rateLimits: bucket),
        tokens: CodexTokenUsage(dailyUsageBuckets: daily)
    )
}

func runCodexProviderTests(_ t: Harness) async {
    await t.suite("Codex: настоящий обмен JSONL") {
        let script = try executableScript(#"""
        contains() {
            case "$1" in
                *"$2"*) ;;
                *) exit 40 ;;
            esac
        }
        [ "$1" = "app-server" ] || exit 41
        [ "$2" = "--stdio" ] || exit 42
        IFS= read -r initialize || exit 43
        contains "$initialize" '"method":"initialize"'
        contains "$initialize" '"id":0'
        contains "$initialize" '"clientInfo"'
        printf '%s\n' '{"id":0,"result":{"userAgent":"fake-codex"}}'
        IFS= read -r initialized || exit 44
        contains "$initialized" '"method":"initialized"'
        IFS= read -r limits_request || exit 45
        case "$limits_request" in
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*) ;;
            *) exit 47 ;;
        esac
        contains "$limits_request" '"id":1'
        IFS= read -r usage_request || exit 46
        case "$usage_request" in
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*) ;;
            *) exit 48 ;;
        esac
        contains "$usage_request" '"id":2'
        printf '%s\n' '{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":18,"windowDurationMins":10080,"resetsAt":1786107600}}}}'
        printf '%s\n' '{"id":2,"result":{"dailyUsageBuckets":[{"startDate":"2026-08-04","tokens":12345}]}}'
        while IFS= read -r rest; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: script.directory) }

        let usage = try await CodexAppServerTransport(
            executableURL: script.file,
            timeout: 2
        ).fetch()
        t.close(usage.limits.rateLimits?.primary?.usedPercent ?? -1, 25,
                "запрос лимитов прошёл после initialize")
        t.equal(usage.limits.rateLimits?.limitId, nil,
                "совместимый ответ не обязан содержать limitId")
        t.equal(usage.limits.rateLimits?.primary?.resetsAt, nil,
                "null-время сброса не ломает весь ответ")
        t.close(usage.limits.rateLimits?.secondary?.usedPercent ?? -1, 18,
                "недельное окно доехало по stdout")
        t.equal(usage.tokens?.dailyUsageBuckets?.first?.tokens, 12_345,
                "второй ответ прочитан из того же процесса")
    }

    t.suite("Codex: документированный JSON лимитов") {
        let json = #"""
        {
          "rateLimits": {
            "limitName": null,
            "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": null},
            "secondary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1786107600},
            "rateLimitReachedType": null
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": 1785844800},
              "secondary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1786107600}
            }
          }
        }
        """#
        let decoded = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        t.equal(decoded.rateLimits?.limitId, nil, "отсутствующий limitId допустим")
        t.close(decoded.rateLimits?.primary?.usedPercent ?? -1, 25,
                "короткое окно прочиталось")
        t.equal(decoded.rateLimits?.primary?.windowDurationMinutes, 15,
                "длина окна взята из windowDurationMins")
        t.equal(decoded.rateLimits?.primary?.resetsAt, nil,
                "отсутствующий сброс изолирован в своём окне")
        t.close(decoded.rateLimits?.secondary?.usedPercent ?? -1, 18,
                "длинное окно прочиталось")
    }

    await t.suite("Codex: снимок панели") {
        let transport = FakeCodexTransport(codexUsage())
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-codex-\(UUID().uuidString)/cache.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let provider = CodexProvider(
            config: config(),
            transport: transport,
            cacheURL: cacheURL,
            clock: { codexNow }
        )
        let snapshot = try await provider.fetch()

        t.equal(snapshot.source, .codex, "источник помечен как Codex")
        t.close(snapshot.usedPercent, 18, "недельный процент взят из secondary")
        t.equal(snapshot.window.end, codexWeekReset, "сброс недели взят у сервера")
        t.check(!snapshot.isEstimate, "итоговый процент точный")
        t.check(snapshot.shapeIsEstimate, "дневная форма честно помечена оценкой")
        t.close(snapshot.byDay.compactMap(\.usedPercent).last ?? -1, 18,
                "накопительная дневная форма приходит ровно к итогу")

        guard let session = snapshot.session else {
            return t.fail("короткое окно Codex не попало в строку сессии")
        }
        t.close(session.usedPercent, 40, "процент короткого окна взят из primary")
        t.equal(session.windowDurationMinutes, 300, "его настоящая длина сохранена")
        t.equal(session.resetsAt, at(2026, 8, 4, 14, 0), "момент сброса сохранён")

        let cached = Store.loadCache(from: cacheURL)
        t.equal(cached?.source, .codex, "снимок Codex записан в отдельный кеш")
        t.close(cached?.usedPercent ?? -1, 18, "процент пережил запись кеша")
    }

    await t.suite("Codex: многобакетный ответ") {
        let codexBucket = codexUsage().limits.rateLimits!
        let modelBucket = CodexRateLimitBucket(
            limitId: "gpt-model",
            secondary: CodexRateLimitWindow(
                usedPercent: 91,
                windowDurationMinutes: 14 * 24 * 60,
                resetsAt: codexWeekReset.addingTimeInterval(7 * 24 * 60 * 60)
            )
        )
        let answer = CodexAccountUsage(
            limits: CodexRateLimits(
                rateLimits: modelBucket,
                rateLimitsByLimitId: ["gpt-model": modelBucket, "codex": codexBucket]
            )
        )
        let provider = CodexProvider(
            config: config(),
            transport: FakeCodexTransport(answer),
            cacheURL: nil,
            clock: { codexNow }
        )
        let snapshot = try await provider.fetch()
        t.close(snapshot.usedPercent, 18,
                "агрегатный bucket codex важнее длинного модельного и legacy-вида")
        t.check(snapshot.byDay.allSatisfy { $0.usedPercent == nil },
                "без дневных бакетов форма не выдумывается")
    }

    await t.suite("Codex: необязательный сброс одного окна") {
        let bucket = CodexRateLimitBucket(
            primary: CodexRateLimitWindow(
                usedPercent: 25,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            secondary: CodexRateLimitWindow(
                usedPercent: 18,
                windowDurationMinutes: 7 * 24 * 60,
                resetsAt: codexWeekReset
            )
        )
        let provider = CodexProvider(
            config: config(),
            transport: FakeCodexTransport(CodexAccountUsage(
                limits: CodexRateLimits(rateLimits: bucket)
            )),
            cacheURL: nil,
            clock: { codexNow }
        )
        let snapshot = try await provider.fetch()
        t.close(snapshot.usedPercent, 18, "действующее недельное окно сохранилось")
        t.equal(snapshot.session, nil, "окно без сброса не показывается действующим")
    }

    await t.suite("Codex: короткое окно не выдаётся за неделю") {
        let primaryOnly = CodexRateLimitBucket(
            limitId: "codex",
            primary: CodexRateLimitWindow(
                usedPercent: 25,
                windowDurationMinutes: 15,
                resetsAt: codexNow.addingTimeInterval(900)
            )
        )
        let answer = CodexAccountUsage(
            limits: CodexRateLimits(rateLimits: primaryOnly)
        )
        let provider = CodexProvider(
            config: config(),
            transport: FakeCodexTransport(answer),
            cacheURL: nil,
            clock: { codexNow }
        )
        do {
            _ = try await provider.fetch()
            t.fail("ждали ошибку: недельного окна в ответе нет")
        } catch UsageError.decoding {
            t.check(true, "15 минут не подписываются недельным лимитом")
        }
    }

    await t.suite("Codex: троттлинг") {
        let transport = FakeCodexTransport(codexUsage())
        let clock = MutableClock(codexNow)
        let provider = CodexProvider(
            config: config(),
            transport: transport,
            cacheURL: nil,
            clock: { clock.now }
        )
        _ = try await provider.fetch()
        clock.advance(30)
        _ = try await provider.fetch()
        t.equal(await transport.callCount(), 1, "повтор через 30 секунд взят из памяти")

        clock.advance(31)
        _ = try await provider.fetch()
        t.equal(await transport.callCount(), 2, "через 61 секунду app-server опрашивается снова")
    }

    t.suite("Codex: совместимость конфига и кеша") {
        let oldConfig = try JSONDecoder().decode(Config.self, from: Data(#"{"resetHour":9}"#.utf8))
        t.equal(oldConfig.activeAccount, .claude, "старый конфиг остаётся на Claude")

        var selected = Config.default
        selected.activeAccount = .codex
        let roundTrip = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(selected))
        t.equal(roundTrip.activeAccount, .codex, "выбор Codex переживает запись")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldSession = try decoder.decode(
            SessionUsage.self,
            from: Data(#"{"usedPercent":41,"resetsAt":"2026-08-04T20:20:00Z"}"#.utf8)
        )
        t.equal(oldSession.windowDurationMinutes, 300,
                "старый кеш без длины восстанавливает пять часов Claude")
    }

    t.suite("Codex: подписи окон") {
        t.equal(Formatting.limitWindow(15, lang: .ru), "15 МИН", "минутное окно")
        t.equal(Formatting.limitWindow(300, lang: .ru), "5 Ч", "часовое окно")
        t.equal(Formatting.limitWindow(1_440, lang: .en), "1 D", "суточное окно")
    }
}
