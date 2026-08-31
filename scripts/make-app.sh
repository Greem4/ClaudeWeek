#!/bin/bash
# Собирает ClaudeWeek.app вручную: SwiftPM даёт только бинарь, бандл клеим сами.
# Xcode не требуется — хватает Command Line Tools.
#
#   ./scripts/make-app.sh              бандл под свою архитектуру
#   ARCH=arm64 ./scripts/make-app.sh   бандл под конкретную архитектуру (arm64|x86_64)
#   UNIVERSAL=1 ./scripts/make-app.sh  универсальный бандл (arm64 + x86_64)
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
BIN_DIR=""
build_slice() {
    local arch="$1"
    echo "==> swift build -c $CONFIG --arch $arch"
    swift build -c "$CONFIG" --arch "$arch" --product ClaudeWeekApp
    BIN_DIR="$(swift build -c "$CONFIG" --arch "$arch" --product ClaudeWeekApp \
        --show-bin-path)"
    SLICE="$BIN_DIR/ClaudeWeekApp"
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
    BIN_DIR="$(swift build -c "$CONFIG" --product ClaudeWeekApp --show-bin-path)"
    SLICE="$BIN_DIR/ClaudeWeekApp"
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

# Ресурсный бандл SwiftPM со знаком Claude для переключателя аккаунтов. Без
# него `Bundle.module` в приложении обрывается fatalError'ом ещё до отрисовки
# панели, поэтому его отсутствие — ошибка сборки, а не пропущенное украшение.
# У универсального бандла срезы кладут одинаковые ресурсы, хватает любого из
# проходов.
RES_BUNDLE="$BIN_DIR/ClaudeWeek_ClaudeWeekApp.bundle"
if [ -d "$RES_BUNDLE" ]; then
    rm -rf "$APP/Contents/Resources/$(basename "$RES_BUNDLE")"
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
    echo "==> ресурсы: $(basename "$RES_BUNDLE")"
else
    echo "не нашёл ресурсный бандл: $RES_BUNDLE" >&2
    exit 1
fi

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

echo "==> подпись"
# Разрешение Keychain на запись «Claude Code-credentials» macOS привязывает к
# designated requirement бандла. У ad-hoc подписи requirement — cdhash, свой у
# каждой сборки, и разрешение слетает при каждой пересборке. Постоянный
# сертификат даёт requirement по identifier и сертификату: один и тот же всегда.
IDENTITY="${CLAUDEWEEK_SIGN_IDENTITY:-ClaudeWeek Signing}"
HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }')"
if [ -n "$HASH" ]; then
    codesign --force --sign "$HASH" "$APP"
    echo "    сертификатом «${IDENTITY}»"
else
    codesign --force --sign - "$APP"
    echo "    ad-hoc: постоянного сертификата «${IDENTITY}» в связке нет"
    echo "    из-за этого macOS снова спросит доступ к токену Claude Code —"
    echo "    заводится один раз: ./scripts/signing-cert.sh"
fi

# Requirement печатаем всегда: это ровно то, к чему привязано разрешение на
# токен, и заметить его смену на сборке дешевле, чем по вернувшемуся диалогу.
# Решётку перед `designated` codesign ставит только у ad-hoc подписи — у
# подписанной сертификатом строка идёт без неё, и точный шаблон молчал.
codesign -d -r- "$APP" 2>&1 | sed -n 's/^#\{0,1\} *designated => /    requirement: /p'

echo "готово: $APP"
