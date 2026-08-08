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
      ClaudeWeek --provider=X    источник данных: official, local или auto
      ClaudeWeek --config=ПУТЬ   свой файл конфигурации
      ClaudeWeek --calibrate=N   подогнать локальную оценку под официальные N %
                                 (число берётся из /usage внутри Claude Code)
      ClaudeWeek --screenshot КАТ отрисовать панель и иконку в PNG (обе темы)
      ClaudeWeek --icon КАТ      сгенерировать .iconset для сборки бандла
      ClaudeWeek --update        поставить свежий выпуск с GitHub, если он вышел
      ClaudeWeek --verbose       подробный лог в stderr
      ClaudeWeek --help          эта справка
    """

    /// Флаги без значения и префиксы флагов со значением. По ним же отличаем
    /// опечатку от каталога у `--icon` и `--screenshot`: те не начинаются с «-».
    static let flags = ["--help", "-h", "--verbose", "--json", "--icon", "--screenshot", "--update"]
    static let flagPrefixes = ["--config=", "--provider=", "--calibrate="]

    static func isKnown(_ argument: String) -> Bool {
        flags.contains(argument) || flagPrefixes.contains { argument.hasPrefix($0) }
    }

    /// Каталог, названный после `--screenshot` или `--icon`; без него —
    /// текущий. Аргумент, начинающийся с «-», — это соседний флаг, а не путь:
    /// `--screenshot --verbose` иначе завёл бы каталог с именем «--verbose».
    static func directory(after flag: String, in arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: flag),
              arguments.count > index + 1,
              !arguments[index + 1].hasPrefix("-")
        else { return URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Незнакомый флаг — не повод молча поднять строку меню: человек просил
    /// не то, что получит, и узнает об этом в лучшем случае через час.
    static func complain(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
        return 2
    }

    struct Output: Encodable {
        let source: String
        let isEstimate: Bool
        let generatedAt: Date
        let window: Window
        let percent: Percent?
        /// Пятичасовой лимит; ключа нет, когда его не сообщили или окно уже
        /// истекло — как и в панели, просроченный процент не показываем.
        let session: Session?
        let cost: Cost
        let days: [Day]
        let scan: Scan
        let note: String?

        struct Window: Encodable {
            let start: Date
            let end: Date
            let resetLabel: String
            let timeZone: String
            /// Рабочий день, по которому разложен план: «11–24».
            let workHours: String
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

        struct Session: Encodable {
            let usedPercent: Double
            let resetsAt: Date
            let timeLeft: String
            let exhausted: Bool
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
            /// Половина дня сброса: часов меньше, чем у соседних суток,
            /// и сравнивать их проценты в лоб нельзя.
            let partial: Bool

            enum CodingKeys: String, CodingKey {
                case index, label, start, planPercent, usedPercent, cost, partial
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
                try c.encode(partial, forKey: .partial)
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
    /// Обновление из терминала: тот же путь, что у кнопки в панели, только без
    /// перезапуска — процесс тут и так один, и завершается он сам. Нужен и для
    /// проверки всей цепочки разом, и тем, кто держит приложение под launchd:
    /// после установки достаточно выйти и войти.
    ///
    /// `bundle` — что подменяем. У `swift run` бандла нет, поэтому явный путь
    /// к установленной копии допустим: `--update` из отладочной сборки чинит
    /// ту, что в ~/Applications.
    static func update(bundle: URL?) async -> Int32 {
        guard let bundle else {
            FileHandle.standardError.write(Data("""
            обновлять нечего: запущено не из ClaudeWeek.app.
            Соберите бандл (./scripts/make-app.sh) или обновите установленную копию:
              ~/Applications/ClaudeWeek.app/Contents/MacOS/ClaudeWeek --update

            """.utf8))
            return 1
        }

        let release: Release
        do {
            switch try await Updater().check() {
            case .upToDate:
                print("у вас последняя версия — \(ClaudeWeek.version)")
                return 0
            case .available(let found):
                release = found
            }
        } catch {
            let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("\(text)\n".utf8))
            return 1
        }

        print("вышла версия \(release.version), у вас \(ClaudeWeek.version)")
        do {
            try await UpdateInstaller(bundle: bundle).install(release) { stage in
                print("  \(stage.title)")
            }
        } catch {
            let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("\(text)\n".utf8))
            return 1
        }

        print("""
        готово: \(bundle.path) теперь версии \(release.version)
        работающую копию перезапустите сами — она всё ещё старая
        """)
        return 0
    }

    static func calibrate(percent: Double, config: Config, configURL: URL) async -> Int32 {
        // Ноль здесь не «край шкалы», а отсутствие наблюдения: делить на него
        // нечего, и бюджет из него не выйдет.
        guard percent > 0, percent <= 100 else {
            FileHandle.standardError.write(
                Data("процент должен быть больше 0 и не больше 100\n".utf8)
            )
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

    /// Одна строка о том, почему вывод выглядит именно так.
    private static func note(
        percent: Output.Percent?,
        snapshot: UsageSnapshot?,
        failure: Error?
    ) -> String? {
        if percent == nil {
            let reason = (failure as? UsageError)?.errorDescription ?? failure?.localizedDescription
            return reason ?? "проценты недоступны: задайте weeklyBudget или calibration в \(ConfigStore.fileURL.path)"
        }
        if snapshot?.isEstimate == true {
            return "локальная оценка: официальный источник недоступен"
        }
        return snapshot?.shapeIsEstimate == true
            ? "итог официальный; разбивка по суткам восстановлена по транскриптам"
            : nil
    }

    static func run(config: Config) async -> Int32 {
        let now = Date()
        let started = Date()

        // Снимок берём тем же путём, что и приложение: официальный источник
        // с падением на локальную оценку. Иначе `--json` показывал бы не то,
        // что видно в строке меню.
        var snapshot: UsageSnapshot?
        var failure: Error?
        do {
            snapshot = try await ResolvingProvider(config: config).fetch()
        } catch {
            failure = error
        }
        let elapsed = Date().timeIntervalSince(started)

        // Окно официального источника, а без него — рассчитанное по конфигу.
        let window = snapshot?.window ?? WeekWindow(containing: now, config: config)
        let local = LocalProvider(config: config)

        // Локальный скан нужен и при официальном источнике: он даёт стоимость
        // и диагностику обхода, которых в ответе API нет.
        let usage: LocalUsage
        do {
            usage = try await local.scan(window: window, now: now)
        } catch {
            FileHandle.standardError.write(Data("не смог прочитать транскрипты: \(error)\n".utf8))
            return 1
        }

        // Бюджет мог быть подобран автоматически по официальному проценту —
        // он лежит в кеше, а не в конфиге.
        let budget = try? await local.budget(for: usage, override: Store.loadCache()?.weeklyBudget)
        var percent: Output.Percent?
        var cumulative: [Double?] = usage.costByDay.map { _ in nil }

        if let snapshot {
            cumulative = snapshot.byDay.map(\.usedPercent)
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

        let session = snapshot?.session
            .flatMap { $0.isFresh(at: now) ? $0 : nil }
            .map {
                Output.Session(
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt,
                    timeLeft: Formatting.duration($0.timeLeft(from: now)),
                    exhausted: $0.isExhausted
                )
            }

        // Те же семь строк, что и на панели: день сброса одной, той его
        // половиной, что идёт сейчас. `index` — номер суток окна, поэтому
        // у последней пятницы он седьмой, а не шестой.
        let days = window.rows(at: now).map { slot in
            Output.Day(
                index: slot.index,
                label: Formatting.weekdayShort(slot.start, calendar: window.calendar),
                start: slot.start,
                planPercent: slot.planPercent,
                usedPercent: slot.index < cumulative.count ? cumulative[slot.index] : nil,
                cost: slot.index < usage.costByDay.count ? usage.costByDay[slot.index] : nil,
                partial: slot.isPartial
            )
        }

        let output = Output(
            source: (snapshot?.source ?? .local).rawValue,
            isEstimate: snapshot?.isEstimate ?? true,
            generatedAt: now,
            window: Output.Window(
                start: window.start,
                end: window.end,
                resetLabel: Formatting.resetLabel(window),
                timeZone: window.calendar.timeZone.identifier,
                workHours: window.workHours.range
            ),
            percent: percent,
            session: session,
            cost: Output.Cost(total: usage.totalCost, weeklyBudget: budget, currency: "USD"),
            days: days,
            scan: Output.Scan(
                filesRead: usage.filesRead,
                records: usage.recordCount,
                duplicatesSkipped: usage.duplicatesSkipped,
                elapsedSeconds: elapsed
            ),
            note: note(percent: percent, snapshot: snapshot, failure: failure)
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
