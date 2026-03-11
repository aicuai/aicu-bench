<#
.SYNOPSIS
  Ex10: 全実験の所要時間・所要ストレージ総合レポート
#>
param([string[]]$Drives = @("D","E","F","G"), [int]$Runs = 3)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex10: Total Summary ===" -ForegroundColor Yellow

# 各ドライブの使用容量を計測
$driveUsage = @()
foreach ($drive in $Drives) {
    $disk = Get-PSDrive $drive -ErrorAction SilentlyContinue
    if ($disk) {
        $driveUsage += [ordered]@{
            drive = $drive
            used_gb = [math]::Round(($disk.Used / 1GB), 1)
            free_gb = [math]::Round(($disk.Free / 1GB), 1)
        }
    }
}

# R4 結果ディレクトリのサイズ集計
$resultDirs = Get-ChildItem "$benchDir\results\*-R4" -Directory -ErrorAction SilentlyContinue
$resultSizes = @()
foreach ($dir in $resultDirs) {
    $size = (Get-ChildItem $dir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $resultSizes += [ordered]@{
        directory = $dir.Name
        size_mb = [math]::Round(($size / 1MB), 1)
        files = (Get-ChildItem $dir -Recurse -File).Count
    }
}

$summary = [ordered]@{
    experiment = "summary-R4"
    drives = $Drives
    runs = $Runs
    timestamp = (Get-Date).ToString("o")
    drive_usage = $driveUsage
    result_sizes = $resultSizes
}

$summaryDir = "$benchDir\results\summary-R4"
if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path "$summaryDir\summary_R4.json" -Encoding UTF8
Write-Host "  Summary: $summaryDir\summary_R4.json" -ForegroundColor Cyan

& py "$benchDir\scripts\update_site.py"
Push-Results "Ex10" "R4 Ex10: Full suite summary"
Write-Host "`n=== Ex10 Complete ===" -ForegroundColor Green
