<#
.SYNOPSIS
  全ベンチマーク一括実行スクリプト（完全自動・標準ベンチマーク形式）
.DESCRIPTION
  Claude Code なしで一気に走る完全自動スクリプト。

  Phase 1: 前提条件チェック (ollama, python, nvidia-smi)
  Phase 2: テスト開始時のディスク残量チェック
  Phase 3: システム情報収集
  Phase 4: モデルダウンロード（タイミング計測）
  Phase 5: ベンチマーク実行
  Phase 6: サイトデータ更新 (data.json)
  Phase 7: 巨大ファイル（モデル）を削除
  Phase 8: テスト終了時のディスク残量チェック + サマリー

  結果ディレクトリには JSON ログ、生成 HTML/画像/動画/MP3 のみ残る。

.PARAMETER Runs
  各実験の計測回数 (デフォルト: 3)
.PARAMETER Fresh
  古い結果を削除して最初からやり直す
.PARAMETER SkipComfyUI
  ComfyUI ベンチマーク (画像+動画) をスキップ
.PARAMETER SkipTTS
  TTS ベンチマークをスキップ
.PARAMETER SkipDownload
  モデルダウンロードをスキップ（既にモデルが配置済みの場合）
.PARAMETER SkipCleanup
  テスト後のモデル削除をスキップ
.EXAMPLE
  # 完全自動実行（推奨）
  .\scripts\run_all_benchmarks.ps1

  # フレッシュスタート（古い結果を削除して再実行）
  .\scripts\run_all_benchmarks.ps1 -Fresh

  # Ollama のみ（ComfyUI, TTS スキップ）
  .\scripts\run_all_benchmarks.ps1 -SkipComfyUI -SkipTTS

  # モデルは配置済み、クリーンアップもしない（開発用）
  .\scripts\run_all_benchmarks.ps1 -SkipDownload -SkipCleanup
#>
param(
    [int]$Runs = 3,
    [switch]$Fresh,
    [switch]$SkipComfyUI,
    [switch]$SkipTTS,
    [switch]$SkipDownload,
    [switch]$SkipCleanup
)

# エラーでもスクリプト全体は止めない（個別 try-catch で処理）
$ErrorActionPreference = "Continue"
$script:Errors = @()

# パス解決
$RootDir = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Split-Path -Parent (Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)) }
$ScriptsDir = Join-Path $RootDir "scripts"
$ResultsDir = Join-Path $RootDir "results"
$SuiteStartTime = Get-Date

# Ollama テスト用モデル一覧
$OllamaModels = @("qwen3:8b", "qwen3:1.7b")

# ── ヘルパー関数 ──

function Log-Error {
    param([string]$Phase, [string]$Message)
    $entry = [ordered]@{ phase = $Phase; message = $Message; timestamp = (Get-Date -Format "o") }
    $script:Errors += $entry
    Write-Host "  ERROR [$Phase]: $Message" -ForegroundColor Red
}

function Get-DriveSpace {
    param([string]$DriveLetter)
    try {
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction Stop
        if ($vol -and $vol.Size -gt 0) {
            return [ordered]@{
                drive    = $DriveLetter
                free_gb  = [math]::Round($vol.FreeSpace / 1GB, 2)
                total_gb = [math]::Round($vol.Size / 1GB, 2)
                used_gb  = [math]::Round(($vol.Size - $vol.FreeSpace) / 1GB, 2)
                free_pct = [math]::Round($vol.FreeSpace / $vol.Size * 100, 1)
            }
        }
    } catch {}
    return [ordered]@{ drive = $DriveLetter; error = "not available" }
}

function Show-DriveSpace {
    param([string[]]$Drives, [string]$Label)
    $result = @()
    foreach ($d in $Drives) {
        $space = Get-DriveSpace -DriveLetter $d
        $result += $space
        if ($space.free_gb) {
            Write-Host "  $($d): $($space.free_gb) GB free / $($space.total_gb) GB total ($($space.free_pct)%)" -ForegroundColor Gray
        } else {
            Write-Host "  $($d): not available" -ForegroundColor DarkYellow
        }
    }
    return $result
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $size = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        return [math]::Round($size / 1MB, 2)
    } catch { return 0 }
}

function Test-OllamaRunning {
    param([int]$Port = 11434)
    try {
        Invoke-RestMethod -Uri "http://localhost:${Port}/api/tags" -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Start-OllamaIfNeeded {
    <# デフォルトの Ollama サーバーが動いていなければ起動 #>
    if (Test-OllamaRunning) {
        Write-Host "  Ollama server already running on port 11434" -ForegroundColor Green
        return
    }
    Write-Host "  Starting Ollama server..." -ForegroundColor Gray
    $proc = Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru
    $script:DefaultOllamaPid = $proc.Id
    for ($w = 0; $w -lt 10; $w++) {
        Start-Sleep -Seconds 2
        if (Test-OllamaRunning) {
            Write-Host "  Ollama server started (PID=$($proc.Id))" -ForegroundColor Green
            return
        }
    }
    Log-Error "preflight" "Ollama server failed to start"
}

function Invoke-OllamaPull {
    <# 指定ドライブにモデルをダウンロード（デフォルト Ollama 経由） #>
    param([string]$ModelName, [string]$DriveLetter)

    $modelsPath = "${DriveLetter}:\ollama\models"
    if (-not (Test-Path $modelsPath)) {
        New-Item -ItemType Directory -Path $modelsPath -Force | Out-Null
    }

    # モデルが既に存在するかチェック（ファイルサイズベース）
    $existingSize = Get-DirectorySize -Path $modelsPath
    # qwen3:8b ≈ 5200MB, qwen3:1.7b ≈ 1400MB — 既に十分なサイズがあればスキップ
    $expectedMinMB = if ($ModelName -match '8b') { 4000 } else { 1000 }

    # Ollama API でチェック（別ポートサーバーを一時起動）
    $benchPort = 11499
    $env:OLLAMA_MODELS = $modelsPath
    $env:OLLAMA_HOST = "127.0.0.1:$benchPort"
    $checkProc = Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru `
        -RedirectStandardError "$env:TEMP\ollama_check_${benchPort}.log"
    Start-Sleep -Seconds 3
    Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue

    $alreadyExists = $false
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:${benchPort}/api/tags" -TimeoutSec 5
        foreach ($m in $tags.models) {
            if ($m.name -eq $ModelName -or $m.name -eq "${ModelName}:latest") {
                $alreadyExists = $true
                break
            }
        }
    } catch {}

    # チェック用サーバー停止
    try { Stop-Process -Id $checkProc.Id -Force -ErrorAction SilentlyContinue } catch {}

    if ($alreadyExists) {
        Write-Host "    SKIP: $ModelName already on ${DriveLetter}: ($existingSize MB)" -ForegroundColor DarkYellow
        return [ordered]@{
            model = $ModelName; drive = $DriveLetter; elapsed_s = 0
            success = $true; skipped = $true; size_mb = $existingSize
        }
    }

    # ダウンロード実行（デフォルト Ollama 経由で pull → 手動コピーではなく、
    # OLLAMA_MODELS を設定した別インスタンスで pull する）
    Write-Host "    Downloading $ModelName to ${DriveLetter}:\ollama\models ..." -ForegroundColor Cyan
    $env:OLLAMA_MODELS = $modelsPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $pullOutput = & ollama pull $ModelName 2>&1
        $sw.Stop()
        $pullOutput | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        $success = $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null
    } catch {
        $sw.Stop()
        $success = $false
        Write-Host "      PULL FAILED: $_" -ForegroundColor Red
    }
    Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue

    $sizeAfter = Get-DirectorySize -Path $modelsPath
    $speedMBs = if ($sw.Elapsed.TotalSeconds -gt 0 -and $sizeAfter -gt 0) {
        [math]::Round($sizeAfter / $sw.Elapsed.TotalSeconds, 1)
    } else { 0 }

    Write-Host "    $ModelName -> ${DriveLetter}: $([math]::Round($sw.Elapsed.TotalSeconds, 1))s ($sizeAfter MB, $speedMBs MB/s)" `
        -ForegroundColor $(if ($success) {"Green"} else {"Red"})

    return [ordered]@{
        model     = $ModelName; drive = $DriveLetter
        elapsed_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        success   = $success; skipped = $false
        size_mb   = $sizeAfter; speed_mbs = $speedMBs
    }
}

# ══════════════════════════════════════════════════════
# テスト対象ドライブの自動検出
# ══════════════════════════════════════════════════════
$AllDriveLetters = @("C", "D", "E", "F", "G", "H")
# ollama\models が既にあるドライブ、またはローカルの物理ドライブ
$TestDrives = @()
foreach ($d in $AllDriveLetters) {
    if (Test-Path "${d}:\ollama\models") {
        $TestDrives += $d
    }
}
if ($TestDrives.Count -eq 0) {
    # フォールバック: 物理ドライブを検出
    foreach ($d in $AllDriveLetters) {
        try {
            $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${d}:'" -ErrorAction Stop
            if ($vol -and $vol.DriveType -eq 3 -and $vol.Size -gt 0) {  # DriveType 3 = Local Disk
                $TestDrives += $d
            }
        } catch {}
    }
}

Write-Host @"

 ========================================================
   ai-storage-bench - Full Benchmark Suite (Autonomous)
 ========================================================
   Runs per experiment : $Runs
   Test drives         : $($TestDrives -join ', ')
   Fresh run           : $Fresh
   Skip ComfyUI        : $SkipComfyUI
   Skip TTS            : $SkipTTS
   Skip Download       : $SkipDownload
   Skip Cleanup        : $SkipCleanup
   Start               : $($SuiteStartTime.ToString("yyyy-MM-dd HH:mm:ss"))
 ========================================================

"@ -ForegroundColor Yellow

if ($TestDrives.Count -eq 0) {
    Write-Host "ERROR: No test drives detected. Aborting." -ForegroundColor Red
    exit 1
}

# ══════════════════════════════════════════════════════
# Phase 1: 前提条件チェック
# ══════════════════════════════════════════════════════
Write-Host "[Phase 1] Pre-flight checks" -ForegroundColor Yellow

$preflightOk = $true

# ollama
$ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaPath) {
    $ollamaVer = & ollama --version 2>$null
    Write-Host "  ollama: OK ($ollamaVer)" -ForegroundColor Green
} else {
    Write-Host "  ollama: NOT FOUND (https://ollama.com)" -ForegroundColor Red
    $preflightOk = $false
}

# python / py
$pyCmd = $null
foreach ($cmd in @("py", "python", "python3")) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        $pyVer = & $cmd --version 2>$null
        Write-Host "  python: OK ($cmd -> $pyVer)" -ForegroundColor Green
        $pyCmd = $cmd
        break
    }
}
if (-not $pyCmd) {
    Write-Host "  python: NOT FOUND" -ForegroundColor Red
    $preflightOk = $false
}

# nvidia-smi
$nvSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvSmi) {
    Write-Host "  nvidia-smi: OK" -ForegroundColor Green
} else {
    Write-Host "  nvidia-smi: NOT FOUND (GPU info will be limited)" -ForegroundColor DarkYellow
}

if (-not $preflightOk) {
    Write-Host "`nPre-flight failed. Install missing tools and retry." -ForegroundColor Red
    exit 1
}

# Ollama サーバーが動いていなければ起動
Start-OllamaIfNeeded

# ══════════════════════════════════════════════════════
# Phase 1.5: Fresh モード（古い結果を削除）
# ══════════════════════════════════════════════════════
if ($Fresh) {
    Write-Host "`n[Phase 1.5] Fresh mode: clearing old results..." -ForegroundColor Yellow
    $oldDirs = @(
        (Join-Path $ResultsDir "vibe-local-bench"),
        (Join-Path $ResultsDir "disk-speed-bench"),
        (Join-Path $ResultsDir "comfyui-imggen-bench"),
        (Join-Path $ResultsDir "comfyui-ltx-bench"),
        (Join-Path $ResultsDir "qwen3tts-bench")
    )
    foreach ($dir in $oldDirs) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force
            Write-Host "  Deleted: $dir" -ForegroundColor Gray
        }
    }
    # bench_summary.json も削除
    $oldSummary = Join-Path $ResultsDir "bench_summary.json"
    if (Test-Path $oldSummary) { Remove-Item $oldSummary -Force }
    Write-Host "  Old results cleared." -ForegroundColor Green
}

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

# ══════════════════════════════════════════════════════
# Phase 2: テスト開始時のディスク残量チェック
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 2] Disk space check (BEFORE)" -ForegroundColor Yellow
$diskBefore = Show-DriveSpace -Drives $TestDrives -Label "before"

# ══════════════════════════════════════════════════════
# Phase 3: システム情報収集
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 3] Collecting system info..." -ForegroundColor Yellow
$sysInfoSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    & "$ScriptsDir\collect_sysinfo.ps1" -OutputDir $ResultsDir
} catch {
    Log-Error "sysinfo" "$_"
}
$sysInfoSw.Stop()
Write-Host "  System info collected in $([math]::Round($sysInfoSw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

# ══════════════════════════════════════════════════════
# Phase 4: モデルダウンロード（タイミング計測）
# ══════════════════════════════════════════════════════
$downloadResults = @()
$totalDownloadTime = 0

if (-not $SkipDownload) {
    Write-Host "`n[Phase 4] Model download (timed)" -ForegroundColor Yellow
    $downloadSw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($d in $TestDrives) {
        Write-Host "`n  Drive ${d}:" -ForegroundColor Cyan
        foreach ($model in $OllamaModels) {
            try {
                $dlResult = Invoke-OllamaPull -ModelName $model -DriveLetter $d
                $downloadResults += $dlResult
            } catch {
                Log-Error "download" "Failed to pull $model to ${d}: $_"
                $downloadResults += [ordered]@{
                    model = $model; drive = $d; elapsed_s = 0
                    success = $false; error = "$_"
                }
            }
        }
    }

    $downloadSw.Stop()
    $totalDownloadTime = [math]::Round($downloadSw.Elapsed.TotalSeconds, 2)
    Write-Host "`n  Total download phase: ${totalDownloadTime}s" -ForegroundColor Green
} else {
    Write-Host "`n[Phase 4] SKIP: Model download (--SkipDownload)" -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════
# Phase 5: ベンチマーク実行
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 5] Running benchmarks..." -ForegroundColor Yellow
$benchSw = [System.Diagnostics.Stopwatch]::StartNew()
$stepTimes = [ordered]@{}

# ── 5a: vibe-local-bench ──
Write-Host "`n  [5a] vibe-local-bench (Ollama model load & codegen)..." -ForegroundColor Cyan
$sw5a = [System.Diagnostics.Stopwatch]::StartNew()
$vibeScript = Join-Path $RootDir "vibe-local-bench\run_all.ps1"
if (Test-Path $vibeScript) {
    try {
        & $vibeScript -Runs $Runs
    } catch {
        Log-Error "vibe-local" "$_"
    }
} else {
    Write-Host "    SKIP: $vibeScript not found" -ForegroundColor DarkYellow
}
$sw5a.Stop()
$stepTimes["vibe_local_bench"] = [math]::Round($sw5a.Elapsed.TotalSeconds, 2)
Write-Host "    vibe-local-bench: $([math]::Round($sw5a.Elapsed.TotalMinutes, 1)) min" -ForegroundColor Gray

# ── 5a2: disk-speed-bench ──
Write-Host "`n  [5a2] disk-speed-bench (sequential read/write)..." -ForegroundColor Cyan
$sw5a2 = [System.Diagnostics.Stopwatch]::StartNew()
$diskBenchScript = Join-Path $RootDir "disk-speed-bench\bench_diskspeed.ps1"
if (Test-Path $diskBenchScript) {
    foreach ($d in $TestDrives) {
        $diskFree = (Get-DriveSpace -DriveLetter $d).free_gb
        if ($diskFree -gt 2) {
            try {
                & $diskBenchScript -Drive $d -Runs $Runs -SizeMB 1024
            } catch {
                Log-Error "disk-speed" "Drive ${d}: $_"
            }
        } else {
            Write-Host "    SKIP ${d}: not enough free space ($diskFree GB)" -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host "    SKIP: $diskBenchScript not found" -ForegroundColor DarkYellow
}
$sw5a2.Stop()
$stepTimes["disk_speed_bench"] = [math]::Round($sw5a2.Elapsed.TotalSeconds, 2)

# ── 5b: comfyui-imggen-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n  [5b] comfyui-imggen-bench (z-image-turbo)..." -ForegroundColor Cyan
    $sw5b = [System.Diagnostics.Stopwatch]::StartNew()
    $imggenScript = Join-Path $RootDir "comfyui-imggen-bench\bench_imggen.py"
    if (Test-Path $imggenScript) {
        # ComfyUI が起動しているか確認
        $comfyOk = $false
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 3 | Out-Null
            $comfyOk = $true
        } catch {}
        if ($comfyOk) {
            try { & $pyCmd $imggenScript --all-drives --runs $Runs } catch { Log-Error "imggen" "$_" }
        } else {
            Write-Host "    SKIP: ComfyUI not running on port 8188" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "    SKIP: $imggenScript not found" -ForegroundColor DarkYellow
    }
    $sw5b.Stop()
    $stepTimes["comfyui_imggen"] = [math]::Round($sw5b.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [5b] SKIP: comfyui-imggen-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── 5c: comfyui-ltx-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n  [5c] comfyui-ltx-bench (LTX-Video)..." -ForegroundColor Cyan
    $sw5c = [System.Diagnostics.Stopwatch]::StartNew()
    $comfyScript = Join-Path $RootDir "comfyui-ltx-bench\bench_comfyui.py"
    if (Test-Path $comfyScript) {
        $comfyOk = $false
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 3 | Out-Null
            $comfyOk = $true
        } catch {}
        if ($comfyOk) {
            try { & $pyCmd $comfyScript --all-drives --runs $Runs } catch { Log-Error "ltx" "$_" }
        } else {
            Write-Host "    SKIP: ComfyUI not running on port 8188" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "    SKIP: $comfyScript not found" -ForegroundColor DarkYellow
    }
    $sw5c.Stop()
    $stepTimes["comfyui_ltx"] = [math]::Round($sw5c.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [5c] SKIP: comfyui-ltx-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── 5d: qwen3tts-bench ──
if (-not $SkipTTS) {
    Write-Host "`n  [5d] qwen3tts-bench (Qwen3-TTS)..." -ForegroundColor Cyan
    $sw5d = [System.Diagnostics.Stopwatch]::StartNew()
    $ttsScript = Join-Path $RootDir "qwen3tts-bench\bench_tts.py"
    if (Test-Path $ttsScript) {
        try { & $pyCmd $ttsScript --all-drives --runs $Runs } catch { Log-Error "tts" "$_" }
    } else {
        Write-Host "    SKIP: $ttsScript not found" -ForegroundColor DarkYellow
    }
    $sw5d.Stop()
    $stepTimes["qwen3tts"] = [math]::Round($sw5d.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [5d] SKIP: qwen3tts-bench (--SkipTTS)" -ForegroundColor DarkYellow
}

$benchSw.Stop()
$totalBenchTime = [math]::Round($benchSw.Elapsed.TotalSeconds, 2)

# ══════════════════════════════════════════════════════
# Phase 6: サイトデータ更新
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 6] Updating site data..." -ForegroundColor Yellow
$updateScript = Join-Path $ScriptsDir "update_site.py"
if (Test-Path $updateScript) {
    try {
        & $pyCmd $updateScript --results-dir $ResultsDir --output (Join-Path $RootDir "site\data.json")
        Write-Host "  data.json updated" -ForegroundColor Green
    } catch {
        Log-Error "site-update" "$_"
    }
} else {
    Write-Host "  SKIP: $updateScript not found" -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════
# Phase 7: クリーンアップ（巨大ファイル削除）
# ══════════════════════════════════════════════════════
$cleanupResults = @()
if (-not $SkipCleanup) {
    Write-Host "`n[Phase 7] Cleanup: removing large model files..." -ForegroundColor Yellow

    # ベンチ用 Ollama が残っていたら停止
    Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -ne $script:DefaultOllamaPid -and $_.Id -ne (Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -lt $SuiteStartTime } | Select-Object -First 1 -ExpandProperty Id -ErrorAction SilentlyContinue)
    } | ForEach-Object {
        Write-Host "  Stopping bench Ollama PID=$($_.Id)" -ForegroundColor Gray
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    foreach ($d in $TestDrives) {
        $modelsPath = "${d}:\ollama\models"
        if (Test-Path $modelsPath) {
            $sizeBefore = Get-DirectorySize -Path $modelsPath
            Write-Host "  ${d}:\ollama\models ($sizeBefore MB) -> deleting..." -ForegroundColor Gray
            try {
                Remove-Item -Path $modelsPath -Recurse -Force -ErrorAction Stop
                Write-Host "    Deleted ($sizeBefore MB freed)" -ForegroundColor Green
                $cleanupResults += [ordered]@{
                    drive = $d; path = $modelsPath
                    freed_mb = $sizeBefore; success = $true
                }
            } catch {
                $sizeAfter = Get-DirectorySize -Path $modelsPath
                Write-Host "    WARNING: partial cleanup: $_" -ForegroundColor DarkYellow
                $cleanupResults += [ordered]@{
                    drive = $d; path = $modelsPath
                    freed_mb = [math]::Round($sizeBefore - $sizeAfter, 2); success = $false
                    error = "$_"
                }
            }
        }
    }

    # 残っているファイルの一覧（ログ・生成物のみのはず）
    Write-Host "`n  Remaining files in results/ (should be logs + generated content only):" -ForegroundColor Gray
    if (Test-Path $ResultsDir) {
        $keptByExt = Get-ChildItem -Path $ResultsDir -Recurse -File -ErrorAction SilentlyContinue | Group-Object Extension | ForEach-Object {
            $totalSize = ($_.Group | Measure-Object -Property Length -Sum).Sum
            $sizeStr = if ($totalSize -gt 1MB) { "$([math]::Round($totalSize / 1MB, 2)) MB" } else { "$([math]::Round($totalSize / 1KB, 1)) KB" }
            Write-Host "    $($_.Name): $($_.Count) files ($sizeStr)" -ForegroundColor DarkGray
            [ordered]@{ extension = $_.Name; count = $_.Count; size_mb = [math]::Round($totalSize / 1MB, 2) }
        }
    }
} else {
    Write-Host "`n[Phase 7] SKIP: Cleanup (--SkipCleanup)" -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════
# Phase 8: テスト終了時のディスク残量チェック + サマリー
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 8] Disk space check (AFTER) + Summary" -ForegroundColor Yellow
$diskAfter = Show-DriveSpace -Drives $TestDrives -Label "after"

# ディスク使用量の差分
Write-Host "`n  Disk space delta:" -ForegroundColor Cyan
$diskDeltas = @()
foreach ($d in $TestDrives) {
    $before = $diskBefore | Where-Object { $_.drive -eq $d }
    $after  = $diskAfter  | Where-Object { $_.drive -eq $d }
    if ($before.free_gb -and $after.free_gb) {
        $delta = [math]::Round($after.free_gb - $before.free_gb, 2)
        $sign = if ($delta -ge 0) { "+" } else { "" }
        Write-Host "    $($d): $($before.free_gb) GB -> $($after.free_gb) GB (${sign}${delta} GB)" `
            -ForegroundColor $(if ([math]::Abs($delta) -lt 0.1) {"Green"} elseif ($delta -ge 0) {"Green"} else {"DarkYellow"})
        $diskDeltas += [ordered]@{ drive = $d; before_gb = $before.free_gb; after_gb = $after.free_gb; delta_gb = $delta }
    }
}

# サマリー JSON
$SuiteEndTime = Get-Date
$TotalDuration = $SuiteEndTime - $SuiteStartTime

$summary = [ordered]@{
    suite              = "ai-storage-bench"
    version            = "2.1"
    hostname           = $env:COMPUTERNAME
    start_time         = $SuiteStartTime.ToString("o")
    end_time           = $SuiteEndTime.ToString("o")
    total_duration_s   = [math]::Round($TotalDuration.TotalSeconds, 2)
    total_duration_hms = $TotalDuration.ToString("hh\:mm\:ss")
    runs_per_experiment = $Runs
    test_drives        = $TestDrives
    disk_before        = $diskBefore
    disk_after         = $diskAfter
    disk_deltas        = $diskDeltas
    download           = [ordered]@{
        total_s = $totalDownloadTime
        skipped = [bool]$SkipDownload
        details = $downloadResults
    }
    benchmark          = [ordered]@{
        total_s    = $totalBenchTime
        step_times = $stepTimes
    }
    cleanup            = [ordered]@{
        skipped = [bool]$SkipCleanup
        details = $cleanupResults
    }
    errors             = $script:Errors
    generated          = (Get-Date -Format "o")
}

$summaryFile = Join-Path $ResultsDir "bench_summary.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryFile -Encoding UTF8

Write-Host @"

 ========================================================
   COMPLETE
 ========================================================
   Total time  : $($TotalDuration.ToString("hh\:mm\:ss"))
   Download    : ${totalDownloadTime}s
   Benchmarks  : ${totalBenchTime}s
   Errors      : $($script:Errors.Count)
   Results     : $ResultsDir
   Summary     : $summaryFile
 ========================================================

"@ -ForegroundColor $(if ($script:Errors.Count -eq 0) {"Green"} else {"Yellow"})

# ステップ別所要時間
if ($stepTimes.Count -gt 0) {
    Write-Host "Step breakdown:" -ForegroundColor Cyan
    foreach ($key in $stepTimes.Keys) {
        $t = $stepTimes[$key]
        $mins = [math]::Floor($t / 60)
        $secs = [math]::Round($t % 60, 1)
        Write-Host "  $key : ${mins}m ${secs}s"
    }
}

# 結果ファイル一覧
Write-Host "`nGenerated files:" -ForegroundColor Cyan
if (Test-Path $ResultsDir) {
    Get-ChildItem -Path $ResultsDir -Recurse -File | ForEach-Object {
        $sizeKB = [math]::Round($_.Length / 1KB, 1)
        Write-Host "  $($_.FullName) ($sizeKB KB)"
    }
}

# エラーがあれば表示
if ($script:Errors.Count -gt 0) {
    Write-Host "`nErrors encountered:" -ForegroundColor Red
    foreach ($err in $script:Errors) {
        Write-Host "  [$($err.phase)] $($err.message)" -ForegroundColor Red
    }
}

# ══════════════════════════════════════════════════════
# Phase 9: 結果送信（コミュニティデータ共有）
# ══════════════════════════════════════════════════════
$submitUrl = "https://bench.aicu.jp/api/submit"
# SSD シリアル番号を匿名化（ハッシュ化）して送信
$sysInfoFile = Join-Path $ResultsDir "sysinfo.json"
$submitPayload = $null
if (Test-Path $summaryFile) {
    try {
        $summaryData = Get-Content $summaryFile -Raw | ConvertFrom-Json
        $siteDataFile = Join-Path $RootDir "site\data.json"
        $siteData = if (Test-Path $siteDataFile) { Get-Content $siteDataFile -Raw | ConvertFrom-Json } else { $null }
        $sysData = if (Test-Path $sysInfoFile) { Get-Content $sysInfoFile -Raw | ConvertFrom-Json } else { $null }

        # ストレージシリアル番号をハッシュ化（プライバシー保護）
        $storageAnon = @()
        if ($sysData -and $sysData.storage) {
            foreach ($s in $sysData.storage) {
                $hashInput = "$($s.serial)$($s.unique_id)"
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashInput))
                $deviceHash = [BitConverter]::ToString($hashBytes).Replace("-","").Substring(0, 16).ToLower()
                $storageAnon += [ordered]@{
                    model     = $s.model
                    device_id = $deviceHash
                    size_gb   = $s.size_gb
                    bus_type  = $s.bus_type
                    firmware  = $s.firmware
                    letters   = $s.letters
                }
            }
        }

        $submitPayload = [ordered]@{
            version       = "2.1"
            hostname_hash = [BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)
                )
            ).Replace("-","").Substring(0, 12).ToLower()
            system        = [ordered]@{
                cpu     = if ($sysData) { $sysData.cpu.name } else { $null }
                gpu     = if ($sysData) { $sysData.gpu.name } else { $null }
                vram_mb = if ($sysData) { $sysData.gpu.vram_total_mb } else { $null }
                ram_gb  = if ($sysData) { $sysData.memory.total_gb } else { $null }
                os      = if ($sysData) { $sysData.os.name } else { $null }
                storage = $storageAnon
            }
            summary       = $summaryData
            experiments   = if ($siteData) { $siteData.experiments } else { $null }
            submitted     = (Get-Date -Format "o")
        }

        Write-Host "`n[Phase 9] Submit results to community database" -ForegroundColor Yellow
        Write-Host "  Endpoint: $submitUrl" -ForegroundColor Gray
        try {
            $jsonBody = $submitPayload | ConvertTo-Json -Depth 10 -Compress
            $response = Invoke-RestMethod -Uri $submitUrl -Method Post -Body $jsonBody `
                -ContentType "application/json" -TimeoutSec 15 -ErrorAction Stop
            Write-Host "  Submitted successfully!" -ForegroundColor Green
            if ($response.id) { Write-Host "  Submission ID: $($response.id)" -ForegroundColor Gray }
        } catch {
            Write-Host "  Submit failed (offline or endpoint not yet deployed): $_" -ForegroundColor DarkYellow
            Write-Host "  Results saved locally. You can submit later via:" -ForegroundColor DarkYellow
            Write-Host "    Invoke-RestMethod -Uri '$submitUrl' -Method Post -Body (Get-Content '$summaryFile' -Raw) -ContentType 'application/json'" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Could not prepare submission: $_" -ForegroundColor DarkYellow
    }
}

Write-Host "`nDone! View results at https://bench.aicu.jp" -ForegroundColor Cyan
