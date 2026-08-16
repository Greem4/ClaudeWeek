#!/bin/bash
# Поднимает версию проекта на один разряд.
#
#   ./scripts/bump-version.sh patch            0.1.6 → 0.1.7
#   ./scripts/bump-version.sh minor            0.1.6 → 0.2.0
#   ./scripts/bump-version.sh major            0.1.6 → 1.0.0
#   ./scripts/bump-version.sh keep             версию не трогать, только показать
#   ./scripts/bump-version.sh patch --dry-run  посчитать, ничего не записывая
#
# Разряд считает до 99 и переносится в старший: 0.1.99 → 0.2.0, 0.99.0 → 1.0.0,
# 0.99.99 → 1.0.0. Двузначные числа при этом законны — 0.1.10 идёт после 0.1.9,
# и в приложении версии сравниваются числами, а не строками (см. Updater.swift).
#
# Единственный источник версии — Version.swift: оттуда её берёт make-app.sh для
# Info.plist, оттуда же release.yml сверяет тег. Поэтому скрипт правит один
# файл и больше ничего: не коммитит, не тегирует, не пушит — это делает тот,
# кто вызвал (workflow release-on-merge.yml или человек руками).
#
# Новая версия печатается в stdout последней строкой, всё остальное уходит в
# stderr: вызывающий читает её как `$(./scripts/bump-version.sh patch | tail -1)`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/Sources/ClaudeWeekCore/Version.swift"

KIND="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

case "$KIND" in
    major|minor|patch|keep) ;;
    *)
        echo "нужен разряд: major | minor | patch | keep" >&2
        exit 1
        ;;
esac

CURRENT="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$VERSION_FILE")"
if [ -z "$CURRENT" ]; then
    echo "в $VERSION_FILE нет строки с static let version" >&2
    exit 1
fi
if ! [[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "версия должна быть вида X.Y.Z, сейчас «$CURRENT»" >&2
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "$KIND" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

# Больше 99 в разряде не бывает: переполнение уходит в старший, как в счётчике.
# Патч, добравшийся до сотни на 0.99.99, поднимает и минор, и мажор — отсюда
# две проверки подряд, а не одна.
if [ "$PATCH" -gt 99 ]; then PATCH=0; MINOR=$((MINOR + 1)); fi
if [ "$MINOR" -gt 99 ]; then MINOR=0; MAJOR=$((MAJOR + 1)); fi

VERSION="$MAJOR.$MINOR.$PATCH"
echo "версия: $CURRENT → $VERSION ($KIND)" >&2

if [ "$DRY_RUN" -eq 0 ] && [ "$VERSION" != "$CURRENT" ]; then
    # Через временный файл, а не `sed -i`: у BSD sed на macOS и у GNU sed на
    # раннере ubuntu разный синтаксис этого ключа, и скрипт запускается там и там.
    TMP="$(mktemp)"
    sed "s/static let version = \"$CURRENT\"/static let version = \"$VERSION\"/" \
        "$VERSION_FILE" > "$TMP"
    mv "$TMP" "$VERSION_FILE"
fi

echo "$VERSION"
