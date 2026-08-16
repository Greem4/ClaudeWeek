import SwiftUI
import ClaudeWeekCore

/// Полоса доли модели: одна заливка на общем треке, без плановой зоны.
/// Плана здесь нет и быть не может — доля Opus ни к какому распорядку не
/// привязана, это просто часть целого.
struct ModelBar: View {
    let sharePercent: Double
    let animated: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let filled = CGFloat(min(max(sharePercent, 0), 100) / 100) * geometry.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(palette.track.color)
                // Цветом плана, а не факта: зелёный в панели значит «столько
                // потрачено против плана», и доля модели, покрашенная так же,
                // читалась бы как ещё один лимит.
                Capsule()
                    .fill(palette.plan.color)
                    .frame(width: filled)
            }
            .animation(animated ? .easeOut(duration: Theme.fillAnimation) : nil, value: sharePercent)
        }
        .frame(height: Theme.barHeight)
    }
}

/// Строка разбивки: чем потрачена неделя. Стоит на месте строк дней и в той же
/// сетке — подпись, полоса, число справа, — чтобы переключение туда-обратно не
/// перекладывало панель заново.
struct ModelRow: View {
    @Environment(\.strings) private var s
    let usage: ModelUsage
    /// Доля этой модели в недельном лимите: та же доля, умноженная на итог
    /// недели. Стоит в подсказке — в строке для второго числа места нет.
    let limitPercent: Double
    let animated: Bool
    /// Клик по числу — вернуться к неделе. Тот же жест, что привёл сюда.
    var valueTap: (() -> Void)?

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(usage.title(s.lang))
                .font(Theme.dayFont)
                .foregroundStyle(palette.primaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Theme.modelLabelWidth, alignment: .leading)

            ModelBar(sharePercent: usage.sharePercent, animated: animated)

            value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .accessibilityAction(named: s.pick("Назад к неделе", "Back to the week")) { valueTap?() }
        .help(tooltip)
    }

    @ViewBuilder
    private var value: some View {
        // «≈» у каждой строки: доля посчитана здесь и по весам, а не получена
        // от сервера, и число без оговорки стояло бы вровень с официальными
        // процентами недели — теми, что в футере и в строке меню.
        let column = Text("≈\(Formatting.percent(usage.sharePercent))")
            .font(Theme.dayFont)
            .fixedSize()
            .foregroundStyle(palette.primaryText.color)
            .frame(width: Theme.valueWidth, alignment: .trailing)

        if let valueTap {
            column
                .contentShape(Rectangle())
                .onTapGesture(perform: valueTap)
        } else {
            column
        }
    }

    /// Всё, что не влезло в строку: вклад в недельный лимит, токены по видам и
    /// условная стоимость. Вопрос «почему у Haiku миллионы токенов и ничего в
    /// доле» решается именно этой подсказкой — чтение кеша вдесятеро дешевле.
    private var tooltip: String {
        let input = Formatting.tokens(usage.tokens.input, lang: s.lang)
        let output = Formatting.tokens(usage.tokens.output, lang: s.lang)
        let cacheWrite = Formatting.tokens(usage.tokens.cacheWrite, lang: s.lang)
        let cacheRead = Formatting.tokens(usage.tokens.cacheRead, lang: s.lang)
        let cost = Formatting.cost(usage.cost, lang: s.lang)
        return s.pick("""
        ≈\(Formatting.percent(limitPercent)) недельного лимита
        Вход \(input) · выход \(output)
        Кеш: запись \(cacheWrite), чтение \(cacheRead)
        Ответов \(usage.messages) · условная стоимость \(cost)
        """, """
        ≈\(Formatting.percent(limitPercent)) of the weekly limit
        Input \(input) · output \(output)
        Cache: write \(cacheWrite), read \(cacheRead)
        Replies \(usage.messages) · weighted cost \(cost)
        """)
    }

    private var voiceOverLabel: String {
        let share = Formatting.percent(usage.sharePercent, withSign: false)
        let limit = Formatting.percent(limitPercent, withSign: false)
        return s.pick("""
        \(usage.title(s.lang)), \(share) процентов расхода недели, примерно \(limit) процентов \
        недельного лимита, ответов \(usage.messages)
        """, """
        \(usage.title(s.lang)), \(share) per cent of the week’s spend, roughly \(limit) per cent \
        of the weekly limit, \(usage.messages) replies
        """)
    }
}
