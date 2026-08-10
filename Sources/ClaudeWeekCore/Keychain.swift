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

    /// Сначала `/usr/bin/security`, и только потом свой запрос к Keychain —
    /// порядок выбран по тому, кто из них не приводит к диалогу.
    ///
    /// Доступ к записи macOS проверяет дважды: по списку доверенных приложений
    /// и по partition list. В первом ClaudeWeek держится по сертификату подписи
    /// и стоит прочно, а во втором — только по cdhash сборки: у
    /// самоподписанного сертификата нет Team ID, и пинить приложение больше не
    /// по чему. Вдобавок partition list обнуляется при каждой перезаписи
    /// записи, а Claude Code переписывает её на каждом обновлении токена —
    /// примерно раз в сутки. Отсюда и дневной диалог: «Всегда разрешать» живёт
    /// ровно до следующего обновления.
    ///
    /// Спасает то, чем Claude Code пишет токен: `/usr/bin/security` остаётся и
    /// в списке доверенных, и в partition list (`apple-tool:`) — их
    /// восстанавливает сама же запись токена. Читая запись этой утилитой, мы
    /// проходим обе проверки всегда, а не до ближайшего обновления.
    private func rawData() throws -> Data {
        if let data = KeychainCredentials.readViaSecurityTool(service: service) {
            return data
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Диалог не показываем ни при каких обстоятельствах: панель
            // обновляется в фоне раз в минуту, и модальное окно посреди чужой
            // работы — худший исход неудачного чтения. Нет доступа без
            // вопроса — уходим на локальную оценку.
            //
            // Ключи помечены устаревшими с macOS 11, и предупреждение сборки
            // остаётся намеренно: предложенная замена — LAContext с
            // interactionNotAllowed — диалог доступа к записи файловой связки
            // не подавляет (проверено: запрос с ней встаёт на диалоге
            // насмерть, а с этими ключами возвращает ошибку и уходит).
            //
            // Строгая сборка о него больше не спотыкается: группу
            // DeprecatedDeclaration CI понижает до предупреждения флагом
            // -Wwarning. Понижение общее на весь пакет, так что новое
            // устаревшее место здесь никто не поймает за руку — проверяйте
            // такие вызовы глазами.
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ] as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        if let data = try? Data(contentsOf: fileURL) {
            Log.debug("Keychain недоступен (\(status)), беру креды из \(fileURL.path)")
            return data
        }

        // errSecInteractionNotAllowed — доступ есть только через диалог,
        // который мы запретили; errSecUserCanceled — пользователь закрыл
        // диалог сам. Оба случая не про «вы не авторизованы», и текст у них
        // отдельный.
        if status == errSecInteractionNotAllowed || status == errSecUserCanceled {
            throw UsageError.unavailable("доступ к записи Keychain не разрешён")
        }
        Log.warn("не нашёл креды: Keychain «\(service)» → \(status), файла \(fileURL.path) тоже нет")
        throw UsageError.unauthorized
    }

    /// Читает запись утилитой `security`. nil — записи нет, доступа нет или
    /// утилита не запустилась; разбираться, что именно, будет вызывающий по
    /// своим запасным путям.
    static func readViaSecurityTool(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Ошибки утилиты нам не нужны, а смешавшись с паролем в одном потоке,
        // они попали бы на разбор как токен.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.debug("security не запустился: \(error.localizedDescription)")
            return nil
        }

        // Если доступ всё-таки спросят диалогом, утилита встанет на нём
        // насмерть, а с ней и обновление панели. Ждём не дольше пяти секунд:
        // непрочитанный токен переживём, повисший виджет — нет.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard process.terminationStatus == 0 else { return nil }
        // Пароль печатается строкой с переводом в конце.
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
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
