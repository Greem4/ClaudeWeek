# Устройство ClaudeWeek

Карта кода: кто за что отвечает, куда лезть и что искать. Файл рассчитан на
того, кто открывает проект впервые (человека или агента) и хочет что-то
изменить, ничего не сломав.

Смежные документы: [API.md](API.md) — схема ответа сервера и дисциплина
запросов; [PLAN.md](PLAN.md) — исходный план, обоснования решений и разбор
отвергнутых вариантов; [ROADMAP.md](ROADMAP.md) — чего не хватает.

---

## 1. Общая схема

```
Keychain (Claude Code / свой токен)
        │
        ▼
OfficialProvider ──┐
                   ├──► ResolvingProvider ──► UsageSnapshot ──► PanelModel ──┬──► PopoverView (панель)
LocalProvider  ────┘            │                                            └──► MenuBarBar (иконка)
   ▲                            │
   │                            ▼
~/.claude/projects/*.jsonl   cache.json (кеш + подобранный бюджет + сессия)
                                ▲
config.json ────────────────────┴──► StatusItemController ◄──► SettingsView (окно настроек)
```

Правило разделения: **`ClaudeWeekCore` не импортирует ни AppKit, ни SwiftUI.**
Всё, что считает проценты, окно недели и план, живёт там и покрыто тестами;
всё, что рисует, — в `ClaudeWeekApp`. Если тянет добавить в ядро `import
SwiftUI` — значит, расчёт просочился в UI или наоборот.

Два исполняемых таргета плюс библиотека:

| Таргет | Что это |
|---|---|
| `ClaudeWeekCore` | библиотека расчётов, без UI |
| `ClaudeWeekApp` | само приложение (`swift run ClaudeWeekApp`) |
| `ClaudeWeekTests` | свой тест-раннер (`swift run ClaudeWeekTests`) — XCTest без Xcode недоступен |

---

## 2. Ядро: `Sources/ClaudeWeekCore`

| Файл | Отвечает за | Ключевые типы |
|---|---|---|
| `Config.swift` | все настройки, чтение и запись `config.json`, починка недопустимых значений | `Config`, `AppearanceConfig`, `ThemeKind`, `AuthSource`, `Thresholds`, `ConfigStore` |
| `WeekWindow.swift` | границы недельного окна, план на момент и на сутки | `WeekWindow`, `WeekDaySlot` |
| `Snapshot.swift` | что показываем: итог, дни, сессия, производные метрики | `UsageSnapshot`, `DayUsage`, `SessionUsage`, `UsageMetrics`, `LimitState` |
| `UsageProvider.swift` | протокол источника и типы ошибок | `UsageProvider`, `UsageError` |
| `OfficialProvider.swift` | запрос к `/api/oauth/usage`, разбор ответа, паузы после отказов | `OfficialProvider`, `OfficialUsage`, `UsageTransport` |
| `LocalProvider.swift` | расчёт по транскриптам, цены моделей, инкрементальное чтение файлов | `LocalProvider`, `LocalUsage`, `ModelPricing` |
| `ResolvingProvider.swift` | выбор источника, падение на запасной, калибровка, запись кеша | `ResolvingProvider` |
| `Cache.swift` | `cache.json` и индекс прочитанных транскриптов | `CachedUsage`, `UsageIndex`, `Store` |
| `Keychain.swift` | чтение OAuth-кредов Claude Code | `KeychainCredentials`, `OAuthCredentials`, `CredentialsSource` |
| `ManualToken.swift` | свой токен: хранение в отдельной записи Keychain | `ManualToken`, `ManualCredentials` |
| `Formatting.swift` | «3 дн 6 ч», проценты, дни недели, часы | `Formatting` |
| `ISO8601.swift` | разбор меток времени обоих видов (с долями секунды и без) | `ISO8601` |
| `Log.swift` | уровни лога в stderr | `Log` |
| `Version.swift` | версия и идентификатор бандла | `ClaudeWeek.version` |

### Что где искать

- **«Откуда берётся 64 %»** → `OfficialProvider.usage(at:)`, поле
  `seven_day.utilization`; форма недели — `shapeByDay`.
- **«Почему полосы такие»** → `WeekWindow.planPercent(forDay:anchor:)`
  и `UsageSnapshot.make(...)`.
- **«Когда сброс»** → `WeekWindow.init(endingAt:config:)` для официального
  ответа, `init(containing:config:)` — запасной путь из конфига.
- **«Почему цифра приблизительная»** → `UsageSnapshot.isEstimate` (итог) и
  `shapeIsEstimate` (разбивка). Это разные вещи, и смешивать их нельзя.
- **«Что лежит в кеше»** → `CachedUsage`: проценты, границы окна, подобранный
  `weeklyBudget`, `officialWindowEnd` и последняя сессия.

### Инварианты ядра

1. **Ноль вместо процента не показываем никогда.** Не смогли получить —
   `UsageError`, а не «потрачено 0 %».
2. **Момент сброса от сервера сильнее конфига.** `officialWindowEnd`
   переживает локальные перезаписи кеша (`ResolvingProvider.save`).
3. **Сессия из кеша годна, только пока не истекло её окно**
   (`SessionUsage.isFresh(at:)`): после сброса процент не «слегка устарел»,
   а обнулился.
4. **Прибавление недели — календарное** (`byAdding: .day, value: 7`), не
   `+604800`: в неделю с переводом часов сутки бывают 23 или 25 часов.
5. **Кривой конфиг чинится, а не отвергается** (`Config.validated()`):
   потерять строку меню из-за опечатки в JSON нельзя.
6. **Токен не логируется, не пишется в конфиг и не выводится в UI.**

---

## 3. Приложение: `Sources/ClaudeWeekApp`

| Файл | Отвечает за |
|---|---|
| `main.swift` | разбор аргументов командной строки, режимы `--json`, `--calibrate`, `--screenshot`, `--icon`; запуск `NSApplication` в режиме `.accessory` |
| `StatusItemController.swift` | **склейка всего**: пункт строки меню, таймеры, сон/пробуждение, смена таймзоны, перечитывание конфига, открытие панели и настроек |
| `PanelModel.swift` | состояние для SwiftUI: снимок, статус, текущий момент, производные подписи |
| `DropdownPanel.swift` | окно панели: форма как у системного меню, материал, обводка, позиция под строкой меню, закрытие по клику мимо |
| `PopoverView.swift` | вёрстка панели: заголовок, сессия, семь строк, футер |
| `DayBar.swift` | одна двухцветная полоса и строка дня |
| `SessionRow.swift` | полоса пятичасовой сессии |
| `MenuBarBar.swift` | иконка строки меню: полоса и процент в два этажа |
| `Theme.swift` | палитры тем, метрики, шрифты, `Ink` и `Palette` |
| `SettingsWindow.swift` | окно настроек: модель, применение изменений, проверка токена |
| `SettingsView.swift` | четыре вкладки настроек и живой предпросмотр |
| `ConfigStamp.swift` | отпечаток файла конфига (замечает правки без file watcher) |
| `Screenshot.swift` | `--screenshot`: панель во всех темах и иконка в PNG |
| `AppIcon.swift` | `--icon`: `.iconset` для сборки бандла |
| `CLI.swift` | `--json` и `--calibrate` |

### Потоки данных

**Обновление цифр.** `StatusItemController.refresh()` → `provider.fetch()`
(на фоне) → `model.apply(snapshot)` → SwiftUI перерисовывает панель, а
`render()` — иконку строки меню. Ошибка → `model.apply(error:)`, панель
показывает текст под заголовком и, если данные были, помечает их возраст.

**Тик времени.** Раз в минуту `tick()`: двигает `model.now` (чтобы «до
сброса» не врало), проверяет отпечаток конфига, перерисовывает иконку.

**Правка настроек.** `SettingsModel.config.didSet` → `applyFromSettings` в
контроллере: сразу применяет к панели и иконке, с задержкой 400 мс пишет
`config.json` (ползунок шлёт по десятку изменений в секунду), и только если
поменялось что-то влияющее на расчёт — пересоздаёт провайдер и дёргает
`refresh()`.

**Правка файла руками.** `ConfigStamp` замечает изменение по (inode, size,
mtime) — атомарная запись меняет inode, поэтому наблюдатель по дескриптору
такие правки теряет, а отпечаток нет.

### Инварианты приложения

1. **Панель — не `NSPopover`.** Стрелку у него не убрать, от строки он
   отступает, фон рисует свой и открывается с анимацией. Своё окно
   (`MenuPanel`) даёт форму системного меню.
2. **Клик по пункту строки меню в мониторах игнорируется**
   (`DropdownPanel.startMonitoring`): иначе панель закрылась бы по монитору и
   тут же открылась по `handleClick`.
3. **Размер окна панели ведётся вручную** (`SizingHostingView`): `NSHostingView`
   не двигает окно, когда SwiftUI меняет высоту контента.
4. **Цвет нигде не единственный носитель смысла**: рядом с каждой полосой
   числа «факт / план», у перерасхода — значок ⚠.
5. **Родная палитра проверена валидатором** на дальтонизм и контраст;
   остальные темы — игровая площадка, о чём написано и в настройках.

---

## 4. Рецепты

### Добавить настройку

1. Поле в `Config` (или в `AppearanceConfig`, если оно только про вид) —
   `Sources/ClaudeWeekCore/Config.swift`. Значение по умолчанию обязательно.
2. Разбор: строка в `init(from decoder:)` через `decodeIfPresent(...) ?? d.поле`.
   Без этого старый конфиг перестанет читаться.
3. Починка недопустимых значений — в `validated()`.
4. Контрол во вкладке `SettingsView.swift`.
5. Если настройка влияет на расчёт — добавить её в список `providerChanged`
   в `StatusItemController.applyFromSettings`, иначе провайдер не пересоздастся.
6. Тест в `Sources/ClaudeWeekTests/ConfigTests.swift`: дефолт, починка,
   переживание записи-чтения, старый файл без нового ключа.
7. Строка в таблице настроек README.

### Добавить тему

1. `ThemeKind` в `Config.swift`: новый case + `title`.
2. `Palette` в `Theme.swift`: статическая палитра со всеми ролями цветов
   и материалом фона.
3. `ThemeKind.palette` — связать case с палитрой (компилятор напомнит).
4. `ClaudeWeekApp --screenshot docs/images` — картинки появятся сами.
5. Галерея в README, если тема достойна показа.

Роли цветов менять нельзя: `track` — вне плана, `plan` — остаток плана,
`good` — факт в пределах плана, `warning` — вылет, `critical` — только
заголовок и иконка (красный не идёт в заливку: с зелёным он неразличим при
дейтеранопии).

### Добавить источник данных

1. Тип, реализующий `UsageProvider` (`fetch() async throws -> UsageSnapshot`).
2. Ветка в `ResolvingProvider` и case в `ProviderPreference`.
3. Тесты с подставным транспортом — см. `OfficialProviderTests`
   (`UsageTransport` для этого и вынесен в протокол).

### Поменять вид панели

- **Форма окна, материал, тень, позиция** — `DropdownPanel.swift`
  (`apply(appearance:palette:)`, `frame(for:anchor:)`).
- **Содержимое** — `PopoverView.swift`; строка дня — `DayBar.swift`.
- **Плотность фона** живёт в `PopoverView.backdrop`: вуаль поверх материала.
  Материал системы в оффскрин-рендер не попадает, поэтому `--screenshot`
  выключает прозрачность и рисует сплошной фон палитры.

### Проверить схему ответа сервера

```bash
swift Scripts/probe-usage.swift    # один запрос, печатает ответ целиком
```

---

## 5. Сборка, установка, проверки

```bash
swift build                     # оба таргета
swift run ClaudeWeekTests       # 240 проверок, без сети и без UI
swift run ClaudeWeekApp         # запустить из исходников (появится вторая иконка!)
./Scripts/make-app.sh           # собрать dist/ClaudeWeek.app
./Scripts/install-agent.sh      # пересобрать, снести старую версию, поставить и запустить
./Scripts/uninstall-agent.sh    # снять агент и удалить приложение
```

Тесты — свой раннер (`Sources/ClaudeWeekTests/Harness.swift`): `t.suite(...)`,
`t.equal(...)`, `t.fail(...)`. Сети в них нет: официальный источник
проверяется подставным `UsageTransport`, локальный — временными каталогами
с транскриптами.

### Грабли

- **Keychain спрашивает доступ после каждой пересборки** — разрешение
  привязано к подписи, а она ad-hoc и меняется. Это не баг.
- **`swift run ClaudeWeekApp` даёт вторую иконку** рядом с установленной
  копией. Для проверки живьём лучше `./Scripts/install-agent.sh`.
- **Swift 6, строгая изоляция.** Колбэки AppKit (`Timer`,
  `NSEvent.addLocalMonitorForEvents`) не изолированы: внутри —
  `MainActor.assumeIsolated { … }`, и возвращать из него можно только
  `Sendable` (`NSEvent` не подходит — верните `Bool`, а событие отдайте снаружи).
- **`NSHostingView` не меняет размер окна сам** — см. `SizingHostingView`.
- **Цвет слоя (`CALayer.borderColor`) не следует за темой**: обводка
  перекрашивается в `viewDidChangeEffectiveAppearance` (`BorderedView`).
- **Тесты не покрывают UI.** Всё, что делает `ClaudeWeekApp`, проверяется
  глазами: `--screenshot` и установка.

---

## 6. Где что лежит на диске

| Путь | Что |
|---|---|
| `~/.config/claude-week/config.json` | настройки (пишет и окно настроек, и вы сами) |
| `~/.config/claude-week/cache.json` | последний снимок, подобранный бюджет, момент сброса, сессия |
| `~/.config/claude-week/index.json` | индекс прочитанных транскриптов (инкрементальное чтение) |
| `~/.claude/projects/**/*.jsonl` | транскрипты Claude Code — вход локального источника |
| `~/Library/Logs/ClaudeWeek.log` | лог запущенного через LaunchAgent приложения |
| `~/Library/LaunchAgents/com.greem4.claudeweek.plist` | автозапуск |
| `~/Applications/ClaudeWeek.app` | установленная копия |
| Keychain `Claude Code-credentials` | токен Claude Code (только читаем) |
| Keychain `ClaudeWeek-token` | свой токен из настроек (пишем и удаляем) |
