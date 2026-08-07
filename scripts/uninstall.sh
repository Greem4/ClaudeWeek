#!/bin/bash
# Снимает автозапуск, гасит работающую копию и удаляет приложение. Конфиг и кеш
# в ~/.config/claude-week остаются — их удаляем только по явной просьбе.
# С --quiet молчит про настройки: так его зовёт install.sh.
set -euo pipefail

QUIET=""
if [ "${1:-}" = "--quiet" ]; then
    QUIET=1
fi

LABEL="com.greem4.claudeweek"
APP="$HOME/Applications/ClaudeWeek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# bootout на незагруженном агенте возвращает ошибку — она здесь ожидаема.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

# Копия, запущенная руками из Finder, launchd не подчиняется: не погасив её,
# после переустановки получим две иконки в строке меню — старую и новую.
# Имя ровно ClaudeWeek, поэтому отладочный swift run (ClaudeWeekApp) цел.
if pkill -x ClaudeWeek 2>/dev/null; then
    for _ in $(seq 20); do
        pgrep -x ClaudeWeek > /dev/null || break
        sleep 0.1
    done
    pkill -9 -x ClaudeWeek 2>/dev/null || true
fi

rm -rf "$APP"

if [ -z "$QUIET" ]; then
    echo "агент снят, приложение удалено"
    echo "настройки остались в ~/.config/claude-week (удалить: rm -rf ~/.config/claude-week)"
fi
