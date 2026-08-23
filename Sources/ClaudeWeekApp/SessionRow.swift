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
    /// Состояние сессии по её собственным порогам — тем же, что красят кольцо
    /// в строке меню.
    let state: LimitState
    /// Каким концом подписан сброс: сколько осталось, во сколько наступит
    /// или и то, и другое.
    let resetDisplay: SessionResetDisplay
    /// Откуда цифры панели. Кружок висит здесь, а не в заголовке: строка
    /// сессии есть почти всегда, когда сервер отвечает, и глаз находит её
    /// первой.
    let source: SourceState
    /// Что кружок говорит словами при наведении.
    let sourceHint: String
    /// Кружок нажали — на месте полосы стоит тот же текст словами. Полоса
    /// гаснет под ним, а кружок и процент остаются: строка не должна ни
    /// съезжать, ни терять число, ради которого её читают.
    let showsSourceText: Bool
    /// Нажатие на кружок — показать текст или убрать его досрочно.
    let onSourceTap: () -> Void
    /// Нажатие на процент — открыть разбивку по моделям. Та же цифра, тот же
    /// смысл, что в строках дней: щёлкнули по числу — спрашивают, из чего оно.
    var onValueTap: (() -> Void)?
    /// Календарь конфига — час сброса показываем в той же зоне, что и всё
    /// остальное в панели, а не в системной.
    let calendar: Calendar
    let animated: Bool

    @Environment(\.palette) private var palette
    @Environment(\.strings) private var s

    private var isWarning: Bool {
        state != .normal
    }

    /// Лимит на исходе или уже исчерпан — тут краснеют значок и цифры, тем же
    /// порогом, что и заливка в строке меню (`MenuBarBar.fillColor`). Заливка
    /// этой полосы красной не станет — та граница проведена в `SessionBar`.
    private var isCritical: Bool {
        state == .critical || state == .exhausted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(s.pick("5 Ч", "5 H"))
                    .font(Theme.dayFont)
                    .foregroundStyle(palette.secondaryText.color)
                    .frame(width: Theme.dayLabelWidth, alignment: .leading)

                // Полоса остаётся в разметке всегда, а причина ложится на неё
                // слоем поверх: меняется одна прозрачность, и ни строка, ни
                // панель от клика по кружку не меняют размера. Отсюда и одна
                // строка текста — второй ряд раздвинул бы строку по высоте, а
                // за ней и всю панель. Длинный отказ дочитывается подсказкой.
                SessionBar(
                    usedPercent: session.usedPercent,
                    isWarning: isWarning,
                    animated: animated
                )
                .opacity(showsSourceText ? 0 : 1)
                .overlay(alignment: .leading) {
                    Text(sourceHint)
                        .font(Theme.captionFont)
                        // Цвет тот же, что у кружка рядом: подпись — это он
                        // словами, и разойтись они не должны.
                        .foregroundStyle(source.color(in: palette))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(showsSourceText ? 1 : 0)
                }

                SourceDot(state: source, hint: sourceHint, onTap: onSourceTap)

                percent
            }

            // Процент сессии без часа сброса — половина сведения: 90 % за
            // десять минут до конца окна и 90 % за четыре часа значат разное.
            Text(caption)
                .font(Theme.captionFont)
                .foregroundStyle(isCritical ? palette.critical.color : palette.secondaryText.color)
                .padding(.leading, Theme.dayLabelWidth + 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        // Тем же отдельным действием, что и в строках дней: жест на цифрах
        // VoiceOver не достаётся — строка объявлена одним элементом.
        .accessibilityAction(named: s.pick("Расход по моделям", "Spend by model")) { onValueTap?() }
    }

    /// Процент сессии — он же кнопка разбивки по моделям.
    @ViewBuilder
    private var percent: some View {
        let column = HStack(spacing: Theme.valueGap) {
            if isCritical {
                Text("⚠")
                    .font(Theme.dayFont)
                    .foregroundStyle(palette.critical.color)
            }
            Text(Formatting.percent(session.usedPercent))
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

    private var reset: String {
        Formatting.sessionReset(
            at: session.resetsAt,
            now: now,
            display: resetDisplay,
            calendar: calendar,
            lang: s.lang
        )
    }

    /// Слова «сессия» в подписи нет: слева от полосы и так стоит «5 Ч». Но
    /// исчерпанная говорит «лимит исчерпан», а не голое «исчерпана» — иначе
    /// подлежащего не остаётся, а молчать о полосе в потолке нельзя.
    private var caption: String {
        session.isExhausted
            ? s.pick("лимит исчерпан · отпустит \(reset)", "limit spent · frees up \(reset)")
            : s.pick("сброс \(reset)", "resets \(reset)")
    }

    private var voiceOverLabel: String {
        let percent = Formatting.percent(session.usedPercent, withSign: false)
        let verdict = session.isExhausted ? s.pick(", лимит исчерпан", ", limit spent") : ""
        return s.pick("""
        Пятичасовая сессия, потрачено \(percent) процентов\(verdict), \
        сброс \(reset), \(source.spokenName(s))
        """, """
        Five-hour session, \(percent) per cent spent\(verdict), \
        resets \(reset), \(source.spokenName(s))
        """)
    }
}
