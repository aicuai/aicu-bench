<#
.SYNOPSIS
  全ドライブで ComfyUI SDXL 画像生成ベンチマークを実行
#>
param([int]$Runs = 3, [int]$Port = 8188)
$ErrorActionPreference = "Stop"
$drives = @("D", "E", "F", "G")
$benchDir = Split-Path $PSScriptRoot -Parent

foreach ($drive in $drives) {
    Write-Host "`n=== Drive $drive ===" -ForegroundColor Yellow
    $comfyPath = "${drive}:\ComfyUI"

    # 既存 Python 停止
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # ComfyUI 起動
    Write-Host "Starting ComfyUI from $comfyPath..." -ForegroundColor Cyan
    $comfyProc = Start-Process -FilePath "py" -ArgumentList "main.py --listen 0.0.0.0 --port $Port" `
        -WorkingDirectory $comfyPath -WindowStyle Hidden -PassThru

    $ready = $false
    for ($w = 0; $w -lt 30; $w++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/system_stats" -TimeoutSec 3 | Out-Null; $ready = $true; break } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { Write-Host "ERROR: ComfyUI failed" -ForegroundColor Red; continue }
    Write-Host "ComfyUI ready" -ForegroundColor Green

    # SDXL ベンチ
    & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" --workflow "$benchDir\workflows\sdxl.json" --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}"

    Stop-Process -Id $comfyProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "Drive $drive done" -ForegroundColor Green
}
Write-Host "`n=== ALL DRIVES COMPLETE ===" -ForegroundColor Green
