# YouTube Video Info Extractor

PowerShell-скрипт: по ссылке на YouTube-видео формирует Markdown-документ в формате
Obsidian Web Clipper с кратким содержанием (summary) и полным транскриптом.

Итоговый файл содержит:
- YAML-фронтматтер (title, source, author, published, created, description, tags);
- превью-ссылку и описание видео;
- секцию **## Summary** — краткое содержание по диапазонам таймкодов (сначала);
- секцию **## Transcript** — полный транскрипт с таймкодами (после summary).

Имя файла: `{Название канала} - {Название видео}.md`.

## Требования

1. **PowerShell 7+**
   ```powershell
   winget install Microsoft.PowerShell
   ```
2. **yt-dlp** — получение метаданных и субтитров. Любой из вариантов:
   - **Автономный exe** (без Python): скачайте [`yt-dlp.exe`](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe)
     в корень проекта и укажите путь к нему в `config.json` → `YtDlpPath`.
   - **Через winget** (попадёт в PATH): `winget install yt-dlp.yt-dlp` — тогда `YtDlpPath` можно оставить пустым.

   (опционально `winget install Gyan.FFmpeg` — на некоторых видео улучшает загрузку).
3. **API-ключ Groq** (бесплатный тариф).

## Как получить ключ Groq

1. Откройте <https://console.groq.com> и войдите (Google/GitHub, бесплатно, карта не нужна).
2. В меню слева выберите **API Keys**.
3. Нажмите **Create API Key**, задайте имя, скопируйте ключ вида `gsk_...`.
   Ключ показывается один раз — сохраните его сразу.

## Настройка

Настройки разделены на два файла:

- **`config.json`** — общие параметры (не зависят от LLM). Здесь же в поле
  `ProviderConfigPath` указывается путь ко второму файлу.
- **`<провайдер>.config.json`** — параметры конкретного LLM-провайдера
  (ключ, модель и т.п.). При переходе на другую модель меняется только этот файл.

1. Скопируйте шаблоны:
   ```powershell
   Copy-Item config.example.json config.json
   Copy-Item groq.config.example.json groq.config.json
   ```
2. Откройте `groq.config.json` и вставьте ключ в поле `ApiKey`.

Файлы `config.json` и `*.config.json` добавлены в `.gitignore`.

### Параметры config.json (общие)

| Поле                     | Назначение                                                        |
|--------------------------|-------------------------------------------------------------------|
| `Provider`               | Имя провайдера модели. Сейчас: `Groq`.                            |
| `ProviderConfigPath`     | Путь к файлу настроек провайдера (например, `./groq.config.json`). |
| `YtDlpPath`              | Путь к `yt-dlp.exe`. Относительный — от каталога скрипта. Пусто — брать из PATH. |
| `OutputDirectory`        | Каталог для итоговых файлов.                                      |
| `SubtitleLanguage`       | Язык субтитров. **Пусто — определяется автоматически** из видео (поле `language`). Задайте код (`en`, `ru`, …), чтобы переопределить. |
| `TranscriptGroupSeconds` | Шаг таймкодов в транскрипте (сек).                                |
| `KeepJson`               | `true` — сохранять JSON с промежуточными данными.                 |

### Параметры groq.config.json (специфичные для провайдера)

| Поле                         | Назначение                                                    |
|------------------------------|---------------------------------------------------------------|
| `ApiKey`                     | Ваш ключ `gsk_...`.                                           |
| `Model`                      | Модель Groq (по умолчанию `openai/gpt-oss-120b`). Список: `GET /openai/v1/models`. |
| `BaseUrl`                    | Endpoint (OpenAI-совместимый).                                |
| `Temperature`                | Температура генерации summary.                                |
| `MaxTokensPerChunk`          | Порог в токенах (оценка), свыше которого транскрипт режется на части. Уменьшите при ошибке лимита токенов (TPM) на бесплатном тарифе. |

## Запуск

Простой вариант — вписать ссылку в `Run.bat` (строка `set "URL=..."`) и запустить его.

Или напрямую через PowerShell:

```powershell
./src/Export-YoutubeVideoInfo.ps1 -Url "https://youtu.be/SWDWc8oHAf4"
```

Дополнительные параметры:

```powershell
# Свой каталог вывода
./src/Export-YoutubeVideoInfo.ps1 -Url "<url>" -OutputDirectory "D:\Notes"

# Сохранить также JSON с промежуточными данными
./src/Export-YoutubeVideoInfo.ps1 -Url "<url>" -KeepJson

# Другой файл настроек
./src/Export-YoutubeVideoInfo.ps1 -Url "<url>" -ConfigPath ".\config.work.json"
```

## Лимиты бесплатного тарифа Groq

Наблюдения по бесплатному тарифу (модель `openai/gpt-oss-120b` и остальные доступные):

- Лимит **8000 токенов в минуту (TPM)** одинаков у всех бесплатных моделей
  (`openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `qwen/qwen3.6-27b`, `qwen/qwen3.8-27b`),
  RPM ≈ 1000. Поэтому смена модели **не увеличивает** пропускную способность.
- Текст на кириллице «весит» в токенах заметно больше латиницы: один и тот же
  объём символов русского транскрипта даёт больше токенов, чем английского.
  Поэтому размер чанка считается в **токенах** (оценка по UTF-8 байтам), а не в символах.
- При превышении TPM скрипт **сам ждёт** (по заголовку `Retry-After`) и повторяет
  запрос — падения нет, но длинные видео обрабатываются медленно (порядка
  8000 токенов/мин). Это ограничение тарифа, а не ошибка.
- Частичные summary объединяются **иерархически** (партиями под лимит), иначе
  финальное слияние многих частей само превысило бы TPM.
- Если часто упираетесь в лимит — уменьшите `MaxTokensPerChunk`, берите видео
  покороче или перейдите на платный тариф Groq (Dev Tier) с более высоким TPM.

## Промт для summary

Текст промта берётся целиком из файла `SummaryPrompt.md`. Формат summary и язык
задаются именно в нём — правьте этот файл, чтобы изменить стиль краткого содержания.

## Структура проекта

```
Run.bat                         # запуск экспорта (впишите URL внутри)
Package.bat                     # сборка zip для разворачивания
SummaryPrompt.md                # промт для summary
config.example.json             # шаблон общих настроек
config.json                     # ваши общие настройки (в .gitignore)
groq.config.example.json        # шаблон настроек провайдера Groq
groq.config.json                # ваш ключ и модель (в .gitignore)
yt-dlp.exe                      # автономный yt-dlp (в .gitignore)
src/
  Export-YoutubeVideoInfo.ps1   # точка входа
  Package.ps1                   # логика сборки архива
  YoutubeSource.psm1            # метаданные и субтитры через yt-dlp
  SummaryProvider.psm1          # выбор провайдера + чанкинг длинных транскриптов
  MarkdownBuilder.psm1          # сборка Markdown и имени файла
  Providers/
    GroqProvider.psm1           # вызов Groq API
```

## Добавление нового провайдера

API Groq совместим с OpenAI, поэтому для другой модели (OpenAI, Gemini, Copilot и т.д.):

1. Создайте `src/Providers/<Имя>Provider.psm1` с функцией
   `Invoke-<Имя>Summary -SystemPrompt -UserContent -Config`.
2. Добавьте ветку в `switch` внутри `Invoke-SummaryProvider` в `src/SummaryProvider.psm1`.
3. Импортируйте модуль в `src/Export-YoutubeVideoInfo.ps1`.
4. Создайте свой `<имя>.config.json` в корне с параметрами этого провайдера
   и укажите в `config.json` поля `Provider` и `ProviderConfigPath`.
