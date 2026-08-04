import Foundation
import Security

/// OAuth-креды Claude Code. Своей авторизации у ClaudeWeek нет: он берёт тот же
/// токен, которым уже пользуется Claude Code на этой машине, и потому видит
/// ровно тот аккаунт, что показывает `/usage`.
///
/// Форма записи (проверено на 2.1.221, 2026-08-04):
/// ```
/// { "claudeAiOauth": { "accessToken": "sk-ant-oat01-…", "expiresAt": 1786…,
///                      "refreshToken": …, "scopes": […],
///                      "subscriptionType": … },
///   "organizationUuid": … }
/// ```
public struct OAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    /// Момент истечения; nil — поля не было.
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }
}

public protocol CredentialsSource: Sendable {
    func load() throws -> OAuthCredentials
}

/// Читает запись Keychain, куда Claude Code кладёт свои OAuth-креды.
///
/// Обновлением токена ClaudeWeek не занимается принципиально: refresh-цикл —
/// дело Claude Code, а два процесса, наперегонки меняющие одну запись, теряют
/// токен. Мы только перечитываем запись перед каждым запросом, чтобы подхватить
/// уже обновлённый токен.
public struct KeychainCredentials: CredentialsSource {
    public static let defaultService = "Claude Code-credentials"

    private let service: String
    /// Запасной путь: на части установок креды лежат файлом, а не в Keychain.
    private let fileURL: URL

    public init(
        service: String = KeychainCredentials.defaultService,
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.service = service
        self.fileURL = fileURL
    }

    public func load() throws -> OAuthCredentials {
        let data = try rawData()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unauthorized
        }
        guard let token = KeychainCredentials.findToken(root), !token.isEmpty else {
            Log.warn("в записи Keychain «\(service)» нет accessToken")
            throw UsageError.unauthorized
        }

        let oauth = root["claudeAiOauth"] as? [String: Any]
        return OAuthCredentials(
            accessToken: token,
            expiresAt: KeychainCredentials.date(from: oauth?["expiresAt"]),
            subscriptionType: oauth?["subscriptionType"] as? String
        )
    }

    private func rawData() throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        if let data = try? Data(contentsOf: fileURL) {
            Log.debug("Keychain недоступен (\(status)), беру креды из \(fileURL.path)")
            return data
        }

        // errSecUserCanceled — пользователь закрыл системный диалог доступа:
        // отдельный текст, чтобы не выглядело как «вы не авторизованы».
        if status == errSecUserCanceled {
            throw UsageError.unavailable("доступ к Keychain отклонён")
        }
        Log.warn("не нашёл креды: Keychain «\(service)» → \(status), файла \(fileURL.path) тоже нет")
        throw UsageError.unauthorized
    }

    /// Ищем по обоим написаниям и на пару уровней вглубь: форма записи —
    /// не публичный контракт, и переименование поля не должно ронять виджет
    /// молча.
    public static func findToken(_ object: [String: Any], depth: Int = 0) -> String? {
        if depth > 3 { return nil }
        for key in ["accessToken", "access_token"] {
            if let token = object[key] as? String, !token.isEmpty { return token }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let token = findToken(nested, depth: depth + 1) {
                return token
            }
        }
        return nil
    }

    /// `expiresAt` приходит числом. Claude Code пишет миллисекунды, но полагаться
    /// на это нельзя: значения меньше 1e11 трактуем как секунды.
    public static func date(from value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }
}
