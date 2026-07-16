# Jerktionary for macOS (native)

Нативный SwiftUI-порт Electron-фронтенда Jerktionary. Главное отличие:
**системный звук захватывается через ScreenCaptureKit** — BlackHole,
Multi-Output Device и вся хрупкая виртуальная маршрутизация не нужны.

## Требования

- macOS 14+
- Backend Jerktionary на `http://127.0.0.1:8000` (адрес меняется в настройках)
- Разрешения: Микрофон (для источника «Микрофон»), Запись экрана и
  системного звука (для источника «Система»)

## Сборка

```bash
swift build            # debug-бинарь
swift test             # юнит-тесты портированной логики
./scripts/make-app.sh  # dist/Jerktionary.app (release + ad-hoc подпись)
```

Проект — обычный SwiftPM-пакет: `open Package.swift` открывает его в Xcode.

## Функциональность (паритет с Electron-версией)

- Живая транскрипция: PCM 16 kHz mono int16 по WebSocket `/ws/audio`,
  reconnect с экспоненциальным backoff
- Подсветка терминов, объяснения по клику (SSE-стриминг + фоновый prefetch)
- Автодетект вопросов (settle-окно 1200/350 мс, канонический ключ с
  фильтрацией филлеров) и стриминговые ответы с кэшем и фоновой генерацией
  «Подробнее»
- Глобальные хоткеи: Ctrl+Shift+Space «ответить сейчас», Ctrl+Shift+O
  компактный оверлей поверх окон, Ctrl+Shift+Enter ответ с полным контекстом
- Stealth: окно исключено из захвата экрана (sharingType), маскируемый
  заголовок окна
- Архив встреч: тот же файл `~/Library/Application Support/Jerktionary/meetings.json`,
  что у Electron-версии — история общая; экспорт в Markdown
- Мастер первоначальной настройки, статус backend (/health, /ready) с опросом 30 с

## Структура

```
Sources/Jerktionary/
  App/            — @main, AppDelegate (хоткеи, stealth)
  Core/           — стор, менеджеры стримов, настройки, встречи
    Audio/        — микрофон (AVAudioEngine), система (ScreenCaptureKit), PCM
    Logic/        — детектор вопросов, слияние терминов
    Network/      — WebSocket, SSE, REST
  UI/             — SwiftUI-вьюхи
```
