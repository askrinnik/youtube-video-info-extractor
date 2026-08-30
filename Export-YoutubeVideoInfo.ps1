#Requires -Version 7.0
<#
.SYNOPSIS
    Экспортирует информацию о YouTube-видео в Markdown-документ с summary и транскриптом.
.DESCRIPTION
    По URL видео получает метаданные и субтитры через yt-dlp, генерирует summary через
    выбранного провайдера (по умолчанию Groq) с промтом из SummaryPrompt.md и собирает
    Markdown в формате Obsidian Web Clipper: сначала секция Summary, затем полный транскрипт.
.PARAMETER Url
    Ссылка на YouTube-видео.
.PARAMETER OutputDirectory
    Каталог для итогового файла (переопределяет значение из config.json).
.PARAMETER ConfigPath
    Путь к файлу настроек. По умолчанию config.json рядом со скриптом.
.PARAMETER PromptPath
    Путь к файлу промта. По умолчанию SummaryPrompt.md рядом со скриптом.
.PARAMETER KeepJson
    Сохранить рядом JSON с промежуточными данными.
.EXAMPLE
    ./Export-YoutubeVideoInfo.ps1 -Url "https://youtu.be/SWDWc8oHAf4"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Url,

    [string]$OutputDirectory,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [string]$PromptPath = (Join-Path $PSScriptRoot 'SummaryPrompt.md'),

    [switch]$KeepJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/YoutubeSource.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src/Providers/GroqProvider.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src/SummaryProvider.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src/MarkdownBuilder.psm1') -Force

function Get-ConfigValue {
    param($Object, [string]$Name, $Default)
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
        return $prop.Value
    }
    return $Default
}

if (-not (Test-Path $ConfigPath)) {
    throw "Файл настроек не найден: $ConfigPath. Скопируйте config.example.json в config.json и заполните ApiKey (см. README.md)."
}
if (-not (Test-Path $PromptPath)) {
    throw "Файл промта не найден: $PromptPath."
}

$rawConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$provider = Get-ConfigValue $rawConfig 'Provider' 'Groq'
$providerConfigName = Get-ConfigValue $rawConfig 'ProviderConfigPath' ''
if ([string]::IsNullOrWhiteSpace($providerConfigName)) {
    throw "В основном config.json не задан ProviderConfigPath — имя файла с настройками провайдера (см. README.md)."
}

# Путь к файлу настроек провайдера считаем от каталога основного конфига
$providerConfigPath = $providerConfigName
if (-not [System.IO.Path]::IsPathRooted($providerConfigPath)) {
    $providerConfigPath = Join-Path (Split-Path $ConfigPath -Parent) $providerConfigName
}
if (-not (Test-Path $providerConfigPath)) {
    throw "Файл настроек провайдера не найден: $providerConfigPath. Создайте его (см. providers/*.config.example.json и README.md)."
}
$rawProvider = Get-Content -Path $providerConfigPath -Raw | ConvertFrom-Json

$config = [pscustomobject]@{
    Provider                   = $provider
    ApiKey                     = Get-ConfigValue $rawProvider 'ApiKey' ''
    Model                      = Get-ConfigValue $rawProvider 'Model' ''
    BaseUrl                    = Get-ConfigValue $rawProvider 'BaseUrl' ''
    Temperature                = [double](Get-ConfigValue $rawProvider 'Temperature' 0.3)
    MaxTranscriptCharsPerChunk = [int](Get-ConfigValue $rawProvider 'MaxTranscriptCharsPerChunk' 24000)
    YtDlpPath                  = Get-ConfigValue $rawConfig 'YtDlpPath' ''
    OutputDirectory            = Get-ConfigValue $rawConfig 'OutputDirectory' './output'
    SubtitleLanguage           = Get-ConfigValue $rawConfig 'SubtitleLanguage' 'en'
    TranscriptGroupSeconds     = [int](Get-ConfigValue $rawConfig 'TranscriptGroupSeconds' 30)
    KeepJson                   = [bool](Get-ConfigValue $rawConfig 'KeepJson' $false)
}

if ($PSBoundParameters.ContainsKey('OutputDirectory')) { $config.OutputDirectory = $OutputDirectory }
if ($KeepJson.IsPresent) { $config.KeepJson = $true }

# Относительный путь к yt-dlp считаем от каталога скрипта
if (-not [string]::IsNullOrWhiteSpace($config.YtDlpPath) -and -not [System.IO.Path]::IsPathRooted($config.YtDlpPath)) {
    $config.YtDlpPath = Join-Path $PSScriptRoot $config.YtDlpPath
}

$prompt = Get-Content -Path $PromptPath -Raw

Write-Host "Получение метаданных видео..." -ForegroundColor Cyan
$meta = Get-YoutubeMetadata -Url $Url -YtDlpPath $config.YtDlpPath

Write-Host "Получение субтитров..." -ForegroundColor Cyan
$transcript = Get-YoutubeTranscript -Url $Url -Language $config.SubtitleLanguage -GroupSeconds $config.TranscriptGroupSeconds -YtDlpPath $config.YtDlpPath

Write-Host "Генерация summary через провайдер '$($config.Provider)' (модель $($config.Model))..." -ForegroundColor Cyan
$summary = Get-VideoSummary -Prompt $prompt -Transcript $transcript -Config $config

Write-Host "Сборка Markdown..." -ForegroundColor Cyan
$markdown = New-VideoMarkdown -Metadata $meta -Summary $summary -Transcript $transcript -SourceUrl $Url

$outDir = $config.OutputDirectory
if (-not [System.IO.Path]::IsPathRooted($outDir)) {
    $outDir = Join-Path $PSScriptRoot $outDir
}
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$fileName = Get-VideoFileName -Metadata $meta
$outPath = Join-Path $outDir $fileName
Set-Content -Path $outPath -Value $markdown -Encoding utf8
Write-Host "Готово: $outPath" -ForegroundColor Green

if ($config.KeepJson) {
    $jsonPath = [System.IO.Path]::ChangeExtension($outPath, '.json')
    [pscustomobject]@{
        url         = $Url
        title       = Get-MetaValue $meta 'title' ''
        channel     = Get-MetaValue $meta 'channel' (Get-MetaValue $meta 'uploader' '')
        published   = Get-MetaValue $meta 'upload_date' ''
        description = Get-MetaValue $meta 'description' ''
        summary     = $summary
        transcript  = $transcript
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding utf8
    Write-Host "JSON с промежуточными данными: $jsonPath" -ForegroundColor Green
}
