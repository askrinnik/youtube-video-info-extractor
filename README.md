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
3. **API-ключ** одного из провайдеров: **Groq** или **Google Gemini** (оба с бесплатным тарифом).

## Как получить ключ Groq

1. Откройте <https://console.groq.com> и войдите (Google/GitHub, бесплатно, карта не нужна).
2. В меню слева выберите **API Keys**.
3. Нажмите **Create API Key**, задайте имя, скопируйте ключ вида `gsk_...`.
   Ключ показывается один раз — сохраните его сразу.

## Как получить ключ Google Gemini

1. Откройте <https://aistudio.google.com/apikey> и войдите в аккаунт Google.
2. Нажмите **Create API key** (можно в новом проекте).
3. Скопируйте ключ.

У Gemini бесплатный лимит по токенам в минуту (TPM) на порядки выше, чем у Groq,
поэтому длинные видео обрабатываются быстрее и почти без пауз на лимит.

## Настройка

Настройки разделены на два файла:

- **`config.json`** — общие параметры (не зависят от LLM). Поле `Provider` выбирает провайдера.
- **`<провайдер>.config.json`** — параметры конкретного LLM-провайдера
  (ключ, модель и т.п.). Имя этого файла **вычисляется автоматически** из `Provider`
  (в нижнем регистре): например, `Provider: "Gemini"` → `gemini.config.json`.

### Вариант A — Groq

```powershell
Copy-Item config.example.json config.json
Copy-Item groq.config.example.json groq.config.json
```

Вставьте ключ в `groq.config.json` → `ApiKey`. В `config.json` оставьте `"Provider": "Groq"`.

### Вариант B — Google Gemini

```powershell
Copy-Item config.example.json config.json
Copy-Item gemini.config.example.json gemini.config.json
```

Вставьте ключ в `gemini.config.json` → `ApiKey`. В `config.json` укажите `"Provider": "Gemini"`.

Переключение между провайдерами — только поле `Provider` (соответствующий файл подхватывается автоматически).

Файлы `config.json` и `*.config.json` добавлены в `.gitignore`.

### Параметры config.json (общие)

| Поле                     | Назначение                                                        |
|--------------------------|-------------------------------------------------------------------|
| `Provider`               | Имя провайдера: `Groq` или `Gemini`. Файл настроек провайдера (`<provider>.config.json`) подбирается автоматически. |
| `YtDlpPath`              | Путь к `yt-dlp.exe`. Относительный — от каталога скрипта. Пусто — брать из PATH. |
| `OutputDirectory`        | Каталог для итоговых файлов.                                      |
| `SubtitleLanguage`       | Язык субтитров. **Пусто — определяется автоматически** из видео (поле `language`). Задайте код (`en`, `ru`, …), чтобы переопределить. |
| `TranscriptGroupSeconds` | Шаг таймкодов в транскрипте (сек).                                |
| `KeepJson`               | `true` — сохранять JSON с промежуточными данными.                 |
### Параметры <провайдер>.config.json (специфичные для провайдера)

**groq.config.json:**

| Поле                         | Назначение                                                    |
|------------------------------|---------------------------------------------------------------|
| `ApiKey`                     | Ваш ключ `gsk_...`.                                           |
| `Model`                      | Модель Groq (по умолчанию `openai/gpt-oss-120b`). Список: `GET /openai/v1/models`. |
| `BaseUrl`                    | Endpoint (OpenAI-совместимый).                                |
| `Temperature`                | Температура генерации summary.                                |
| `MaxTokensPerChunk`          | Порог в токенах (оценка), свыше которого транскрипт режется на части. Уменьшите при ошибке лимита токенов (TPM). |

**gemini.config.json:**

| Поле                | Назначение                                                          |
|---------------------|---------------------------------------------------------------------|
| `ApiKey`            | Ваш ключ Gemini.                                                    |
| `Model`             | Модель Gemini (по умолчанию `gemini-flash-latest` — алиас на актуальную flash). Список: `GET /v1beta/models`. |
| `BaseUrl`           | Endpoint Generative Language API.                                   |
| `Temperature`       | Температура генерации summary.                                      |
| `MaxTokensPerChunk` | Порог чанкинга в токенах. У Gemini лимит TPM высокий, можно ставить большим (напр. 100000) — чанкинг почти не нужен. |

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
  покороче, перейдите на платный тариф Groq (Dev Tier) **или используйте
  провайдер Gemini** — у него бесплатный TPM на порядки выше.

## Лимиты бесплатного тарифа Gemini

Наблюдения по бесплатному тарифу (модель `gemini-flash-latest`):

- Лимит **токенов в минуту (TPM) на порядки выше**, чем у Groq (сотни тысяч против
  8000). На практике даже часовой русский транскрипт уходит **одним запросом**,
  без чанкинга и пауз — обработка почти мгновенная. Поэтому `MaxTokensPerChunk`
  в `gemini.config.example.json` выставлен большим (100000) — резать почти не нужно.
- Ограничения бесплатного тарифа — это в первую очередь **запросы в минуту (RPM)**
  и **запросы в день (RPD)**, а не токены. Точные лимиты зависят от модели и видны
  в [Google AI Studio → Rate limits](https://aistudio.google.com/rate-limit).
- **Имена моделей устаревают.** Конкретные версии (например, `gemini-2.5-flash`)
  со временем становятся недоступны новым пользователям. Поэтому по умолчанию
  используется алиас **`gemini-flash-latest`** — он всегда указывает на актуальную
  flash-модель. Список доступных моделей: `GET /v1beta/models`.
- Иногда приходит временная ошибка **503 UNAVAILABLE** («high demand») — это не
  ошибка настройки; скрипт **сам ждёт и повторяет** запрос.
- При превышении лимитов (429 `RESOURCE_EXHAUSTED`) скрипт ждёт указанное в ответе
  время (`retryDelay`) и повторяет — как и для Groq.

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
gemini.config.example.json      # шаблон настроек провайдера Gemini
groq.config.json                # ваш ключ Groq (в .gitignore)
gemini.config.json              # ваш ключ Gemini (в .gitignore)
yt-dlp.exe                      # автономный yt-dlp (в .gitignore)
src/
  Export-YoutubeVideoInfo.ps1   # точка входа
  Package.ps1                   # логика сборки архива
  YoutubeSource.psm1            # метаданные и субтитры через yt-dlp
  SummaryProvider.psm1          # выбор провайдера + чанкинг длинных транскриптов
  MarkdownBuilder.psm1          # сборка Markdown и имени файла
  Providers/
    GroqProvider.psm1           # вызов Groq API
    GeminiProvider.psm1         # вызов Google Gemini API
```

## Добавление нового провайдера

Провайдеры взаимозаменяемы: каждый модуль экспортирует функцию с **одинаковым
именем** `Invoke-ProviderSummary`, а главный скрипт по полю `Provider` подключает
**только нужный** модуль и вызывает эту функцию. Ни диспетчера, ни правки switch.

Чтобы добавить провайдера `Foo`:

1. Создайте `src/Providers/FooProvider.psm1` с функцией
   `Invoke-ProviderSummary -SystemPrompt -UserContent -Config` (сигнатура и имя —
   как у существующих; в конце `Export-ModuleMember -Function Invoke-ProviderSummary`).
2. Создайте `foo.config.json` в корне с параметрами провайдера
   (`ApiKey`, `Model`, `BaseUrl`, `Temperature`, `MaxTokensPerChunk`).
3. В `config.json` укажите `"Provider": "Foo"` — модуль `FooProvider.psm1` и файл
   `foo.config.json` подхватятся автоматически.
