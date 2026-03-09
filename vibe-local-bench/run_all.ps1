<#
.SYNOPSIS
  vibe-local-bench 全ドライブ一括実行
.DESCRIPTION
  ollama/models が存在するドライブでモデルロード & コード生成ベンチマークを順次実行。
  各ドライブは別ポートでベンチ用 Ollama を起動するため、既存サーバーに影響しない。
.PARAMETER Runs
  各ドライブの計測回数 (デフォルト: 3)
.PARAMETER BasePort
  ベンチ用 Ollama の開始ポート番号 (デフォルト: 11435)
#>
param(
    [int]$Runs = 3,
    [int]$BasePort = 11435
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# 利用可能なドライブを自動検出 (ollama/models が存在するドライブ)
$AllDrives = @("C", "D", "E", "F", "G", "H", "I", "J")
$Drives = $AllDrives | Where-Object { Test-Path "${_}:\ollama\models" }

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  vibe-local-bench: Full Benchmark Run" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

if ($Drives.Count -eq 0) {
    Write-Host "ERROR: No drives with ollama\models directory found." -ForegroundColor Red
    Write-Host "Searched: $($AllDrives -join ', ')" -ForegroundColor Red
    Write-Host "Set up models: `$env:OLLAMA_MODELS='X:\ollama\models'; ollama pull qwen3:8b" -ForegroundColor Yellow
    exit 1
}

Write-Host "Detected drives with models: $($Drives -join ', ')" -ForegroundColor Green

$portOffset = 0
foreach ($drive in $Drives) {
    $port = $BasePort + $portOffset
    Write-Host "`n--- Drive $drive (port $port) ---" -ForegroundColor Cyan

    # モデルロードベンチマーク
    & "$ScriptDir\bench_load.ps1" -Drive $drive -Runs $Runs -Port $port

    # コード生成ベンチマーク
    & "$ScriptDir\bench_codegen.ps1" -Drive $drive -Runs $Runs -Port $port

    $portOffset++
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  vibe-local-bench: Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
Write-Host "Results: $(Resolve-Path "$ScriptDir\..\results\vibe-local-bench")"
