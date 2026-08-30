#Requires -Version 7.0
<#
.SYNOPSIS
    Собирает zip-архив со всеми файлами, необходимыми для разворачивания
    проекта на другом компьютере. Секреты (config.json, providers/*.config.json)
    в архив НЕ включаются.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Файлы и папки, которые попадут в архив
$include = @(
    'Export-YoutubeVideoInfo.ps1',
    'SummaryPrompt.md',
    'README.md',
    'Run.bat',
    'config.example.json',
    '.gitignore',
    'src',
    'providers',
    'yt-dlp.exe'
)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$zipName = "youtube-video-info-extractor-$timestamp.zip"
$zipPath = Join-Path $OutputDirectory $zipName
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "yvie_pkg_$timestamp"

New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($item in $include) {
        $src = Join-Path $PSScriptRoot $item
        if (-not (Test-Path $src)) {
            Write-Warning "Пропущено (не найдено): $item"
            continue
        }
        Copy-Item -Path $src -Destination (Join-Path $stage $item) -Recurse -Force
    }

    # Секретные конфиги провайдеров в архив не кладём (оставляем только *.config.example.json)
    $stageProviders = Join-Path $stage 'providers'
    if (Test-Path $stageProviders) {
        Get-ChildItem -Path $stageProviders -Filter '*.config.json' -File |
            Where-Object { $_.Name -notlike '*.config.example.json' } |
            Remove-Item -Force
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host "Архив создан: $zipPath ($sizeMb MB)" -ForegroundColor Green
}
finally {
    Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
}
