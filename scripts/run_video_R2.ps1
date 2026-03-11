<#
.SYNOPSIS
  ComfyUI LTX-Video ベンチマーク R2 (各ドライブで ComfyUI 再起動)
#>
param([int]$Runs = 3, [int]$Port = 8188)
$ErrorActionPreference = "Stop"
$drives = @("D", "E", "F", "G")
$benchDir = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $benchDir "results\comfyui-video-bench-R2"

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

    # LTX-Video ベンチ (R2 出力先)
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" --workflow "$benchDir\workflows\ltx_2b_t2v_bench.json" --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}" --output-dir $outDir

    Stop-Process -Id $comfyProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Write-Host "Drive $drive done" -ForegroundColor Green
}
Write-Host "`n=== ALL DRIVES COMPLETE ===" -ForegroundColor Green
