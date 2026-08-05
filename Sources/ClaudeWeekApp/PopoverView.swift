import SwiftUI
import ClaudeWeekCore

/// Панель недели: заголовок, семь двухцветных полос, футер с итогами.
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
            palette.panelTint.color.opacity(appearance.panelTintOpacity)
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

                if let window = model.snapshot?.window {
                    Text(Formatting.resetLabel(window))
                        .font(Theme.captionFont)
                        .fixedSize()
                        .foregroundStyle(palette.secondaryText.color)
                }

                Text("≈14 % в сутки")
                    .font(Theme.captionFont)
                    .fixedSize()
                    .foregroundStyle(palette.secondaryText.color)
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
        VStack(spacing: Theme.rowSpacing) {
            ForEach(snapshot.byDay, id: \.index) { day in
                DayRow(
                    day: day,
                    label: Formatting.weekdayShort(day.start, calendar: snapshot.window.calendar),
                    fullLabel: Formatting.weekdayFull(day.start, calendar: snapshot.window.calendar),
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
            ForEach(0..<WeekWindow.daysInWeek, id: \.self) { _ in
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
                    .font(Theme.captionFont)
                    .foregroundStyle(
                        model.resetIsClose ? palette.warning.color : palette.secondaryText.color
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if appearance.showForecast, let forecast {
                    Text(forecast)
                        .font(Theme.captionFont)
                        .foregroundStyle(palette.critical.color)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button(action: onSettings) {
                    Text("⚙")
                        .font(Theme.footerFont)
                        .foregroundStyle(palette.secondaryText.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("настройки")

                Button(action: onRefresh) {
                    Text(model.isRefreshing ? "…" : "⟳")
                        .font(Theme.footerFont)
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
        var parts = [
            "осталось \(Formatting.percent(metrics.remainingPercent))",
            "сброс через \(Formatting.duration(metrics.timeLeft))",
        ]
        if let rate = metrics.burnRate {
            parts.append("темп \(Formatting.rate(rate))")
        }
        return parts.joined(separator: " · ")
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
