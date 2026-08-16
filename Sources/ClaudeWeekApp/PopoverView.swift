import SwiftUI
import ClaudeWeekCore

/// Панель недели: заголовок, семь двухцветных полос, футер с итогами.
/// Полос всегда семь — по дням недели, день сброса одной строкой.
struct PopoverView: View {
    @Bindable var model: PanelModel
    /// Новая версия — новость, а не настройка: строка о ней появляется в
    /// панели и исчезает вместе с поводом.
    @Bindable var update: UpdateController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Кружок источника нажали: там, где он стоит, панель на несколько секунд
    /// подменяет соседа текстом — в строке сессии полосу, в заголовке час
    /// сброса. Само состояние живёт здесь, а не в модели: это не то, что
    /// панель показывает, а то, что человек в ней сейчас делает.
    @State private var showsSourceText = false

    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    private var appearance: AppearanceConfig { model.config.appearance }
    private var palette: Palette { appearance.theme.palette }

    /// Язык панели — тот же, что у настроек: обе половины программы читают
    /// его из конфига, и переключение перерисовывает их разом.
    private var s: L10n { model.strings }

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
                    state: model.sessionState,
                    resetDisplay: appearance.sessionReset,
                    source: model.sourceState,
                    sourceHint: model.sourceHint,
                    showsSourceText: showsSourceText,
                    onSourceTap: { showsSourceText.toggle() },
                    onValueTap: toggleModels,
                    calendar: model.config.calendar,
                    animated: !reduceMotion
                )
            }

            Divider().overlay(palette.separator.color)

            if let snapshot = model.snapshot {
                // Разбивка встаёт ровно на место дней, в ту же сетку: щелчок
                // по цифрам меняет содержание строк, а не открывает второе
                // место, где те же проценты сказаны по-своему.
                if model.showsModels {
                    models(snapshot)
                } else {
                    days(snapshot)
                }
            } else {
                placeholders
            }

            Divider().overlay(palette.separator.color)
            footer

            if let banner = update.banner {
                Divider().overlay(palette.separator.color)
                updateRow(banner)
            }
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
        // Прозрачный режим: под панелью материал строки меню, а здесь только
        // вуаль поверх него. Непрозрачный — сплошная заливка палитры.
        .background(backdrop)
        .environment(\.palette, palette)
        .environment(\.strings, s)
        // Текст уходит сам: панель открывают ради полос, и оставлять её без
        // них до следующего клика нельзя. Повторный клик снимает текст раньше
        // — смена `showsSourceText` отменяет и эту задачу.
        .task(id: showsSourceText) {
            guard showsSourceText else { return }
            try? await Task.sleep(for: .seconds(Theme.sourceTextDuration))
            guard !Task.isCancelled else { return }
            showsSourceText = false
        }
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

    /// Кружок источника живёт в строке сессии, а когда её нет — в заголовке.
    /// Без строки сессии панель остаётся именно в тех случаях, когда знать
    /// источник важнее всего: локальный режим сессии не считает вовсе.
    private var showsSessionRow: Bool {
        appearance.showSession && model.session != nil
    }

    /// Причина в заголовке — только когда кружок стоит здесь: со строкой
    /// сессии текст показывает она, поверх своей полосы.
    private var showsHeaderSourceText: Bool {
        showsSourceText && !showsSessionRow
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.state == .exhausted || model.state == .critical {
                    Text("⚠")
                        .font(Theme.titleFont)
                        .foregroundStyle(palette.critical.color)
                }
                // Заголовок называет то, что сейчас в строках: иначе разбивка
                // читалась бы как недельный ряд со странными подписями.
                Text(model.showsModels
                     ? s.pick("МОДЕЛИ", "MODELS")
                     : s.pick("ЛИМИТ НЕДЕЛИ", "WEEKLY LIMIT"))
                    .font(Theme.titleFont)
                    .tracking(0.4)
                    .fixedSize()
                    .foregroundStyle(
                        model.state == .exhausted
                            ? palette.critical.color
                            : palette.primaryText.color
                    )

                Spacer(minLength: 4)

                if !showsSessionRow {
                    // Кружок не текст, и по базовой линии его равнять нечем:
                    // без поправки он сел бы на неё донышком и выглядел бы
                    // просевшим относительно цифр рядом.
                    SourceDot(
                        state: model.sourceState,
                        hint: model.sourceHint,
                        onTap: { showsSourceText.toggle() }
                    )
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }

                // Момент сброса — в зоне окна, той же, по которой считаются
                // сутки. Ни московского времени для сверки, ни прежних
                // «≈14 % в сутки» здесь нет: строке заголовка хватает одного
                // числа, а два подряд читались как спорящие.
                //
                // На эти же несколько секунд его место занимает текст
                // источника. Оба стоят в разметке всегда и меняются одной
                // прозрачностью: подмена не должна ни раздвигать заголовок по
                // высоте, ни сдвигать кружок слева — щёлкать обратно
                // приходится туда же, куда щёлкнул.
                ZStack(alignment: .trailing) {
                    if let window = model.snapshot?.window {
                        Text(Formatting.resetLabel(window, lang: s.lang))
                            .fixedSize()
                            .opacity(showsHeaderSourceText ? 0 : 1)
                    }
                    if !showsSessionRow {
                        Text(model.sourceHint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Тот же цвет, что у кружка слева, — он и сказал
                            // это первым, текст лишь повторяет словами.
                            .foregroundStyle(model.sourceState.color(in: palette))
                            .opacity(showsHeaderSourceText ? 1 : 0)
                    }
                }
                .font(Theme.captionFont)
                .foregroundStyle(palette.secondaryText.color)
            }
        }
        // Пометки об источнике под заголовком больше нет — её место занял
        // кружок. VoiceOver цвет с заливкой не читает, поэтому источник он
        // получает подсказкой, и только когда кружок стоит здесь.
        .accessibilityElement(children: .combine)
        .accessibilityHint(showsSessionRow ? "" : model.sourceState.spokenName(s))
    }

    // MARK: Дни

    private func days(_ snapshot: UsageSnapshot) -> some View {
        let calendar = snapshot.window.calendar
        // Строк семь — или одна, текущих суток, если панель настроена
        // компактно. День сброса стоит одной: пока неделя катится — её вечером
        // после сброса, в последние сутки окна — утром перед следующим.
        return VStack(spacing: Theme.rowSpacing) {
            ForEach(model.dayRows(snapshot), id: \.index) { day in
                DayRow(
                    day: day,
                    label: Formatting.weekdayShort(day.start, calendar: calendar),
                    fullLabel: Formatting.weekdayFull(day.start, calendar: calendar),
                    // День сброса короче суток: интервал поясняет, какая из
                    // его половин сейчас на строке.
                    interval: day.isPartial ? Formatting.interval(day.start, day.end, calendar: calendar) : nil,
                    isToday: day.index == model.todayIndex,
                    animated: !reduceMotion,
                    tap: dayTap,
                    valueTap: toggleModels
                )
            }
        }
    }

    // MARK: Модели

    /// Разбивка на месте дней. Возвращает обратно тот же клик по цифрам —
    /// другого выхода отсюда искать не приходится: где нажал, там и вернул.
    private func models(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: Theme.rowSpacing) {
            if snapshot.byModel.isEmpty {
                Text(s.pick("разбивки нет: транскриптов за это окно не нашлось",
                            "no breakdown: no transcripts found for this window"))
                    .font(Theme.captionFont)
                    .foregroundStyle(palette.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Нажимаемо и в пустом виде: иначе панель, открытая до
                    // первого ответа, застревала бы в разбивке без строк.
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleModels)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(s.pick("нажмите — назад к неделе", "tap to go back to the week"))
            } else {
                ForEach(snapshot.byModel, id: \.family) { usage in
                    ModelRow(
                        usage: usage,
                        limitPercent: snapshot.limitPercent(of: usage),
                        animated: !reduceMotion,
                        valueTap: toggleModels
                    )
                }

                // Откуда эти числа — сразу под ними, а не в футере: футер
                // говорит про неделю, и оговорка про разбивку, стоящая там,
                // читалась бы как оговорка про весь лимит.
                Text(s.pick("≈ примерный локальный подсчёт", "≈ rough local estimate"))
                    .font(Theme.captionFont)
                    .foregroundStyle(palette.secondaryText.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private func toggleModels() {
        model.showsModels.toggle()
    }

    /// В компактном виде клик по любой строке дня переключает ряд: свёрнутый
    /// раскрывается на всю неделю, раскрытый сворачивается обратно. Настройку
    /// это не трогает — раскрытие живёт до закрытия панели, и следующий её
    /// показ снова компактный.
    private var dayTap: DayRowTap? {
        guard appearance.panelLayout == .compact else { return nil }
        return DayRowTap(expands: !model.expandsWeek) {
            model.expandsWeek.toggle()
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
        .accessibilityLabel(s.pick("данные загружаются", "loading data"))
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
                // Та же рамка фокуса, что портила кружок источника: AppKit
                // обводит нажатую кнопку синим прямоугольником, и на панели
                // размером с меню он читается как ошибка вёрстки. Обе кнопки
                // футера дублируются пунктами меню — клавиатуре они не нужны.
                .focusEffectDisabled()
                .accessibilityLabel(s.pick("настройки", "settings"))

                Button(action: onRefresh) {
                    Text(model.isRefreshing ? "…" : "⟳")
                        .font(Theme.actionFont)
                        .foregroundStyle(palette.secondaryText.color)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(s.pick("обновить", "refresh"))
            }
        }
    }

    /// Строка обновления. Стоит под футером и живёт ровно столько, сколько
    /// есть повод: вышел выпуск, идёт установка, поставленное ждёт
    /// перезапуска. Тихие состояния — «проверяю», «у вас последняя» — сюда не
    /// доходят: панель открывают ради недельного лимита.
    ///
    /// Это уведомление, а не вторая кнопка обновления: сама установка живёт
    /// одной кнопкой на вкладке «О программе», и щелчок по строке ведёт
    /// туда же. Одно и то же действие в двух местах разошлось бы состояниями —
    /// ровно та причина, по которой из меню убрали автозапуск.
    private func updateRow(_ text: String) -> some View {
        Button(action: onSettings) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("↑ \(text)")
                    .font(Theme.footerFont)
                    // Тем же цветом, что и плановая полоса: это подсказка
                    // «так надо», а не тревога.
                    .foregroundStyle(palette.plan.color)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text(s.pick("в настройках →", "in settings →"))
                    .font(Theme.footerFont)
                    .foregroundStyle(palette.secondaryText.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(s.pick("\(text). Открыть настройки", "\(text). Open settings"))
    }

    private var summary: String {
        guard let metrics = model.metrics else { return s.pick("нет данных", "no data") }
        let left = Formatting.duration(metrics.timeLeft, lang: s.lang)
        if model.state == .exhausted {
            return s.pick("лимит недели исчерпан · сброс через \(left)",
                          "weekly limit spent · resets in \(left)")
        }
        // Темпа «1.0×» здесь больше нет: то же самое видно по расхождению
        // зелёной и синей полос, а числом это читалось как ещё один лимит.
        // Когда темп ведёт к беде, о ней говорит строка прогноза ниже.
        let remaining = Formatting.percent(metrics.remainingPercent)
        return s.pick("осталось \(remaining) · сброс через \(left)",
                      "\(remaining) left · resets in \(left)")
    }

    /// Вторая строка футера появляется только когда при нынешнем темпе лимит
    /// кончится раньше сброса.
    private var forecast: String? {
        guard model.state != .exhausted,
              let exhaustion = model.metrics?.exhaustionDate,
              let window = model.snapshot?.window
        else { return nil }
        let day = Formatting.weekdayShort(exhaustion, calendar: window.calendar, lang: s.lang)
        let clock = Formatting.clock(exhaustion, calendar: window.calendar)
        return s.pick("при таком темпе кончится \(day) \(clock)",
                      "at this rate it runs out \(day) \(clock)")
    }
}
