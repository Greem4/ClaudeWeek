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
        HStack(spacing: 4) {
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
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? palette.primaryText.color : palette.secondaryText.color)
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(isSelected ? palette.track.color : .clear)
                }
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? palette.plan.color : palette.separator.color,
                        lineWidth: isSelected ? 1.5 : 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch account {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var help: String {
        let title = account.title(s.lang)
        return isSelected
            ? s.pick("Показан \(title)", "Showing \(title)")
            : s.pick("Показать \(title)", "Show \(title)")
    }
}
