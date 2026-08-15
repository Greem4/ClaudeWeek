import Foundation
import ClaudeWeekCore

/// Песочница с транскриптами: каталог проектов + свой файл индекса.
private struct Sandbox {
    let root: URL
    let indexURL: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-fixtures-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    func write(_ relativePath: String, lines: [String], append: Bool = false) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = lines.joined(separator: "\n") + "\n"
        if append, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func index() -> UsageIndex { Store.loadIndex(from: indexURL) }

    /// Ищем по имени файла: обход каталога может вернуть путь в другой, но
    /// стабильной форме, и завязываться на неё в тесте незачем.
    func entry(_ fileName: String) -> FileIndexEntry? {
        index().files.first { $0.key.hasSuffix(fileName) }?.value
    }
}

/// Ассистентское сообщение в том виде, в каком его пишет Claude Code.
private func line(
    uuid: String,
    at timestamp: String,
    model: String = "claude-opus-5",
    input: Int = 0,
    output: Int = 0,
    write5m: Int = 0,
    write1h: Int = 0,
    read: Int = 0
) -> String {
    """
    {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)",\
    "usage":{"input_tokens":\(input),"output_tokens":\(output),\
    "cache_creation_input_tokens":\(write5m + write1h),"cache_read_input_tokens":\(read),\
    "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)}}}}
    """
}

private let testNow = at(2026, 8, 4, 12, 0)

private func provider(_ sandbox: Sandbox, config c: Config = config()) -> LocalProvider {
    LocalProvider(config: c, root: sandbox.root, indexURL: sandbox.indexURL, clock: { testNow })
}

func runLocalProviderTests(_ t: Harness) async {
    t.suite("веса моделей") {
        // Opus: вход $5, выход $25, запись 5м ×1.25, запись 1ч ×2, чтение ×0.1.
        let opus = ModelPricing.weights(for: "claude-opus-5")
        t.close(opus?.input ?? 0, 5, "вход Opus")
        t.close(opus?.output ?? 0, 25, "выход Opus")
        t.close(opus?.cacheWrite5m ?? 0, 6.25, "запись пятиминутного кеша")
        t.close(opus?.cacheWrite1h ?? 0, 10, "запись часового кеша")
        t.close(opus?.cacheRead ?? 0, 0.5, "чтение кеша")

        t.close(ModelPricing.weights(for: "claude-sonnet-5")?.input ?? 0, 3, "вход Sonnet")
        t.close(ModelPricing.weights(for: "claude-haiku-4-5-20251001")?.input ?? 0, 1,
                "имя с датой сопоставляется по префиксу")
        t.close(ModelPricing.weights(for: "claude-opus-4-8")?.input ?? 0, 5, "Opus 4.8 по тем же ценам")
        t.check(ModelPricing.weights(for: "<synthetic>") == nil, "синтетические сообщения не считаются")
        t.check(ModelPricing.weights(for: nil) == nil, "сообщение без модели не считается")
        t.close(ModelPricing.weights(for: "claude-неизвестно-9")?.input ?? 0, 3,
                "незнакомая модель считается по весам Sonnet")
    }

    await t.suite("взвешивание токенов") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            line(uuid: "a1", at: "2026-08-01T10:00:00.000Z",
                 input: 1000, output: 500, write5m: 2000, write1h: 1000, read: 10_000),
        ])

        let usage = try await provider(sandbox).scan(
            window: WeekWindow(containing: testNow, config: config()), now: testNow
        )
        // 1000×5 + 500×25 + 2000×6.25 + 1000×10 + 10000×0.5 = 45 000 → $0.045
        t.close(usage.totalCost, 0.045, "стоимость известного набора токенов", tolerance: 1e-12)
        t.equal(usage.recordCount, 1, "одна учтённая запись")
    }

    await t.suite("парсер: мусор и пропуски") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user"}}"#,
            "{это не json",
            line(uuid: "a1", at: "2026-08-01T11:00:00.000Z", input: 1_000_000),
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-08-01T12:00:00.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"type":"assistant","uuid":"a3","timestamp":"кривая дата","message":{"model":"claude-opus-5","usage":{"input_tokens":1000000}}}"#,
            line(uuid: "a4", at: "2026-08-01T13:00:00.000Z", model: "claude-неизвестная", input: 1_000_000),
        ])

        let usage = try await provider(sandbox).scan(
            window: WeekWindow(containing: testNow, config: config()), now: testNow
        )
        t.equal(usage.recordCount, 2, "учтены только строки с расходом")
        // Opus $5 за Mtok + неизвестная модель по весам Sonnet $3.
        t.close(usage.totalCost, 8, "битая строка не мешает считать остальные", tolerance: 1e-12)
    }

    await t.suite("дедупликация subagents") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        let duplicate = line(uuid: "shared", at: "2026-08-01T10:00:00.000Z", input: 1_000_000)
        sandbox.write("проект/сессия.jsonl", lines: [
            duplicate,
            line(uuid: "own", at: "2026-08-01T10:05:00.000Z", input: 1_000_000),
        ])
        sandbox.write("проект/сессия/subagents/agent-1.jsonl", lines: [duplicate])

        let usage = try await provider(sandbox).scan(
            window: WeekWindow(containing: testNow, config: config()), now: testNow
        )
        t.equal(usage.recordCount, 2, "общая запись учтена один раз")
        t.equal(usage.duplicatesSkipped, 1, "дубль посчитан отдельно")
        t.close(usage.totalCost, 10, "стоимость без задвоения", tolerance: 1e-12)
    }

    await t.suite("раскладка по суткам окна") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            // ПТ 15:30 по Саратову — вечер пятницы, первая строка окна.
            line(uuid: "d0", at: "2026-07-31T11:30:00.000Z", input: 1_000_000),
            // СБ 14:00 — суббота; час сброса на строку больше не влияет.
            line(uuid: "d0b", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
            // СБ 16:00 — та же суббота, а не следующие сутки.
            line(uuid: "d1", at: "2026-08-01T12:00:00.000Z", input: 1_000_000),
            // Прошлая неделя — вне окна.
            line(uuid: "old", at: "2026-07-28T10:00:00.000Z", input: 1_000_000),
        ])

        let window = WeekWindow(containing: testNow, config: config())
        let usage = try await provider(sandbox).scan(window: window, now: testNow)
        t.close(usage.costByDay[0] ?? -1, 5, "вечер пятницы", tolerance: 1e-12)
        t.close(usage.costByDay[1] ?? -1, 10, "обе субботние записи — в субботе", tolerance: 1e-12)
        // testNow — вторник 12:00: вторник текущий, среда ещё не началась.
        t.close(usage.costByDay[4] ?? -1, 0, "текущие сутки без расхода — ноль, не пропуск")
        t.check(usage.costByDay[5] == nil, "следующие сутки ещё не наступили")
        t.check(usage.costByDay[7] == nil, "и последние тоже")
        t.close(usage.totalCost, 15, "записи прошлой недели в итог не идут", tolerance: 1e-12)
    }

    await t.suite("инкрементальный индекс: дописали строку") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        let path = "проект/сессия.jsonl"
        sandbox.write(path, lines: [
            line(uuid: "a1", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
        ])
        let window = WeekWindow(containing: testNow, config: config())
        let local = provider(sandbox)

        let first = try await local.scan(window: window, now: testNow)
        t.equal(first.filesRead, 1, "первый проход читает файл")
        let firstOffset = sandbox.entry("сессия.jsonl")?.offset ?? 0
        t.check(firstOffset > 0, "смещение записано в индекс")

        // Повторный проход на неизменившемся файле не читает ничего.
        let unchanged = try await local.scan(window: window, now: testNow)
        t.equal(unchanged.filesRead, 0, "неизменившийся файл не перечитывается")
        t.close(unchanged.totalCost, first.totalCost, "итог не поплыл", tolerance: 1e-12)

        // Дописали строку — читаем только хвост.
        sandbox.write(path, lines: [
            line(uuid: "a2", at: "2026-08-01T11:00:00.000Z", input: 1_000_000),
        ], append: true)
        let grown = try await local.scan(window: window, now: testNow)
        t.equal(grown.filesRead, 1, "изменившийся файл прочитан")
        t.close(grown.totalCost, 10, "учтены обе записи", tolerance: 1e-12)
        let entry = sandbox.entry("сессия.jsonl")
        t.equal(entry?.records.count, 2, "в индексе ровно две записи — хвост не задвоился")
        t.check((entry?.offset ?? 0) > firstOffset, "смещение сдвинулось")
    }

    await t.suite("инкрементальный индекс: файл пересоздали") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        let path = "проект/сессия.jsonl"
        let url = sandbox.write(path, lines: [
            line(uuid: "a1", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
            line(uuid: "a2", at: "2026-08-01T11:00:00.000Z", input: 1_000_000),
        ])
        let window = WeekWindow(containing: testNow, config: config())
        let local = provider(sandbox)

        let before = try await local.scan(window: window, now: testNow)
        t.close(before.totalCost, 10, "две записи до пересоздания", tolerance: 1e-12)
        let oldInode = sandbox.entry("сессия.jsonl")?.inode ?? 0

        // Пересоздаём файл: другой inode и меньший размер.
        try FileManager.default.removeItem(at: url)
        sandbox.write(path, lines: [
            line(uuid: "b1", at: "2026-08-01T12:00:00.000Z", input: 1_000_000),
        ])

        let after = try await local.scan(window: window, now: testNow)
        t.close(after.totalCost, 5, "старые записи забыты, файл перечитан целиком", tolerance: 1e-12)
        let entry = sandbox.entry("сессия.jsonl")
        t.equal(entry?.records.count, 1, "в индексе только новая запись")
        t.check((entry?.inode ?? 0) != oldInode, "inode сменился")
    }

    await t.suite("индекс: пропавшие файлы") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.write("проект/сессия.jsonl", lines: [
            line(uuid: "a1", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
        ])
        let window = WeekWindow(containing: testNow, config: config())
        let local = provider(sandbox)
        _ = try await local.scan(window: window, now: testNow)
        t.equal(sandbox.index().files.count, 1, "файл в индексе")

        try FileManager.default.removeItem(at: url)
        let after = try await local.scan(window: window, now: testNow)
        t.close(after.totalCost, 0, "удалённый файл не влияет на итог")
        t.equal(sandbox.index().files.count, 0, "запись из индекса убрана")
    }

    await t.suite("проценты и калибровка") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            line(uuid: "a1", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
            line(uuid: "a2", at: "2026-08-02T10:00:00.000Z", input: 1_000_000),
        ])

        // Без бюджета и калибровки процент считать не из чего.
        do {
            _ = try await provider(sandbox).fetch()
            t.fail("ждали ошибку notCalibrated")
        } catch UsageError.notCalibrated {
            t.check(true, "без калибровки честно сообщаем об этом")
        }

        // Явный бюджет: 10 из 40 условных долларов — 25 %.
        var withBudget = config()
        withBudget.weeklyBudget = 40
        let snapshot = try await provider(sandbox, config: withBudget).fetch()
        t.close(snapshot.usedPercent, 25, "процент от заданного бюджета", tolerance: 1e-9)
        t.check(snapshot.isEstimate, "локальный источник помечен как оценка")
        t.equal(snapshot.source, .local, "источник — локальный")
        // Обе записи легли на 14:00 по Саратову: суббота и воскресенье.
        // Вечер пятницы — отдельная первая строка, и в нём пусто.
        t.close(snapshot.byDay[0].usedPercent ?? -1, 0, "вечер пятницы без расхода", tolerance: 1e-9)
        t.close(snapshot.byDay[1].usedPercent ?? -1, 12.5, "накопительный факт субботы", tolerance: 1e-9)
        t.close(snapshot.byDay[2].usedPercent ?? -1, 25, "накопительный факт воскресенья", tolerance: 1e-9)

        // Калибровка: на момент наблюдения потрачено $5 и это было 20 % —
        // значит бюджет недели $25, а весь расход $10 даёт 40 %.
        var calibrated = config()
        calibrated.calibration = Calibration(observedPercent: 20, at: at(2026, 8, 1, 20, 0))
        let byCalibration = try await provider(sandbox, config: calibrated).fetch()
        t.close(byCalibration.usedPercent, 40, "процент по калибровке", tolerance: 1e-9)
    }

    await t.suite("разбивка по моделям") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            // Opus: 1 Mtok входа — $5.
            line(uuid: "o1", at: "2026-08-01T10:00:00.000Z", input: 1_000_000),
            // Opus ещё раз, выходом: 100 ktok × $25 — $2.5.
            line(uuid: "o2", at: "2026-08-01T11:00:00.000Z", output: 100_000),
            // Sonnet: 500 ktok входа — $1.5.
            line(uuid: "s1", at: "2026-08-02T10:00:00.000Z",
                 model: "claude-sonnet-5", input: 500_000),
            // Haiku: 1 Mtok чтения кеша — $0.1.
            line(uuid: "h1", at: "2026-08-02T11:00:00.000Z",
                 model: "claude-haiku-4-5-20251001", read: 1_000_000),
        ])

        let window = WeekWindow(containing: testNow, config: config())
        let usage = try await provider(sandbox).scan(window: window, now: testNow)
        t.equal(usage.byModel.count, 3, "три модели — три строки")

        let opus = usage.byModel[0]
        t.equal(opus.family, ModelFamily.opus, "самая дорогая модель — первой")
        t.close(opus.cost, 7.5, "стоимость Opus сложена по обеим записям", tolerance: 1e-12)
        t.equal(opus.messages, 2, "два ответа Opus")
        t.equal(opus.tokens.input, 1_000_000, "вход Opus")
        t.equal(opus.tokens.output, 100_000, "выход Opus")
        // Всего $9.1: доля Opus 7.5/9.1.
        t.close(opus.sharePercent, 7.5 / 9.1 * 100, "доля Opus в стоимости недели", tolerance: 1e-9)

        t.equal(usage.byModel[1].family, ModelFamily.sonnet, "Sonnet вторым")
        t.equal(usage.byModel[2].family, ModelFamily.haiku, "Haiku последним")
        t.equal(usage.byModel[2].tokens.cacheRead, 1_000_000, "чтение кеша Haiku")
        t.close(usage.byModel.reduce(0) { $0 + $1.sharePercent }, 100,
                "доли складываются в сотню", tolerance: 1e-9)

        // Разбивка доезжает до снимка и переводится в проценты лимита: при
        // бюджете $91 неделя стоит 10 %, из которых на Opus ≈8.24 %.
        var withBudget = config()
        withBudget.weeklyBudget = 91
        let snapshot = try await provider(sandbox, config: withBudget).fetch()
        t.equal(snapshot.byModel.count, 3, "снимок несёт разбивку")
        t.close(snapshot.limitPercent(of: snapshot.byModel[0]), 7.5 / 91 * 100,
                "доля Opus в недельном лимите", tolerance: 1e-9)
    }

    await t.suite("незнакомая модель в разбивке") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        sandbox.write("проект/сессия.jsonl", lines: [
            line(uuid: "x1", at: "2026-08-01T10:00:00.000Z",
                 model: "claude-неизвестно-9", input: 1_000_000),
        ])

        let usage = try await provider(sandbox).scan(
            window: WeekWindow(containing: testNow, config: config()), now: testNow
        )
        t.equal(usage.byModel.count, 1, "незнакомая модель тоже строка разбивки")
        t.equal(usage.byModel[0].family, "claude-неизвестно-9",
                "зовётся своим именем, а не «прочим»")
        t.equal(usage.byModel[0].title, "claude-неизвестно-9",
                "подпись у неё та же — придумывать семейство нечем")
    }

    t.suite("смена схемы индекса") {
        let sandbox = Sandbox()
        defer { sandbox.cleanup() }
        // Индекс версии 1: записи без модели и токенов. Целиком он не
        // разбирается, и загрузка обязана вернуть пустой, а не упасть.
        let old = """
        {"version":1,"files":{"/x.jsonl":{"inode":1,"size":10,"mtime":"2026-08-01T10:00:00Z",\
        "offset":10,"records":[{"uuid":"a","timestamp":"2026-08-01T10:00:00Z","cost":1.5}]}}}
        """
        try? old.write(to: sandbox.indexURL, atomically: true, encoding: .utf8)

        let index = Store.loadIndex(from: sandbox.indexURL)
        t.equal(index.version, UsageIndex.currentVersion, "индекс прошлой схемы заменён пустым")
        t.equal(index.files.count, 0, "старые записи не подхватываются")
    }
}
