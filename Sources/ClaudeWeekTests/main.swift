import Foundation
import ClaudeWeekCore

let t = Harness()

runConfigTests(t)
runWeekWindowTests(t)
runPlanTests(t)
runFormattingTests(t)
await runLocalProviderTests(t)

t.report()
