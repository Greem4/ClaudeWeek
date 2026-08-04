import Foundation
import ClaudeWeekCore

/// Отладочный режим без UI: `ClaudeWeekApp --json` печатает разбивку недели.
/// Им же удобно подбирать `weeklyBudget` — стоимость выводится всегда,
/// даже когда калибровки ещё нет.
enum CLI {
    static let usage = """
    ClaudeWeek \(ClaudeWeek.version) — недельный лимит Claude Code в строке меню.

    Использование:
      ClaudeWeek                 запустить приложение в строке меню
      ClaudeWeek --json          напечатать состояние недели в JSON и выйти
      ClaudeWeek --provider=X    источник данных: local (official будет в M3)
      ClaudeWeek --config=ПУТЬ   свой файл конфигурации
      ClaudeWeek --calibrate=N   подогнать локальную оценку под официальные N %
                                 (число берётся из /usage внутри Claude Code)
      ClaudeWeek --screenshot КАТ отрисовать панель в PNG (обе темы)
      ClaudeWeek --icon КАТ      сгенерировать .iconset для сборки бандла
      ClaudeWeek --verbose       подробный лог в stderr
      ClaudeWeek --help          эта справка
    """

    struct Output: Encodable {
        let source: String
        let isEstimate: Bool
        let generatedAt: Date
        let window: Window
        let percent: Percent?
        let cost: Cost
        let days: [Day]
        let scan: Scan
        let note: String?

        struct Window: Encodable {
            let start: Date
            let end: Date
            let resetLabel: String
            let timeZone: String
            let planAnchor: String
        }

        struct Percent: Encodable {
            let used: Double
            let planNow: Double
            let remaining: Double
            let burnRate: Double?
            let projected: Double?
            let state: String
            let timeLeft: String
            let exhaustionAt: Date?
        }

        struct Cost: Encodable {
            let total: Double
            let weeklyBudget: Double?
            let currency: String
        }

        struct Day: Encodable {
            let index: Int
            let label: String
            let start: Date
            let planPercent: Double
            let usedPercent: Double?
            let cost: Double?

            enum CodingKeys: String, CodingKey {
                case index, label, start, planPercent, usedPercent, cost
            }

            // Синтезированный encode выбрасывает пустые поля, и у будущих
            // суток ключи просто исчезают. Скриптам удобнее стабильная схема
            // с явным null, поэтому пишем их руками.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(index, forKey: .index)
                try c.encode(label, forKey: .label)
                try c.encode(start, forKey: .start)
                try c.encode(planPercent, forKey: .planPercent)
                try c.encode(usedPercent, forKey: .usedPercent)
                try c.encode(cost, forKey: .cost)
            }
        }

        struct Scan: Encodable {
            let filesRead: Int
            let records: Int
            let duplicatesSkipped: Int
            let elapsedSeconds: Double
        }
    }

    /// `--calibrate=64`: привязывает локальную оценку к одному официальному
    /// наблюдению. Считает, сколько условных долларов уже потрачено, и делит
    /// на долю — получается бюджет недели.
    static func calibrate(percent: Double, config: Config, configURL: URL) async -> Int32 {
        guard percent > 0, percent <= 100 else {
            FileHandle.standardError.write(Data("процент должен быть в диапазоне 0…100\n".utf8))
            return 1
        }

        let now = Date()
        let window = WeekWindow(containing: now, config: config)
        let provider = LocalProvider(config: config)

        let spent: Double
        do {
            spent = try await provider.scan(window: window, now: now).totalCost
        } catch {
            FileHandle.standardError.write(Data("не смог прочитать транскрипты: \(error)\n".utf8))
            return 1
        }
        guard spent > 0 else {
            FileHandle.standardError.write(Data("за текущую неделю расхода нет — калибровать не по чему\n".utf8))
            return 1
        }

        var updated = config
        updated.weeklyBudget = spent / (percent / 100)
        updated.calibration = Calibration(observedPercent: percent, at: now)

        do {
            try ConfigStore.save(updated, to: configURL)
        } catch {
            FileHandle.standardError.write(Data("не сохранил конфиг: \(error)\n".utf8))
            return 1
        }

        print("""
        Откалибровано по официальным \(Formatting.percent(percent)).
        Потрачено за неделю: $\(String(format: "%.2f", spent)) условных.
        Бюджет недели: $\(String(format: "%.2f", updated.weeklyBudget)).
        Записано в \(configURL.path)
        """)
        return 0
    }

    static func run(config: Config) async -> Int32 {
        let now = Date()
        let window = WeekWindow(containing: now, config: config)
        let provider = LocalProvider(config: config)

        let started = Date()
        let usage: LocalUsage
        do {
            usage = try await provider.scan(window: window, now: now)
        } catch {
            FileHandle.standardError.write(Data("не смог прочитать транскрипты: \(error)\n".utf8))
            return 1
        }
        let elapsed = Date().timeIntervalSince(started)

        // Бюджет может быть не задан — тогда печатаем стоимость без процентов.
        let budget = try? await provider.budget(for: usage)
        var percent: Output.Percent?
        var cumulative: [Double?] = usage.costByDay.map { _ in nil }

        if let budget, budget > 0 {
            var running = 0.0
            cumulative = usage.costByDay.map { cost in
                guard let cost else { return nil }
                running += cost
                return running / budget * 100
            }
            let snapshot = UsageSnapshot.make(
                usedPercent: usage.totalCost / budget * 100,
                cumulativeByDay: cumulative,
                window: window,
                source: .local,
                fetchedAt: now,
                isEstimate: true
            )
            let metrics = snapshot.metrics(at: now, thresholds: config.thresholds)
            percent = Output.Percent(
                used: metrics.usedPercent,
                planNow: metrics.planNowPercent,
                remaining: metrics.remainingPercent,
                burnRate: metrics.burnRate,
                projected: metrics.projectedPercent,
                state: metrics.state.rawValue,
                timeLeft: Formatting.duration(metrics.timeLeft),
                exhaustionAt: metrics.exhaustionDate
            )
        }

        let days = window.days.map { slot in
            Output.Day(
                index: slot.index,
                label: Formatting.weekdayShort(slot.start, calendar: window.calendar),
                start: slot.start,
                planPercent: slot.planPercent,
                usedPercent: slot.index < cumulative.count ? cumulative[slot.index] : nil,
                cost: usage.costByDay[slot.index]
            )
        }

        let output = Output(
            source: SourceKind.local.rawValue,
            isEstimate: true,
            generatedAt: now,
            window: Output.Window(
                start: window.start,
                end: window.end,
                resetLabel: Formatting.resetLabel(window),
                timeZone: window.calendar.timeZone.identifier,
                planAnchor: window.anchor.rawValue
            ),
            percent: percent,
            cost: Output.Cost(total: usage.totalCost, weeklyBudget: budget, currency: "USD"),
            days: days,
            scan: Output.Scan(
                filesRead: usage.filesRead,
                records: usage.recordCount,
                duplicatesSkipped: usage.duplicatesSkipped,
                elapsedSeconds: elapsed
            ),
            note: percent == nil
                ? "проценты недоступны: задайте weeklyBudget или calibration в \(ConfigStore.fileURL.path)"
                : nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(output) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }
}
