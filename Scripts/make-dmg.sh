#!/bin/bash
# Пакует ClaudeWeek.app в dist/ClaudeWeek-<версия>.dmg — тот самый файл,
# который уезжает в GitHub Releases.
#
#   ./Scripts/make-dmg.sh              собрать бандл и упаковать
#   UNIVERSAL=1 ./Scripts/make-dmg.sh  универсальный бандл (arm64 + x86_64)
#   SKIP_BUILD=1 ./Scripts/make-dmg.sh упаковать уже собранный dist/ClaudeWeek.app
#
# Раскладку окна образа Finder'ом не рисуем: это делается AppleScript'ом,
# который на машине без графической сессии (то есть в CI) отваливается.
# Внутри — приложение и ярлык /Applications, перетащить одно на другое.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ClaudeWeek.app"
VOLNAME="ClaudeWeek"

cd "$ROOT"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    "$ROOT/Scripts/make-app.sh"
fi
[ -d "$APP" ] || { echo "не нашёл бандл: $APP (сначала Scripts/make-app.sh)" >&2; exit 1; }

# Версию берём из готового бандла, а не из исходников: в образ должно попасть
# ровно то, что лежит в .app, даже если Version.swift успели поправить.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/ClaudeWeek-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> собираю содержимое образа"
cp -R "$APP" "$STAGE/ClaudeWeek.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

echo "готово: $DMG"
shasum -a 256 "$DMG"
