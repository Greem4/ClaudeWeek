#!/bin/bash
# Пакует ClaudeWeek.app в dist/ClaudeWeek-<версия>[-архитектура].dmg — тот
# самый файл, который уезжает в GitHub Releases.
#
#   ./scripts/make-dmg.sh              собрать бандл и упаковать
#   ARCH=arm64 ./scripts/make-dmg.sh   бандл под arm64 → ...-arm64.dmg
#   ARCH=x86_64 ./scripts/make-dmg.sh  бандл под x86_64 → ...-x86_64.dmg
#   UNIVERSAL=1 ./scripts/make-dmg.sh  универсальный бандл, суффикса нет
#   SKIP_BUILD=1 ./scripts/make-dmg.sh упаковать уже собранный dist/ClaudeWeek.app
#
# Архитектуру для суффикса берём не из ARCH, а из готового бинаря (`lipo
# -archs`): у SKIP_BUILD=1 своего ARCH может не быть, а образ всё равно
# должен называться по правде, а не по тому, что попросили собрать.
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
    "$ROOT/scripts/make-app.sh"
fi
[ -d "$APP" ] || { echo "не нашёл бандл: $APP (сначала scripts/make-app.sh)" >&2; exit 1; }

# Версию берём из готового бандла, а не из исходников: в образ должно попасть
# ровно то, что лежит в .app, даже если Version.swift успели поправить.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")"

BUNDLE_ARCHES="$(lipo -archs "$APP/Contents/MacOS/ClaudeWeek")"
case "$BUNDLE_ARCHES" in
    "arm64 x86_64"|"x86_64 arm64") SUFFIX="" ;;
    "arm64")                       SUFFIX="-arm64" ;;
    "x86_64")                      SUFFIX="-x86_64" ;;
    *)                             SUFFIX="-${BUNDLE_ARCHES// /-}" ;;
esac
DMG="$ROOT/dist/ClaudeWeek-$VERSION$SUFFIX.dmg"

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
