#!/bin/bash
# Ставит ClaudeWeek в ~/Applications и поднимает LaunchAgent автозапуска.
# Повторный запуск — полная переустановка: сначала собирается свежий бандл,
# потом старая версия снимается целиком (агент, живой процесс, приложение),
# и только затем ставится новая. Копии не плодятся.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.greem4.claudeweek"
APP_SOURCE="$ROOT/dist/ClaudeWeek.app"
APP_DEST="$HOME/Applications/ClaudeWeek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ClaudeWeek.log"

# Сборка идёт до сноса: упадёт компиляция — старая версия останется работать.
echo "==> собираю свежий бандл"
"$ROOT/Scripts/make-app.sh"

echo "==> снимаю старую версию"
"$ROOT/Scripts/uninstall-agent.sh" --quiet

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

echo "готово: ClaudeWeek в строке меню, лог — $LOG"
echo "если процента ещё нет: выполните /usage в Claude Code и запустите"
echo "  $APP_DEST/Contents/MacOS/ClaudeWeek --calibrate=<процент>"
