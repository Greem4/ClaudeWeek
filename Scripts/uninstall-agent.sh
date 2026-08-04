#!/bin/bash
# Снимает автозапуск и удаляет приложение. Конфиг и кеш в
# ~/.config/claude-week остаются — их удаляем только по явной просьбе.
set -euo pipefail

LABEL="com.greem4.claudeweek"
APP="$HOME/Applications/ClaudeWeek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"

echo "агент снят, приложение удалено"
echo "настройки остались в ~/.config/claude-week (удалить: rm -rf ~/.config/claude-week)"
