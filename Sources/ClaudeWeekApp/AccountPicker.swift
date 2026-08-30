import AppKit
import SwiftUI
import ClaudeWeekCore

/// Два знака в заголовке панели — Claude и Codex. Выбор хранится в конфиге, но
/// сам вид получает только значение и действие: отдельного локального
/// состояния, способного разойтись с реально загруженным аккаунтом, нет.
struct AccountPicker: View {
    let selection: UsageAccount
    let onSelect: (UsageAccount) -> Void

    @Environment(\.strings) private var s

    var body: some View {
        HStack(spacing: 5) {
            ForEach(UsageAccount.allCases, id: \.self) { account in
                AccountButton(
                    account: account,
                    isSelected: account == selection,
                    onSelect: onSelect
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.pick("Аккаунт", "Account"))
        // Заголовок собран по базовой линии текста, а у картинки она проходит
        // по нижней кромке — знаки вставали над строкой. Выдаём за базовую
        // линию собственный центр, поднятый на столько же, на сколько центр
        // строки стоит над baseline: знаки встают ровно посередине надписи.
        .alignmentGuide(.firstTextBaseline) {
            $0[VerticalAlignment.center] + Theme.textCenterAboveBaseline
        }
    }
}

private struct AccountButton: View {
    let account: UsageAccount
    let isSelected: Bool
    let onSelect: (UsageAccount) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.strings) private var s

    var body: some View {
        Button {
            onSelect(account)
        } label: {
            // Ни подложки, ни рамки: в заголовке это знаки, а не органы
            // управления. Что выбрано, говорит цвет; поле вокруг знака
            // добавлено только ради попадания мышью.
            providerIcon
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Системное кольцо фокуса рисует вокруг знака рамку, которой здесь
        // быть не должно: после клика подсвечены оба сервиса сразу.
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var assetName: String {
        switch account {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// У поставщиков нет подходящих SF Symbols: знаки лежат в ресурсах
    /// таргета как шаблонные PNG — силуэт держит альфа-канал, цвета в файле
    /// нет. Красит их `iconColor`, поэтому знак живёт в любой теме.
    @ViewBuilder
    private var providerIcon: some View {
        if let url = Bundle.module.url(forResource: assetName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // Шаблонным знак делает сама картинка: SwiftUI на macOS красит
            // `Image(nsImage:)` по `foregroundStyle` только тогда, когда
            // `isTemplate` стоит у NSImage, — одного `renderingMode` мало.
            Image(nsImage: template(image))
                .resizable()
                .scaledToFit()
                .foregroundStyle(iconColor)
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondaryText.color)
                .frame(width: 13, height: 13)
        }
    }

    private func template(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }

    /// Выбранный сервис горит своим цветом — Claude фирменным оранжевым,
    /// Codex цветом текста, — невыбранный гаснет до приглушённого серого.
    /// Разница цвета и есть выделение: подложка под знаком в заголовке
    /// читалась бы как кнопка, которой здесь нет.
    private var iconColor: Color {
        guard isSelected else { return palette.secondaryText.color.opacity(0.55) }
        switch account {
        case .claude: return Color(red: 0.83, green: 0.42, blue: 0.30)
        case .codex: return palette.primaryText.color
        }
    }

    private var help: String {
        let title = account.title(s.lang)
        return isSelected
            ? s.pick("Показан \(title)", "Showing \(title)")
            : s.pick("Показать \(title)", "Show \(title)")
    }
}
