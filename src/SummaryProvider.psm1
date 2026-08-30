#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-VideoSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Transcript,
        [Parameter(Mandatory)]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Transcript)) {
        return '_Транскрипт недоступен — summary не сформировано._'
    }

    $maxTokens = [int]$Config.MaxTokensPerChunk
    if ($maxTokens -le 0) { $maxTokens = 4000 }

    if ((Get-EstimatedTokens $Transcript) -le $maxTokens) {
        return (Invoke-ProviderSummary -SystemPrompt $Prompt -UserContent $Transcript -Config $Config)
    }

    $chunks = Split-Transcript -Transcript $Transcript -MaxTokens $maxTokens
    Write-Verbose "Транскрипт разбит на $($chunks.Count) частей для чанкинга."

    $partials = [System.Collections.Generic.List[string]]::new()
    for ($n = 0; $n -lt $chunks.Count; $n++) {
        $partPrompt = $Prompt + "`n`nЭто ЧАСТЬ $($n + 1) из $($chunks.Count) транскрипта одного видео. Составь summary только для этой части, строго соблюдая требуемый формат."
        $partials.Add((Invoke-ProviderSummary -SystemPrompt $partPrompt -UserContent $chunks[$n] -Config $Config))
    }

    return (Merge-Summaries -Partials $partials -Prompt $Prompt -Config $Config -MaxTokens $maxTokens)
}

function Merge-Summaries {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Partials,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$MaxTokens
    )
    if ($Partials.Count -le 1) {
        return ($Partials -join "`n").Trim()
    }

    $mergePrompt = $Prompt + "`n`nНиже приведены частичные summary разных отрезков одного видео. Объедини их в единый список: убери дубли, сохрани хронологический порядок и формат диапазонов таймкодов."

    # Иерархическое объединение: партии под лимит токенов, чтобы каждый запрос помещался
    $items = [System.Collections.Generic.List[string]]::new($Partials)
    while ($items.Count -gt 1) {
        $next = [System.Collections.Generic.List[string]]::new()
        $batch = [System.Collections.Generic.List[string]]::new()
        $batchTokens = 0

        foreach ($item in $items) {
            $itemTokens = Get-EstimatedTokens $item
            if ($batch.Count -gt 0 -and ($batchTokens + $itemTokens) -gt $MaxTokens) {
                $next.Add((Invoke-ProviderSummary -SystemPrompt $mergePrompt -UserContent ($batch -join "`n") -Config $Config))
                $batch.Clear()
                $batchTokens = 0
            }
            $batch.Add($item)
            $batchTokens += $itemTokens
        }
        if ($batch.Count -eq 1) {
            $next.Add($batch[0])
        }
        elseif ($batch.Count -gt 1) {
            $next.Add((Invoke-ProviderSummary -SystemPrompt $mergePrompt -UserContent ($batch -join "`n") -Config $Config))
        }

        # Защита от зацикливания, если ужать не удалось
        if ($next.Count -ge $items.Count) {
            return ($next -join "`n").Trim()
        }
        $items = $next
    }
    return ($items[0]).Trim()
}

function Get-EstimatedTokens {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    # Оценка по UTF-8 байтам устойчивее к языку, чем по символам (кириллица «весит» больше)
    return [int][math]::Ceiling([System.Text.Encoding]::UTF8.GetByteCount($Text) / 2.5)
}

function Split-Transcript {
    param(
        [Parameter(Mandatory)][string]$Transcript,
        [Parameter(Mandatory)][int]$MaxTokens
    )
    $blocks = $Transcript -split '\r?\n\r?\n' | Where-Object { $_.Trim() -ne '' }
    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $currentTokens = 0

    foreach ($b in $blocks) {
        $blockTokens = Get-EstimatedTokens $b
        if ($current.Length -gt 0 -and ($currentTokens + $blockTokens) -gt $MaxTokens) {
            $chunks.Add($current.ToString().TrimEnd())
            [void]$current.Clear()
            $currentTokens = 0
        }
        if ($current.Length -gt 0) {
            [void]$current.AppendLine()
            [void]$current.AppendLine()
        }
        [void]$current.Append($b)
        $currentTokens += $blockTokens
    }
    if ($current.Length -gt 0) {
        $chunks.Add($current.ToString().TrimEnd())
    }
    return $chunks
}

Export-ModuleMember -Function Get-VideoSummary
