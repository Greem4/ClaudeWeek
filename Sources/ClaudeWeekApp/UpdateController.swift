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

    /// `manually` — проверку запросили из меню или настроек. Разница только в
    /// том, о чём молчать: самостоятельная проверка без сети не должна
    /// зажигать в панели красную строку, а нажатая кнопка обязана ответить.
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
                case .available(let release):
                    Log.info("вышла версия \(release.version), у нас \(ClaudeWeek.version)")
                    state = .available(release)
                }
            } catch {
                let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
                Log.warn("проверка обновлений не удалась: \(text)")
                state = manually ? .failed(text, nil) : .idle
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
            } catch {
                let text = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
                Log.warn("не поставил обновление: \(text)")
                state = .failed(text, release)
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

    /// Кнопка рядом со строкой об обновлении делает то, что напрашивается
    /// в этом состоянии, — отдельных «повторить» и «поставить» не заводим.
    func act() {
        switch state {
        case .available(let release): install(release)
        case .installed: relaunch()
        case .failed(_, let release?): install(release)
        case .failed(_, nil), .upToDate, .idle: check(manually: true)
        case .checking, .installing: break
        }
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

    /// Подпись кнопки рядом со строкой; nil — кнопки нет.
    var actionTitle: String? {
        switch state {
        case .available: "Обновить"
        case .installed: "Перезапустить"
        case .failed(_, .some): "Ещё раз"
        case .failed(_, .none): nil
        case .idle, .checking, .upToDate, .installing: nil
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
