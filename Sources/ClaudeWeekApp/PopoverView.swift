import SwiftUI
import ClaudeWeekCore

/// Панель недели: заголовок, семь двухцветных полос, футер с итогами.
/// Полос всегда семь — по дням недели, день сброса одной строкой.
struct PopoverView: View {
    @Bindable var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    private var appearance: AppearanceConfig { model.config.appearance }
    private var palette: Palette { appearance.theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            header

            // Пятичасовая сессия стоит над разделителем, в одной сетке с
            // сутками, но по свою его сторону: лимит независимый, и путать
            // его с восьмым днём недели нельзя. Нет данных — нет и строки.
            if appearance.showSession, let session = model.session {
                SessionRow(
                    session: session,
                    now: model.now,
                    criticalThreshold: model.config.thresholds.critical,
                    resetDisplay: appearance.sessionReset,
                    showLabel: appearance.showSessionLabel,
                    source: model.sourceState,
                    sourceHint: model.sourceHint,
                    calendar: model.config.calendar,
                    animated: !reduceMotion
                )
            }

            Divider().overlay(palette.separator.color)

            if let snapshot = model.snapshot {
                days(snapshot)
            } else {
                placeholders
            }

            Divider().overlay(palette.separator.color)
            footer
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
        // Прозрачный режим: под панелью материал строки меню, а здесь только
        // вуаль поверх него. Непрозрачный — сплошная заливка палитры.
        .background(backdrop)
        .environment(\.palette, palette)
    }

    @ViewBuilder
    private var backdrop: some View {
        if appearance.transparentPanel {
            // Вуаль идёт по шкале с потолком: на полной плотности она гасила
            // материал целиком, и «прозрачный фон с размытием» отличался от
            // сплошного только оттенком.
            palette.panelTint.color.opacity(appearance.panelTintOpacity * Theme.maxPanelTint)
        } else {
            palette.panelBackground.color
        }
    }

    // MARK: Заголовок

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.state == .exhausted || model.state == .critical {
                    Text("⚠")
                        .font(Theme.titleFont)
                        .foregroundStyle(palette.critical.color)
                }
                Text("ЛИМИТ НЕДЕЛИ")
                    .font(Theme.titleFont)
                    .tracking(0.4)
                    .fixedSize()
                    .foregroundStyle(
                        model.state == .exhausted
                            ? palette.critical.color
                            : palette.primaryText.color
                    )

                Spacer(minLength: 4)

                // Момент сброса — в зоне окна, той же, по которой считаются
                // сутки. Ни московского времени для сверки, ни прежних
                // «≈14 % в сутки» здесь нет: строке заголовка хватает одного
                // числа, а два подряд читались как спорящие.
                if let window = model.snapshot?.window {
                    Text(Formatting.resetLabel(window))
                        .font(Theme.captionFont)
                        .fixedSize()
                        .foregroundStyle(palette.secondaryText.color)
                }
            }

            if let note = model.sourceNote {
                Text(note)
                    .font(Theme.footerFont)
                    .foregroundStyle(
                        model.isEstimate ? palette.warning.color : palette.secondaryText.color
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Дни

    private func days(_ snapshot: UsageSnapshot) -> some View {
        let calendar = snapshot.window.calendar
        // Строк ровно семь. День сброса стоит одной: пока неделя катится — её
        // вечером после сброса, в последние сутки окна — утром перед следующим.
        return VStack(spacing: Theme.rowSpacing) {
            ForEach(snapshot.rows(at: model.now), id: \.index) { day in
                DayRow(
                    day: day,
                    label: Formatting.weekdayShort(day.start, calendar: calendar),
                    fullLabel: Formatting.weekdayFull(day.start, calendar: calendar),
                    // День сброса короче суток: интервал поясняет, какая из
                    // его половин сейчас на строке.
                    interval: day.isPartial ? Formatting.interval(day.start, day.end, calendar: calendar) : nil,
                    isToday: day.index == model.todayIndex,
                    animated: !reduceMotion
                )
            }
        }
    }

    /// Первый запуск без кеша: те же семь строк, чтобы панель не прыгала,
    /// когда придут данные.
    private var placeholders: some View {
        VStack(spacing: Theme.rowSpacing) {
            ForEach(0..<model.placeholderRows, id: \.self) { _ in
                HStack(spacing: 8) {
                    Capsule()
                        .fill(palette.track.color)
                        .frame(width: Theme.dayLabelWidth, height: Theme.barHeight)
                    Capsule().fill(palette.track.color).frame(height: Theme.barHeight)
                    Capsule()
                        .fill(palette.track.color)
                        .frame(width: Theme.valueWidth, height: Theme.barHeight)
                }
            }
        }
        .opacity(0.6)
        .accessibilityLabel("данные загружаются")
    }

    // MARK: Футер

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(Theme.footerFont)
                    .foregroundStyle(
                        model.resetIsClose ? palette.warning.color : palette.secondaryText.color
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if appearance.showForecast, let forecast {
                    Text(forecast)
                        .font(Theme.footerFont)
                        .foregroundStyle(palette.critical.color)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button(action: onSettings) {
                    Text("⚙")
                        .font(Theme.actionFont)
                        .foregroundStyle(palette.secondaryText.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("настройки")

                Button(action: onRefresh) {
                    Text(model.isRefreshing ? "…" : "⟳")
                        .font(Theme.actionFont)
                        .foregroundStyle(palette.secondaryText.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("обновить")
            }
        }
    }

    private var summary: String {
        guard let metrics = model.metrics else { return "нет данных" }
        if model.state == .exhausted {
            return "лимит недели исчерпан · сброс через \(Formatting.duration(metrics.timeLeft))"
        }
        // Темпа «1.0×» здесь больше нет: то же самое видно по расхождению
        // зелёной и синей полос, а числом это читалось как ещё один лимит.
        // Когда темп ведёт к беде, о ней говорит строка прогноза ниже.
        return "осталось \(Formatting.percent(metrics.remainingPercent))"
            + " · сброс через \(Formatting.duration(metrics.timeLeft))"
    }

    /// Вторая строка футера появляется только когда при нынешнем темпе лимит
    /// кончится раньше сброса.
    private var forecast: String? {
        guard model.state != .exhausted,
              let exhaustion = model.metrics?.exhaustionDate,
              let window = model.snapshot?.window
        else { return nil }
        let day = Formatting.weekdayShort(exhaustion, calendar: window.calendar)
        let clock = Formatting.clock(exhaustion, calendar: window.calendar)
        return "при таком темпе кончится \(day) \(clock)"
    }
}
