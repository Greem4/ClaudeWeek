import AppKit
import ClaudeWeekCore

/// Выпуск своего токена командой Claude Code.
///
/// Своего окна авторизации у ClaudeWeek нет и не будет: `client_id` сторонним
/// программам Anthropic не выдаёт, а ходить с чужим — значит показывать
/// человеку чужое имя в окне согласия. Поэтому авторизацию проводит сам
/// Claude Code, а наше дело — открыть терминал с командой и принять готовую
/// строку. В чужие креды при этом никто не заглядывает.
@MainActor
enum SetupToken {
    static let command = "claude setup-token"

    static let docsURL = URL(
        string: "https://code.claude.com/docs/en/authentication#generate-a-long-lived-token"
    )!

    static func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Открывает команду в терминале. Возвращает текст ошибки, если открыть
    /// не вышло: молча проглоченная кнопка выглядит как сломанная.
    @discardableResult
    static func run() -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWeek-setup-token.command")
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            // 0o700: файл лежит в общей временной папке, и запускать его
            // вправе только тот, для кого он написан.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch {
            Log.warn("не смог подготовить команду выпуска токена: \(error.localizedDescription)")
            return "не смог открыть терминал — выполните \(command) сами"
        }
        guard NSWorkspace.shared.open(url) else {
            Log.warn("терминал не открылся для \(url.path)")
            return "терминал не открылся — выполните \(command) сами"
        }
        return nil
    }

    /// Приложение запускается из LaunchAgent, и `PATH` у него куцый — до
    /// терминала это не касается, но нативный установщик Claude Code кладёт
    /// бинарь в `~/.local/bin`, которого нет в `PATH` у части оболочек.
    private static let script = """
    #!/bin/zsh
    # Файл создан ClaudeWeek для выпуска токена. Его можно удалить.
    PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

    if ! command -v claude >/dev/null; then
      print "Не нашёл команду claude. Установите Claude Code и повторите."
      print "Enter — закрыть окно."
      read -r _
      exit 1
    fi

    print "Выпуск токена для ClaudeWeek. Сейчас откроется браузер —"
    print "подтвердите доступ, и токен напечатается ниже.\\n"

    \(command)

    print "\\nСкопируйте строку sk-ant-oat01-… и вставьте её в настройках"
    print "ClaudeWeek, вкладка «Доступ». Enter — закрыть окно."
    read -r _
    """
}
