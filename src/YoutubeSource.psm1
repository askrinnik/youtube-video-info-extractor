#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-YtDlpPath {
    param([string]$Path)
    # Путь из настроек имеет приоритет; иначе — локальный exe, затем PATH
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (Test-Path $Path) { return (Resolve-Path $Path).Path }
        throw "yt-dlp не найден по указанному в config.json пути (YtDlpPath): $Path"
    }
    $local = Join-Path (Split-Path $PSScriptRoot -Parent) 'yt-dlp.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "yt-dlp не найден. Укажите путь в config.json (YtDlpPath) или установите 'winget install yt-dlp.yt-dlp' (см. README.md)."
}

function Test-YtDlp {
    param([string]$Path)
    [void](Get-YtDlpPath -Path $Path)
}

function Get-YoutubeMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$YtDlpPath
    )
    $ytDlp = Get-YtDlpPath -Path $YtDlpPath
    # Иногда yt-dlp возвращает ответ без поля language (отвечает web/tv-клиент) — повторяем, чтобы язык определился стабильно
    $meta = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $json = & $ytDlp --dump-single-json --skip-download --no-warnings $Url 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            throw "Не удалось получить метаданные видео через yt-dlp для URL: $Url"
        }
        $meta = $json | ConvertFrom-Json
        $lp = $meta.PSObject.Properties['language']
        if ($lp -and -not [string]::IsNullOrWhiteSpace("$($lp.Value)")) { break }
    }
    return $meta
}

function Get-BestSubtitleLanguage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metadata,
        [string]$Preferred
    )
    $manual = @()
    $auto = @()
    $primary = ''

    $sp = $Metadata.PSObject.Properties['subtitles']
    if ($sp -and $sp.Value) { $manual = @($sp.Value.PSObject.Properties | ForEach-Object Name) }
    $ap = $Metadata.PSObject.Properties['automatic_captions']
    if ($ap -and $ap.Value) { $auto = @($ap.Value.PSObject.Properties | ForEach-Object Name) }
    $lp = $Metadata.PSObject.Properties['language']
    if ($lp -and $lp.Value) { $primary = "$($lp.Value)" }

    # Родной язык видео надёжнее брать из аудиодорожки-оригинала (format_note ~ "original"
    # или максимальный language_preference): поле language yt-dlp отдаёт нестабильно,
    # а для видео с дубляжом порой подставляет язык озвучки вместо оригинала.
    $fp = $Metadata.PSObject.Properties['formats']
    if ($fp -and $fp.Value) {
        $audio = @($fp.Value | Where-Object {
                $_.PSObject.Properties['acodec'] -and $_.acodec -ne 'none' -and
                $_.PSObject.Properties['language'] -and $_.language
            })
        $orig = $audio | Where-Object { $_.PSObject.Properties['format_note'] -and $_.format_note -match '(?i)original' } | Select-Object -First 1
        if (-not $orig -and $audio.Count -gt 0) {
            $orig = $audio | Sort-Object -Property @{ Expression = { if ($_.PSObject.Properties['language_preference']) { [int]$_.language_preference } else { -999 } } } -Descending | Select-Object -First 1
        }
        if ($orig -and -not [string]::IsNullOrWhiteSpace("$($orig.language)")) { $primary = "$($orig.language)" }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$key)
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $candidates.Contains($key)) { $candidates.Add($key) }
    }

    # Для базового языка: ручные -> оригинальная авто-дорожка (<base>-orig) -> обычная (<base>).
    # Обычные (переведённые) авто-субтитры YouTube отдаёт через лимитируемый эндпоинт (HTTP 429),
    # а <base>-orig скачивается стабильно, поэтому оригинал приоритетнее перевода.
    $addBase = {
        param([string]$cand)
        if ([string]::IsNullOrWhiteSpace($cand)) { return }
        $base = ($cand -split '-')[0]
        $rx = "^$([regex]::Escape($base))(-|$)"
        foreach ($m in ($manual | Where-Object { $_ -imatch $rx })) { & $add $m }
        foreach ($o in ($auto   | Where-Object { $_ -imatch "^$([regex]::Escape($base))-orig$" })) { & $add $o }
        foreach ($p in ($auto   | Where-Object { $_ -ieq $base })) { & $add $p }
        foreach ($r in ($auto   | Where-Object { $_ -imatch $rx })) { & $add $r }
    }

    # Настройка пользователя важнее всего. Дальше выбираем порядок по языку видео:
    # английское (или неизвестное) видео -> en, ru; не английское -> оригинал, ru, en.
    & $addBase $Preferred
    $primaryBase = ''
    if (-not [string]::IsNullOrWhiteSpace($primary)) { $primaryBase = ($primary -split '-')[0] }
    if ($primaryBase -and $primaryBase -inotmatch '^en$') {
        & $addBase $primary
        & $addBase 'ru'
        & $addBase 'en'
    }
    else {
        & $addBase 'en'
        & $addBase 'ru'
    }

    # Финальный фолбэк: любые оригинальные авто-дорожки, ручные, затем всё остальное.
    foreach ($o in ($auto   | Where-Object { $_ -match '-orig$' })) { & $add $o }
    foreach ($m in $manual) { & $add $m }
    foreach ($a in $auto)   { & $add $a }

    if ($candidates.Count -eq 0) { & $add 'en' }
    return $candidates.ToArray()
}

function Get-YoutubeTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string[]]$Languages = @('en'),
        [int]$GroupSeconds = 30,
        [string]$YtDlpPath,
        [int]$MaxAttempts = 3
    )
    $ytDlp = Get-YtDlpPath -Path $YtDlpPath
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ytvi_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $outTemplate = Join-Path $tempDir '%(id)s.%(ext)s'
        $langs = @($Languages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($langs.Count -eq 0) { $langs = @('en') }
        $lastError = ''

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $sawRateLimit = $false
            foreach ($lang in $langs) {
                Get-ChildItem -Path $tempDir -Filter '*.vtt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

                # Не глушим вывод yt-dlp: перехватываем stderr, чтобы показать реальную причину сбоя
                $output = & $ytDlp --skip-download --write-auto-subs --write-subs `
                    --sub-langs $lang --sub-format vtt `
                    -o $outTemplate $Url 2>&1 | Out-String

                $vtt = Get-ChildItem -Path $tempDir -Filter '*.vtt' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($vtt) {
                    Write-Host "Субтитры получены, язык: $lang" -ForegroundColor Green
                    $entries = ConvertFrom-VttFile -Path $vtt.FullName
                    return (Format-Transcript -Entries $entries -GroupSeconds $GroupSeconds)
                }

                $lastError = (($output -split '\r?\n') | Where-Object { $_ -match 'ERROR|WARNING' } | Select-Object -Last 2) -join ' | '
                if ($output -match '429|Too Many Requests') { $sawRateLimit = $true }
            }

            # 429 лимитирует эндпоинт субтитров целиком — ждём и пробуем весь список заново
            if ($sawRateLimit -and $attempt -lt $MaxAttempts) {
                $delay = 10 * $attempt
                Write-Warning "YouTube вернул HTTP 429 (превышен лимит запросов). Повтор через $delay c (попытка $attempt из $MaxAttempts)..."
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        Write-Warning "Не удалось получить субтитры (пробованы: $($langs -join ', ')). Транскрипт будет пустым."
        if ($lastError) { Write-Warning "Причина (yt-dlp): $lastError" }
        if ($lastError -match 'PO Token|JavaScript runtime') {
            Write-Warning "Похоже, отсутствует JS-runtime для yt-dlp. Установите deno (см. README.md) — положите deno.exe рядом с yt-dlp.exe."
        }
        return ''
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-VttFile {
    param([Parameter(Mandatory)][string]$Path)

    $lines = Get-Content -Path $Path -Encoding utf8
    $cues = [System.Collections.Generic.List[pscustomobject]]::new()
    $timeRegex = '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})\.(?<ms>\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})'
    $inlineTag = '<\d{2}:\d{2}:\d{2}\.\d{3}>'

    $i = 0
    $anyInline = $false
    while ($i -lt $lines.Count) {
        $m = [regex]::Match($lines[$i], $timeRegex)
        if ($m.Success) {
            $start = ([int]$m.Groups['h'].Value) * 3600 + ([int]$m.Groups['m'].Value) * 60 + [int]$m.Groups['s'].Value
            $i++
            $textLines = [System.Collections.Generic.List[string]]::new()
            while ($i -lt $lines.Count -and $lines[$i] -ne '' -and -not [regex]::IsMatch($lines[$i], $timeRegex)) {
                $textLines.Add($lines[$i])
                if ([regex]::IsMatch($lines[$i], $inlineTag)) { $anyInline = $true }
                $i++
            }
            $cues.Add([pscustomobject]@{ Start = $start; Lines = $textLines })
        }
        else {
            $i++
        }
    }

    $entries = [System.Collections.Generic.List[pscustomobject]]::new()
    $lastText = ''
    foreach ($cue in $cues) {
        # У автосубтитров реальный новый текст несут только строки с встроенными тайм-тегами
        if ($anyInline) {
            $selected = @($cue.Lines | Where-Object { [regex]::IsMatch($_, $inlineTag) })
        }
        else {
            $selected = @($cue.Lines)
        }
        if ($selected.Count -eq 0) { continue }

        $text = ($selected -join ' ')
        $text = [regex]::Replace($text, '<[^>]+>', '')
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        $text = ($text -replace '\s+', ' ').Trim()

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -eq $lastText) { continue }

        $entries.Add([pscustomobject]@{ Start = $cue.Start; Text = $text })
        $lastText = $text
    }
    return $entries
}

function Format-Transcript {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[pscustomobject]]$Entries,
        [int]$GroupSeconds = 30
    )
    if ($Entries.Count -eq 0) { return '' }

    $formatTime = {
        param([int]$total)
        $mm = [math]::Floor($total / 60)
        $ss = $total % 60
        '{0}:{1:D2}' -f $mm, $ss
    }

    $sb = [System.Text.StringBuilder]::new()
    $segStart = $Entries[0].Start
    $buffer = [System.Collections.Generic.List[string]]::new()

    foreach ($e in $Entries) {
        if ($buffer.Count -gt 0 -and ($e.Start - $segStart) -ge $GroupSeconds) {
            [void]$sb.AppendLine(('**{0}** · {1}' -f (& $formatTime $segStart), ($buffer -join ' ')))
            [void]$sb.AppendLine()
            $buffer.Clear()
            $segStart = $e.Start
        }
        $buffer.Add($e.Text)
    }
    if ($buffer.Count -gt 0) {
        [void]$sb.AppendLine(('**{0}** · {1}' -f (& $formatTime $segStart), ($buffer -join ' ')))
    }
    return $sb.ToString().TrimEnd()
}

Export-ModuleMember -Function Get-YoutubeMetadata, Get-YoutubeTranscript, Test-YtDlp, Get-YtDlpPath, Get-BestSubtitleLanguage
