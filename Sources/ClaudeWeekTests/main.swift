import Foundation
import ClaudeWeekCore

let t = Harness()

runConfigTests(t)
runAccountTests(t)
runWeekWindowTests(t)
runPlanTests(t)
runFormattingTests(t)
runAlertTests(t)
await runLocalProviderTests(t)
await runOfficialProviderTests(t)
await runUpdaterTests(t)

t.report()
