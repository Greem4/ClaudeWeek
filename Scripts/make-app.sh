#!/bin/bash
# Собирает ClaudeWeek.app вручную: SwiftPM даёт только бинарь, бандл клеим сами.
# Xcode не требуется — хватает Command Line Tools.
#
#   ./Scripts/make-app.sh              бандл под свою архитектуру
#   UNIVERSAL=1 ./Scripts/make-app.sh  универсальный бандл (arm64 + x86_64)
#
# Универсальный собирается двумя проходами и склейкой lipo, а не одним
# `swift build --arch arm64 --arch x86_64`: тот требует полного Xcode, а
# отдельные проходы идут и на голых Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
APP="$ROOT/dist/ClaudeWeek.app"

cd "$ROOT"

SLICES=()
if [ "$UNIVERSAL" = "1" ]; then
    for ARCH in arm64 x86_64; do
        echo "==> swift build -c $CONFIG --arch $ARCH"
        swift build -c "$CONFIG" --arch "$ARCH" --product ClaudeWeekApp
        SLICE="$(swift build -c "$CONFIG" --arch "$ARCH" --product ClaudeWeekApp \
            --show-bin-path)/ClaudeWeekApp"
        [ -x "$SLICE" ] || { echo "не нашёл бинарь $ARCH: $SLICE" >&2; exit 1; }
        SLICES+=("$SLICE")
    done
else
    echo "==> swift build -c $CONFIG"
    swift build -c "$CONFIG" --product ClaudeWeekApp
    SLICE="$(swift build -c "$CONFIG" --product ClaudeWeekApp --show-bin-path)/ClaudeWeekApp"
    [ -x "$SLICE" ] || { echo "не нашёл бинарь: $SLICE" >&2; exit 1; }
    SLICES+=("$SLICE")
fi

echo "==> собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN="$APP/Contents/MacOS/ClaudeWeek"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$BIN"
    echo "==> архитектуры бандла: $(lipo -archs "$BIN")"
else
    cp "${SLICES[0]}" "$BIN"
fi
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
    echo "   иконку сделать не вышло — бандл без иконки" >&2
fi

echo "==> ad-hoc подпись"
codesign --force --sign - "$APP"

echo "готово: $APP"
