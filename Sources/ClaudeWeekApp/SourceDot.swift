import SwiftUI
import ClaudeWeekCore

/// Кружок источника: откуда взяты цифры, которые панель показывает сейчас.
/// Стоит в строке сессии между полосой и процентом, а без неё — в заголовке
/// у часа сброса: сказать, что число посчитано на месте, надо в любом случае.
///
/// Кодируется двумя каналами сразу. Цвет — зелёный у сервера, красный у
/// локальной оценки — при дейтеранопии почти не разделяется, поэтому форма
/// несёт то же самое ещё раз: свои цифры залиты целиком, чужие обведены
/// контуром. Это тот же приём, что и зазор в суточной полосе.
struct SourceDot: View {
    let state: SourceState
    /// Подсказка при наведении: цвет говорит «свои или чужие цифры», а
    /// почему именно — «нет сети», «данные 20 мин назад» — только она.
    let hint: String
    /// Клик по кружку: та же подсказка, но прямо в панели, поверх полосы.
    /// Всплывающей подсказки мало — её надо ждать с мышью на девяти точках,
    /// а отказ хочется прочитать сразу, как только заметил цвет.
    var onTap: () -> Void = {}

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: onTap) {
            dot
                .frame(width: Theme.sourceDotSize, height: Theme.sourceDotSize)
                // Зона клика шире кружка, но разметка от этого не едет: поля
                // тут же снимаются отрицательными, и полоса рядом остаётся на
                // своём месте.
                .padding(Theme.sourceDotHitPadding)
                .contentShape(Rectangle())
                .padding(-Theme.sourceDotHitPadding)
        }
        .buttonStyle(.plain)
        // Без этого AppKit обводит нажатый кружок прямоугольной рамкой фокуса:
        // на девятипунктовой точке она крупнее самой точки и читается как
        // ошибка вёрстки. Клавиатуре кружок и не нужен — то же самое говорит
        // подсказка, а VoiceOver берёт источник из строки.
        .focusEffectDisabled()
        .help(hint)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var dot: some View {
        if isFilled {
            Circle().fill(color)
        } else {
            Circle().strokeBorder(color, lineWidth: Theme.sourceDotStroke)
        }
    }

    private var isFilled: Bool {
        switch state {
        case .synced, .stale: true
        case .local, .missing: false
        }
    }

    private var color: Color {
        switch state {
        case .synced: palette.good.color
        case .stale: palette.warning.color
        case .local: palette.critical.color
        case .missing: palette.secondaryText.color
        }
    }
}

extension SourceState {
    /// Для VoiceOver: кружок сам по себе скрыт от него — цвет и заливку
    /// озвучить нечем, поэтому строка называет источник словом.
    var spokenName: String {
        switch self {
        case .synced: "данные с сервера"
        case .stale: "данные с сервера, устаревшие"
        case .local: "локальная оценка"
        case .missing: "данных нет"
        }
    }
}
