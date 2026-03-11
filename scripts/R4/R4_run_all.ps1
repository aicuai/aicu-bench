<#
.SYNOPSIS
  R4 全実験一括実行 (非対話・一気通貫)
  Ex0 -> Ex1 -> ... -> Ex10 を順次実行し、各 Ex 完了後に自動 git push

.PARAMETER Runs
  各実験の計測回数 (デフォルト: 3)
.PARAMETER StartFrom
  途中から再開する場合の開始 Ex 番号 (デフォルト: 0)
.PARAMETER Drives
  テスト対象ドライブ (デフォルト: D,E,F,G)

.EXAMPLE
  # 全実験を最初から実行
  .\R4_run_all.ps1

  # Ex3 から再開 (Ex0-2 はスキップ)
  .\R4_run_all.ps1 -StartFrom 3

  # D と E だけ、5回計測
  .\R4_run_all.ps1 -Drives D,E -Runs 5
#>
param(
    [int]$Runs = 3,
    [int]$StartFrom = 0,
    [string[]]$Drives = @("D", "E", "F", "G"),
    [int]$Port = 8188
)

$ErrorActionPreference = "Stop"
$totalStart = Get-Date

Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  AICU-bench R4: Full Benchmark Suite" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "Drives : $($Drives -join ', ')"
Write-Host "Runs   : $Runs"
Write-Host "Start  : Ex$StartFrom"
Write-Host "Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================="
Write-Host ""

$scripts = @(
    @{ ex = 0;  file = "R4_Ex00_disk_speed.ps1";       name = "Disk Speed" }
    @{ ex = 1;  file = "R4_Ex01_download.ps1";          name = "Download" }
    @{ ex = 2;  file = "R4_Ex02_ollama_llm.ps1";        name = "Ollama LLM" }
    @{ ex = 3;  file = "R4_Ex03_comfyui_sdxl.ps1";      name = "ComfyUI SDXL" }
    @{ ex = 4;  file = "R4_Ex04_comfyui_aicuty.ps1";    name = "ComfyUI AiCuty" }
    @{ ex = 5;  file = "R4_Ex05_comfyui_wan22.ps1";      name = "Wan 2.2 Video" }
    @{ ex = 6;  file = "R4_Ex06_comfyui_ltx23.ps1";      name = "LTX 2.3 Video" }
    @{ ex = 7;  file = "R4_Ex07_comfyui_pipeline.ps1";   name = "Pipeline" }
    # Ex8 (Qwen3-TTS) はスキップ — 実行時間が長すぎるため
    # @{ ex = 8;  file = "R4_Ex08_qwen3tts.ps1";          name = "Qwen3-TTS" }
    @{ ex = 9;  file = "R4_Ex09_moshi.ps1";             name = "llm-jp-moshi" }
    @{ ex = 10; file = "R4_Ex10_summary.ps1";            name = "Summary" }
)

foreach ($s in $scripts) {
    if ($s.ex -lt $StartFrom) {
        Write-Host "SKIP Ex$($s.ex): $($s.name)" -ForegroundColor DarkGray
        continue
    }

    $exStart = Get-Date
    Write-Host "`n>>> Ex$($s.ex): $($s.name) starting... <<<" -ForegroundColor White -BackgroundColor DarkBlue

    $scriptPath = Join-Path $PSScriptRoot $s.file
    & powershell -ExecutionPolicy Bypass -File $scriptPath -Runs $Runs -Drives $Drives -Port $Port

    $exDuration = (Get-Date) - $exStart
    Write-Host ">>> Ex$($s.ex) done in $($exDuration.ToString('hh\:mm\:ss')) <<<`n" -ForegroundColor White -BackgroundColor DarkGreen
}

$totalDuration = (Get-Date) - $totalStart
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  R4 ALL EXPERIMENTS COMPLETE" -ForegroundColor Green
Write-Host "  Total time: $($totalDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
