import Foundation
import ClaudeWeekCore

let t = Harness()

runConfigTests(t)
runWeekWindowTests(t)
runPlanTests(t)
runFormattingTests(t)
runAlertTests(t)
await runLocalProviderTests(t)
await runOfficialProviderTests(t)
await runCodexProviderTests(t)
await runUpdaterTests(t)

t.report()
