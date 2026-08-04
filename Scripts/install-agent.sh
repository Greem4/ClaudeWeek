#!/bin/bash
# Ставит ClaudeWeek в ~/Applications и поднимает LaunchAgent автозапуска.
# Скрипт идемпотентен: повторный запуск переустанавливает агент, не плодя копии.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.greem4.claudeweek"
APP_SOURCE="$ROOT/dist/ClaudeWeek.app"
APP_DEST="$HOME/Applications/ClaudeWeek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ClaudeWeek.log"

if [ ! -d "$APP_SOURCE" ]; then
    echo "==> бандла нет, собираю"
    "$ROOT/Scripts/make-app.sh"
fi

echo "==> ставлю в $APP_DEST"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
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

# bootout на незагруженном агенте возвращает ошибку — она здесь ожидаема.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "готово: ClaudeWeek в строке меню, лог — $LOG"
echo "если процента ещё нет: выполните /usage в Claude Code и запустите"
echo "  $APP_DEST/Contents/MacOS/ClaudeWeek --calibrate=<процент>"
