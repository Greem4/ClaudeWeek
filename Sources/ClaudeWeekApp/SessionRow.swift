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

    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let filled = CGFloat(min(max(usedPercent, 0), 100) / 100) * geometry.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(palette.track.color)
                Capsule()
                    .fill(isWarning ? palette.warning.color : palette.good.color)
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
    /// Каким концом подписан сброс: сколько осталось, во сколько наступит
    /// или и то, и другое.
    let resetDisplay: SessionResetDisplay
    /// Откуда цифры панели. Кружок висит здесь, а не в заголовке: строка
    /// сессии есть почти всегда, когда сервер отвечает, и глаз находит её
    /// первой.
    let source: SourceState
    /// Что кружок говорит словами при наведении.
    let sourceHint: String
    /// Календарь конфига — час сброса показываем в той же зоне, что и всё
    /// остальное в панели, а не в системной.
    let calendar: Calendar
    let animated: Bool

    @Environment(\.palette) private var palette

    private var isWarning: Bool {
        session.usedPercent >= criticalThreshold * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("5 Ч")
                    .font(Theme.dayFont)
                    .foregroundStyle(palette.secondaryText.color)
                    .frame(width: Theme.dayLabelWidth, alignment: .leading)

                SessionBar(
                    usedPercent: session.usedPercent,
                    isWarning: isWarning,
                    animated: animated
                )

                SourceDot(state: source, hint: sourceHint)

                HStack(spacing: 3) {
                    if session.isExhausted {
                        Text("⚠")
                            .font(Theme.dayFont)
                            .foregroundStyle(palette.critical.color)
                    }
                    Text(Formatting.percent(session.usedPercent))
                        .font(Theme.dayFont)
                        .foregroundStyle(session.isExhausted ? palette.critical.color : palette.primaryText.color)
                }
                .frame(width: Theme.valueWidth, alignment: .trailing)
            }

            // Процент сессии без часа сброса — половина сведения: 90 % за
            // десять минут до конца окна и 90 % за четыре часа значат разное.
            Text(caption)
                .font(Theme.captionFont)
                .foregroundStyle(session.isExhausted ? palette.critical.color : palette.secondaryText.color)
                .padding(.leading, Theme.dayLabelWidth + 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    private var reset: String {
        Formatting.sessionReset(
            at: session.resetsAt,
            now: now,
            display: resetDisplay,
            calendar: calendar
        )
    }

    /// Слова «сессия» в подписи нет: слева от полосы и так стоит «5 Ч». Но
    /// исчерпанная говорит «лимит исчерпан», а не голое «исчерпана» — иначе
    /// подлежащего не остаётся, а молчать о полосе в потолке нельзя.
    private var caption: String {
        session.isExhausted
            ? "лимит исчерпан · отпустит \(reset)"
            : "сброс \(reset)"
    }

    private var voiceOverLabel: String {
        let percent = Formatting.percent(session.usedPercent, withSign: false)
        let verdict = session.isExhausted ? ", лимит исчерпан" : ""
        return """
        Пятичасовая сессия, потрачено \(percent) процентов\(verdict), \
        сброс \(reset), \(source.spokenName)
        """
    }
}
