<#
.SYNOPSIS
  Ex1: ダウンロード速度を通した実操作計測
#>
param([string[]]$Drives = @("D","E","F","G"))
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex1: Download Speed Measurement ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File "$benchDir\scripts\download_models.ps1" -Drive $drive
}

Push-Results "Ex1" "R4 Ex1: Download speed measurement complete"
Write-Host "`n=== Ex1 Complete ===" -ForegroundColor Green
