import AppKit
import Observation
import ClaudeWeekCore

/// Обновление с точки зрения человека: что мы про него знаем и что предлагаем
/// сделать. Проверка идёт сама — при запуске и раз в сутки, — а скачивание и
/// подмена бандла только по кнопке: программа в строке меню не должна
/// перезапускаться посреди работы без спроса.
@MainActor
@Observable
final class UpdateController {
    /// Язык окон и строки в панели. У AppKit-класса нет окружения SwiftUI,
    /// поэтому язык ему выдаёт владелец — тем же движением, каким применяет
    /// конфиг.
    var strings = L10n(Lang.ru)

    /// Нашлась новая версия при самостоятельной проверке. Владелец превращает
    /// это в баннер: сам контроллер обновлений с уведомлениями не знаком —
    /// он про GitHub и установку, а не про разговоры с человеком.
    var onFound: ((Release) -> Void)?

    enum State: Equatable {
        /// Ни новостей, ни повода что-то показывать.
        case idle
        case checking
        /// Проверено в этот момент, новее ничего нет.
        case upToDate(Date)
        case available(Release)
        case installing(Release, UpdateInstaller.Stage)
        /// Новая версия уже на диске — осталось перезапустить.
        case installed(Release)
        /// Сорвалось. Релиз запомнен, если знаем, на чём именно.
        case failed(String, Release?)
    }

    private(set) var state: State = .idle

    /// Раз в сутки: релизы у проекта выходят в лучшем случае раз в неделю, и
    /// спрашивать GitHub чаще незачем — там 60 запросов в час на адрес, и
    /// тратить их на «а вдруг» неприлично.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Проверку при запуске откладываем: первые секунды уходят на данные для
    /// строки меню, и обновление в этой очереди последнее.
    private static let startupDelay: TimeInterval = 5

    private let updater: Updater
    /// Бандл, который будем подменять; nil — запущено `swift run`, обновлять
    /// нечего (ровно как с автозапуском в `LoginItem`).
    private let bundle: URL?
    private var lastCheck: Date?
    private var timer: Timer?

    init(updater: Updater = Updater(), bundle: URL? = UpdateController.runningBundle) {
        self.updater = updater
        self.bundle = bundle
    }

    /// Обновляется только собранный бандл. У отладочного `swift run`
    /// исполняемый файл лежит в .build и живёт до следующей сборки.
    static var runningBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var isAvailable: Bool { bundle != nil }

    // MARK: Расписание

    func start() {
        guard isAvailable else { return }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startupDelay))
            self?.check()
        }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Час допуска: сутки плюс-минус час — то же самое, а система вольна
        // сложить это пробуждение с другими.
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Проверка после сна: таймер, проспавший свой срок, срабатывает не сразу,
    /// а машину закрывают на ночь — без этого «раз в сутки» превращалось бы
    /// в «раз в сутки работы».
    func checkIfDue() {
        guard let lastCheck else { return check() }
        guard Date().timeIntervalSince(lastCheck) >= Self.interval else { return }
        check()
    }

    // MARK: Действия

    /// Единственная кнопка обновления живёт на вкладке «О программе» и делает
    /// следующий шаг, какой бы он ни был: спросить GitHub, показать найденное,
    /// поставить, перезапустить. Отдельных «проверить» и «установить» не
    /// заводим — человек всё равно нажимает их подряд.
    func run() {
        switch state {
        case .idle, .upToDate, .failed(_, nil): check(manually: true)
        case .available(let release), .failed(_, .some(let release)): offer(release)
        case .installed(let release): askRelaunch(release)
        case .checking, .installing: break
        }
    }

    /// `manually` — проверку запросили кнопкой. Разница в том, о чём молчать:
    /// самостоятельная проверка не должна ни выскакивать окном посреди
    /// работы, ни зажигать в панели строку из-за пропавшей сети, а нажатая
    /// кнопка обязана ответить в любом случае.
    func check(manually: Bool = false) {
        guard isAvailable, !isBusy else { return }
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let check = try await updater.check()
                lastCheck = Date()
                switch check {
                case .upToDate:
                    state = .upToDate(Date())
                    if manually { sayUpToDate() }
                case .available(let release):
                    Log.info("вышла версия \(release.version), у нас \(ClaudeWeek.version)")
                    state = .available(release)
                    // Нажатая кнопка отвечает окном, самостоятельная проверка —
                    // баннером: строку внизу панели видит только тот, кто её
                    // открыл, а обновление ждёт как раз тех, кто не открывает.
                    if manually { offer(release) } else { onFound?(release) }
                }
            } catch {
                let text = (error as? UpdateError)?.message(strings.lang) ?? error.localizedDescription
                Log.warn("проверка обновлений не удалась: \(text)")
                state = manually ? .failed(text, nil) : .idle
                if manually { report(text) }
            }
        }
    }

    func install(_ release: Release) {
        guard let bundle, !isBusy else { return }
        state = .installing(release, .downloading)

        Task { [weak self] in
            guard let self else { return }
            let installer = UpdateInstaller(bundle: bundle)
            do {
                // Шаги приходят с актора установщика — возвращаем их на главный,
                // где живёт состояние. Захват сильный, но и живёт он ровно
                // столько, сколько идёт установка.
                try await installer.install(release) { stage in
                    Task { @MainActor in
                        self.state = .installing(release, stage)
                    }
                }
                state = .installed(release)
                askRelaunch(release)
            } catch {
                let text = (error as? UpdateError)?.message(strings.lang) ?? error.localizedDescription
                Log.warn("не поставил обновление: \(text)")
                state = .failed(text, release)
                report(text)
            }
        }
    }

    /// Перезапуск после подмены бандла. Новый экземпляр поднимаем не сразу, а
    /// через секунду и уже из отдельного процесса: пока мы живы, в строке меню
    /// висели бы два значка, а `open` дожидаться нашего выхода не умеет.
    func relaunch() {
        guard let bundle else { return }
        let path = bundle.path.replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        do {
            try process.run()
        } catch {
            Log.warn("не смог перезапуститься: \(error)")
            state = .failed(strings.pick("новая версия поставлена, но перезапустить не вышло — запустите вручную",
                                         "the new version is installed but the restart failed — start it by hand"), nil)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Разговор с человеком

    /// Что изменилось — до того, как качать. Заметки пишет release.yml: там и
    /// установка, и контрольная сумма, и список коммитов, поэтому берём начало
    /// и отправляем за подробностями на страницу релиза.
    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = strings.pick("Вышла версия \(release.version)", "Version \(release.version) is out")
        alert.informativeText = Self.digest(of: release)
        alert.addButton(withTitle: strings.pick("Обновить", "Update"))
        alert.addButton(withTitle: strings.pick("Что нового", "What’s new"))
        alert.addButton(withTitle: strings.pick("Отмена", "Cancel"))

        switch present(alert) {
        case .alertFirstButtonReturn:
            install(release)
        case .alertSecondButtonReturn:
            // Страница вместо установки: прочитает и нажмёт кнопку снова —
            // найденный выпуск никуда из состояния не денется.
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    /// Перезапуск — отдельный вопрос, а не продолжение установки: на диске уже
    /// новая версия, но в строке меню работает прежняя, и выбрать момент
    /// человек должен сам.
    private func askRelaunch(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = strings.pick("ClaudeWeek \(release.version) установлена",
                                         "ClaudeWeek \(release.version) is installed")
        alert.informativeText = strings.pick("""
        В строке меню пока работает \(ClaudeWeek.version) — новая версия \
        начнётся с перезапуска. Настройки, кеш и калибровка остались на месте.
        """, """
        The menu bar still runs \(ClaudeWeek.version) — the new one starts with a \
        restart. Settings, cache and calibration stayed where they were.
        """)
        alert.addButton(withTitle: strings.pick("Перезапустить", "Restart"))
        alert.addButton(withTitle: strings.pick("Позже", "Later"))
        if present(alert) == .alertFirstButtonReturn { relaunch() }
    }

    private func sayUpToDate() {
        let alert = NSAlert()
        alert.messageText = strings.pick("У вас последняя версия", "You are on the latest version")
        alert.informativeText = strings.pick("ClaudeWeek \(ClaudeWeek.version) — свежее на GitHub ничего нет.",
                                             "ClaudeWeek \(ClaudeWeek.version) — nothing newer on GitHub.")
        alert.addButton(withTitle: strings.pick("Хорошо", "OK"))
        _ = present(alert)
    }

    private func report(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.pick("Обновиться не вышло", "The update did not go through")
        alert.informativeText = text
        alert.addButton(withTitle: strings.pick("Понятно", "Got it"))
        _ = present(alert)
    }

    /// Приложение живёт без Dock (`LSUIElement`), и без явной активации окно
    /// откроется за спиной у той программы, в которой человек сейчас работает.
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Начало заметок без разметки: NSAlert растёт вместе с текстом, а полный
    /// список коммитов в модальном окне никому не нужен.
    private static func digest(of release: Release) -> String {
        var items: [String] = []
        for raw in release.notes.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Свёрнутый список коммитов и строка-ссылка «все изменения» стоят
            // после главного — дальше читать нечего. Ссылка узнаётся по тому,
            // что занимает строку целиком: ссылка на `docs/` посреди фразы
            // заканчивается словами, а не закрывающей скобкой.
            if line.hasPrefix("<") || (line.hasPrefix("[") && line.hasSuffix(")")) { break }
            // Заголовки секций, ограждения блоков кода и команды карантина —
            // это про установку руками, которой здесь как раз не будет.
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```") else { continue }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if items.count == 3 { break }
                items.append(String(line.dropFirst(2)))
            } else if let last = items.popLast() {
                // Заметки приходят из журнала, а там строки перенесены по
                // ширине файла: без склейки окно обрывало бы фразу на
                // полуслове там, где кончилась строка markdown.
                items.append(last + " " + line)
            } else {
                items.append(line)
            }
        }
        let notes = items.isEmpty
            ? ""
            : items.map { "• " + shortened($0) }.joined(separator: "\n") + "\n\n"
        return """
        \(notes)У вас \(ClaudeWeek.version). Образ скачается со страницы релиза, \
        сверится по контрольной сумме и заменит работающее приложение.
        """
    }

    /// Пункт журнала бывает в абзац длиной — целиком он раздувает модальное
    /// окно и топит соседние. Обрезаем по границе слова: подробности всё равно
    /// за кнопкой «Что нового».
    private static func shortened(_ text: String, limit: Int = 180) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }

    private var isBusy: Bool {
        switch state {
        // Поставленное обновление важнее любой новой проверки: до перезапуска
        // на диске уже другая версия, и говорить о ней что-то ещё — врать.
        case .checking, .installing, .installed: true
        default: false
        }
    }

    // MARK: Как это читается

    /// Строка для панели; nil — показывать нечего. Тихие состояния («идёт
    /// проверка», «у вас последняя») сюда не попадают: панель открывают ради
    /// недельного лимита, и место в ней занимает только новость.
    var banner: String? {
        switch state {
        case .idle, .checking, .upToDate: nil
        case .available(let release):
            strings.pick("вышла версия \(release.version)", "version \(release.version) is out")
        case .installing(_, let stage): stage.title(strings.lang)
        case .installed(let release):
            strings.pick("версия \(release.version) готова", "version \(release.version) is ready")
        case .failed(let text, _): text
        }
    }

    /// Подпись единственной кнопки обновления — она же говорит, что случится
    /// по нажатию.
    var actionTitle: String {
        switch state {
        case .idle, .upToDate, .failed(_, .none):
            strings.pick("Проверить обновления", "Check for updates")
        case .available(let release):
            strings.pick("Обновить до \(release.version)…", "Update to \(release.version)…")
        case .failed(_, .some): strings.pick("Попробовать ещё раз", "Try again")
        case .installed: strings.pick("Перезапустить", "Restart")
        case .checking: strings.pick("Проверяю…", "Checking…")
        case .installing(_, let stage): stage.title(strings.lang)
        }
    }

    /// Строка для вкладки «О программе» — там, в отличие от панели, отвечать
    /// надо на любой исход, включая «проверил, всё свежее».
    var summary: String {
        switch state {
        case .idle:
            isAvailable
                ? strings.pick("проверю в ближайшие секунды", "checking in a few seconds")
                : strings.pick("только у собранного приложения", "built app only")
        case .checking:
            strings.pick("спрашиваю GitHub…", "asking GitHub…")
        case .upToDate(let at):
            strings.pick("последняя версия — \(ClaudeWeek.version), проверено \(Self.checkedAt(at, lang: strings.lang))",
                         "latest version — \(ClaudeWeek.version), checked \(Self.checkedAt(at, lang: strings.lang))")
        case .available(let release):
            strings.pick("доступна \(release.version) — у вас \(ClaudeWeek.version)",
                         "\(release.version) is available — you have \(ClaudeWeek.version)")
        case .installing(_, let stage):
            stage.title(strings.lang)
        case .installed(let release):
            strings.pick("\(release.version) поставлена — осталось перезапустить",
                         "\(release.version) is installed — a restart is all that is left")
        case .failed(let text, _):
            text
        }
    }

    /// «в 14:23», а проверенное вчера — «ВТ в 14:23». День нужен потому, что
    /// программа живёт в строке меню сутками, а проверка идёт раз в сутки:
    /// голый час у позавчерашней проверки читается как сегодняшний.
    static func checkedAt(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        lang: Lang = .ru
    ) -> String {
        let day = calendar.isDate(date, inSameDayAs: now)
            ? ""
            : "\(Formatting.weekdayShort(date, calendar: calendar, lang: lang)) "
        let clock = Formatting.clock(date, calendar: calendar)
        return L10n(lang).pick("\(day)в \(clock)", "\(day)at \(clock)")
    }

    var isWorking: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    /// Релиз, о котором сейчас речь, — для ссылки «что нового».
    var release: Release? {
        switch state {
        case .available(let release), .installing(let release, _), .installed(let release): release
        case .failed(_, let release): release
        case .idle, .checking, .upToDate: nil
        }
    }
}
