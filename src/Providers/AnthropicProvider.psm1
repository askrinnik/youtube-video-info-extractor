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
        throw "Не задан ApiKey для Anthropic в anthropic.config.json (см. README.md)."
    }

    $baseUrl = if ([string]::IsNullOrWhiteSpace($Config.BaseUrl)) { 'https://api.anthropic.com/v1' } else { $Config.BaseUrl.TrimEnd('/') }
    $uri = "$baseUrl/messages"

    # max_tokens у Anthropic обязателен; для summary достаточно небольшого значения
    $maxOut = 4096
    $mp = $Config.PSObject.Properties['MaxOutputTokens']
    if ($mp -and $mp.Value) { $maxOut = [int]$mp.Value }

    $payload = @{
        model      = $Config.Model
        max_tokens = $maxOut
        system     = $SystemPrompt
        messages   = @(@{ role = 'user'; content = $UserContent })
    }
    # temperature устарел у новых моделей Claude — шлём только при явном SendTemperature=true
    $st = $Config.PSObject.Properties['SendTemperature']
    if ($st -and $st.Value) { $payload['temperature'] = [double]$Config.Temperature }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 6))
    $headers = @{
        'x-api-key'         = $Config.ApiKey
        'anthropic-version' = '2023-06-01'
    }
    # Identity-linked ключам нужен ID рабочего пространства
    $wp = $Config.PSObject.Properties['WorkspaceId']
    if ($wp -and $wp.Value) { $headers['anthropic-workspace-id'] = $wp.Value }

    $maxRetries = 5
    for ($attempt = 1; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $body
            return (Get-AnthropicText -Response $response)
        }
        catch {
            $detail = $_.ErrorDetails.Message
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $isRateLimit = ($status -eq 429) -or ($detail -match 'rate_limit_error')
            # 529 overloaded_error — временная перегрузка, тоже повторяем
            $isOverloaded = ($status -eq 529) -or ($detail -match 'overloaded_error')

            if (($isRateLimit -or $isOverloaded) -and $attempt -le $maxRetries) {
                $wait = Get-AnthropicRetryAfterSeconds -Exception $_ -Detail $detail -IsOverloaded:$isOverloaded -Attempt $attempt
                $why = if ($isRateLimit) { 'превышен лимит запросов' } else { 'сервис перегружен (529)' }
                Write-Warning "Anthropic: $why. Ожидание $wait с и повтор (попытка $attempt из $maxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }

            if ($isRateLimit) {
                throw "Anthropic API: превышен лимит даже после повторов. Уменьшите MaxTokensPerChunk в anthropic.config.json или смените модель. $detail"
            }
            throw "Ошибка запроса к Anthropic API: $($_.Exception.Message). $detail"
        }
    }
}

function Get-AnthropicText {
    param($Response)
    $blocks = @($Response.content)
    if ($blocks.Count -eq 0) {
        throw "Anthropic не вернул содержимое ответа (stop_reason: $(Get-MetaSafe $Response 'stop_reason'))."
    }
    # У моделей с thinking бывают служебные блоки; берём только текстовые
    $texts = @($blocks | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    return (($texts -join "`n").Trim())
}

function Get-MetaSafe {
    param($Object, [string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return ''
}

function Get-AnthropicRetryAfterSeconds {
    param($Exception, [string]$Detail, [switch]$IsOverloaded, [int]$Attempt = 1)
    # Заголовок Retry-After (в секундах)
    $resp = $Exception.Exception.Response
    if ($resp -and $resp.Headers.RetryAfter) {
        if ($resp.Headers.RetryAfter.Delta) {
            $s = [math]::Ceiling($resp.Headers.RetryAfter.Delta.TotalSeconds)
            if ($s -gt 0) { return [int]$s }
        }
    }
    # Перегрузка (529) — короткий нарастающий бэкофф
    if ($IsOverloaded) { return [Math]::Min(30, 5 * $Attempt) }
    return 20
}

Export-ModuleMember -Function Invoke-ProviderSummary
