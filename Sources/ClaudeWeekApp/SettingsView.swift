import SwiftUI
import AppKit
import ClaudeWeekCore

/// Окно настроек: шесть вкладок, по одной на предмет разговора — откуда цифры,
/// что показывает строка меню, как выглядит панель, когда программа заговорит
/// сама, доступ к токену, справка. Предпросмотром служит сама панель: она
/// закреплена на экране, пока окно открыто, и перерисовывается на каждую правку.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    /// Ширина окна: ровно столько, сколько форма отдаёт своим строкам. Шире
    /// растут только поля по бокам, поэтому вбок окно и не тянется.
    static let width: CGFloat = 720

    private var s: L10n { model.config.strings }

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label(s.pick("Общие", "General"), systemImage: "gearshape") }

            MenuBarSettings(model: model)
                .tabItem { Label(s.pick("Строка меню", "Menu bar"), systemImage: "menubar.rectangle") }

            AppearanceSettings(model: model)
                .tabItem { Label(s.pick("Панель", "Panel"), systemImage: "paintpalette") }

            NotificationSettings(model: model)
                .tabItem { Label(s.pick("Уведомления", "Notifications"), systemImage: "bell") }

            AccessSettings(model: model)
                .tabItem { Label(s.pick("Доступ", "Access"), systemImage: "key") }

            AboutSettings(model: model)
                .tabItem { Label(s.pick("О программе", "About"), systemImage: "info.circle") }
        }
        // Ширина закреплена, высота тянется. Форма `.grouped` в macOS сама
        // не даёт своим строкам стать шире примерно семисот точек, и лишняя
        // ширина окна уходила не в настройки, а в пустые поля по бокам —
        // тянуть вбок было незачем и некрасиво. Высота другое дело: длинные
        // вкладки прокручиваются, и растянуть окно вниз — единственный способ
        // увидеть их целиком.
        //
        // Высота по умолчанию взята по самой длинной вкладке, а не по средней:
        // вкладки переключаются в одном окне, и размер под короткую заставлял
        // бы прокручивать все остальные.
        .frame(
            minWidth: Self.width, idealWidth: Self.width, maxWidth: Self.width,
            minHeight: 460, idealHeight: 780, maxHeight: .infinity
        )
    }
}

/// Пояснение под настройкой — тем же кеглем и цветом во всех шести вкладках.
///
/// `maxWidth: .infinity` здесь не украшение: `Form` в macOS кладёт одинокий
/// `Text` в узкую колонку значений, и растянутое мышью окно оставляло бы
/// пояснение висеть в прежней ширине, обтекая пустоту справа. С ним текст
/// перебивается по живой ширине окна, а `fixedSize` по вертикали не даёт
/// строке обрезаться вместо переноса.
private extension View {
    func settingsHint() -> some View {
        font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Имя раскрывающейся секции — одно на все вкладки: человек, раскрывший её
/// однажды, должен узнавать её и на соседней вкладке.
private extension L10n {
    var advancedTitle: String { pick("Расширенные настройки", "Advanced settings") }
}

/// Раскрывающаяся секция «Расширенные настройки» — одна на все вкладки, и
/// раскрывается везде одинаково.
///
/// Заголовок здесь свой, а не встроенный в `Section(isExpanded:)`: у того
/// нажимается только треугольник размером с букву, и попасть в него стоит
/// отдельного прицеливания. Кнопка во всю ширину строки принимает щелчок
/// куда угодно в заголовке — и в текст, и в пустоту справа от него.
private struct AdvancedSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            if isExpanded { content }
        } header: {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                    // Растягивает кнопку до края формы: без него щелчок мимо
                    // букв уходил бы в пустоту, а целиться в слово из двух
                    // слогов ровно та же морока, что и в треугольник.
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            // Курсор-палец: заголовок формы сам по себе не выглядит нажимаемым,
            // и без подсказки о том, что он кнопка, догадываются не сразу.
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

/// Подзаголовок внутри «Расширенных настроек». Секция там одна на вкладку, а
/// разговоров в ней бывает два — про недельный лимит и про пятичасовую
/// сессию, — и без подписей четыре одинаковых ползунка слились бы в один ряд,
/// где не видно, который к чему.
private struct GroupTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.body.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

// MARK: - Общие

private struct GeneralSettings: View {
    @Bindable var model: SettingsModel

    /// Свёрнута при каждом открытии окна, а не запоминается: раскрытая
    /// секция — то, что человек делает сейчас, а не настройка.
    @State private var showsAdvanced = false

    private var config: Binding<Config> { $model.config }
    private var appearance: Binding<AppearanceConfig> { $model.config.appearance }

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
            }

            Section(s.pick("Запуск", "Startup")) {
                Toggle(s.pick("Запускать при входе в систему", "Launch at login"), isOn: launchAtLogin)
                    .disabled(!LoginItem.isAvailable)
                    // Пояснения под галочкой больше нет, а погашенной она
                    // бывает — у отладочного `swift run` автозапускать нечего.
                    // Подсказкой при наведении, чтобы не выглядело поломкой.
                    .help(launchHint)
            }

            Section(s.pick("Источник данных", "Data source")) {
                Picker(s.pick("Откуда брать цифры", "Where the numbers come from"), selection: config.provider) {
                    Text(s.pick("Всегда онлайн", "Always online")).tag(ProviderPreference.auto)
                    Text(s.pick("Только официальный", "Official only")).tag(ProviderPreference.official)
                    Text(s.pick("Только локальная оценка", "Local estimate only")).tag(ProviderPreference.local)
                }

                LabeledContent(s.pick("Обновлять раз в", "Refresh every")) {
                    HStack {
                        Slider(
                            value: config.refreshInterval,
                            in: 60...1800,
                            step: 30
                        )
                        Text(Formatting.duration(model.config.refreshInterval, lang: s.lang))
                            .font(.body.monospacedDigit())
                            .frame(width: 78, alignment: .trailing)
                    }
                }
            }

            // Раскрывающаяся секция, а не `DisclosureGroup` внутри обычной:
            // группа вкладывает свои строки в одну ячейку формы, и они теряют
            // и колонки, и разделители — треугольник открывался в мелкую кашу
            // вместо ряда настроек. Здесь же раскрываются полноценные строки
            // формы.
            AdvancedSection(title: s.advancedTitle, isExpanded: $showsAdvanced) {
                // Первым — переключатель суточных полос: он решает судьбу
                // почти всего, что под ним. Пояснять это текстом больше не
                // нужно — выключенный план тут же убирает «Показывать» и
                // «Начало недели», и связь видно глазами.
                Toggle(s.pick("Дневной план", "Daily plan"), isOn: appearance.showsPlan)

                if model.config.appearance.showsPlan {
                    Picker(s.pick("Показывать", "Show"), selection: appearance.panelLayout) {
                        ForEach(PanelLayout.allCases, id: \.self) { layout in
                            Text(layout.title(s.lang)).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(layoutHint)
                        .settingsHint()

                    Picker(s.pick("Начало недели", "Week starts on"), selection: config.weekStart) {
                        ForEach(WeekStart.allCases, id: \.self) { start in
                            Text(start.title(s.lang)).tag(start)
                        }
                    }
                    Text(model.weekStartNote)
                        .settingsHint()
                } else {
                    Text(noPlanHint)
                        .settingsHint()
                }

                Picker(s.pick("Таймзона", "Time zone"), selection: config.timeZone) {
                    Text(s.pick("Системная", "System")).tag("")
                    ForEach(popularZones, id: \.self) { zone in
                        Text(zone).tag(zone)
                    }
                }

                Picker(s.pick("Распорядок", "Schedule"), selection: config.workHours) {
                    ForEach(WorkHours.presets, id: \.self) { hours in
                        Text(hours.title(s.lang)).tag(hours)
                    }
                    // Часы, накрученные степперами, тоже должны где-то стоять,
                    // иначе список показывал бы чужое значение как выбранное.
                    if !WorkHours.presets.contains(model.config.workHours) {
                        Text(model.config.workHours.title(s.lang)).tag(model.config.workHours)
                    }
                }

                // Границы держат день непустым: вывернутый интервал конфиг
                // чинит на круглосуточный, и в степпере это выглядело бы как
                // самовольный сброс настройки.
                LabeledContent(s.pick("Часы", "Hours")) {
                    HStack(spacing: 16) {
                        Stepper(
                            s.pick("с \(model.config.workHours.start):00",
                                   "from \(model.config.workHours.start):00"),
                            value: config.workHours.start,
                            in: 0...(model.config.workHours.end - 1)
                        )
                        Stepper(
                            s.pick("до \(hourLabel(model.config.workHours.end))",
                                   "to \(hourLabel(model.config.workHours.end))"),
                            value: config.workHours.end,
                            in: (model.config.workHours.start + 1)...24
                        )
                    }
                }
                LabeledContent(s.pick("Получается", "Adds up to"), value: workHoursSummary)
                Text(workHoursHint)
                    .settingsHint()
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
            return s.pick("""
            Доступно только у собранного приложения: у отладочного swift run \
            исполняемый файл лежит в .build и живёт до следующей сборки.
            """, """
            Only available to a built app: with a debug swift run the executable \
            sits in .build and lives until the next build.
            """)
        }
        return s.pick("""
        Правит того же launchd-агента, что ставит install.sh, — файл \
        ~/Library/LaunchAgents/\(LoginItem.label).plist. Включение и выключение \
        начинают действовать со следующего входа в систему: запущенное \
        приложение галочка не гасит и второй копии не поднимает.
        """, """
        Edits the same launchd agent install.sh sets up — the file \
        ~/Library/LaunchAgents/\(LoginItem.label).plist. Turning it on or off takes \
        effect at the next login: it neither quits the running app nor starts a \
        second copy.
        """)
    }

    /// Полночь показываем как «0:00 следующих суток», а не как «24:00»:
    /// в степпере это край шкалы, и человеку нужно понимать, что дальше некуда.
    private func hourLabel(_ hour: Int) -> String {
        hour >= 24 ? s.pick("полуночи", "midnight") : "\(hour):00"
    }

    /// «10:00 – 18:00, 8 ч в сутки» — часы словами, чтобы не считать их
    /// в уме по двум степперам.
    private var workHoursSummary: String {
        let work = model.config.workHours
        guard !work.isAllDay else { return s.pick("круглые сутки, 24 ч", "all day and night, 24 h") }
        return s.pick("\(work.clockRange(s.lang)), \(work.hours) ч в сутки",
                      "\(work.clockRange(s.lang)), \(work.hours) h a day")
    }

    private var workHoursHint: String {
        let hours = model.config.workHours.hours
        guard !model.config.workHours.isAllDay else {
            return s.pick("""
            Круглосуточно: план растёт и ночью, поэтому за сон набегает \
            около 40 % недельного лимита.
            """, """
            Around the clock: the plan grows at night too, so sleep alone eats \
            about 40 % of the weekly limit.
            """)
        }
        return s.pick("""
        Недельный лимит раскладывается по этим часам — \(hours) ч в сутки. \
        Ночью план стоит: утром вы начинаете с той же отметки, на которой \
        закончили, а работа в три ночи целиком ложится в перерасход.
        """, """
        The weekly limit is spread over these hours — \(hours) h a day. At night \
        the plan stands still: you start the morning exactly where you left off, \
        and work at three in the morning counts entirely as overspend.
        """)
    }

    /// Что осталось от суточных полос, когда их выключили. Про рабочие часы
    /// здесь сказано отдельно: они переживают выключенный план — по ним
    /// по-прежнему растёт плановая зона в значке строки меню и считается
    /// прогноз «кончится в …».
    private var noPlanHint: String {
        s.pick("""
        Дней в панели нет — вместо семи полос с планом одна на всю неделю, \
        голый факт без сравнения с графиком. Начало недели вместе с ними \
        уходит: переставлять нечего. Рабочие часы остаются в деле — по ним \
        растёт плановая зона в значке строки меню и считается прогноз \
        «кончится в …».
        """, """
        There are no day rows in the panel — instead of seven bars with a \
        plan there is one for the whole week, the bare spend with no pacing \
        comparison. The week start goes with them: there is nothing left to \
        reorder. Working hours still count — they drive the plan zone in the \
        menu bar icon and the “runs out at …” forecast.
        """)
    }

    private var layoutHint: String {
        switch model.config.appearance.panelLayout {
        case .week:
            s.pick("Семь полос, по дню недели каждая: весь ряд перед глазами.",
                   "Seven bars, one per weekday: the whole row in front of you.")
        case .compact:
            s.pick("""
            Только текущие сутки — панель короче на шесть строк. Неделя не \
            потеряна: щёлкните по строке дня, и ряд раскроется целиком, пока \
            панель открыта. Итог недели и час сброса остаются на месте в любом \
            случае.
            """, """
            Today only — six rows shorter. The week is not lost: click the day \
            row and the whole row unfolds for as long as the panel stays open. \
            The week total and the reset time stay put either way.
            """)
        }
    }

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

    /// Свёрнута при каждом открытии окна — как и на соседних вкладках.
    @State private var showsAdvanced = false

    private var thresholds: Thresholds { model.config.thresholds }

    private var s: L10n { model.config.strings }

    var body: some View {
        Form {
            Section(s.pick("Значок", "Icon")) {
                Picker(s.pick("Показывать", "Show"), selection: $model.config.menuBarStyle) {
                    Text(s.pick("Полоса и процент", "Bar and percentage")).tag(MenuBarStyle.percent)
                    Text(s.pick("Только полоса", "Bar only")).tag(MenuBarStyle.compact)
                    Text(s.pick("Кольцо с процентом", "Ring with percentage")).tag(MenuBarStyle.ring)
                }
                Text(styleHint)
                    .settingsHint()

                // Расклад кольца спрашиваем только когда оно выбрано: у полосы
                // второго лимита нет, и пункт стоял бы там без смысла.
                if model.config.menuBarStyle == .ring {
                    Picker(s.pick("Заполнять дугой", "Fill the arc with"), selection: $model.config.ringArc) {
                        ForEach(RingArc.allCases, id: \.self) { arc in
                            Text(arc.title(s.lang)).tag(arc)
                        }
                    }
                    Text(ringHint)
                        .settingsHint()
                }
            }

            Section(s.pick("Цвет", "Colour")) {
                Toggle(s.pick("Менять цвет по порогам", "Change colour at thresholds"), isOn: colorize)
                Text(s.pick("""
                Выключенный — значок всегда нейтрального цвета, а расход \
                по-прежнему виден заполнением и цифрой. Панель красится в любом \
                случае: пороги ниже задают цвет и её заголовку с полосой сессии.
                """, """
                Off — the icon stays neutral, while the spend is still readable \
                from the fill and the number. The panel is coloured either way: \
                the thresholds below also colour its heading and session bar.
                """))
                .settingsHint()
            }

            // Пороги — под раскрывающейся секцией: заводские отметки трогают
            // редко, а места они занимают на пол-вкладки.
            AdvancedSection(title: s.advancedTitle, isExpanded: $showsAdvanced) {
                GroupTitle(text: s.pick("Недельный лимит", "Weekly limit"))
                PercentRow(title: s.pick("Жёлтый после", "Amber after"), value: weekWarn)
                PercentRow(title: s.pick("Красный после", "Red after"), value: weekCritical)

                GroupTitle(text: s.pick("Пятичасовая сессия", "5-hour session"))
                PercentRow(title: s.pick("Жёлтый после", "Amber after"), value: sessionWarn)
                PercentRow(title: s.pick("Красный после", "Red after"), value: sessionCritical)
                Text(s.pick("""
                Считается по факту: сколько потрачено прямо сейчас. План и \
                прогноз на цвет больше не влияют — они отвечают на вопрос \
                «в графике ли я», а цвет на «пора ли беспокоиться». Сессию \
                сообщает только официальный источник: на локальной оценке её \
                процент стоит на нуле.
                """, """
                Counted from the fact: how much is spent right now. Neither the \
                plan nor the forecast colours anything any more — they answer \
                “am I on schedule”, while colour answers “should I worry yet”. \
                The session comes from the official source only: on a local \
                estimate its percentage stays at zero.
                """))
                .settingsHint()
            }
        }
        .formStyle(.grouped)
    }

    private var styleHint: String {
        switch model.config.menuBarStyle {
        case .percent:
            s.pick("Полоса недели с планом, под ней недельный процент.",
                   "The week bar with its plan, the weekly percentage underneath.")
        case .compact:
            s.pick("Одна полоса недели, без числа — самый узкий значок.",
                   "One week bar, no number — the narrowest icon there is.")
        case .ring:
            s.pick("Два лимита в одном значке: один на дуге, второй цифрой внутри.",
                   "Both limits in one icon: one on the arc, the other as the number inside.")
        }
    }

    /// Расклад кольца словами: какой лимит куда попал при нынешнем выборе.
    /// Цвета остаются раздельными в обе стороны — дуга и цифра горят каждая
    /// по своим порогам, и красная дуга при спокойной цифре это норма, а не
    /// сбой.
    private var ringHint: String {
        switch model.config.ringArc {
        case .session:
            s.pick("""
            Дуга — пятичасовая сессия, цифра внутри — недельный процент. \
            Цвет у каждого свой, по своим порогам ниже.
            """, """
            The arc is the 5-hour session, the number inside is the weekly \
            percentage. Each has its own colour, by its own thresholds below.
            """)
        case .week:
            s.pick("""
            Дуга — недельный лимит, цифра внутри — процент пятичасовой сессии. \
            Цвет у каждого свой, по своим порогам ниже.
            """, """
            The arc is the weekly limit, the number inside is the 5-hour session \
            percentage. Each has its own colour, by its own thresholds below.
            """)
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

    private var s: L10n { model.config.strings }

    var body: some View {
        Form {
            Section(s.pick("Тема", "Theme")) {
                Picker(s.pick("Палитра", "Palette"), selection: appearance.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { theme in
                        Text(theme.title(s.lang)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text(themeHint)
                    .settingsHint()
            }

            Section(s.pick("Фон панели", "Panel background")) {
                Toggle(s.pick("Прозрачный фон с размытием", "Translucent background with blur"),
                       isOn: appearance.transparentPanel)
                LabeledContent(s.pick("Плотность фона", "Background density")) {
                    HStack {
                        Slider(value: appearance.panelTintOpacity, in: 0...1, step: 0.01)
                            .disabled(!model.config.appearance.transparentPanel)
                        Text(String(format: "%.0f %%", model.config.appearance.panelTintOpacity * 100))
                            .font(.body.monospacedDigit())
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                LabeledContent(s.pick("Скругление углов", "Corner radius")) {
                    HStack {
                        Slider(value: appearance.cornerRadius, in: 0...24, step: 1)
                        Text("\(Int(model.config.appearance.cornerRadius)) pt")
                            .font(.body.monospacedDigit())
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                Text(s.pick("""
                Ноль плотности — чистый материал строки меню, как у системных \
                меню; дальше вуаль подкрашивает его, но размытие остаётся \
                видно. Нужен глухой фон — выключите прозрачность, это \
                отдельный режим. Как это выглядит, видно на самой панели: она \
                висит у строки меню, пока открыто это окно.
                """, """
                Zero density is the bare menu bar material, the same one system \
                menus use; above it a veil tints the material while the blur \
                stays visible. Want a solid background — turn translucency off, \
                that is a separate mode. The panel itself shows the result: it \
                hangs by the menu bar while this window is open.
                """))
                .settingsHint()
            }

            Section(s.pick("Сброс сессии", "Session reset")) {
                Picker(s.pick("Подписывать", "Label it as"), selection: appearance.sessionReset) {
                    ForEach(SessionResetDisplay.allCases, id: \.self) { display in
                        Text(display.title(s.lang)).tag(display)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.config.appearance.showSession)

                LabeledContent(s.pick("Выглядит так", "Looks like this")) {
                    Text(sessionResetSample)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(s.pick("""
                Момент сброса приходит от сервера вместе с процентом — настройка \
                выбирает не его, а лишь то, каким концом его показать. Час \
                за полночь подписывается днём недели: пятичасовое окно легко \
                через неё перешагивает.
                """, """
                The reset moment arrives from the server together with the \
                percentage — this setting picks not the moment but which end of \
                it to show. An hour past midnight is labelled with the weekday: \
                a 5-hour window steps over midnight easily.
                """))
                .settingsHint()
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
            calendar: model.config.calendar,
            lang: s.lang
        )
        return s.pick("сброс \(reset)", "resets \(reset)")
    }

    private var themeHint: String {
        switch model.config.appearance.theme {
        case .system:
            s.pick("Родная палитра: прогнана через валидатор на дальтонизм и контраст.",
                   "The native palette: run through a validator for colour blindness and contrast.")
        case .midnight, .graphite, .paper, .contrast:
            s.pick("Экспериментальная палитра: валидатором не проверялась, роли цветов те же.",
                   "An experimental palette: not validated, though the colours keep their roles.")
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

    /// Свёрнута при каждом открытии окна — как и на соседних вкладках.
    /// Параметр, а не всегда `false`, — ради `Screenshot.notificationsTab`:
    /// картинка в README существует затем, чтобы показать именно пороги,
    /// и снимать её со свёрнутой секцией было бы бессмысленно.
    @State private var showsAdvanced: Bool

    init(model: SettingsModel, showsAdvanced: Bool = false) {
        self.model = model
        self._showsAdvanced = State(initialValue: showsAdvanced)
    }

    private var notifications: NotificationsConfig { model.config.notifications }
    /// Пороги настраиваются и при выключенных уведомлениях — гасим их только
    /// вместе с самим тумблером, чтобы не пришлось включать баннеры ради того,
    /// чтобы посмотреть, на чём они стоят.
    private var isOff: Bool { !notifications.enabled }

    private var s: L10n { model.config.strings }

    var body: some View {
        Form {
            Section(s.pick("Уведомления", "Notifications")) {
                Toggle(s.pick("Предупреждать о приближении к лимиту", "Warn when a limit gets close"),
                       isOn: enabled)
                Text(model.notifications.summary(s))
                    .settingsHint()
                if model.notifications.needsSystemSettings {
                    Button(s.pick("Открыть настройки уведомлений macOS", "Open macOS notification settings")) {
                        model.notifications.openSystemSettings()
                    }
                }

                Toggle(s.pick("Со звуком", "With sound"), isOn: sound)
                    .disabled(isOff)

                Toggle(s.pick("Сообщать о новой версии", "Announce a new version"),
                       isOn: updates)
            }

            // Пороги обоих лимитов — под раскрывающейся секцией, как пороги
            // цвета на вкладке «Строка меню». Гасим не саму секцию, а её
            // содержимое: у выключенной заголовок перестал бы раскрываться,
            // и посмотреть, на чём стоят отметки, стало бы нельзя, не включив
            // уведомления.
            AdvancedSection(title: s.advancedTitle, isExpanded: $showsAdvanced) {
                Group {
                    GroupTitle(text: s.pick("Недельный лимит", "Weekly limit"))
                    Toggle(s.pick("Уведомлять о недельном лимите", "Notify about the weekly limit"),
                           isOn: weekEnabled)
                    PercentRow(title: s.pick("Предупредить после", "Warn after"), value: weekFirst)
                    PercentRow(title: s.pick("И ещё раз после", "And again after"), value: weekSecond)
                    previewButton(.week)
                    Text(s.pick("""
                    Неделя не сбросится до её конца, поэтому предупреждать о ней \
                    стоит раньше: после первого порога расход ещё можно растянуть \
                    на оставшиеся дни.
                    """, """
                    The week will not reset before it ends, so it deserves an \
                    earlier warning: after the first threshold the spend can still \
                    be stretched over the days that are left.
                    """))
                    .settingsHint()
                }
                .disabled(isOff)

                Group {
                    GroupTitle(text: s.pick("Пятичасовая сессия", "5-hour session"))
                    Toggle(s.pick("Уведомлять о пятичасовой сессии", "Notify about the 5-hour session"),
                           isOn: sessionEnabled)
                    PercentRow(title: s.pick("Предупредить после", "Warn after"), value: sessionFirst)
                    PercentRow(title: s.pick("И ещё раз после", "And again after"), value: sessionSecond)
                    previewButton(.session)
                    Text(s.pick("""
                    Сессию сообщает только официальный источник: на локальной \
                    оценке её процент не считается вовсе, и уведомлений о ней \
                    не будет.
                    """, """
                    The session comes from the official source only: a local \
                    estimate does not compute its percentage at all, so there will \
                    be no notifications about it.
                    """))
                    .settingsHint()
                }
                .disabled(isOff)
            }
        }
        .formStyle(.grouped)
    }

    /// Кнопка «Показать пример» стоит в секции своего лимита: у недели и
    /// сессии баннеры разные — заголовком, порогом и масштабом времени до
    /// сброса, — и одна кнопка на двоих показывала бы чужой.
    private func previewButton(_ kind: AlertKind) -> some View {
        HStack {
            Button(s.pick("Показать пример", "Show an example")) { model.previewNotification(kind) }
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

    /// Не гаснет вместе с общим тумблером: тот про разговоры о расходе, а
    /// новая версия — новость другого рода, и молчать о ней человек просит
    /// отдельно.
    private var updates: Binding<Bool> {
        Binding(
            get: { notifications.update },
            set: { model.config.notifications.update = $0 }
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
    /// Спрашиваем до, а не «отменить» после: отсечку назад не отмотать —
    /// прежний счёт нигде не сохранён.
    @State private var confirmingReset = false

    private var s: L10n { model.config.strings }

    /// Три разных положения, и путать их нельзя: каталога нет — аккаунт не
    /// заводили, каталог есть и выхода нет — в него не вошли, вход есть —
    /// показываем, кто именно. Советы человеку в первых двух случаях разные.
    private func state(of row: AccountRow) -> String {
        guard row.exists else { return s.pick("дом не заведён", "no config home") }
        guard row.status.loggedIn else { return s.pick("не вошли", "not signed in") }
        return row.status.title(fallback: s.pick("вошли", "signed in"))
    }

    var body: some View {
        Form {
            Section(s.pick("Аккаунты", "Accounts")) {
                ForEach(model.accountRows) { row in
                    LabeledContent(row.account.fallbackTitle(s.lang)) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(state(of: row))
                                .foregroundStyle(row.status.loggedIn ? .primary : .secondary)
                                .textSelection(.enabled)
                            Text(row.home)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }

                Text(s.pick(
                    "У каждого аккаунта свой лимит, свой снимок и своя отсечка счёта — переключатель меняет их все разом.",
                    "Each account has its own limit, its own snapshot and its own counting cut-off — the switch changes all of them at once."
                ))
                .settingsHint()
            }

            Section(s.pick("Аккаунт и счёт", "Account and count")) {
                LabeledContent(s.pick("Сейчас в ключе", "Currently in the key")) {
                    Text(model.account ?? s.pick("не читается", "cannot be read"))
                        .font(.body.monospaced())
                        .foregroundStyle(model.account == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(s.pick("Начать счёт заново", "Start counting over")) {
                        confirmingReset = true
                    }
                    Spacer()
                }
                Text(model.countingNote)
                    .settingsHint()

                Text(s.pick(
                    "Нужно после входа другим аккаунтом: суточная разбивка идёт по транскриптам, а в них аккаунт не различить.",
                    "Needed after logging in with a different account: the daily breakdown comes from transcripts, which do not tell accounts apart."
                ))
                .settingsHint()
            }

            Section(s.pick("Токен для официального источника", "Token for the official source")) {
                Text(s.pick(
                    "Берётся из Keychain Claude Code и только читается. Свой вставить нельзя: сервер принимает лишь токен сеанса Claude Code.",
                    "Taken from the Claude Code Keychain item, read-only. Pasting your own is not possible: the server accepts a Claude Code session token only."
                ))
                .settingsHint()
            }

            Section(s.pick("Проверка", "Check")) {
                HStack {
                    Button(model.isChecking
                           ? s.pick("Проверяю…", "Checking…")
                           : s.pick("Проверить сейчас", "Check now"),
                           action: model.checkNow)
                        .disabled(model.isChecking)
                    Spacer()
                    if let result = model.checkResult {
                        Text(result.text)
                            .font(.body)
                            .foregroundStyle(result.ok ? .green : .red)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Text(s.pick("""
                Токен никуда не отправляется, кроме api.anthropic.com, не пишется \
                в config.json и не попадает в лог.
                """, """
                The token goes nowhere but api.anthropic.com, is never written to \
                config.json and never reaches the log.
                """))
                .settingsHint()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            s.pick("Начать счёт заново?", "Start counting over?"),
            isPresented: $confirmingReset
        ) {
            Button(s.pick("Начать заново", "Start over"), role: .destructive, action: model.resetCounting)
            Button(s.pick("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(s.pick("""
            Расход до этой минуты в счёт больше не идёт: снимок, подобранный \
            бюджет и уже сказанные предупреждения стираются, а суточные полосы \
            начнутся с нуля. Настройки, транскрипты и сам недельный процент от \
            сервера остаются на месте.
            """, """
            Spending up to this minute stops counting: the snapshot, the worked-out \
            budget and the warnings already given are erased, and the daily bars \
            start from zero. Settings, transcripts and the server’s own weekly \
            percentage stay as they are.
            """))
        }
    }
}

// MARK: - О программе

private struct AboutSettings: View {
    @Bindable var model: SettingsModel
    /// Сброс необратим и применяется мгновенно — спрашиваем до, а не «отменить»
    /// после: отменять нечем, прежние значения нигде не сохранены.
    @State private var confirmingReset = false

    private var s: L10n { model.config.strings }

    var body: some View {
        Form {
            Section {
                LabeledContent(s.pick("Версия", "Version")) {
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
                        Text(.init("[\(s.pick("журнал изменений", "changelog"))]"
                                   + "(\(ClaudeWeek.changelogURL.absoluteString))"))
                    }
                }
                LabeledContent(s.pick("Бюджет недели", "Week budget")) {
                    Text(model.budgetNote)
                }
                LabeledContent(s.pick("Ручная калибровка", "Manual calibration")) {
                    Text(model.config.calibration.observedPercent.map {
                        s.pick("\(Formatting.percent($0)) официальных", "\(Formatting.percent($0)) official")
                    } ?? s.pick("не было — бюджет подбирается сам", "none — the budget tunes itself"))
                }
            }

            Section(s.pick("Обновление", "Update")) {
                LabeledContent(s.pick("Состояние", "Status")) {
                    Text(model.update.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(model.update.actionTitle) { model.update.run() }
                        .disabled(model.update.isWorking || !model.update.isAvailable)
                    if let release = model.update.release {
                        Button(s.pick("Что нового", "What’s new")) { NSWorkspace.shared.open(release.page) }
                    }
                }
                Text(updateHint)
                    .settingsHint()
            }

            Section(s.pick("Файлы", "Files")) {
                fileRow(s.pick("Конфигурация", "Configuration"), url: ConfigStore.fileURL)
                fileRow(s.pick("Кеш", "Cache"), url: Store.cacheURL)
                fileRow(s.pick("Лог", "Log"), url: URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Logs/ClaudeWeek.log"))
            }

            Section {
                Button(s.pick("Сбросить настройки", "Reset settings"), role: .destructive) {
                    confirmingReset = true
                }
                Text(s.pick("""
                Вернёт всё к заводским значениям, кроме подобранного бюджета недели \
                и калибровки — их программа набрала по живым данным.
                """, """
                Puts everything back to factory values except the week budget it \
                worked out and the calibration — those the app earned from live \
                data.
                """))
                .settingsHint()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            s.pick("Сбросить настройки к заводским?", "Reset settings to factory values?"),
            isPresented: $confirmingReset
        ) {
            Button(s.pick("Сбросить", "Reset"), role: .destructive, action: model.resetToDefaults)
            Button(s.pick("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(s.pick("""
            Тема, прозрачность, пороги и недельное окно вернутся к значениям по \
            умолчанию. Бюджет недели и калибровка останутся.
            """, """
            Theme, translucency, thresholds and the week window go back to their \
            defaults. The week budget and the calibration stay.
            """))
        }
    }

    private var updateHint: String {
        guard model.update.isAvailable else {
            // Ровно как с автозапуском: у отладочного `swift run` подменять
            // нечего, и молчаливо погашенная кнопка выглядела бы поломкой.
            return s.pick("""
            Доступно только у собранного приложения: у отладочного swift run \
            исполняемый файл лежит в .build и живёт до следующей сборки.
            """, """
            Only available to a built app: with a debug swift run the executable \
            sits in .build and lives until the next build.
            """)
        }
        return s.pick("""
        Программа сама спрашивает GitHub при запуске и раз в сутки, о найденном \
        сообщает строкой внизу панели. Скачивание и установка — только по этой \
        кнопке: она покажет, что изменилось, сверит образ по SHA256 из релиза, \
        заменит приложение и спросит про перезапуск. Настройки, кеш и \
        калибровка остаются на месте.
        """, """
        The app asks GitHub itself at launch and once a day, and reports what it \
        finds on the bottom line of the panel. Downloading and installing happen \
        only through this button: it shows what changed, verifies the image \
        against the SHA256 from the release, replaces the app and asks about \
        restarting. Settings, cache and calibration stay where they are.
        """)
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(url.path)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Button(s.pick("Открыть", "Open")) { NSWorkspace.shared.open(url) }
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
