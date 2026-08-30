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
        throw "Не задан ApiKey для Groq в config.json (см. README.md)."
    }

    $baseUrl = if ([string]::IsNullOrWhiteSpace($Config.BaseUrl)) { 'https://api.groq.com/openai/v1' } else { $Config.BaseUrl.TrimEnd('/') }
    $uri = "$baseUrl/chat/completions"

    $payload = @{
        model       = $Config.Model
        temperature = [double]$Config.Temperature
        messages    = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user'; content = $UserContent }
        )
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 6))
    $headers = @{ Authorization = "Bearer $($Config.ApiKey)" }

    $maxRetries = 5
    for ($attempt = 1; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $body
            return $response.choices[0].message.content.Trim()
        }
        catch {
            $detail = $_.ErrorDetails.Message
            $isRateLimit = $detail -match 'rate_limit_exceeded' -or
                ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 429)

            if ($isRateLimit -and $attempt -le $maxRetries) {
                $wait = Get-RetryAfterSeconds -Exception $_ -Detail $detail
                Write-Warning "Groq: превышен лимит токенов (TPM). Ожидание $wait с и повтор (попытка $attempt из $maxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }

            if ($isRateLimit) {
                throw "Groq API: превышен лимит токенов даже после повторов. Уменьшите MaxTranscriptCharsPerChunk в groq.config.json или смените модель. $detail"
            }
            throw "Ошибка запроса к Groq API: $($_.Exception.Message). $detail"
        }
    }
}

function Get-RetryAfterSeconds {
    param($Exception, [string]$Detail)
    # 1) Заголовок Retry-After
    $resp = $Exception.Exception.Response
    if ($resp -and $resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) {
        $s = [math]::Ceiling($resp.Headers.RetryAfter.Delta.TotalSeconds)
        if ($s -gt 0) { return [int]$s }
    }
    # 2) Из текста ошибки вида "try again in 12.5s"
    if ($Detail -match 'try again in\s+([0-9]+(?:\.[0-9]+)?)\s*s') {
        return [int][math]::Ceiling([double]$Matches[1]) + 1
    }
    # 3) По умолчанию — минута (TPM считается за минуту)
    return 60
}

Export-ModuleMember -Function Invoke-ProviderSummary

