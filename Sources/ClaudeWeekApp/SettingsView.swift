import SwiftUI
import AppKit
import ClaudeWeekCore

/// Окно настроек: четыре вкладки. Предпросмотром служит сама панель — она
/// закреплена на экране, пока окно открыто, и перерисовывается на каждую правку.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Общие", systemImage: "gearshape") }

            AppearanceSettings(model: model)
                .tabItem { Label("Внешний вид", systemImage: "paintpalette") }

            AccessSettings(model: model)
                .tabItem { Label("Доступ", systemImage: "key") }

            AboutSettings(model: model)
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 580)
    }
}

// MARK: - Общие

private struct GeneralSettings: View {
    @Bindable var model: SettingsModel

    private var config: Binding<Config> { $model.config }

    var body: some View {
        Form {
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

                Picker("План считать на", selection: config.planAnchor) {
                    Text("середину суток (7/21/36/50…)").tag(PlanAnchor.midDay)
                    Text("конец суток (14/29/43/57…)").tag(PlanAnchor.endOfDay)
                }
            }

            Section("Пороги") {
                LabeledContent("Строка меню желтеет при превышении плана в") {
                    HStack {
                        Slider(value: config.thresholds.warn, in: 1...2, step: 0.05)
                        Text(String(format: "%.2f×", model.config.thresholds.warn))
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                LabeledContent("Заголовок и сессия тревожатся после") {
                    HStack {
                        Slider(value: config.thresholds.critical, in: 0.5...1, step: 0.01)
                        Text(Formatting.percent(model.config.thresholds.critical * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("""
                Суточные полосы желтеют на любом перерасходе — это сам график, \
                а не тревога. Пороги красят цифру в строке меню, заголовок \
                панели и полосу пятичасовой сессии.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Внешний вид

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

            Section("Что показывать") {
                Toggle("Строку пятичасовой сессии", isOn: appearance.showSession)
                Toggle("Прогноз «кончится в …»", isOn: appearance.showForecast)
                Picker("Строка меню", selection: $model.config.menuBarStyle) {
                    Text("Полоса и процент").tag(MenuBarStyle.percent)
                    Text("Только полоса").tag(MenuBarStyle.compact)
                }
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
        return "сессия · сброс \(reset)"
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
                LabeledContent("Версия", value: ClaudeWeek.version)
                LabeledContent("Бюджет недели") {
                    Text(model.budgetNote)
                }
                LabeledContent("Ручная калибровка") {
                    Text(model.config.calibration.observedPercent.map {
                        "\(Formatting.percent($0)) официальных"
                    } ?? "не было — бюджет подбирается сам")
                }
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
