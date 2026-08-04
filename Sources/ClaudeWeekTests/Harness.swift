import Foundation

/// Минимальный раннер проверок: XCTest и swift-testing без Xcode недоступны.
/// Ненулевой код возврата = падение.
final class Harness {
    private var passed = 0
    private var failures: [String] = []
    private var group = ""

    func suite(_ name: String, _ body: () throws -> Void) {
        group = name
        do {
            try body()
        } catch {
            failures.append("\(name): бросило исключение — \(error)")
        }
        group = ""
    }

    func check(_ condition: Bool, _ what: String) {
        if condition {
            passed += 1
        } else {
            failures.append("\(group) → \(what)")
        }
    }

    func equal<T: Equatable>(_ got: T, _ want: T, _ what: String) {
        if got == want {
            passed += 1
        } else {
            failures.append("\(group) → \(what): получили \(got), ждали \(want)")
        }
    }

    /// Сравнение с допуском — для процентов и долей, где точное равенство
    /// Double бессмысленно.
    func close(_ got: Double, _ want: Double, _ what: String, tolerance: Double = 1e-9) {
        if abs(got - want) <= tolerance {
            passed += 1
        } else {
            failures.append("\(group) → \(what): получили \(got), ждали \(want) ±\(tolerance)")
        }
    }

    func fail(_ what: String) {
        failures.append("\(group) → \(what)")
    }

    func report() -> Never {
        if failures.isEmpty {
            print("✓ проверок пройдено: \(passed)")
            exit(0)
        }
        print("✗ провалено: \(failures.count), пройдено: \(passed)\n")
        for failure in failures {
            print("  • \(failure)")
        }
        exit(1)
    }
}
