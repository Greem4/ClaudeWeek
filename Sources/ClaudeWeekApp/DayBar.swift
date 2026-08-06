import SwiftUI
import ClaudeWeekCore

/// Bullet-график одних суток: трек — вся неделя, поверх него зона плана,
/// поверх неё фактическая заливка. Где зелёное упирается в синее — идём
/// вровень; где появился янтарный — перерасход.
struct DayBar: View {
    let planPercent: Double
    let usedPercent: Double?
    let animated: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let planWidth = offset(planPercent, in: width)

            ZStack(alignment: .leading) {
                Capsule().fill(palette.track.color)

                Capsule()
                    .fill(palette.plan.color)
                    .frame(width: planWidth)

                if let used = usedPercent {
                    let insidePlan = offset(min(used, planPercent), in: width)
                    Capsule()
                        .fill(palette.good.color)
                        .frame(width: insidePlan)

                    if used > planPercent {
                        let overspend = offset(used, in: width) - planWidth - Theme.overspendGap
                        Capsule()
                            .fill(palette.warning.color)
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

/// Что делает клик по строке дня. Есть только в компактном виде: там строка —
/// ещё и способ развернуть ряд, а с полным рядом разворачивать нечего.
struct DayRowTap {
    /// Клик раскроет неделю; иначе — свернёт её обратно до текущих суток.
    let expands: Bool
    let action: () -> Void

    /// Что случится по клику — словами, для подсказки при наведении и
    /// VoiceOver: полосы сами о своей нажимаемости не говорят.
    var hint: String {
        expands ? "нажмите — вся неделя" : "нажмите — только сегодня"
    }
}

/// Строка панели: подпись дня, полоса и числа «факт / план».
/// Числа обязательны — цвет нигде не остаётся единственным носителем смысла.
struct DayRow: View {
    let day: DayUsage
    let label: String
    let fullLabel: String
    /// Часы обрезанных суток («16:00 → 0:00»); nil — сутки полные.
    var interval: String?
    let isToday: Bool
    let animated: Bool
    /// Клик по строке; nil — панель показывает весь ряд, и щёлкать незачем.
    var tap: DayRowTap?

    @Environment(\.palette) private var palette

    private var isOverspent: Bool {
        guard let used = day.usedPercent else { return false }
        return used > day.planPercent
    }

    var body: some View {
        let row = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(voiceOverLabel)
            .help(tooltip)

        // Нажимаемой строка становится целиком, вместе с прозрачными зазорами
        // между подписью, полосой и числами: попасть в неё надо мышью, а не
        // прицелом.
        if let tap {
            row
                .contentShape(Rectangle())
                .onTapGesture(perform: tap.action)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(tap.hint)
        } else {
            row
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(isToday ? Theme.todayFont : Theme.dayFont)
                .foregroundStyle(isToday ? palette.primaryText.color : palette.secondaryText.color)
                .frame(width: Theme.dayLabelWidth, alignment: .leading)

            DayBar(planPercent: day.planPercent, usedPercent: day.usedPercent, animated: animated)

            HStack(spacing: 3) {
                if isOverspent {
                    Text("⚠")
                        .font(Theme.dayFont)
                        .foregroundStyle(palette.warning.color)
                }
                Text(values)
                    .font(Theme.dayFont)
                    .foregroundStyle(
                        day.usedPercent == nil
                            ? palette.secondaryText.color
                            : palette.primaryText.color
                    )
            }
            .frame(width: Theme.valueWidth, alignment: .trailing)
        }
    }

    /// Наведение поясняет, какие именно часы стоят за строкой: у крайних
    /// суток недели подпись дня повторяется, и различает их только время.
    /// В компактном виде оно же и подсказывает про клик — иначе о раскрытии
    /// недели никто не догадается.
    private var tooltip: String {
        let day = interval.map { "\(fullLabel), \($0)" } ?? fullLabel
        guard let tap else { return day }
        return "\(day) · \(tap.hint)"
    }

    private var values: String {
        let used = day.usedPercent.map { Formatting.percent($0, withSign: false) } ?? "—"
        return "\(used) / \(Formatting.percent(day.planPercent))"
    }

    private var voiceOverLabel: String {
        let plan = Formatting.percent(day.planPercent, withSign: false)
        // Начертание и цвет VoiceOver не читает: текущие сутки он узнаёт словом.
        let today = isToday ? "\(fullLabel), сегодня" : fullLabel
        let name = interval.map { "\(today), \($0)" } ?? today
        guard let used = day.usedPercent else {
            return "\(name), план \(plan) процентов, расхода ещё нет"
        }
        let fact = Formatting.percent(used, withSign: false)
        let verdict = isOverspent ? ", перерасход" : ""
        return "\(name), потрачено \(fact) процентов из \(plan) плановых\(verdict)"
    }
}
