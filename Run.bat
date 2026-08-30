@echo off
REM ============================================================
REM  Запуск экспортёра: подставьте ссылку на видео в SET URL
REM ============================================================

set "URL=https://youtu.be/TICae6-uNeM"

pwsh -NoProfile -File "%~dp0src\Export-YoutubeVideoInfo.ps1" -Url "%URL%"

pause
