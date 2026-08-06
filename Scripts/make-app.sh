#!/bin/bash
# Собирает ClaudeWeek.app вручную: SwiftPM даёт только бинарь, бандл клеим сами.
# Xcode не требуется — хватает Command Line Tools.
#
#   ./Scripts/make-app.sh              бандл под свою архитектуру
#   ARCH=arm64 ./Scripts/make-app.sh   бандл под конкретную архитектуру (arm64|x86_64)
#   UNIVERSAL=1 ./Scripts/make-app.sh  универсальный бандл (arm64 + x86_64)
#
# Универсальный собирается двумя проходами и склейкой lipo, а не одним
# `swift build --arch arm64 --arch x86_64`: тот требует полного Xcode, а
# отдельные проходы идут и на голых Command Line Tools. По той же причине
# ARCH тоже даёт отдельный проход — просто без склейки, один срез как есть.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
ARCH="${ARCH:-}"
APP="$ROOT/dist/ClaudeWeek.app"

cd "$ROOT"

# Результат отдаёт через глобальный SLICE, а не печатью на stdout: вызов внутри
# `$(...)` увёл бы туда же вывод самой сборки, а `exit 1` при ненайденном
# бинаре погасил бы только подоболочку, и скрипт поехал бы дальше.
SLICE=""
build_slice() {
    local arch="$1"
    echo "==> swift build -c $CONFIG --arch $arch"
    swift build -c "$CONFIG" --arch "$arch" --product ClaudeWeekApp
    SLICE="$(swift build -c "$CONFIG" --arch "$arch" --product ClaudeWeekApp \
        --show-bin-path)/ClaudeWeekApp"
    [ -x "$SLICE" ] || { echo "не нашёл бинарь $arch: $SLICE" >&2; exit 1; }
}

SLICES=()
if [ "$UNIVERSAL" = "1" ]; then
    for A in arm64 x86_64; do
        build_slice "$A"
        SLICES+=("$SLICE")
    done
elif [ -n "$ARCH" ]; then
    build_slice "$ARCH"
    SLICES+=("$SLICE")
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
