# Changelog

All notable changes to ClaudeWeek are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for 0.1.0–0.1.7 were reconstructed from git history and release notes —
the file was started during 0.1.8 development. From 0.1.8 on, every change is
written here in the same pull request that makes it, under `Unreleased`; the
heading is renamed to the version once the release goes out. Release notes on
GitHub are still generated from commit subjects by `release.yml`, so this file
is the place for the shorter, human-facing story.

## [Unreleased]

### Added

- Notifications when spend crosses a threshold you set: two thresholds per
  limit — 80 % and 95 % for the week, 75 % and 95 % for the 5-hour session —
  configured on a new "Уведомления" tab, with a "Показать пример" button in each
  section that sends the real banner on demand. Each limit can be silenced on
  its own, and one switch turns all notifications off. The banner is two lines —
  how much is spent and how long until the reset — and *which* limit it is comes
  from the artwork rather than a third line of text: the 5-hour session arrives
  as an arc filled to the spend, the weekly limit as a red number, the same
  language the menu bar icon speaks. Three rules keep it quiet: one banner per
  threshold per limit window, only on the way up, and no two banners closer than
  five minutes. What has been said is stored in
  `~/.config/claude-week/alerts.json`, so a restart mid-week does not repeat it.
  The decision logic and the wording both live in the core (`AlertPlanner`,
  `LimitAlert.message`) and are covered by tests.
- `--screenshot` now also renders the notifications tab
  (`settings-notifications-light.png`, `settings-notifications-dark.png`). Form
  views are captured through a real window: `ImageRenderer` returns an empty
  rectangle for a grouped `Form`, and an inactive window would draw every switch
  grey, making enabled settings look off.
- `Formatting.longDuration` — the same interval in words ("2 дня 4 часа",
  "1 час 12 минут"), with Russian pluralisation. The panel keeps the short form;
  a banner has room for the long one.
- Model breakdown in the panel: clicking the percentage — on a day row or on
  the 5-hour session row — replaces the day rows with one row per model (Opus,
  Sonnet, Haiku), each with the same kind of bar showing its share of the
  week's spend. Clicking the percentage again brings the week back. Every share
  carries a `≈`, and a line under the rows marks the whole thing as a rough
  local estimate. Hovering a row gives the rest: share of the weekly limit,
  input / output / cache tokens, reply count and weighted cost.
- `--screenshot` now also renders the panel in that state
  (`panel-models-light.png`, `panel-models-dark.png`).

### Changed

- The update status on the About tab now names the version and the day it was
  checked: "у вас последняя — 0.1.7, проверено ВТ в 14:23". Previously it gave
  the time only, which read as "today" for a check made two days ago.
- Usage index schema bumped to 2: records now carry the model family and token
  counts, which is what the breakdown is built from. The old index cannot be
  migrated and is rebuilt from transcripts on first run — one longer scan, then
  business as usual. A stale index is now recognised by its version before it is
  parsed, so a schema change no longer looks like a corrupted file in the log.

### Notes

- Notifications are on out of the box: a feature that stays silent until you
  find its tab does not do the job it was added for. macOS asks for permission
  once, on the first launch of the new version; if it is refused, the tab says
  so and offers the only place the ban can be lifted — System Settings. A build
  run straight from `swift run` has no notifications at all: macOS identifies an
  app by its bundle, and there isn't one.
- Session notifications need the official source. The local estimate does not
  compute the 5-hour percentage at all, so offline there is nothing to warn
  about — and an expired session stays quiet rather than warning off a cached
  number that reset hours ago.
- The breakdown is computed from local transcripts in `~/.claude/projects` and
  weighted by model prices, so it is an estimate — which the panel states
  plainly while the breakdown is on screen. The official `/api/oauth/usage`
  endpoint reports one number for the whole week and says nothing about
  models — see [docs/API.md](docs/API.md). The week total in the footer is
  still the exact figure from the server.

## [0.1.7] — 2026-08-15

### Added

- Releases now go out on pull request merge: `release-on-merge.yml` bumps the
  version, tags it and starts the release build. PR labels pick the part —
  `версия:мажор`, `версия:минор`, patch by default, `без-релиза` to skip.
  Documentation-only merges do not produce a release.
- `scripts/bump-version.sh` for raising the version in `Version.swift`.

## [0.1.6] — 2026-08-10

### Changed

- Release builds moved to the `macos-26` runner: on macOS 26 the look of an app
  is decided by the SDK it was linked with, and builds from the older runner
  looked dated next to locally built ones. The workflow now fails if the SDK
  turns out to be older than 26.
- Factory defaults changed to the settings the app had actually been used with;
  README screenshots were regenerated to match.

### Fixed

- Strict builds no longer break on deprecated Keychain keys.

## [0.1.5] — 2026-08-10

### Fixed

- The Keychain access prompt no longer comes back after every update: the token
  is read through `/usr/bin/security` rather than a direct Keychain query, so
  the permission survives the token being refreshed by Claude Code.

## [0.1.4] — 2026-08-09

### Added

- Release builds are signed with a stable project certificate
  (`scripts/signing-cert.sh`). The signature proves nothing about origin — it is
  there so the designated requirement stays the same between versions and macOS
  keeps the Keychain permission across updates. Without the secrets configured
  the build falls back to ad-hoc signing.

### Fixed

- Release workflow no longer fails outright when checking for signing secrets:
  the `secrets` context is not available in a step condition, and GitHub
  rejected the whole file.

## [0.1.3] — 2026-08-08

### Added

- In-app updates: the app checks GitHub releases (at startup and once a day),
  offers the new version, downloads the disk image, verifies its checksum and
  replaces the running bundle. Installing and relaunching stay manual.
- Launch at login moved from the menu into Settings, where the rest of the
  settings live.

## [0.1.2] — 2026-08-07

### Added

- Install scripts: `install.sh`, `make-app.sh`, `make-dmg.sh`, `uninstall.sh`,
  plus the `probe-usage` and `probe-panel` probes.
- Launch at login through a launchd agent set up by the installer.
- Choice of which limit fills the menu bar ring arc and which one sits as the
  number inside it.

### Changed

- Menu bar colour now follows spend thresholds rather than pace, so the icon no
  longer turns amber before any meaningful spend.

## [0.1.1] — 2026-08-07

### Fixed

- The panel opens on the first click when the desktop has just been switched.
- The week resets to zero immediately after the reset moment instead of showing
  the exhausted limit until the next scheduled poll.
- The percentage column is wide enough not to wrap.

### Added

- A release can be rebuilt by hand from its tag (Actions → Release → Run
  workflow), for when a tag push misses Actions entirely.

## [0.1.0] — 2026-08-06

First release: the weekly Claude Code limit in the menu bar — panel with the
seven days of the week window, the 5-hour session, official numbers from
`/api/oauth/usage` with a local estimate as fallback, settings window, MIT
licence, CI, and a disk image built by tag for Apple Silicon.

[Unreleased]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Greem4/ClaudeWeek/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Greem4/ClaudeWeek/releases/tag/v0.1.0
