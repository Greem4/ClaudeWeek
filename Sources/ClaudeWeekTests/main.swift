import Foundation
import ClaudeWeekCore

let t = Harness()

t.suite("каркас") {
    t.equal(ClaudeWeek.bundleIdentifier, "com.greem4.claudeweek", "идентификатор бандла")
}

t.report()
