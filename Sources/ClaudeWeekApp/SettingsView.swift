import SwiftUI
import AppKit
import ClaudeWeekCore

/// Окно настроек: шесть вкладок, по одной на предмет разговора — откуда цифры,
/// что показывает строка меню, как выглядит панель, когда программа заговорит
/// сама, доступ к токену, справка. Предпросмотром служит сама панель: она
/// закреплена на экране, пока окно открыто, и перерисовывается на каждую правку.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Общие", systemImage: "gearshape") }

            MenuBarSettings(model: model)
                .tabItem { Label("Строка меню", systemImage: "menubar.rectangle") }

            AppearanceSettings(model: model)
                .tabItem { Label("Панель", systemImage: "paintpalette") }

            NotificationSettings(model: model)
                .tabItem { Label("Уведомления", systemImage: "bell") }

            AccessSettings(model: model)
                .tabItem { Label("Доступ", systemImage: "key") }

            AboutSettings(model: model)
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 580)
    }
}

/// Строка «подпись — ползунок — процент». Одна на пороги цвета и пороги
/// уведомлений: величина в них одна и та же — процент расхода, — и выглядеть
/// в двух вкладках по-разному она не должна.
struct PercentRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: 0...100, step: 1)
                Text(Formatting.percent(value))
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}

// MARK: - Общие

private struct GeneralSettings: View {
    @Bindable var model: SettingsModel

    private var config: Binding<Config> { $model.config }

    /// Строки на выбранном языке. Читаются из конфига, а не из глобальной
    /// переменной: смена языка меняет конфиг, а по нему SwiftUI перерисует
    /// вкладку сам — без перезапуска и без ручного оповещения.
    private var s: L10n { model.config.strings }

    var body: some View {
        Form {
            Section {
                Picker(s.languageTitle, selection: config.language) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.title(s.lang)).tag(language)
                    }
                }
                Text(s.languageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Запуск") {
                Toggle("Запускать при входе в систему", isOn: launchAtLogin)
                    .disabled(!LoginItem.isAvailable)
                Text(launchHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Источник данных") {
                Picker("Откуда брать цифры", selection: config.provider) {
                    Text("Официальный, с падением на локальный").tag(ProviderPreference.auto)
                    Text("Только официальный").tag(ProviderPreference.official)
                    Text("Только локальная оценка").tag(ProviderPreference.local)
                }
                Text(providerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Обновлять раз в") {
                    HStack {
                        Slider(
                            value: config.refreshInterval,
                            in: 60...1800,
                            step: 30
                        )
                        Text(Formatting.duration(model.config.refreshInterval))
                            .font(.caption.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }

            Section("Недельное окно") {
                Picker("День сброса", selection: config.resetWeekday) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }
                HStack {
                    Stepper("Час сброса: \(model.config.resetHour)", value: config.resetHour, in: 0...23)
                    Stepper("Минута: \(model.config.resetMinute)", value: config.resetMinute, in: 0...59)
                }
                Picker("Таймзона", selection: config.timeZone) {
                    Text("Системная").tag("")
                    ForEach(popularZones, id: \.self) { zone in
                        Text(zone).tag(zone)
                    }
                }
                Text("""
                При живом официальном источнике момент сброса берётся из ответа \
                сервера — эти поля нужны только офлайн.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Рабочий день") {
                Picker("Распорядок", selection: config.workHours) {
                    ForEach(WorkHours.presets, id: \.self) { hours in
                        Text(hours.title).tag(hours)
                    }
                    // Часы, накрученные степперами, тоже должны где-то стоять,
                    // иначе список показывал бы чужое значение как выбранное.
                    if !WorkHours.presets.contains(model.config.workHours) {
                        Text(model.config.workHours.title).tag(model.config.workHours)
                    }
                }

                // Границы держат день непустым: вывернутый интервал конфиг
                // чинит на круглосуточный, и в степпере это выглядело бы как
                // самовольный сброс настройки.
                HStack {
                    Stepper(
                        "С \(model.config.workHours.start):00",
                        value: config.workHours.start,
                        in: 0...(model.config.workHours.end - 1)
                    )
                    Stepper(
                        "до \(hourLabel(model.config.workHours.end))",
                        value: config.workHours.end,
                        in: (model.config.workHours.start + 1)...24
                    )
                }
                LabeledContent("Получается", value: workHoursSummary)
                Text(workHoursHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    /// Галочка ходит не в конфиг, а в launchd, поэтому и биндинг свой:
    /// состояние после щелчка модель перечитывает из самого агента.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var launchHint: String {
        guard LoginItem.isAvailable else {
            // Запущено не из бандла — из .build, отладочным `swift run`.
            // Прописывать такой путь в launchd бессмысленно, и молчаливо
            // погашенная галочка выглядела бы поломкой.
            return """
            Доступно только у собранного приложения: у отладочного swift run \
            исполняемый файл лежит в .build и живёт до следующей сборки.
            """
        }
        return """
        Правит того же launchd-агента, что ставит install.sh, — файл \
        ~/Library/LaunchAgents/\(LoginItem.label).plist. Включение и выключение \
        начинают действовать со следующего входа в систему: запущенное \
        приложение галочка не гасит и второй копии не поднимает.
        """
    }

    /// Полночь показываем как «0:00 следующих суток», а не как «24:00»:
    /// в степпере это край шкалы, и человеку нужно понимать, что дальше некуда.
    private func hourLabel(_ hour: Int) -> String {
        hour >= 24 ? "полуночи" : "\(hour):00"
    }

    /// «10:00 – 18:00, 8 ч в сутки» — часы словами, чтобы не считать их
    /// в уме по двум степперам.
    private var workHoursSummary: String {
        let work = model.config.workHours
        guard !work.isAllDay else { return "круглые сутки, 24 ч" }
        return "\(work.clockRange), \(work.hours) ч в сутки"
    }

    private var workHoursHint: String {
        let hours = model.config.workHours.hours
        guard !model.config.workHours.isAllDay else {
            return """
            Круглосуточно: план растёт и ночью, поэтому за сон набегает \
            около 40 % недельного лимита.
            """
        }
        return """
        Недельный лимит раскладывается по этим часам — \(hours) ч в сутки. \
        Ночью план стоит: утром вы начинаете с той же отметки, на которой \
        закончили, а работа в три ночи целиком ложится в перерасход.
        """
    }

    private var providerHint: String {
        switch model.config.provider {
        case .auto:
            "Как в /usage; когда сеть или авторизация отваливаются — локальная оценка с пометкой ≈."
        case .official:
            "Только цифры сервера. Нет сети — панель честно скажет, что данных нет."
        case .local:
            "Считает по транскриптам ~/.claude/projects. Работает офлайн, точность зависит от калибровки."
        }
    }

    private let weekdays = [
        "Воскресенье", "Понедельник", "Вторник", "Среда",
        "Четверг", "Пятница", "Суббота",
    ]

    private let popularZones = [
        "Europe/Saratov", "Europe/Moscow", "Europe/Kaliningrad", "Europe/Samara",
        "Asia/Yekaterinburg", "Asia/Novosibirsk", "Asia/Vladivostok",
        "Europe/Berlin", "Europe/London", "America/New_York", "America/Los_Angeles", "UTC",
    ]
}

// MARK: - Строка меню

/// Всё про значок у часов: что он показывает и когда меняет цвет. Пороги
/// живут здесь же, хотя красят и панель: разговор про цвет один, и разносить
/// его по двум вкладкам значит искать половину в другом месте.
private struct MenuBarSettings: View {
    @Bindable var model: SettingsModel

    private var thresholds: Thresholds { model.config.thresholds }

    var body: some View {
        Form {
            Section("Значок") {
                Picker("Показывать", selection: $model.config.menuBarStyle) {
                    Text("Полоса и процент").tag(MenuBarStyle.percent)
                    Text("Только полоса").tag(MenuBarStyle.compact)
                    Text("Кольцо с процентом").tag(MenuBarStyle.ring)
                }
                Text(styleHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Расклад кольца спрашиваем только когда оно выбрано: у полосы
                // второго лимита нет, и пункт стоял бы там без смысла.
                if model.config.menuBarStyle == .ring {
                    Picker("Заполнять дугой", selection: $model.config.ringArc) {
                        ForEach(RingArc.allCases, id: \.self) { arc in
                            Text(arc.title).tag(arc)
                        }
                    }
                    Text(ringHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Цвет") {
                Toggle("Менять цвет по порогам", isOn: colorize)
                Text("""
                Выключенный — значок всегда нейтрального цвета, а расход \
                по-прежнему виден заполнением и цифрой. Панель красится в любом \
                случае: пороги ниже задают цвет и её заголовку с полосой сессии.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Недельный лимит") {
                PercentRow(title: "Жёлтый после", value: weekWarn)
                PercentRow(title: "Красный после", value: weekCritical)
            }

            Section("Пятичасовая сессия") {
                PercentRow(title: "Жёлтый после", value: sessionWarn)
                PercentRow(title: "Красный после", value: sessionCritical)
                Text("""
                Считается по факту: сколько потрачено прямо сейчас. План и \
                прогноз на цвет больше не влияют — они отвечают на вопрос \
                «в графике ли я», а цвет на «пора ли беспокоиться». Сессию \
                сообщает только официальный источник: на локальной оценке её \
                процент стоит на нуле.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var styleHint: String {
        switch model.config.menuBarStyle {
        case .percent: "Полоса недели с планом, под ней недельный процент."
        case .compact: "Одна полоса недели, без числа — самый узкий значок."
        case .ring: "Два лимита в одном значке: один на дуге, второй цифрой внутри."
        }
    }

    /// Расклад кольца словами: какой лимит куда попал при нынешнем выборе.
    /// Цвета остаются раздельными в обе стороны — дуга и цифра горят каждая
    /// по своим порогам, и красная дуга при спокойной цифре это норма, а не
    /// сбой.
    private var ringHint: String {
        switch model.config.ringArc {
        case .session:
            """
            Дуга — пятичасовая сессия, цифра внутри — недельный процент. \
            Цвет у каждого свой, по своим порогам ниже.
            """
        case .week:
            """
            Дуга — недельный лимит, цифра внутри — процент пятичасовой сессии. \
            Цвет у каждого свой, по своим порогам ниже.
            """
        }
    }

    // Пороги держим в порядке прямо в биндингах: жёлтый выше красного —
    // не «неверная настройка», а неотличимое от красного поведение, и
    // объяснять его окошком с ошибкой хуже, чем не дать сделать.
    private var weekWarn: Binding<Double> {
        Binding(
            get: { thresholds.weekWarn },
            set: {
                model.config.thresholds.weekWarn = $0
                model.config.thresholds.weekCritical = max(thresholds.weekCritical, $0)
            }
        )
    }

    private var weekCritical: Binding<Double> {
        Binding(
            get: { thresholds.weekCritical },
            set: {
                model.config.thresholds.weekCritical = $0
                model.config.thresholds.weekWarn = min(thresholds.weekWarn, $0)
            }
        )
    }

    private var sessionWarn: Binding<Double> {
        Binding(
            get: { thresholds.sessionWarn },
            set: {
                model.config.thresholds.sessionWarn = $0
                model.config.thresholds.sessionCritical = max(thresholds.sessionCritical, $0)
            }
        )
    }

    private var sessionCritical: Binding<Double> {
        Binding(
            get: { thresholds.sessionCritical },
            set: {
                model.config.thresholds.sessionCritical = $0
                model.config.thresholds.sessionWarn = min(thresholds.sessionWarn, $0)
            }
        )
    }

    private var colorize: Binding<Bool> {
        Binding(
            get: { thresholds.colorizeMenuBar },
            set: { model.config.thresholds.colorizeMenuBar = $0 }
        )
    }
}

// MARK: - Панель

private struct AppearanceSettings: View {
    @Bindable var model: SettingsModel

    private var appearance: Binding<AppearanceConfig> { $model.config.appearance }

    var body: some View {
        Form {
            Section("Тема") {
                Picker("Палитра", selection: appearance.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text(themeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Фон панели") {
                Toggle("Прозрачный фон с размытием", isOn: appearance.transparentPanel)
                LabeledContent("Плотность фона") {
                    HStack {
                        Slider(value: appearance.panelTintOpacity, in: 0...1, step: 0.01)
                            .disabled(!model.config.appearance.transparentPanel)
                        Text(String(format: "%.0f %%", model.config.appearance.panelTintOpacity * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                LabeledContent("Скругление углов") {
                    HStack {
                        Slider(value: appearance.cornerRadius, in: 0...24, step: 1)
                        Text("\(Int(model.config.appearance.cornerRadius)) pt")
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("""
                Ноль плотности — чистый материал строки меню, как у системных \
                меню; дальше вуаль подкрашивает его, но размытие остаётся \
                видно. Нужен глухой фон — выключите прозрачность, это \
                отдельный режим. Как это выглядит, видно на самой панели: она \
                висит у строки меню, пока открыто это окно.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Суточные полосы") {
                Picker("Показывать", selection: appearance.panelLayout) {
                    ForEach(PanelLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Text(layoutHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Строки панели") {
                Toggle("Пятичасовая сессия", isOn: appearance.showSession)
                Toggle("Прогноз «кончится в …»", isOn: appearance.showForecast)
                Text("""
                Откуда взяты цифры, говорит кружок рядом с полосой сессии: \
                залитый зелёный — ответ сервера, залитый жёлтый — он же, но \
                из кеша, контурный красный — локальная оценка. Наведите на \
                него, и панель скажет, что именно случилось.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Сброс сессии") {
                Picker("Подписывать", selection: appearance.sessionReset) {
                    ForEach(SessionResetDisplay.allCases, id: \.self) { display in
                        Text(display.title).tag(display)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.config.appearance.showSession)

                LabeledContent("Выглядит так") {
                    Text(sessionResetSample)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("""
                Момент сброса приходит от сервера вместе с процентом — настройка \
                выбирает не его, а лишь то, каким концом его показать. Час \
                за полночь подписывается днём недели: пятичасовое окно легко \
                через неё перешагивает.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Образец подписи на выдуманных 1 ч 12 мин. Живая панель рядом показывает
    /// настоящую строку, но только когда сессия есть: без данных от сервера её
    /// нет вовсе, и выбирать пришлось бы вслепую.
    private var sessionResetSample: String {
        let now = Date()
        let reset = Formatting.sessionReset(
            at: now.addingTimeInterval(72 * 60),
            now: now,
            display: model.config.appearance.sessionReset,
            calendar: model.config.calendar
        )
        return "сброс \(reset)"
    }

    private var layoutHint: String {
        switch model.config.appearance.panelLayout {
        case .week:
            "Семь полос, по дню недели каждая: весь ряд перед глазами."
        case .compact:
            """
            Только текущие сутки — панель короче на шесть строк. Неделя не \
            потеряна: щёлкните по строке дня, и ряд раскроется целиком, пока \
            панель открыта. Итог недели и час сброса остаются на месте в любом \
            случае.
            """
        }
    }

    private var themeHint: String {
        switch model.config.appearance.theme {
        case .system:
            "Родная палитра: прогнана через валидатор на дальтонизм и контраст."
        case .midnight, .graphite, .paper, .contrast:
            "Экспериментальная палитра: валидатором не проверялась, роли цветов те же."
        }
    }
}

// MARK: - Уведомления

/// Когда программа заговорит сама. Пороги здесь свои, отдельные от цветовых:
/// цвет замечают, только посмотрев на значок, а баннер приходит поверх работы,
/// и отметки, на которых человек готов отвлечься, обычно выше.
///
/// Единственная вкладка не под `private`: её снимает `--screenshot` для
/// документации — картинку настроек иначе пришлось бы обновлять руками.
struct NotificationSettings: View {
    @Bindable var model: SettingsModel

    private var notifications: NotificationsConfig { model.config.notifications }
    /// Пороги настраиваются и при выключенных уведомлениях — гасим их только
    /// вместе с самим тумблером, чтобы не пришлось включать баннеры ради того,
    /// чтобы посмотреть, на чём они стоят.
    private var isOff: Bool { !notifications.enabled }

    var body: some View {
        Form {
            Section("Уведомления") {
                Toggle("Предупреждать о приближении к лимиту", isOn: enabled)
                Text(model.notifications.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.notifications.needsSystemSettings {
                    Button("Открыть настройки уведомлений macOS") {
                        model.notifications.openSystemSettings()
                    }
                }

                Toggle("Со звуком", isOn: sound)
                    .disabled(isOff)

                Text("""
                В баннере две строки: сколько израсходовано и через сколько \
                сброс. Какой это лимит, говорит картинка справа — пятичасовая \
                сессия приходит дугой, недельный лимит красным числом.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("""
                Об одном пороге программа говорит один раз за окно лимита и \
                только на ухудшении: откатившийся расход молчит, а следующая \
                неделя и следующая сессия начинают отсчёт заново. Два баннера \
                подряд не приходят ближе, чем через пять минут.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Недельный лимит") {
                Toggle("Уведомлять о недельном лимите", isOn: weekEnabled)
                PercentRow(title: "Предупредить после", value: weekFirst)
                PercentRow(title: "И ещё раз после", value: weekSecond)
                previewButton(.week)
                Text("""
                Неделя не сбросится до её конца, поэтому предупреждать о ней \
                стоит раньше: после первого порога расход ещё можно растянуть \
                на оставшиеся дни.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(isOff)

            Section("Пятичасовая сессия") {
                Toggle("Уведомлять о пятичасовой сессии", isOn: sessionEnabled)
                PercentRow(title: "Предупредить после", value: sessionFirst)
                PercentRow(title: "И ещё раз после", value: sessionSecond)
                previewButton(.session)
                Text("""
                Сессию сообщает только официальный источник: на локальной \
                оценке её процент не считается вовсе, и уведомлений о ней \
                не будет.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(isOff)
        }
        .formStyle(.grouped)
    }

    /// Кнопка «Показать пример» стоит в секции своего лимита: у недели и
    /// сессии баннеры разные — заголовком, порогом и масштабом времени до
    /// сброса, — и одна кнопка на двоих показывала бы чужой.
    private func previewButton(_ kind: AlertKind) -> some View {
        HStack {
            Button("Показать пример") { model.previewNotification(kind) }
                .disabled(!model.notifications.canPreview)
            Spacer()
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { notifications.enabled },
            set: { model.config.notifications.enabled = $0 }
        )
    }

    private var sound: Binding<Bool> {
        Binding(
            get: { notifications.sound },
            set: { model.config.notifications.sound = $0 }
        )
    }

    private var weekEnabled: Binding<Bool> {
        Binding(
            get: { notifications.week.enabled },
            set: { model.config.notifications.week.enabled = $0 }
        )
    }

    private var sessionEnabled: Binding<Bool> {
        Binding(
            get: { notifications.session.enabled },
            set: { model.config.notifications.session.enabled = $0 }
        )
    }

    // Порядок держим прямо в биндингах, как и у цветовых порогов: второй порог
    // ниже первого — это не «неверная настройка», а два одинаковых баннера,
    // и не дать их сделать лучше, чем объяснять окошком с ошибкой.
    private var weekFirst: Binding<Double> {
        Binding(
            get: { notifications.week.first },
            set: {
                model.config.notifications.week.first = $0
                model.config.notifications.week.second = max(notifications.week.second, $0)
            }
        )
    }

    private var weekSecond: Binding<Double> {
        Binding(
            get: { notifications.week.second },
            set: {
                model.config.notifications.week.second = $0
                model.config.notifications.week.first = min(notifications.week.first, $0)
            }
        )
    }

    private var sessionFirst: Binding<Double> {
        Binding(
            get: { notifications.session.first },
            set: {
                model.config.notifications.session.first = $0
                model.config.notifications.session.second = max(notifications.session.second, $0)
            }
        )
    }

    private var sessionSecond: Binding<Double> {
        Binding(
            get: { notifications.session.second },
            set: {
                model.config.notifications.session.second = $0
                model.config.notifications.session.first = min(notifications.session.first, $0)
            }
        )
    }
}

// MARK: - Доступ

private struct AccessSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Токен для официального источника") {
                Text("""
                Берётся из Keychain Claude Code, запись «Claude Code-credentials». \
                Виджет видит ровно тот аккаунт, что показывает /usage: сервер узнаёт \
                его по этому токену. Запись только читается — обновляет её сам \
                Claude Code, и лезть туда вдвоём значит потерять токен.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("""
                Вставить свой токен нельзя, и это не упущение: /api/oauth/usage \
                принимает только токен сеанса Claude Code. Ключ API (sk-ant-api…) и \
                годовой токен от claude setup-token он отвергает с 401 — проверено.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Можно и без токена") {
                Text("""
                Доступ к записи Keychain можно не давать вовсе: на вкладке «Общие» \
                выберите «Только локальная оценка» — расход посчитается по вашим же \
                транскриптам в ~/.claude/projects, без сети и без единого секрета. \
                Цена отказа — знак ≈ перед процентом.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Если macOS снова спросила доступ") {
                Text("""
                Запись читается утилитой /usr/bin/security — той же, которой \
                пишет токен сам Claude Code, и потому разрешение на неё \
                восстанавливается при каждом обновлении токена. Прямой запрос \
                к Keychain остался запасным путём и диалога не показывает: \
                не пустили — панель уходит на локальную оценку.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("""
                Вопрос всё же вернулся — значит доступа нет и у security. \
                Заведите постоянный сертификат подписи: ./scripts/signing-cert.sh \
                в каталоге исходников, затем ./scripts/install.sh. Он держит \
                приложение в списке доверенных приложений записи, и обновления \
                переподписываются им же.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Проверка") {
                HStack {
                    Button(model.isChecking ? "Проверяю…" : "Проверить сейчас", action: model.checkNow)
                        .disabled(model.isChecking)
                    Spacer()
                    if let result = model.checkResult {
                        Text(result.text)
                            .font(.caption)
                            .foregroundStyle(result.ok ? .green : .red)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Text("""
                Токен никуда не отправляется, кроме api.anthropic.com, не пишется \
                в config.json и не попадает в лог.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - О программе

private struct AboutSettings: View {
    @Bindable var model: SettingsModel
    /// Сброс необратим и применяется мгновенно — спрашиваем до, а не «отменить»
    /// после: отменять нечем, прежние значения нигде не сохранены.
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Версия") {
                    HStack(spacing: 8) {
                        Text(ClaudeWeek.version)
                        Text("·").foregroundStyle(.tertiary)
                        // Ссылка стоит у версии, а не в разделе обновления:
                        // «что нового» там появляется, только когда есть куда
                        // обновляться, а прочитать, чем эта версия отличается
                        // от прошлой, хочется и на самой свежей. Ссылка
                        // текстом, а не кнопкой: кнопка забирает фокус вкладки
                        // и открывается с синей рамкой вокруг единственной
                        // строчки, которую здесь читают.
                        Text(.init("[журнал изменений](\(ClaudeWeek.changelogURL.absoluteString))"))
                    }
                }
                LabeledContent("Бюджет недели") {
                    Text(model.budgetNote)
                }
                LabeledContent("Ручная калибровка") {
                    Text(model.config.calibration.observedPercent.map {
                        "\(Formatting.percent($0)) официальных"
                    } ?? "не было — бюджет подбирается сам")
                }
            }

            Section("Обновление") {
                LabeledContent("Состояние") {
                    Text(model.update.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(model.update.actionTitle) { model.update.run() }
                        .disabled(model.update.isWorking || !model.update.isAvailable)
                    if let release = model.update.release {
                        Button("Что нового") { NSWorkspace.shared.open(release.page) }
                    }
                }
                Text(updateHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Файлы") {
                fileRow("Конфигурация", url: ConfigStore.fileURL)
                fileRow("Кеш", url: Store.cacheURL)
                fileRow("Лог", url: URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Logs/ClaudeWeek.log"))
            }

            Section {
                Button("Сбросить настройки", role: .destructive) { confirmingReset = true }
                Text("""
                Вернёт всё к заводским значениям, кроме подобранного бюджета недели \
                и калибровки — их программа набрала по живым данным.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Сбросить настройки к заводским?",
            isPresented: $confirmingReset
        ) {
            Button("Сбросить", role: .destructive, action: model.resetToDefaults)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Тема, прозрачность, пороги и недельное окно вернутся к значениям по умолчанию. Бюджет недели и калибровка останутся.")
        }
    }

    private var updateHint: String {
        guard model.update.isAvailable else {
            // Ровно как с автозапуском: у отладочного `swift run` подменять
            // нечего, и молчаливо погашенная кнопка выглядела бы поломкой.
            return """
            Доступно только у собранного приложения: у отладочного swift run \
            исполняемый файл лежит в .build и живёт до следующей сборки.
            """
        }
        return """
        Программа сама спрашивает GitHub при запуске и раз в сутки, о найденном \
        сообщает строкой внизу панели. Скачивание и установка — только по этой \
        кнопке: она покажет, что изменилось, сверит образ по SHA256 из релиза, \
        заменит приложение и спросит про перезапуск. Настройки, кеш и \
        калибровка остаются на месте.
        """
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(url.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Button("Открыть") { NSWorkspace.shared.open(url) }
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
