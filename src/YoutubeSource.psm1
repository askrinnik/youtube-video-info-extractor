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
    $json = & $ytDlp --dump-single-json --skip-download --no-warnings $Url 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Не удалось получить метаданные видео через yt-dlp для URL: $Url"
    }
    return ($json | ConvertFrom-Json)
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

    $available = @($manual + $auto)

    # \u041f\u0440\u0438\u043e\u0440\u0438\u0442\u0435\u0442: \u044f\u0432\u043d\u0430\u044f \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430, \u0437\u0430\u0442\u0435\u043c \u044f\u0437\u044b\u043a \u0441\u0430\u043c\u043e\u0433\u043e \u0432\u0438\u0434\u0435\u043e (\u043f\u043e\u043b\u0435 language)
    foreach ($cand in @($Preferred, $primary)) {
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        $base = ($cand -split '-')[0]
        $hit = $available | Where-Object { $_ -ieq $cand -or $_ -imatch "^$([regex]::Escape($base))(-|$)" } | Select-Object -First 1
        if ($hit) { return $base }
    }

    if ($manual.Count -gt 0) { return (($manual[0]) -split '-')[0] }
    if (-not [string]::IsNullOrWhiteSpace($primary)) { return ($primary -split '-')[0] }
    return 'en'
}

function Get-YoutubeTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$Language = 'en',
        [int]$GroupSeconds = 30,
        [string]$YtDlpPath
    )
    $ytDlp = Get-YtDlpPath -Path $YtDlpPath
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ytvi_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $outTemplate = Join-Path $tempDir '%(id)s.%(ext)s'
        & $ytDlp --skip-download --write-auto-subs --write-subs `
            --sub-langs "$Language.*" --sub-format vtt `
            --no-warnings -o $outTemplate $Url 2>$null | Out-Null

        $vtt = Get-ChildItem -Path $tempDir -Filter '*.vtt' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $vtt) {
            Write-Warning "Субтитры для языка '$Language' не найдены. Транскрипт будет пустым."
            return ''
        }
        $entries = ConvertFrom-VttFile -Path $vtt.FullName
        return (Format-Transcript -Entries $entries -GroupSeconds $GroupSeconds)
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
