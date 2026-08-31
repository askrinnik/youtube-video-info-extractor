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
        throw "Не задан ApiKey для OpenAI в openai.config.json (см. README.md)."
    }

    $baseUrl = if ([string]::IsNullOrWhiteSpace($Config.BaseUrl)) { 'https://api.openai.com/v1' } else { $Config.BaseUrl.TrimEnd('/') }
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

            # Нет баланса/квоты — повторять бессмысленно, нужна оплата
            if ($detail -match 'insufficient_quota') {
                throw "OpenAI API: недостаточно средств на балансе (insufficient_quota). Пополните баланс на platform.openai.com/settings/billing. $detail"
            }

            $isRateLimit = ($detail -match 'rate_limit_exceeded') -or
                ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 429)

            if ($isRateLimit -and $attempt -le $maxRetries) {
                $wait = Get-OpenAIRetryAfterSeconds -Exception $_ -Detail $detail
                Write-Warning "OpenAI: превышен лимит запросов. Ожидание $wait с и повтор (попытка $attempt из $maxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }

            if ($isRateLimit) {
                throw "OpenAI API: превышен лимит даже после повторов. Уменьшите MaxTokensPerChunk в openai.config.json или смените модель. $detail"
            }
            throw "Ошибка запроса к OpenAI API: $($_.Exception.Message). $detail"
        }
    }
}

function Get-OpenAIRetryAfterSeconds {
    param($Exception, [string]$Detail)
    # 1) Заголовок Retry-After
    $resp = $Exception.Exception.Response
    if ($resp -and $resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) {
        $s = [math]::Ceiling($resp.Headers.RetryAfter.Delta.TotalSeconds)
        if ($s -gt 0) { return [int]$s }
    }
    # 2) Из текста ошибки вида "try again in 1.5s"
    if ($Detail -match 'try again in\s+([0-9]+(?:\.[0-9]+)?)\s*s') {
        return [int][math]::Ceiling([double]$Matches[1]) + 1
    }
    return 20
}

Export-ModuleMember -Function Invoke-ProviderSummary
