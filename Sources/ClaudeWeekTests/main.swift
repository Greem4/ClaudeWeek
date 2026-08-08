import Foundation
import ClaudeWeekCore

let t = Harness()

runConfigTests(t)
runWeekWindowTests(t)
runPlanTests(t)
runFormattingTests(t)
await runLocalProviderTests(t)
await runOfficialProviderTests(t)
await runUpdaterTests(t)

t.report()
