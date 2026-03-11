<#
.SYNOPSIS
  Ex0: ダミーファイルを使ったシーケンシャル速度スペックチェック
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"))
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex0: Disk Speed Spec Check ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File "$benchDir\disk-speed-bench\bench_diskspeed.ps1" `
        -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\disk-speed-bench-R4"
}

Push-Results "Ex0" "R4 Ex0: Disk spec check complete (D/E/F/G x $Runs runs)"
Write-Host "`n=== Ex0 Complete ===" -ForegroundColor Green
