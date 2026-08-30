#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-GroqSummary {
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

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $body
    }
    catch {
        $detail = $_.ErrorDetails.Message
        throw "Ошибка запроса к Groq API: $($_.Exception.Message). $detail"
    }

    return $response.choices[0].message.content.Trim()
}

Export-ModuleMember -Function Invoke-GroqSummary
