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
                    if manually { offer(release) }
                }
            } catch {
                let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
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
                let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
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
            state = .failed("новая версия поставлена, но перезапустить не вышло — запустите вручную", nil)
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
        alert.messageText = "Вышла версия \(release.version)"
        alert.informativeText = Self.digest(of: release)
        alert.addButton(withTitle: "Обновить")
        alert.addButton(withTitle: "Что нового")
        alert.addButton(withTitle: "Отмена")

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
        alert.messageText = "ClaudeWeek \(release.version) установлена"
        alert.informativeText = """
        В строке меню пока работает \(ClaudeWeek.version) — новая версия \
        начнётся с перезапуска. Настройки, кеш и калибровка остались на месте.
        """
        alert.addButton(withTitle: "Перезапустить")
        alert.addButton(withTitle: "Позже")
        if present(alert) == .alertFirstButtonReturn { relaunch() }
    }

    private func sayUpToDate() {
        let alert = NSAlert()
        alert.messageText = "У вас последняя версия"
        alert.informativeText = "ClaudeWeek \(ClaudeWeek.version) — свежее на GitHub ничего нет."
        alert.addButton(withTitle: "Хорошо")
        _ = present(alert)
    }

    private func report(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Обновиться не вышло"
        alert.informativeText = text
        alert.addButton(withTitle: "Понятно")
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
        var lines: [String] = []
        for raw in release.notes.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Заголовки секций, ограждения блоков кода и команды карантина —
            // это про установку руками, которой здесь как раз не будет.
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```") else { continue }
            lines.append(line)
            if lines.count == 6 { break }
        }
        let notes = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
        return """
        \(notes)У вас \(ClaudeWeek.version). Образ скачается со страницы релиза, \
        сверится по контрольной сумме и заменит работающее приложение.
        """
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
        case .available(let release): "вышла версия \(release.version)"
        case .installing(_, let stage): stage.title
        case .installed(let release): "версия \(release.version) готова"
        case .failed(let text, _): text
        }
    }

    /// Подпись единственной кнопки обновления — она же говорит, что случится
    /// по нажатию.
    var actionTitle: String {
        switch state {
        case .idle, .upToDate, .failed(_, .none): "Проверить обновления"
        case .available(let release): "Обновить до \(release.version)…"
        case .failed(_, .some): "Попробовать ещё раз"
        case .installed: "Перезапустить"
        case .checking: "Проверяю…"
        case .installing(_, let stage): stage.title
        }
    }

    /// Строка для вкладки «О программе» — там, в отличие от панели, отвечать
    /// надо на любой исход, включая «проверил, всё свежее».
    var summary: String {
        switch state {
        case .idle:
            isAvailable ? "проверю в ближайшие секунды" : "только у собранного приложения"
        case .checking:
            "спрашиваю GitHub…"
        case .upToDate(let at):
            "у вас последняя, проверено в \(Formatting.clock(at, calendar: .current))"
        case .available(let release):
            "доступна \(release.version) — у вас \(ClaudeWeek.version)"
        case .installing(_, let stage):
            stage.title
        case .installed(let release):
            "\(release.version) поставлена — осталось перезапустить"
        case .failed(let text, _):
            text
        }
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
