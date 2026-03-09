<#
.SYNOPSIS
  全ベンチマーク一括実行スクリプト（ランスルーテスト）
.DESCRIPTION
  1. システム情報収集
  2. vibe-local-bench (Ollama モデルロード & コード生成)
  3. comfyui-imggen-bench (ComfyUI z-image-turbo 画像生成)
  4. comfyui-ltx-bench (ComfyUI LTX-Video 動画生成)
  5. qwen3tts-bench (Qwen3-TTS 音声合成)
  全結果を results/ に JSON 出力。
.PARAMETER Runs
  各実験の計測回数 (デフォルト: 3)
.PARAMETER SkipComfyUI
  ComfyUI ベンチマーク (画像+動画) をスキップ
.PARAMETER SkipTTS
  TTS ベンチマークをスキップ
#>
param(
    [int]$Runs = 3,
    [switch]$SkipComfyUI,
    [switch]$SkipTTS
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path $PSScriptRoot -Parent
$ResultsDir = Join-Path $RootDir "results"
$StartTime = Get-Date

Write-Host @"

 ===================================================
   ai-storage-bench - Full Benchmark Suite
 ===================================================
   Runs per drive: $Runs
   Start: $($StartTime.ToString("yyyy-MM-dd HH:mm:ss"))
 ===================================================

"@ -ForegroundColor Yellow

# ── Step 1: システム情報収集 ──
Write-Host "`n[1/5] Collecting system info..." -ForegroundColor Cyan
& "$PSScriptRoot\collect_sysinfo.ps1" -OutputDir $ResultsDir

# ── Step 2: vibe-local-bench ──
Write-Host "`n[2/5] Running vibe-local-bench..." -ForegroundColor Cyan
$vibeScript = Join-Path $RootDir "vibe-local-bench\run_all.ps1"
if (Test-Path $vibeScript) {
    & $vibeScript -Runs $Runs
} else {
    Write-Host "  SKIP: $vibeScript not found" -ForegroundColor DarkYellow
}

# ── Step 3: comfyui-imggen-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n[3/5] Running comfyui-imggen-bench (z-image-turbo)..." -ForegroundColor Cyan
    $imggenScript = Join-Path $RootDir "comfyui-imggen-bench\bench_imggen.py"
    if (Test-Path $imggenScript) {
        py $imggenScript --all-drives --runs $Runs
    } else {
        Write-Host "  SKIP: $imggenScript not found" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "`n[3/5] SKIP: comfyui-imggen-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── Step 4: comfyui-ltx-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n[4/5] Running comfyui-ltx-bench (LTX-Video)..." -ForegroundColor Cyan
    $comfyScript = Join-Path $RootDir "comfyui-ltx-bench\bench_comfyui.py"
    if (Test-Path $comfyScript) {
        py $comfyScript --all-drives --runs $Runs
    } else {
        Write-Host "  SKIP: $comfyScript not found" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "`n[4/5] SKIP: comfyui-ltx-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── Step 5: qwen3tts-bench ──
if (-not $SkipTTS) {
    Write-Host "`n[5/5] Running qwen3tts-bench..." -ForegroundColor Cyan
    $ttsScript = Join-Path $RootDir "qwen3tts-bench\bench_tts.py"
    if (Test-Path $ttsScript) {
        py $ttsScript --all-drives --runs $Runs
    } else {
        Write-Host "  SKIP: $ttsScript not found" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "`n[5/5] SKIP: qwen3tts-bench (--SkipTTS)" -ForegroundColor DarkYellow
}

# ── 完了サマリー ──
$EndTime = Get-Date
$Duration = $EndTime - $StartTime

Write-Host @"

 ===================================================
   COMPLETE
 ===================================================
   Duration: $($Duration.ToString("hh\:mm\:ss"))
   Results:  $ResultsDir
 ===================================================

"@ -ForegroundColor Green

# 結果ファイル一覧
Write-Host "Generated files:" -ForegroundColor Cyan
Get-ChildItem -Path $ResultsDir -Recurse -Filter "*.json" | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
