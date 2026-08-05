import Foundation
import Security

/// Токен, вставленный руками в настройках ClaudeWeek.
///
/// Живёт в собственной записи Keychain, а не в `config.json`: конфиг лежит
/// открытым файлом, его копируют в бэкапы и показывают в чужих скриншотах —
/// токену там не место. Запись Claude Code при этом не трогается вовсе:
/// читать чужие креды можно, писать в них — нет.
public enum ManualToken {
    public static let service = "ClaudeWeek-token"
    private static let account = "oauth"

    public static func load() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Пустая строка стирает запись: «сохранить пустое поле» и «удалить
    /// токен» — одно и то же намерение.
    @discardableResult
    public static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let data = Data(trimmed.utf8)

        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if update == errSecSuccess { return true }

        var attributes = query
        attributes[kSecValueData] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.warn("не сохранил токен в Keychain: \(status)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    public static func delete() -> Bool {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static var exists: Bool { load() != nil }

    /// Проверка формы, а не действительности: настоящий ответ даст только
    /// запрос к API, но опечатку видно и так.
    public static func looksLikeOAuthToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-oat") && trimmed.count > 20
    }
}

/// Креды из ручного токена. `expiresAt` неизвестен — за сроком следит тот,
/// кто токен выдал; наше дело — честно получить 401 и уйти на локальную оценку.
public struct ManualCredentials: CredentialsSource {
    public init() {}

    public func load() throws -> OAuthCredentials {
        guard let token = ManualToken.load() else {
            Log.warn("выбран ручной токен, но его нет в Keychain")
            throw UsageError.unauthorized
        }
        return OAuthCredentials(accessToken: token, expiresAt: nil, subscriptionType: nil)
    }
}

public extension AuthSource {
    /// Источник кредов, соответствующий выбору в настройках.
    var credentials: CredentialsSource {
        switch self {
        case .claudeCode: KeychainCredentials()
        case .manual: ManualCredentials()
        }
    }

    var title: String {
        switch self {
        case .claudeCode: "Из Claude Code"
        case .manual: "Свой токен"
        }
    }
}
