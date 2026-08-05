#!/bin/bash
# Собирает ClaudeWeek.app вручную: SwiftPM даёт только бинарь, бандл клеим сами.
# Xcode не требуется — хватает Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/ClaudeWeek.app"

cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product ClaudeWeekApp

BIN="$(swift build -c "$CONFIG" --product ClaudeWeekApp --show-bin-path)/ClaudeWeekApp"
[ -x "$BIN" ] || { echo "не нашёл бинарь: $BIN" >&2; exit 1; }

echo "==> собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ClaudeWeek"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Версия у программы одна — та, что в Version.swift; в plist она попадает
# отсюда, а не переписывается руками во втором месте.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/ClaudeWeekCore/Version.swift")"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$APP/Contents/Info.plist" > /dev/null
    echo "==> версия бандла: $VERSION"
else
    echo "   не разобрал версию из Version.swift — в plist осталась прежняя" >&2
fi

echo "==> иконка"
ICONSET_DIR="$ROOT/dist/icon"
if "$BIN" --icon "$ICONSET_DIR" > /dev/null && command -v iconutil > /dev/null; then
    iconutil -c icns "$ICONSET_DIR/ClaudeWeek.iconset" \
        -o "$APP/Contents/Resources/ClaudeWeek.icns"
    rm -rf "$ICONSET_DIR"
else
    echo "   iconutil не найден — бандл без иконки" >&2
fi

echo "==> ad-hoc подпись"
codesign --force --sign - "$APP"

echo "готово: $APP"
