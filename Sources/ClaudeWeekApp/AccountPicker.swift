import AppKit
import SwiftUI
import ClaudeWeekCore

/// Два знака в заголовке панели — два аккаунта Claude. Выбор хранится в
/// конфиге, но сам вид получает только значение и действие: отдельного
/// локального состояния, способного разойтись с реально загруженным
/// аккаунтом, нет.
struct AccountPicker: View {
    let selection: UsageAccount
    /// Чем подписан каждый аккаунт в подсказке — адрес из `claude auth status`,
    /// пока он не получен, порядковое название.
    let titles: [UsageAccount: String]
    let onSelect: (UsageAccount) -> Void

    @Environment(\.strings) private var s

    var body: some View {
        HStack(spacing: 5) {
            ForEach(UsageAccount.allCases, id: \.self) { account in
                AccountButton(
                    account: account,
                    isSelected: account == selection,
                    title: titles[account] ?? account.fallbackTitle(s.lang),
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
    let title: String
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
        // быть не должно: после клика подсвечены оба аккаунта сразу.
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// У Claude нет подходящего SF Symbol: знак лежит в ресурсах таргета как
    /// шаблонный PNG — силуэт держит альфа-канал, цвета в файле нет. Красит
    /// его `iconColor`, поэтому знак живёт в любой теме.
    @ViewBuilder
    private var providerIcon: some View {
        if let url = Bundle.module.url(forResource: "Claude", withExtension: "png"),
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

    /// Знаки у обоих аккаунтов одинаковые — сервис-то один, — поэтому
    /// выбранный различает цвет: он горит фирменным оранжевым, невыбранный
    /// гаснет до приглушённого серого. Кто из них кто, говорит подсказка: там
    /// стоит живой адрес аккаунта, а не порядковый номер.
    private var iconColor: Color {
        isSelected
            ? Color(red: 0.83, green: 0.42, blue: 0.30)
            : palette.secondaryText.color.opacity(0.55)
    }

    private var help: String {
        isSelected
            ? s.pick("Показан \(title)", "Showing \(title)")
            : s.pick("Показать \(title)", "Show \(title)")
    }
}
