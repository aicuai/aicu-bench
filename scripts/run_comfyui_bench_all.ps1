<#
.SYNOPSIS
  全ドライブで ComfyUI ベンチマーク（画像生成 + 動画生成）を一括実行
.DESCRIPTION
  各ドライブごとに ComfyUI を起動し、SDXL 画像生成 + LTX 動画生成ベンチを実行。
  ドライブ切り替え時に ComfyUI を再起動してストレージ差を計測。
#>
param(
    [int]$Runs = 3,
    [int]$Port = 8188
)

$ErrorActionPreference = "Stop"
$drives = @("D", "E", "F", "G")
$benchDir = Split-Path $PSScriptRoot -Parent

foreach ($drive in $drives) {
    Write-Host "`n============================================" -ForegroundColor Yellow
    Write-Host "  Drive $drive - ComfyUI Benchmark" -ForegroundColor Yellow
    Write-Host "============================================`n" -ForegroundColor Yellow

    $comfyPath = "${drive}:\ComfyUI"
    if (-not (Test-Path "$comfyPath\main.py")) {
        Write-Host "SKIP: ComfyUI not found at $comfyPath" -ForegroundColor Red
        continue
    }

    # 既存の ComfyUI を停止
    Get-Process python -ErrorAction SilentlyContinue | Where-Object {
        try { $_.MainModule.FileName -match "python" } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # ComfyUI 起動
    Write-Host "Starting ComfyUI from $comfyPath..." -ForegroundColor Cyan
    $comfyProc = Start-Process -FilePath "py" -ArgumentList "main.py --listen 0.0.0.0 --port $Port" `
        -WorkingDirectory $comfyPath -WindowStyle Hidden -PassThru

    # 起動待ち
    $ready = $false
    for ($w = 0; $w -lt 30; $w++) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/system_stats" -TimeoutSec 3 | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ready) {
        Write-Host "ERROR: ComfyUI failed to start for drive $drive" -ForegroundColor Red
        Stop-Process -Id $comfyProc.Id -Force -ErrorAction SilentlyContinue
        continue
    }
    Write-Host "ComfyUI ready (PID=$($comfyProc.Id))" -ForegroundColor Green

    # 画像生成ベンチ (SDXL)
    Write-Host "`n--- SDXL Image Generation Benchmark (Drive $drive) ---" -ForegroundColor Cyan
    & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" --workflow "$benchDir\workflows\sdxl.json" --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}"

    # 動画生成ベンチ (LTX-Video)
    Write-Host "`n--- LTX-Video Generation Benchmark (Drive $drive) ---" -ForegroundColor Cyan
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}"

    # ComfyUI 停止
    Write-Host "Stopping ComfyUI..." -ForegroundColor Gray
    Stop-Process -Id $comfyProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Write-Host "Drive $drive complete.`n" -ForegroundColor Green
}

Write-Host "`n=== ALL DRIVES COMPLETE ===" -ForegroundColor Green
