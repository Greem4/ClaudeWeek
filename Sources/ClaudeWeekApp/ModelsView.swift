import SwiftUI
import ClaudeWeekCore

/// Окно «Расход по моделям»: чем именно набрана неделя.
///
/// Итог недели наверху — от сервера, а вот разбивка под ним всегда посчитана
/// здесь, по транскриптам `~/.claude/projects`: официальный эндпоинт отдаёт
/// один процент на всю неделю и о моделях не говорит ничего (`docs/API.md`).
/// Поэтому доли подписаны «≈» и оговорены внизу — выдавать оценку за цифру
/// сервера нельзя, ради этого различия в панели заведён целый кружок источника.
struct ModelsView: View {
    @Bindable var model: PanelModel

    /// Ширины колонок держим здесь: числа в них выровнены по правому краю, и
    /// без общей ширины столбцы разъезжались бы от строки к строке.
    private enum Column {
        static let share: CGFloat = 88
        static let limit: CGFloat = 88
        static let tokens: CGFloat = 68
        static let messages: CGFloat = 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content(for: model.snapshot)
            Divider()
            footnote
        }
        // Высоту не задаём: моделей бывает три, бывает шесть, и окно должно
        // вырасти под список, а не прокручивать его в дырке фиксированного
        // размера. Ширина, наоборот, постоянная — по ней размечены колонки.
        .frame(width: 640)
    }

    // MARK: Заголовок

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Чем потрачена неделя")
                    .font(.headline)
                Spacer(minLength: 12)
                if let window = model.snapshot?.window {
                    Text(Formatting.resetLabel(window))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text(totals)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    /// Оба лимита одной строкой — те же числа, что в панели, чтобы окно и
    /// панель нельзя было прочитать по-разному.
    private var totals: String {
        guard let snapshot = model.snapshot else { return "данных пока нет" }
        let week = snapshot.isEstimate
            ? "неделя ≈\(Formatting.percent(snapshot.usedPercent))"
            : "неделя \(Formatting.percent(snapshot.usedPercent))"
        guard let session = model.session else { return week }
        return "\(week) · сессия 5 ч \(Formatting.percent(session.usedPercent))"
    }

    // MARK: Таблица

    @ViewBuilder
    private func content(for snapshot: UsageSnapshot?) -> some View {
        if let snapshot, !snapshot.byModel.isEmpty {
            table(snapshot)
        } else {
            // Своя высота: без неё окно, у которого нет заданной, схлопнулось
            // бы вокруг двух строк текста и выглядело обрубком.
            explanation(hasSnapshot: snapshot != nil)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    /// Таблица без прокрутки: семейств моделей единицы, и все они помещаются
    /// в окно. Прокрутки здесь нет ещё и потому, что оффскрин-рендер
    /// (`--screenshot`) её содержимое не раскладывает — картинка выходила
    /// пустой ровно в том месте, ради которого окно и заведено.
    private func table(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Модель")
                    Text("Доля").frame(width: Column.share, alignment: .trailing)
                    Text("В лимите").frame(width: Column.limit, alignment: .trailing)
                    Text("Вход").frame(width: Column.tokens, alignment: .trailing)
                    Text("Выход").frame(width: Column.tokens, alignment: .trailing)
                    Text("Кеш").frame(width: Column.tokens, alignment: .trailing)
                    Text("Ответов").frame(width: Column.messages, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(snapshot.byModel, id: \.family) { usage in
                    GridRow {
                        Text(usage.title)
                            .font(.body.weight(.medium))
                            .gridColumnAlignment(.leading)

                        HStack(spacing: 8) {
                            ShareBar(percent: usage.sharePercent)
                            Text(Formatting.percent(usage.sharePercent))
                                .monospacedDigit()
                        }
                        .frame(width: Column.share, alignment: .trailing)

                        // «≈» стоит у каждой строки, а не только в сноске: это
                        // единственное место, где число выглядит как процент
                        // лимита, и спутать его с официальным легче всего.
                        Text("≈\(Formatting.percent(snapshot.limitPercent(of: usage)))")
                            .monospacedDigit()
                            .frame(width: Column.limit, alignment: .trailing)

                        // Три колонки токенов, а не одна сумма: вход, выход и
                        // кеш стоят по-разному, и «46,6 млн» у Haiku рядом с
                        // «7 %» доли выглядит противоречием, пока не видно,
                        // что почти всё это — дешёвое чтение кеша.
                        Text(Formatting.tokens(usage.tokens.input))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: Column.tokens, alignment: .trailing)

                        Text(Formatting.tokens(usage.tokens.output))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: Column.tokens, alignment: .trailing)

                        Text(Formatting.tokens(usage.tokens.cacheWrite + usage.tokens.cacheRead))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: Column.tokens, alignment: .trailing)

                        Text("\(usage.messages)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: Column.messages, alignment: .trailing)
                    }
                    .help(details(of: usage))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(voiceOver(usage, in: snapshot))
                }
            }
            .padding(16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Полный расклад — при наведении: в строке ему места нет, а вопрос
    /// «почему у Haiku миллионы токенов и ничего в лимите» решается именно им.
    private func details(of usage: ModelUsage) -> String {
        """
        Кеш: запись \(Formatting.tokens(usage.tokens.cacheWrite)), \
        чтение \(Formatting.tokens(usage.tokens.cacheRead))
        Всего \(Formatting.tokens(usage.tokens.total)) токенов
        Условная стоимость \(Formatting.cost(usage.cost))
        """
    }

    private func voiceOver(_ usage: ModelUsage, in snapshot: UsageSnapshot) -> String {
        """
        \(usage.title), \(Formatting.percent(usage.sharePercent, withSign: false)) процентов \
        расхода, примерно \(Formatting.percent(snapshot.limitPercent(of: usage), withSign: false)) \
        процентов недельного лимита, \(Formatting.tokens(usage.tokens.total)) токенов всего, \
        ответов \(usage.messages)
        """
    }

    /// Пусто бывает по двум разным причинам, и разговор с человеком у них тоже
    /// разный: подождать или искать транскрипты.
    private func explanation(hasSnapshot: Bool) -> some View {
        VStack(spacing: 8) {
            Text(hasSnapshot ? "Разбивки пока нет" : "Данных пока нет")
                .font(.headline)
            Text(hasSnapshot
                 ? """
                 За это недельное окно транскриптов не нашлось: каталог \
                 ~/.claude/projects пуст, или Claude Code писал в другой.
                 """
                 : "Панель ещё не получила первый ответ — загляните через секунду.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    // MARK: Сноска

    private var footnote: some View {
        Text("""
        Разбивка посчитана по локальным транскриптам ~/.claude/projects: \
        официальный источник сообщает только итог недели и о моделях молчит. \
        Доли взвешены по ценам моделей, поэтому это оценка — «≈» относится \
        именно к ним, а сам итог недели остаётся тем же, что в панели.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}

/// Полоса доли: та же мысль, что у суточных полос панели, но без плана —
/// сравнивать долю модели не с чем, она просто часть целого.
private struct ShareBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            let filled = CGFloat(min(max(percent, 0), 100) / 100) * geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: filled)
            }
        }
        .frame(width: 40, height: 6)
    }
}
