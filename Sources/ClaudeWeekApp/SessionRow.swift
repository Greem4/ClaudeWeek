import SwiftUI
import ClaudeWeekCore

/// Полоса пятичасовой сессии: одна заливка на общем треке, без плановой зоны.
/// Плана здесь нет намеренно — пятичасовое окно не обязано расходоваться
/// равномерно (можно просто закончить работу), и синяя «сколько положено
/// к этому часу» изображала бы темп, которого у сессии по смыслу нет.
struct SessionBar: View {
    let usedPercent: Double
    /// Лимит на исходе — заливка желтеет. Красный в заливку не идёт по той же
    /// причине, что и в суточных полосах: с зелёным он неразличим при
    /// дейтеранопии, поэтому тревога живёт в тексте и значке.
    let isWarning: Bool
    let animated: Bool

    var body: some View {
        GeometryReader { geometry in
            let filled = CGFloat(min(max(usedPercent, 0), 100) / 100) * geometry.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(isWarning ? Theme.warning : Theme.good)
                    .frame(width: filled)
            }
            .animation(animated ? .easeOut(duration: Theme.fillAnimation) : nil, value: usedPercent)
        }
        .frame(height: Theme.barHeight)
    }
}

/// Строка сессии в сетке суточных полос, но над разделителем: это второй,
/// независимый лимит, а не восьмой день недели. Метка и колонка значения
/// шириной как у дней — иначе полосы разъехались бы по вертикали.
struct SessionRow: View {
    let session: SessionUsage
    let now: Date
    /// Доля лимита, после которой полоса желтеет. Берётся из тех же порогов,
    /// что и неделя: два набора настроек ради одной полосы не нужны.
    let criticalThreshold: Double
    let animated: Bool

    private var isWarning: Bool {
        session.usedPercent >= criticalThreshold * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("5 Ч")
                    .font(Theme.dayFont)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Theme.dayLabelWidth, alignment: .leading)

                SessionBar(
                    usedPercent: session.usedPercent,
                    isWarning: isWarning,
                    animated: animated
                )

                HStack(spacing: 3) {
                    if session.isExhausted {
                        Text("⚠")
                            .font(Theme.dayFont)
                            .foregroundStyle(Theme.critical)
                    }
                    Text(Formatting.percent(session.usedPercent))
                        .font(Theme.dayFont)
                        .foregroundStyle(session.isExhausted ? Theme.critical : Theme.primaryText)
                }
                .frame(width: Theme.valueWidth, alignment: .trailing)
            }

            // Процент сессии без часа сброса — половина сведения: 90 % за
            // десять минут до конца окна и 90 % за четыре часа значат разное.
            Text(caption)
                .font(Theme.captionFont)
                .foregroundStyle(session.isExhausted ? Theme.critical : Theme.secondaryText)
                .padding(.leading, Theme.dayLabelWidth + 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    private var left: String {
        Formatting.duration(session.timeLeft(from: now))
    }

    private var caption: String {
        session.isExhausted
            ? "сессия исчерпана · отпустит через \(left)"
            : "сессия · сброс через \(left)"
    }

    private var voiceOverLabel: String {
        let percent = Formatting.percent(session.usedPercent, withSign: false)
        let verdict = session.isExhausted ? ", лимит исчерпан" : ""
        return "Пятичасовая сессия, потрачено \(percent) процентов\(verdict), сброс через \(left)"
    }
}
