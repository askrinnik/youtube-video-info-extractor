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

    $maxChars = [int]$Config.MaxTranscriptCharsPerChunk
    if ($maxChars -le 0) { $maxChars = 24000 }

    if ($Transcript.Length -le $maxChars) {
        return (Invoke-SummaryProvider -SystemPrompt $Prompt -UserContent $Transcript -Config $Config)
    }

    $chunks = Split-Transcript -Transcript $Transcript -MaxChars $maxChars
    Write-Verbose "Транскрипт разбит на $($chunks.Count) частей для чанкинга."

    $partials = [System.Collections.Generic.List[string]]::new()
    for ($n = 0; $n -lt $chunks.Count; $n++) {
        $partPrompt = $Prompt + "`n`nЭто ЧАСТЬ $($n + 1) из $($chunks.Count) транскрипта одного видео. Составь summary только для этой части, строго соблюдая требуемый формат."
        $partials.Add((Invoke-SummaryProvider -SystemPrompt $partPrompt -UserContent $chunks[$n] -Config $Config))
    }

    $combined = ($partials -join "`n")
    $mergePrompt = $Prompt + "`n`nНиже приведены частичные summary разных отрезков одного видео. Объедини их в единый список из 5–10 пунктов: убери дубли, сохрани хронологический порядок и формат диапазонов таймкодов."
    return (Invoke-SummaryProvider -SystemPrompt $mergePrompt -UserContent $combined -Config $Config)
}

function Invoke-SummaryProvider {
    param(
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserContent,
        [Parameter(Mandatory)]$Config
    )
    switch (($Config.Provider).ToString().ToLowerInvariant()) {
        'groq' { return (Invoke-GroqSummary -SystemPrompt $SystemPrompt -UserContent $UserContent -Config $Config) }
        default { throw "Неизвестный провайдер '$($Config.Provider)'. Сейчас поддерживается: Groq." }
    }
}

function Split-Transcript {
    param(
        [Parameter(Mandatory)][string]$Transcript,
        [Parameter(Mandatory)][int]$MaxChars
    )
    $blocks = $Transcript -split '\r?\n\r?\n' | Where-Object { $_.Trim() -ne '' }
    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()

    foreach ($b in $blocks) {
        if ($current.Length -gt 0 -and ($current.Length + $b.Length + 2) -gt $MaxChars) {
            $chunks.Add($current.ToString().TrimEnd())
            [void]$current.Clear()
        }
        if ($current.Length -gt 0) {
            [void]$current.AppendLine()
            [void]$current.AppendLine()
        }
        [void]$current.Append($b)
    }
    if ($current.Length -gt 0) {
        $chunks.Add($current.ToString().TrimEnd())
    }
    return $chunks
}

Export-ModuleMember -Function Get-VideoSummary
