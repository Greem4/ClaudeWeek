import AppKit
import SwiftUI
import ClaudeWeekCore

/// Две компактные кнопки в заголовке панели. Выбор хранится в конфиге, но
/// сам вид получает только значение и действие — отдельного локального
/// состояния, способного разойтись с реально загруженным аккаунтом, нет.
struct AccountPicker: View {
    let selection: UsageAccount
    let onSelect: (UsageAccount) -> Void

    @Environment(\.strings) private var s

    var body: some View {
        HStack(spacing: 1) {
            ForEach(UsageAccount.allCases, id: \.self) { account in
                AccountButton(
                    account: account,
                    isSelected: account == selection,
                    onSelect: onSelect
                )
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.pick("Аккаунт", "Account"))
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
            VStack(spacing: 1) {
                providerIcon

                Capsule()
                    .fill(palette.plan.color)
                    .frame(width: 12, height: 1.5)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: 22, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? palette.track.color : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
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

    /// У поставщиков нет подходящих SF Symbols: загружаем их контуры как
    /// обычные PNG, чтобы не подменять узнаваемый знак абстрактной звездой
    /// или значком исходного кода.
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
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondaryText.color)
                .frame(width: 14, height: 14)
        }
    }

    private func template(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }

    private var iconColor: Color {
        switch account {
        case .claude:
            return isSelected ? Color(red: 0.87, green: 0.36, blue: 0.10) : palette.secondaryText.color
        case .codex:
            return isSelected ? palette.primaryText.color : palette.secondaryText.color
        }
    }

    private var help: String {
        let title = account.title(s.lang)
        return isSelected
            ? s.pick("Показан \(title)", "Showing \(title)")
            : s.pick("Показать \(title)", "Show \(title)")
    }
}
