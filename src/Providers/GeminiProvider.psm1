#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-ProviderSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserContent,
        [Parameter(Mandatory)]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.ApiKey) -or $Config.ApiKey -like '*ЗАМЕНИ*') {
        throw "Не задан ApiKey для Gemini в gemini.config.json (см. README.md)."
    }

    $baseUrl = if ([string]::IsNullOrWhiteSpace($Config.BaseUrl)) { 'https://generativelanguage.googleapis.com/v1beta' } else { $Config.BaseUrl.TrimEnd('/') }
    $uri = "$baseUrl/models/$($Config.Model):generateContent"

    $payload = @{
        systemInstruction = @{ parts = @(@{ text = $SystemPrompt }) }
        contents          = @(@{ role = 'user'; parts = @(@{ text = $UserContent }) })
        generationConfig  = @{ temperature = [double]$Config.Temperature }
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8))
    $headers = @{ 'x-goog-api-key' = $Config.ApiKey }

    $maxRetries = 5
    for ($attempt = 1; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $body
            return (Get-GeminiText -Response $response)
        }
        catch {
            $detail = $_.ErrorDetails.Message
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $isRateLimit = ($status -eq 429) -or ($detail -match 'RESOURCE_EXHAUSTED')
            # 503/UNAVAILABLE — временная перегрузка модели, тоже имеет смысл повторить
            $isTransient = ($status -eq 503) -or ($detail -match 'UNAVAILABLE')

            if (($isRateLimit -or $isTransient) -and $attempt -le $maxRetries) {
                $wait = if ($isTransient -and -not $isRateLimit) { [Math]::Min(30, 5 * $attempt) } else { Get-GeminiRetryAfterSeconds -Exception $_ -Detail $detail }
                $why = if ($isRateLimit) { 'превышен лимит запросов' } else { 'модель временно недоступна (503)' }
                Write-Warning "Gemini: $why. Ожидание $wait с и повтор (попытка $attempt из $maxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }

            if ($isRateLimit) {
                throw "Gemini API: превышен лимит даже после повторов. Уменьшите MaxTokensPerChunk в gemini.config.json или смените модель. $detail"
            }
            throw "Ошибка запроса к Gemini API: $($_.Exception.Message). $detail"
        }
    }
}

function Get-GeminiText {
    param($Response)
    $cand = @($Response.candidates)
    if ($cand.Count -eq 0) {
        $reason = ''
        $pf = $Response.PSObject.Properties['promptFeedback']
        if ($pf -and $pf.Value.PSObject.Properties['blockReason']) {
            $reason = " (blockReason: $($pf.Value.blockReason))"
        }
        throw "Gemini не вернул кандидатов ответа$reason."
    }
    # У thinking-моделей могут быть служебные части; берём только текстовые
    $texts = @($cand[0].content.parts | Where-Object { $_.PSObject.Properties['text'] } | ForEach-Object { $_.text })
    return (($texts -join "`n").Trim())
}

function Get-GeminiRetryAfterSeconds {
    param($Exception, [string]$Detail)
    # Gemini отдаёт retryDelay в теле ошибки, напр. "retryDelay": "42s"
    if ($Detail -and $Detail -match 'retryDelay"?\s*:\s*"?([0-9]+(?:\.[0-9]+)?)s') {
        return [int][math]::Ceiling([double]$Matches[1]) + 1
    }
    $resp = $Exception.Exception.Response
    if ($resp -and $resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) {
        $s = [math]::Ceiling($resp.Headers.RetryAfter.Delta.TotalSeconds)
        if ($s -gt 0) { return [int]$s }
    }
    return 30
}

Export-ModuleMember -Function Invoke-ProviderSummary
