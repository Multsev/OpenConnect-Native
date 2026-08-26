# CiscoConnect

Нативный macOS-шаблон для Cisco AnyConnect-совместимых VPN. Шаблон
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

## Ограничение транспорта

В репозитории намеренно нет привилегированного VPN-движка. Cisco AnyConnect SSL
создаёт сетевой туннель и маршруты, поэтому рабочий macOS-транспорт должен быть
отдельным подписанным Network Extension либо привилегированным helper вокруг
OpenConnect. `UnavailableTunnelClient` сохраняет границу в коде и не передаёт
пароль или OTP в аргументах командной строки. До установки такого транспорта
приложение корректно объясняет, почему подключение не запущено.

OpenConnect поддерживает Cisco AnyConnect и рекомендует передавать пароль через
stdin, а не через `--form-entry`; это важно, чтобы реквизиты не были видны в
списке процессов. См. [официальное руководство OpenConnect](https://www.infradead.org/openconnect/manual.html).

Не поддерживаются без отдельного согласования с владельцем VPN: SAML/SSO во
внешнем браузере, CSD/HostScan и клиентские сертификаты.

## Запуск

Требуются macOS 14+ и Xcode 15.4+.

```bash
cd /Users/max/Downloads/CiscoConnect
swift run CiscoConnect
```

## Проверка

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
├── Services/        # use case подключения и транспортный контракт
└── UI/              # декларативные системные экраны macOS
Tests/               # правила профиля и защиты от повторных попыток
```

## Подключение реального транспорта

Реализуйте `TunnelClient` в отдельном модуле `Integrations/OpenConnect` или
Network Extension. Он получает `CiscoAuthenticationRequest`, передаёт пароль и
OTP только через защищённый IPC/stdin, проверяет сертификат шлюза, выдаёт
события `TunnelStatus` и не выполняет автоматический повтор после отказа.
`VPNConnectionService` и SwiftUI при этом менять не нужно.

