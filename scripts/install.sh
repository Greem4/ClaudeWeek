#!/bin/bash
# Ставит ClaudeWeek: собирает бандл, сносит всё прежнее и поднимает автозапуск.
#
#   ./scripts/install.sh                 собрать и поставить то, что в этом каталоге
#   ./scripts/install.sh --ref <ветка>   поставить конкретную ветку, тег или коммит
#   ./scripts/install.sh --latest        поставить самую свежую ветку репозитория
#   ./scripts/install.sh --no-fetch      не ходить в origin (только локальные ветки)
#
# Скрипт всегда печатает, что именно собирает: путь, ветку, коммит и дату.
# Без этого легко поставить не то — каталог с исходниками у репозитория не
# один (рабочая копия, git worktree ветки), и «собери отсюда» молча даёт
# версию, которой в этом каталоге ещё нет.
#
# Снос старого — полный: launchd-агенты (все, чьи plist поминают ClaudeWeek),
# живые процессы, приложение в ~/Applications и /Applications, вчерашний
# бандл в dist. Конфиг и кеш в ~/.config/claude-week не трогаются никогда:
# в них живут калибровка и подобранный бюджет.
set -euo pipefail

LABEL="com.greem4.claudeweek"
APP_DEST="$HOME/Applications/ClaudeWeek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ClaudeWeek.log"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REF=""
LATEST=0
FETCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)
            REF="${2:-}"
            [ -n "$REF" ] || { echo "--ref без значения" >&2; exit 2; }
            shift 2
            ;;
        --ref=*) REF="${1#--ref=}"; shift ;;
        --latest) LATEST=1; shift ;;
        --no-fetch) FETCH=0; shift ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "не знаю такого флага: $1" >&2; exit 2 ;;
    esac
done

is_git() { git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; }

# Ветка с самым свежим коммитом — среди локальных и origin/*. HEAD-указатель
# origin/HEAD пропускаем: это псевдоним, а не отдельная ветка.
newest_ref() {
    git -C "$ROOT" for-each-ref \
        --sort=-committerdate \
        --format='%(refname:short)' \
        refs/heads refs/remotes/origin 2>/dev/null \
        | grep -v '^origin/HEAD$' \
        | head -1
}

ref_stamp() {
    git -C "$ROOT" log -1 --format='%h · %cd · %s' --date=format:'%d.%m %H:%M' "$1" 2>/dev/null
}

if is_git && [ "$FETCH" = 1 ] && git -C "$ROOT" remote get-url origin > /dev/null 2>&1; then
    echo "==> обновляю ветки из origin"
    git -C "$ROOT" fetch --quiet origin || echo "    origin недоступен, беру локальные ветки"
fi

if [ "$LATEST" = 1 ]; then
    is_git || { echo "--latest требует git-репозиторий" >&2; exit 1; }
    REF="$(newest_ref)"
    [ -n "$REF" ] || { echo "не нашёл ни одной ветки" >&2; exit 1; }
    echo "==> самая свежая ветка: $REF"
fi

# Сборка идёт до сноса: упадёт компиляция — старая версия останется работать.
# Из чужого ref собираем во временном git worktree, не трогая рабочую копию:
# переключать ветку под человеком нельзя, у него тут могут быть правки.
TEMP_TREE=""
cleanup() {
    [ -n "$TEMP_TREE" ] && git -C "$ROOT" worktree remove --force "$TEMP_TREE" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$REF" ]; then
    is_git || { echo "--ref требует git-репозиторий" >&2; exit 1; }
    git -C "$ROOT" rev-parse --verify --quiet "$REF" > /dev/null \
        || { echo "не знаю такой ветки или коммита: $REF" >&2; exit 1; }
    TEMP_TREE="$(mktemp -d "${TMPDIR:-/tmp}/claudeweek-build.XXXXXX")"
    rm -rf "$TEMP_TREE"
    git -C "$ROOT" worktree add --detach --quiet "$TEMP_TREE" "$REF"
    BUILD_ROOT="$TEMP_TREE"
    SOURCE_NOTE="$REF · $(ref_stamp "$REF")"
else
    BUILD_ROOT="$ROOT"
    if is_git; then
        BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
        SOURCE_NOTE="$BRANCH · $(ref_stamp HEAD)"
        if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
            SOURCE_NOTE="$SOURCE_NOTE · есть несохранённые правки"
        fi
        # Ровно та ошибка, ради которой этот скрипт и переписан: собрали из
        # каталога, где нужной ветки нет, и получили вчерашнюю версию.
        NEWEST="$(newest_ref)"
        if [ -n "$NEWEST" ] \
            && [ "$(git -C "$ROOT" rev-parse "$NEWEST")" != "$(git -C "$ROOT" rev-parse HEAD)" ] \
            && [ -n "$(git -C "$ROOT" rev-list -1 --since="$(git -C "$ROOT" log -1 --format=%cI HEAD)" "$NEWEST")" ]; then
            echo "!!  свежее есть в ветке $NEWEST ($(ref_stamp "$NEWEST"))"
            echo "    поставить именно её: $0 --ref $NEWEST"
        fi
    else
        SOURCE_NOTE="не git-репозиторий"
    fi
fi

echo "==> собираю из $BUILD_ROOT"
echo "    $SOURCE_NOTE"
rm -rf "$BUILD_ROOT/dist/ClaudeWeek.app"
"$BUILD_ROOT/scripts/make-app.sh"

APP_SOURCE="$BUILD_ROOT/dist/ClaudeWeek.app"
[ -d "$APP_SOURCE" ] || { echo "сборка не дала бандл: $APP_SOURCE" >&2; exit 1; }

echo "==> сношу прежние версии"
# Агентов может оказаться несколько: label когда-то был другим, а plist от
# прежнего имени продолжает поднимать старую копию при каждом входе в систему.
for plist in "$HOME/Library/LaunchAgents/"*.plist; do
    [ -e "$plist" ] || continue
    grep -qi "claudeweek\|claude-week" "$plist" || continue
    label="$(basename "$plist" .plist)"
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "    снят агент $label"
done

# Копию, запущенную руками из Finder, launchd не подчиняется: не погасив её,
# после переустановки получим две иконки в строке меню — старую и новую.
# Имя ровно ClaudeWeek, поэтому отладочный swift run (ClaudeWeekApp) цел.
if pkill -x ClaudeWeek 2>/dev/null; then
    for _ in $(seq 20); do
        pgrep -x ClaudeWeek > /dev/null || break
        sleep 0.1
    done
    pkill -9 -x ClaudeWeek 2>/dev/null || true
    echo "    погашен работавший процесс"
fi

rm -rf "$APP_DEST"
# Копия в общем /Applications — не наша забота ставить, но наша убрать: две
# версии в системе означают, что запустится не та, что вы только что собрали.
if [ -d "/Applications/ClaudeWeek.app" ]; then
    if rm -rf "/Applications/ClaudeWeek.app" 2>/dev/null; then
        echo "    удалена копия из /Applications"
    else
        echo "!!  в /Applications лежит копия, снести её мне не дали:"
        echo "    sudo rm -rf /Applications/ClaudeWeek.app"
    fi
fi

echo "==> ставлю в $APP_DEST"
mkdir -p "$HOME/Applications"
cp -R "$APP_SOURCE" "$APP_DEST"

echo "==> пишу $PLIST"
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_DEST/Contents/MacOS/ClaudeWeek</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
</dict>
</plist>
PLIST_EOF

# Страховка: агент уже снят выше, но если launchd почему-то ещё держит сервис,
# bootstrap упал бы с ошибкой. Лишний bootout на незагруженном агенте безвреден.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

VERSION="$(defaults read "$APP_DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo
# Ad-hoc подпись означает, что разрешение на чтение токена Claude Code не
# переживёт следующую пересборку: macOS привязывает его к designated
# requirement, а у ad-hoc это хеш бинаря. Сказать об этом надо здесь — вопрос
# про доступ к Keychain человек увидит через несколько секунд.
if ! codesign -d -r- "$APP_DEST" 2>&1 | grep -q "certificate leaf"; then
    echo "подпись ad-hoc: доступ к токену Claude Code macOS спросит снова после"
    echo "каждой пересборки. Чтобы спросила последний раз — постоянный сертификат:"
    echo "  ./scripts/signing-cert.sh && ./scripts/install.sh"
    echo
fi
echo "готово: ClaudeWeek $VERSION в строке меню"
echo "        собрано из: $SOURCE_NOTE"
echo "        лог — $LOG"
echo "если процента ещё нет: выполните /usage в Claude Code и запустите"
echo "  $APP_DEST/Contents/MacOS/ClaudeWeek --calibrate=<процент>"
