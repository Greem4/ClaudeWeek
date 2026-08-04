#!/usr/bin/env swift

// Разведка официального источника (этап M3, шаг М2.1 плана).
//
// Берёт OAuth-токен Claude Code из Keychain, делает один GET на
// /api/oauth/usage и печатает ответ — по нему пишется декодер OfficialProvider.
//
// Токен не логируется, не пишется на диск и не выводится: в отчёт попадают
// только имена ключей записи Keychain, префикс токена и его длина.
//
// Запуск:  swift Scripts/probe-usage.swift
// macOS спросит доступ к записи Keychain — это ожидаемо.

import Foundation
import Security

let service = "Claude Code-credentials"
let endpoint = "https://api.anthropic.com/api/oauth/usage"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ошибка: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Keychain

/// Ищет generic password по service; account не задаём, чтобы не гадать.
func keychainData(service: String) -> (Data?, OSStatus) {
    var item: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &item)
    return (item as? Data, status)
}

func statusText(_ status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
}

var credentialsData: Data?
var origin = ""

let (data, status) = keychainData(service: service)
if let data {
    credentialsData = data
    origin = "Keychain «\(service)»"
} else {
    print("Keychain «\(service)»: \(statusText(status))")
    // Запасной путь: на части установок креды лежат файлом.
    let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
    if let fileData = try? Data(contentsOf: file) {
        credentialsData = fileData
        origin = "файл ~/.claude/.credentials.json"
    }
}

guard let credentialsData else {
    fail("не нашёл OAuth-креды ни в Keychain, ни в ~/.claude/.credentials.json. Выполните `claude` и авторизуйтесь.")
}

print("источник кред: \(origin), \(credentialsData.count) байт")

// MARK: - Разбор кред

guard let root = try? JSONSerialization.jsonObject(with: credentialsData) as? [String: Any] else {
    fail("содержимое записи — не JSON-объект")
}

/// Печатает форму объекта: только ключи и типы значений, без самих значений.
func describe(_ object: [String: Any], indent: String = "  ") {
    for key in object.keys.sorted() {
        let value = object[key]
        switch value {
        case let nested as [String: Any]:
            print("\(indent)\(key): {")
            describe(nested, indent: indent + "  ")
            print("\(indent)}")
        case is String:
            print("\(indent)\(key): String")
        case is NSNumber:
            print("\(indent)\(key): Number")
        case let array as [Any]:
            print("\(indent)\(key): Array(\(array.count))")
        default:
            print("\(indent)\(key): \(value.map { String(describing: type(of: $0)) } ?? "null")")
        }
    }
}

print("форма записи (только ключи, значения скрыты):")
describe(root)

/// Токен ищем по вероятным путям, а не по одному угаданному.
func findAccessToken(_ object: [String: Any], depth: Int = 0) -> String? {
    if depth > 3 { return nil }
    for key in ["accessToken", "access_token"] {
        if let token = object[key] as? String, !token.isEmpty { return token }
    }
    for value in object.values {
        if let nested = value as? [String: Any], let token = findAccessToken(nested, depth: depth + 1) {
            return token
        }
    }
    return nil
}

guard let token = findAccessToken(root) else {
    fail("в записи нет поля accessToken — сверьте форму выше с ожиданиями")
}

let prefix = String(token.prefix(13))
print("токен найден: префикс «\(prefix)…», длина \(token.count)")

if let expiresAt = (root["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? Double {
    let date = Date(timeIntervalSince1970: expiresAt > 1e11 ? expiresAt / 1000 : expiresAt)
    let expired = date < Date()
    print("срок действия: \(ISO8601DateFormatter().string(from: date))\(expired ? "  ← ИСТЁК, запустите claude для обновления" : "")")
}

// MARK: - Запрос

// Набор вариантов: неизвестно, требует ли эндпоинт beta-заголовок.
// Первый успешный ответ и есть искомая форма.
let variants: [(String, [String: String])] = [
    ("только Bearer", [:]),
    ("Bearer + anthropic-beta: oauth-2025-04-20", ["anthropic-beta": "oauth-2025-04-20"]),
    ("Bearer + anthropic-version: 2023-06-01", ["anthropic-version": "2023-06-01"]),
]

for (name, extraHeaders) in variants {
    var request = URLRequest(url: URL(string: endpoint)!)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("claude-week-probe/0.1", forHTTPHeaderField: "User-Agent")
    for (field, value) in extraHeaders {
        request.setValue(value, forHTTPHeaderField: field)
    }

    print("\n── попытка: \(name)")

    let semaphore = DispatchSemaphore(value: 0)
    var body: Data?
    var code = 0
    var failure: Error?

    URLSession.shared.dataTask(with: request) { responseData, response, error in
        body = responseData
        code = (response as? HTTPURLResponse)?.statusCode ?? 0
        failure = error
        semaphore.signal()
    }.resume()

    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        print("   таймаут")
        continue
    }
    if let failure {
        print("   сеть: \(failure.localizedDescription)")
        continue
    }

    print("   HTTP \(code)")
    guard let body, !body.isEmpty else {
        print("   пустое тело")
        continue
    }

    // Тело безопасно печатать целиком: там проценты и даты, не секреты.
    if let json = try? JSONSerialization.jsonObject(with: body),
       let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: pretty, encoding: .utf8) {
        print(text)
    } else {
        print(String(data: body, encoding: .utf8) ?? "<не текст>")
    }

    if code == 200 {
        print("\n✓ рабочий набор заголовков: \(name)")
        exit(0)
    }
    if code == 401 {
        print("   401 — токен протух. Запустите `claude`, дайте ему обновить токен, повторите.")
    }
}

fail("ни один вариант не дал 200")
