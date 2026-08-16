#!/bin/bash
# Работа с CHANGELOG.md: закрыть версию и достать её раздел.
#
#   ./scripts/changelog.sh release 0.1.11        «Не выпущено» → «[0.1.11] — сегодня»
#   ./scripts/changelog.sh release 0.1.11 --dry-run   показать, ничего не записывая
#   ./scripts/changelog.sh section 0.1.11        напечатать раздел версии
#
# Зачем: раздел «Не выпущено» переименовывали руками, и версия 0.1.10 уехала в
# релиз, оставив свои записи под этим заголовком. Теперь заголовок закрывает
# release-on-merge.yml тем же шагом, что поднимает версию, а release.yml берёт
# отсюда готовый текст для заметок к релизу — журнал перестаёт быть отдельной
# обязанностью, о которой надо помнить.
#
# `release` идемпотентна: раздел с такой версией уже есть — файл не трогается,
# повторный запуск workflow ничего не портит. Пустое «Не выпущено» тоже не
# закрывается: пустой раздел в журнале хуже отсутствующего, а release.yml на
# такой случай соберёт заметки из сообщений коммитов, как и раньше.
#
# `section` печатает тело раздела без заголовка. Не найдя версию, отдаёт
# «Не выпущено»: так заметки собираются даже у релиза, выпущенного руками по
# тегу, до того как версия в журнале закрыта. Нечего отдать — выход 1 и пустой
# stdout, вызывающий решает сам.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
UNRELEASED='Не выпущено'

COMMAND="${1:-}"
VERSION="${2:-}"

case "$COMMAND" in
    release|section) ;;
    *)
        echo "нужна команда: release <версия> [--dry-run] | section <версия>" >&2
        exit 1
        ;;
esac

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "версия должна быть вида X.Y.Z, сейчас «${VERSION}»" >&2
    exit 1
fi

# Тело раздела: всё между его заголовком и следующим `## ` или блоком ссылок
# внизу файла, без пустых строк по краям.
section_body() {
    awk -v want="$1" '
        /^## \[/ {
            name = $0
            sub(/^## \[/, "", name)
            sub(/\].*/, "", name)
            inside = (name == want)
            next
        }
        /^\[[^]]+\]: / { inside = 0 }
        inside { line[++n] = $0; if (NF) last = n }
        END {
            first = 1
            while (first <= last && line[first] == "") first++
            for (i = first; i <= last; i++) print line[i]
        }
    ' "$CHANGELOG"
}

if [ "$COMMAND" = "section" ]; then
    BODY="$(section_body "$VERSION")"
    if [ -z "$BODY" ]; then
        echo "раздела [$VERSION] в журнале нет — беру «${UNRELEASED}»" >&2
        BODY="$(section_body "$UNRELEASED")"
    fi
    if [ -z "$BODY" ]; then
        echo "в журнале нечего взять: ни [$VERSION], ни непустого «${UNRELEASED}»" >&2
        exit 1
    fi
    printf '%s\n' "$BODY"
    exit 0
fi

DRY_RUN=0
[ "${3:-}" = "--dry-run" ] && DRY_RUN=1
DATE="$(date +%F)"

if grep -q "^## \[$VERSION\]" "$CHANGELOG"; then
    echo "раздел [$VERSION] в журнале уже закрыт — не трогаю" >&2
    exit 0
fi

if ! grep -q "^## \[$UNRELEASED\]" "$CHANGELOG"; then
    echo "::warning::в журнале нет раздела «${UNRELEASED}» — закрывать нечего" >&2
    exit 0
fi

if [ -z "$(section_body "$UNRELEASED")" ]; then
    echo "::warning::раздел «${UNRELEASED}» пуст — версия $VERSION выйдет без записи в журнале" >&2
    exit 0
fi

# Прошлая версия нужна для ссылки сравнения; берём её из той же ссылки внизу
# файла (`compare/v0.1.10...HEAD`), а не из тегов — журнал должен закрываться и
# там, где истории git под рукой нет.
PREV="$(sed -n "s|^\[$UNRELEASED\]: .*/compare/v\([0-9.]*\)\.\.\.HEAD *$|\1|p" "$CHANGELOG" | tail -1)"

TMP="$(mktemp)"
awk -v version="$VERSION" -v date="$DATE" -v prev="$PREV" -v unreleased="$UNRELEASED" '
    # Заголовок раздела: над ним заводим новый пустой «Не выпущено».
    $0 == "## [" unreleased "]" {
        print "## [" unreleased "]"
        print ""
        print "## [" version "] — " date
        next
    }
    # Ссылка внизу: «Не выпущено» теперь считается от свежего тега, а под ней
    # встаёт строка самой версии.
    $0 ~ "^\\[" unreleased "\\]: " {
        line = $0
        if (prev != "") {
            sub("v" prev "\\.\\.\\.HEAD", "v" version "...HEAD", line)
            print line
            base = $0
            sub("^\\[" unreleased "\\]: ", "", base)
            sub("/compare/.*", "", base)
            print "[" version "]: " base "/compare/v" prev "...v" version
        } else {
            print line
        }
        next
    }
    { print }
' "$CHANGELOG" > "$TMP"

if [ "$DRY_RUN" -eq 1 ]; then
    diff -u "$CHANGELOG" "$TMP" || true
    rm -f "$TMP"
    echo "--dry-run: файл не изменён" >&2
    exit 0
fi

mv "$TMP" "$CHANGELOG"
echo "журнал: «${UNRELEASED}» → [$VERSION] — $DATE" >&2
