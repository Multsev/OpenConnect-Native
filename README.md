# CiscoConnect

Бесплатное нативное приложение macOS для Cisco AnyConnect-совместимых VPN.
Оно включает OpenConnect внутри DMG: пользователю не нужны Homebrew, Terminal
или отдельная установка VPN-клиента.

## Как работает

- GUI сохраняет шлюз, группу и логин в `UserDefaults`, основной пароль — в
  Keychain, а OTP держит только в памяти одной попытки;
- перед подключением macOS показывает штатный диалог администратора: это
  необходимо для создания интерфейса VPN, DNS и маршрутов;
- OpenConnect запускается с `--passwd-on-stdin`. Пароль и OTP не попадают в
  argv, логи или настройки; временный файл с ними имеет права `0600` и
  удаляется до запуска VPN-процесса;
- правила защиты от повторных ошибок соответствуют Project Pulse: 1 минута
  после первой и 30 минут после второй ошибки за 30 минут.

Поддерживаются логин/пароль, необязательная группа и заранее известный OTP.
SAML/SSO в браузере, CSD/HostScan, клиентские сертификаты и интерактивный OTP,
который сервер запрашивает только после первой формы, требуют отдельной работы.

## Установка из GitHub Release

1. Скачайте `CiscoConnect-*.dmg` и файл `*.dmg.sha256`.
2. В Terminal выполните `shasum -a 256 CiscoConnect-*.dmg` и сравните хеш с
   файлом `.sha256`.
3. Откройте DMG и перетащите `CiscoConnect.app` в `Applications`.
4. При первом запуске нажмите приложение правой кнопкой → **Открыть** →
   **Открыть**. Это одноразовое требование Gatekeeper для бесплатной ad-hoc
   подписи.
5. Заполните профиль, сохраните пароль в Keychain и нажмите Connect. Подтвердите
   системный запрос администратора.

## Локальная сборка DMG

Требуются macOS 14+, Xcode 15.4+, Homebrew и OpenConnect:

```bash
brew install xcodegen openconnect
cd /Users/max/Downloads/CiscoConnect
./Scripts/package_dmg.sh development
```

Результат: `build/CiscoConnect-0.1.0.dmg` и файл контрольной суммы рядом с ним.
Скрипт вкладывает OpenConnect и его динамические библиотеки в приложение и
подписывает каждый компонент ad-hoc-подписью. Проверка:

```bash
codesign --verify --deep --strict build/Release/CiscoConnect.app
```

## Публикация на GitHub

Workflow [`.github/workflows/release.yml`](.github/workflows/release.yml)
собирает DMG на macOS 14. Pull request публикует артефакт проверки, а тег вида
`v0.1.0` создаёт GitHub Release с DMG и SHA-256:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Никакой Apple Developer Program для этого не нужен. Однако ad-hoc подпись не
является Developer ID: приложение не будет нотарифицировано и при первом
запуске потребует ручного разрешения Gatekeeper. Убрать это предупреждение для
всех пользователей можно только с платным Apple Developer Program и Developer
ID Application certificate.

## Лицензии

Исходный код CiscoConnect распространяется под [MIT](LICENSE). Встроенный
OpenConnect и `vpnc-script` имеют собственные лицензии; см.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Перед выпуском новой версии
нужно проверять notices всех dylib, которые в неё вошли.

## Структура

```text
Sources/CiscoConnect/
├── App/             # запуск и композиция зависимостей
├── Domain/          # профиль, статусы, Cisco-формы
├── Persistence/     # UserDefaults, Keychain, cooldown
├── Services/        # use case VPN и защищённый запуск OpenConnect
└── UI/              # системные SwiftUI-экраны macOS
Scripts/             # XcodeGen, упаковка runtime и DMG
.github/workflows/   # CI и GitHub Releases
Tests/               # доменные правила
```

Проверка доменной логики: `swift test`.
