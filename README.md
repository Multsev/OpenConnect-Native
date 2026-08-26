# CiscoConnect

Нативное macOS-приложение для Cisco AnyConnect-совместимых VPN. Оно
демонстрирует подход «business logic first»: профиль, реквизиты, ограничения
попыток и сценарий подключения независимы от SwiftUI; интерфейс строится
системными `Form`, `NavigationSplitView`, `Table` и `ContentUnavailableView`.

## Возможности шаблона

- хранит шлюз, группу и логин в `UserDefaults`;
- хранит основной пароль в macOS Keychain; пароль не попадает в логи,
  настройки или экспорт;
- запрашивает OTP только перед подключением и держит его только в памяти;
- нормализует HTTPS-адрес и проверяет обязательные поля;
- предотвращает подбор реквизитов: 1 минута после первой ошибки, 30 минут
  после второй за последние 30 минут;
- строит `CiscoAuthenticationRequest`, который явно соответствует Cisco
  XML-формам `main:username`, `main:password`, `main:group_list` и
  `challenge:answer`.

## Встроенный VPN-движок

Приложение включает собственный Packet Tunnel system extension. Он вызывает
`libopenconnect` напрямую и связывает её с `NEPacketTunnelFlow`; внешний
исполняемый файл `openconnect` пользователю не нужен. Шлюз передаёт extension
адрес, DNS и split-маршруты, а extension применяет их через NetworkExtension.

OpenConnect поддерживает Cisco AnyConnect и рекомендует передавать пароль через
stdin, а не через `--form-entry`; это важно, чтобы реквизиты не были видны в
списке процессов. См. [официальное руководство OpenConnect](https://www.infradead.org/openconnect/manual.html).

Не поддерживаются без отдельного согласования с владельцем VPN: SAML/SSO во
внешнем браузере, CSD/HostScan и клиентские сертификаты.

## Запуск

Требуются macOS 14+ и Xcode 15.4+.

```bash
cd /Users/max/Downloads/CiscoConnect
./Scripts/generate_xcode_project.sh
open CiscoConnect.xcodeproj
```

Для локальной проверки исходников без подписи:

```bash
xcodebuild -project CiscoConnect.xcodeproj -scheme CiscoConnect \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Перед запуском реального VPN задайте `DEVELOPMENT_TEAM`, включите Network
Extensions для идентификатора приложения в Apple Developer и добавьте
универсальную сборку `libopenconnect` в `Vendor/OpenConnect`. Homebrew-библиотека
на этом Mac используется только для компиляционной проверки и не предназначена
для распространения.

## Проверка доменной логики

```bash
swift test
swift build
```

## Структура

```text
Sources/CiscoConnect/
├── App/             # запуск и сборка зависимостей
├── Domain/          # профиль, статус и запрос Cisco-формы
├── Persistence/     # UserDefaults, Keychain, сохранённый cooldown
├── Services/        # use case подключения и NetworkExtension-клиент
└── UI/              # декларативные системные экраны macOS
Extensions/CiscoTunnel/ # Packet Tunnel + Objective-C мост libopenconnect
Tests/               # правила профиля и защиты от повторных попыток
```

## Дистрибуция

Перед внешним распространением зафиксируйте версию OpenConnect и её зависимости,
соберите arm64/x86_64 runtime, подпишите сначала вложенные dylib, затем system
extension и приложение, после чего выполните notarization. Подробности о
структуре runtime — в `Vendor/OpenConnect/README.md`.
