import Foundation

/// Разбор меток времени из транскриптов и из ответа API.
///
/// Форматтер приходится держать в двух экземплярах: `.withFractionalSeconds`
/// разбирает только строки с долями секунды и возвращает nil на строке без них,
/// и наоборот. В транскриптах встречаются оба вида, а API отдаёт
/// `2026-08-07T12:00:00.357993+00:00` — с микросекундами и смещением вместо `Z`.
public enum ISO8601 {
    public static func parse(_ text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        return plain.date(from: text)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
