import SwiftUI
import ClaudeWeekCore

/// Bullet-график одних суток: трек — вся неделя, поверх него зона плана,
/// поверх неё фактическая заливка. Где зелёное упирается в синее — идём
/// вровень; где появился янтарный — перерасход.
struct DayBar: View {
    let planPercent: Double
    let usedPercent: Double?
    let animated: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let planWidth = offset(planPercent, in: width)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)

                Capsule()
                    .fill(Theme.plan)
                    .frame(width: planWidth)

                if let used = usedPercent {
                    let insidePlan = offset(min(used, planPercent), in: width)
                    Capsule()
                        .fill(Theme.good)
                        .frame(width: insidePlan)

                    if used > planPercent {
                        let overspend = offset(used, in: width) - planWidth - Theme.overspendGap
                        Capsule()
                            .fill(Theme.warning)
                            .frame(width: max(overspend, 1))
                            .offset(x: planWidth + Theme.overspendGap)
                    }
                }
            }
            .animation(animated ? .easeOut(duration: Theme.fillAnimation) : nil, value: usedPercent)
        }
        .frame(height: Theme.barHeight)
    }

    private func offset(_ percent: Double, in width: CGFloat) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100) * width
    }
}

/// Строка панели: подпись дня, полоса и числа «факт / план».
/// Числа обязательны — цвет нигде не остаётся единственным носителем смысла.
struct DayRow: View {
    let day: DayUsage
    let label: String
    let fullLabel: String
    let isToday: Bool
    let animated: Bool

    private var isOverspent: Bool {
        guard let used = day.usedPercent else { return false }
        return used > day.planPercent
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.dayFont)
                .foregroundStyle(isToday ? Theme.primaryText : Theme.secondaryText)
                .frame(width: Theme.dayLabelWidth, alignment: .leading)

            DayBar(planPercent: day.planPercent, usedPercent: day.usedPercent, animated: animated)

            HStack(spacing: 3) {
                if isOverspent {
                    Text("⚠")
                        .font(Theme.dayFont)
                        .foregroundStyle(Theme.warning)
                }
                Text(values)
                    .font(Theme.dayFont)
                    .foregroundStyle(day.usedPercent == nil ? Theme.secondaryText : Theme.primaryText)
            }
            .frame(width: Theme.valueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    private var values: String {
        let used = day.usedPercent.map { Formatting.percent($0, withSign: false) } ?? "—"
        return "\(used) / \(Formatting.percent(day.planPercent))"
    }

    private var voiceOverLabel: String {
        let plan = Formatting.percent(day.planPercent, withSign: false)
        guard let used = day.usedPercent else {
            return "\(fullLabel), план \(plan) процентов, расхода ещё нет"
        }
        let fact = Formatting.percent(used, withSign: false)
        let verdict = isOverspent ? ", перерасход" : ""
        return "\(fullLabel), потрачено \(fact) процентов из \(plan) плановых\(verdict)"
    }
}
