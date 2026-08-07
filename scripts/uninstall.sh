#!/bin/bash
# Снимает автозапуск, гасит работающую копию и удаляет приложение. Конфиг и кеш
# в ~/.config/claude-week остаются — их удаляем только по явной просьбе.
# С --quiet не печатает напоминание про настройки.
#
# Снос тот же, что делает install.sh перед установкой: агентов может быть
# несколько (label когда-то был другим, и plist от прежнего имени продолжает
# поднимать старую копию), а приложение бывает и в /Applications — из образа.
set -euo pipefail

QUIET=""
if [ "${1:-}" = "--quiet" ]; then
    QUIET=1
fi

APP="$HOME/Applications/ClaudeWeek.app"

# Агентов может оказаться несколько: label когда-то был другим, а plist от
# прежнего имени продолжает поднимать старую копию при каждом входе в систему.
# bootout на незагруженном агенте возвращает ошибку — она здесь ожидаема.
for plist in "$HOME/Library/LaunchAgents/"*.plist; do
    [ -e "$plist" ] || continue
    grep -qi "claudeweek\|claude-week" "$plist" || continue
    label="$(basename "$plist" .plist)"
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    rm -f "$plist"
done

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

# Копия из образа лежит в общем /Applications, и без неё снос неполон:
# оставшись, она поднимется следующим запуском и человек решит, что удаление
# не сработало. Прав на общий каталог может не хватить — тогда говорим, как.
if [ -d "/Applications/ClaudeWeek.app" ]; then
    if ! rm -rf "/Applications/ClaudeWeek.app" 2>/dev/null; then
        echo "!!  в /Applications лежит копия, снести её мне не дали:"
        echo "    sudo rm -rf /Applications/ClaudeWeek.app"
    fi
fi

if [ -z "$QUIET" ]; then
    echo "агент снят, приложение удалено"
    echo "настройки остались в ~/.config/claude-week (удалить: rm -rf ~/.config/claude-week)"
fi
