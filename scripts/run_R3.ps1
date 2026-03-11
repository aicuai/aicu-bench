<#
.SYNOPSIS
  R3 全実験オーケストレーション
  Ex0-Ex10 を順次実行し、各 Ex 完了後に git push

.PARAMETER Runs
  各実験の計測回数 (デフォルト: 3)
.PARAMETER StartFrom
  途中から再開する場合の開始 Ex 番号 (デフォルト: 0)
.PARAMETER Drives
  テスト対象ドライブ (デフォルト: D,E,F,G)
#>
param(
    [int]$Runs = 3,
    [int]$StartFrom = 0,
    [string[]]$Drives = @("D", "E", "F", "G"),
    [int]$Port = 8188
)

$ErrorActionPreference = "Stop"
$benchDir = Split-Path $PSScriptRoot -Parent
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"

Write-Host "=== AICU-bench R3: Full Benchmark Suite ===" -ForegroundColor Yellow
Write-Host "Drives: $($Drives -join ', ') | Runs: $Runs | Start: Ex$StartFrom"
Write-Host "Start: $(Get-Date -Format 'o')`n"

$totalStart = Get-Date

function Push-Results {
    param([string]$ExName, [string]$Message)
    Set-Location $benchDir
    & py scripts/update_site.py
    git add site/data.json Results-P8/ logs/ -f 2>$null
    git add results/*-R3/ results/summary-R3/ results/parallel-bench-R3/ results/monitor_parallel_*.csv -f 2>$null
    git add scripts/ workflows/ llm-jp-moshi-bench/ qwen3tts-bench/ -f 2>$null
    git commit -m "$Message`n`nCo-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>" 2>$null
    git push 2>$null
    Write-Host "  Pushed: $ExName" -ForegroundColor Green
}

function Start-ComfyUI {
    param([string]$Drive)
    $comfyPath = "${Drive}:\ComfyUI"
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  Starting ComfyUI from $comfyPath..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "py" -ArgumentList "main.py --listen 0.0.0.0 --port $Port" `
        -WorkingDirectory $comfyPath -WindowStyle Hidden -PassThru
    $ready = $false
    for ($w = 0; $w -lt 30; $w++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/system_stats" -TimeoutSec 3 | Out-Null; $ready = $true; break } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { Write-Host "ERROR: ComfyUI failed" -ForegroundColor Red; return $null }
    Write-Host "  ComfyUI ready (PID: $($proc.Id))" -ForegroundColor Green
    return $proc
}

function Stop-ComfyUI {
    param($Proc)
    if ($Proc) { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}

# =============================================================================
# Ex0: ダミーファイル ディスクスペックチェック
# =============================================================================
if ($StartFrom -le 0) {
    Write-Host "`n=== Ex0: Disk Spec Check ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        & powershell -ExecutionPolicy Bypass -File "$benchDir\disk-speed-bench\bench_diskspeed.ps1" `
            -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\disk-speed-bench-R3"
    }
    Push-Results "Ex0" "R3 Ex0: Disk spec check complete"
}

# =============================================================================
# Ex1: ダウンロード速度計測 (モデルダウンロード)
# =============================================================================
if ($StartFrom -le 1) {
    Write-Host "`n=== Ex1: Download Speed (Model Downloads) ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        & powershell -ExecutionPolicy Bypass -File "$benchDir\scripts\download_models.ps1" -Drive $drive
    }
    Push-Results "Ex1" "R3 Ex1: Download speed measurement complete"
}

# =============================================================================
# Ex2: Local LLM コーディング (Ollama qwen3)
# =============================================================================
if ($StartFrom -le 2) {
    Write-Host "`n=== Ex2: Ollama Load + Codegen ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        $env:OLLAMA_MODELS = "${drive}:\ollama\models"
        & powershell -ExecutionPolicy Bypass -File "$benchDir\vibe-local-bench\bench_load.ps1" `
            -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\vibe-local-bench-R3"
        & powershell -ExecutionPolicy Bypass -File "$benchDir\vibe-local-bench\bench_codegen.ps1" `
            -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\vibe-local-bench-R3"
    }
    Push-Results "Ex2" "R3 Ex2: Ollama LLM cold start + codegen complete"
}

# =============================================================================
# Ex3: ComfyUI SDXL 画像生成
# =============================================================================
if ($StartFrom -le 3) {
    Write-Host "`n=== Ex3: ComfyUI SDXL Image Gen ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        $proc = Start-ComfyUI -Drive $drive
        if ($proc) {
            & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" --workflow "$benchDir\workflows\sdxl.json" `
                --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}" `
                --output-dir "$benchDir\results\comfyui-imggen-bench-R3"
            Stop-ComfyUI -Proc $proc
        }
    }
    Push-Results "Ex3" "R3 Ex3: ComfyUI SDXL image gen complete"
}

# =============================================================================
# Ex4: ComfyUI AiCuty 複数モデル比較
# =============================================================================
if ($StartFrom -le 4) {
    Write-Host "`n=== Ex4: ComfyUI AiCuty Multi-Model ===" -ForegroundColor Yellow
    $workflows = @(
        @{ name = "aicuty_sdxl"; file = "aicuty_sdxl.json" }
        # WAI, AnimagineXL4, Mellow Pencil は WF 準備後に追加
    )
    foreach ($drive in $Drives) {
        $proc = Start-ComfyUI -Drive $drive
        if ($proc) {
            foreach ($wf in $workflows) {
                $wfPath = "$benchDir\workflows\$($wf.file)"
                if (Test-Path $wfPath) {
                    & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" --workflow $wfPath `
                        --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}" `
                        --output-dir "$benchDir\results\comfyui-aicuty-bench-R3"
                }
            }
            Stop-ComfyUI -Proc $proc
        }
    }
    Push-Results "Ex4" "R3 Ex4: ComfyUI AiCuty multi-model comparison complete"
}

# =============================================================================
# Ex5: ComfyUI Wan2.2 動画生成
# =============================================================================
if ($StartFrom -le 5) {
    Write-Host "`n=== Ex5: ComfyUI Wan 2.2 Video Gen ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        $proc = Start-ComfyUI -Drive $drive
        if ($proc) {
            # t2v
            $wfPath = "$benchDir\workflows\wan2_2_14B_t2v_api.json"
            if (Test-Path $wfPath) {
                & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" --workflow $wfPath `
                    --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}" `
                    --output-dir "$benchDir\results\comfyui-wan2-bench-R3"
            }
            Stop-ComfyUI -Proc $proc
        }
    }
    Push-Results "Ex5" "R3 Ex5: ComfyUI Wan2.2 video gen complete"
}

# =============================================================================
# Ex6: ComfyUI LTX 2.3 動画生成
# =============================================================================
if ($StartFrom -le 6) {
    Write-Host "`n=== Ex6: ComfyUI LTX 2.3 Video Gen ===" -ForegroundColor Yellow
    foreach ($drive in $Drives) {
        $proc = Start-ComfyUI -Drive $drive
        if ($proc) {
            $wfPath = "$benchDir\workflows\ltx2_3_t2v.json"
            if (-not (Test-Path $wfPath)) { $wfPath = "$benchDir\workflows\ltx_2b_t2v_bench.json" }
            & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" --workflow $wfPath `
                --drive $drive --runs $Runs --host "http://127.0.0.1:${Port}" `
                --output-dir "$benchDir\results\comfyui-ltx2-bench-R3"
            Stop-ComfyUI -Proc $proc
        }
    }
    Push-Results "Ex6" "R3 Ex6: ComfyUI LTX2.3 video gen complete"
}

# =============================================================================
# Ex7: ComfyUI 総合パイプライン (Mellow Pencil → LTX i2v)
# =============================================================================
if ($StartFrom -le 7) {
    Write-Host "`n=== Ex7: ComfyUI Combined Pipeline ===" -ForegroundColor Yellow
    Write-Host "  (Requires Ex4 Mellow Pencil output + Ex6 LTX i2v workflow)" -ForegroundColor Cyan
    # WF 準備後に実装
    Push-Results "Ex7" "R3 Ex7: Combined pipeline (placeholder)"
}

# =============================================================================
# Ex8: Qwen3-TTS 長文 TTS
# =============================================================================
if ($StartFrom -le 8) {
    Write-Host "`n=== Ex8: Qwen3-TTS Long Text ===" -ForegroundColor Yellow
    & py "$benchDir\qwen3tts-bench\bench_tts.py" --all-drives --runs $Runs --save-audio `
        --output-dir "$benchDir\results\qwen3tts-bench-R3"
    Push-Results "Ex8" "R3 Ex8: Qwen3-TTS long text TTS complete"
}

# =============================================================================
# Ex9: llm-jp-moshi 高速音声応答
# =============================================================================
if ($StartFrom -le 9) {
    Write-Host "`n=== Ex9: llm-jp-moshi Voice Response ===" -ForegroundColor Yellow
    & py "$benchDir\llm-jp-moshi-bench\bench_moshi.py" --all-drives --runs $Runs `
        --output-dir "$benchDir\results\llm-jp-moshi-bench-R3"
    Push-Results "Ex9" "R3 Ex9: llm-jp-moshi voice response complete"
}

# =============================================================================
# Ex9.5: 並列同時実行テスト (動画生成以外)
# R2 知見: 98GB VRAM で TTS(3.5GB) + moshi(15.4GB) が余裕で共存
# 単体テスト x4 のあとに、同一ドライブで複数ワークロード同時実行
# =============================================================================
if ($StartFrom -le 9) {
    Write-Host "`n=== Ex9.5: Parallel Workload Test (VRAM Coexistence) ===" -ForegroundColor Yellow
    Write-Host "  Testing: TTS + moshi + SDXL simultaneous execution" -ForegroundColor Cyan
    Write-Host "  (Video gen skipped - requires >30GB VRAM alone)" -ForegroundColor DarkYellow

    foreach ($drive in $Drives) {
        Write-Host "`n--- Parallel Test: Drive $drive ---" -ForegroundColor Yellow
        $monitorCsv = "$benchDir\results\monitor_parallel_${drive}.csv"
        $parallelOutDir = "$benchDir\results\parallel-bench-R3"
        if (-not (Test-Path $parallelOutDir)) { New-Item -ItemType Directory -Path $parallelOutDir -Force | Out-Null }

        # GPU/CPU モニター開始 (バックグラウンド)
        $monitorProc = Start-Process -FilePath "py" -ArgumentList `
            "$benchDir\scripts\gpu_monitor.py --output $monitorCsv --interval 5 --duration 600 --quiet" `
            -WindowStyle Hidden -PassThru
        Write-Host "  Monitor started (PID: $($monitorProc.Id))" -ForegroundColor Cyan

        # ComfyUI 起動 (SDXL 用)
        $comfyProc = Start-ComfyUI -Drive $drive

        # 並列で 3 つのワークロードを起動
        # 1) TTS (短縮版: 短文のみ, 1 run)
        $ttsJob = Start-Job -ScriptBlock {
            param($benchDir, $drive, $parallelOutDir)
            & py "$benchDir\qwen3tts-bench\bench_tts.py" --drive $drive --runs 1 `
                --output-dir $parallelOutDir 2>&1
        } -ArgumentList $benchDir, $drive, $parallelOutDir

        # 2) moshi (1 run)
        $moshiJob = Start-Job -ScriptBlock {
            param($benchDir, $drive, $parallelOutDir)
            & py "$benchDir\llm-jp-moshi-bench\bench_moshi.py" --drive $drive --runs 1 `
                --output-dir $parallelOutDir 2>&1
        } -ArgumentList $benchDir, $drive, $parallelOutDir

        # 3) SDXL 画像生成 (1 run)
        if ($comfyProc) {
            $sdxlJob = Start-Job -ScriptBlock {
                param($benchDir, $drive, $parallelOutDir, $Port)
                & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" `
                    --workflow "$benchDir\workflows\sdxl.json" `
                    --drive $drive --runs 1 --host "http://127.0.0.1:${Port}" `
                    --output-dir $parallelOutDir 2>&1
            } -ArgumentList $benchDir, $drive, $parallelOutDir, $Port
        }

        # 全ジョブ完了待ち
        Write-Host "  Waiting for parallel jobs..." -ForegroundColor Cyan
        $ttsJob, $moshiJob | Wait-Job -Timeout 600 | Out-Null
        if ($comfyProc -and $sdxlJob) { $sdxlJob | Wait-Job -Timeout 300 | Out-Null }

        # 結果表示
        Write-Host "  TTS result:" -ForegroundColor Green
        Receive-Job $ttsJob | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
        Write-Host "  Moshi result:" -ForegroundColor Green
        Receive-Job $moshiJob | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
        if ($comfyProc -and $sdxlJob) {
            Write-Host "  SDXL result:" -ForegroundColor Green
            Receive-Job $sdxlJob | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
        }

        # クリーンアップ
        Remove-Job $ttsJob, $moshiJob -Force -ErrorAction SilentlyContinue
        if ($sdxlJob) { Remove-Job $sdxlJob -Force -ErrorAction SilentlyContinue }
        Stop-ComfyUI -Proc $comfyProc
        Stop-Process -Id $monitorProc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Monitor data: $monitorCsv" -ForegroundColor Cyan
        Write-Host "  Drive $drive parallel test done" -ForegroundColor Green
    }

    Push-Results "Ex9.5" "R3 Ex9.5: Parallel workload test (TTS+moshi+SDXL coexistence)"
}

# =============================================================================
# Ex10: 全体サマリー
# =============================================================================
if ($StartFrom -le 10) {
    Write-Host "`n=== Ex10: Total Summary ===" -ForegroundColor Yellow
    $totalEnd = Get-Date
    $totalDuration = $totalEnd - $totalStart
    $summary = [ordered]@{
        experiment = "summary-R3"
        drives = $Drives
        runs = $Runs
        start = $totalStart.ToString("o")
        end = $totalEnd.ToString("o")
        total_duration_s = [math]::Round($totalDuration.TotalSeconds, 1)
        total_duration_hms = $totalDuration.ToString("hh\:mm\:ss")
    }
    $summaryDir = "$benchDir\results\summary-R3"
    if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path "$summaryDir\summary_R3.json" -Encoding UTF8

    & py scripts/update_site.py
    Push-Results "Ex10" "R3 Ex10: Full suite complete ($($totalDuration.ToString('hh\:mm\:ss')))"
}

Write-Host "`n=== R3 ALL EXPERIMENTS COMPLETE ===" -ForegroundColor Green
Write-Host "Total time: $((Get-Date) - $totalStart)" -ForegroundColor Cyan
