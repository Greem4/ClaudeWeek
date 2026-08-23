import SwiftUI
import ClaudeWeekCore

/// Итог недели одной полосой без плановой зоны — тем же видом, что у строки
/// пятичасовой сессии. Встаёт на место семи суточных полос, когда дневной
/// план в настройках выключен: раскладывать факт по дням незачем, если не с
/// чем его сравнивать, и панель показывает голый процент недели.
struct WeekRow: View {
    let usedPercent: Double
    let state: LimitState
    let animated: Bool
    /// Нажатие на процент — открыть разбивку по моделям, тот же жест, что у
    /// суточных строк и строки сессии.
    var onValueTap: (() -> Void)?

    @Environment(\.palette) private var palette
    @Environment(\.strings) private var s

    private var isCritical: Bool { state == .critical || state == .exhausted }

    var body: some View {
        HStack(spacing: 8) {
            Text(s.pick("НЕД", "WK"))
                .font(Theme.dayFont)
                .foregroundStyle(palette.secondaryText.color)
                .frame(width: Theme.dayLabelWidth, alignment: .leading)

            LimitBar(usedPercent: usedPercent, state: state, animated: animated)

            percent
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .accessibilityAction(named: s.pick("Расход по моделям", "Spend by model")) { onValueTap?() }
    }

    /// Процент недели — он же кнопка разбивки по моделям, тот же приём, что
    /// в строках дней и сессии.
    @ViewBuilder
    private var percent: some View {
        let column = HStack(spacing: Theme.valueGap) {
            if isCritical {
                Text("⚠")
                    .font(Theme.dayFont)
                    .foregroundStyle(palette.critical.color)
            }
            Text(Formatting.percent(usedPercent))
                .font(Theme.dayFont)
                .fixedSize()
                .foregroundStyle(isCritical ? palette.critical.color : palette.primaryText.color)
        }
        .frame(width: Theme.valueWidth, alignment: .trailing)

        if let onValueTap {
            column
                .contentShape(Rectangle())
                .onTapGesture(perform: onValueTap)
                .help(DayRow.valueHint(s))
        } else {
            column
        }
    }

    private var voiceOverLabel: String {
        let percent = Formatting.percent(usedPercent, withSign: false)
        let verdict = isCritical ? s.pick(", лимит на исходе", ", limit almost spent") : ""
        return s.pick("Лимит недели, потрачено \(percent) процентов\(verdict)",
                      "Weekly limit, \(percent) per cent spent\(verdict)")
    }
}
