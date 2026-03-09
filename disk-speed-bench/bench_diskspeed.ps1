<#
.SYNOPSIS
  ストレージシーケンシャル速度ベンチマーク（AI モデルサイズ準拠）
.DESCRIPTION
  AI モデルファイルと同等サイズ (1GB/5GB) のテストファイルを生成し、
  シーケンシャルリード・ライト速度を計測。
  SSD/NVMe/HDD の性能差を可視化する。
.PARAMETER Drive
  テスト対象ドライブレター
.PARAMETER Runs
  計測回数 (デフォルト: 3)
.PARAMETER SizeMB
  テストファイルサイズ MB (デフォルト: 1024 = 1GB)
.PARAMETER OutputDir
  結果出力ディレクトリ
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[A-Z]$")]
    [string]$Drive,

    [int]$Runs = 3,

    [int]$SizeMB = 1024,

    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

if (-not $OutputDir) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path) }
    $OutputDir = Join-Path (Split-Path $scriptDir -Parent) "results\disk-speed-bench"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$TestDir = "${Drive}:\aicu-bench-temp"
$TestFile = Join-Path $TestDir "bench_test_${SizeMB}MB.bin"
$BufferSize = 4MB  # 4MB バッファ（NVMe のキューデプスに最適化）

Write-Host "`n=== Disk Speed Benchmark ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | Size: ${SizeMB} MB | Runs: $Runs | Buffer: $($BufferSize / 1MB) MB`n"

# テストディレクトリ作成
if (-not (Test-Path $TestDir)) {
    New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
}

# ディスク残量チェック
$vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${Drive}:'"
$freeGB = [math]::Round($vol.FreeSpace / 1GB, 2)
$neededGB = [math]::Round($SizeMB / 1024, 2)
if ($freeGB -lt ($neededGB * 1.5)) {
    Write-Host "ERROR: Not enough free space on ${Drive}: (need ${neededGB} GB, have ${freeGB} GB)" -ForegroundColor Red
    exit 1
}
Write-Host "Free space: $freeGB GB (need $neededGB GB)`n" -ForegroundColor Gray

$results = @()

for ($run = 1; $run -le $Runs; $run++) {
    Write-Host "--- Run $run/$Runs ---" -ForegroundColor Cyan

    # ── シーケンシャルライト ──
    Write-Host "  Write test ($SizeMB MB)..." -ForegroundColor Gray

    # Windows ファイルキャッシュをフラッシュ（管理者権限なしでもベストエフォート）
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    $writeSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $fs = [System.IO.FileStream]::new(
            $TestFile,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            $BufferSize,
            [System.IO.FileOptions]::WriteThrough  # OS キャッシュバイパス
        )
        $buf = New-Object byte[] $BufferSize
        # ランダムデータ生成（圧縮回避）
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($buf)

        $totalBytes = [long]$SizeMB * 1MB
        $written = 0L
        while ($written -lt $totalBytes) {
            $chunk = [math]::Min($BufferSize, $totalBytes - $written)
            $fs.Write($buf, 0, $chunk)
            $written += $chunk
        }
        $fs.Flush()
        $fs.Close()
        $writeSw.Stop()
        $writeTime = $writeSw.Elapsed.TotalSeconds
        $writeMBs = [math]::Round($SizeMB / $writeTime, 1)
        $writeSuccess = $true
        Write-Host "    Write: ${writeMBs} MB/s ($([math]::Round($writeTime, 2))s)" -ForegroundColor Green
    } catch {
        $writeSw.Stop()
        $writeTime = $writeSw.Elapsed.TotalSeconds
        $writeMBs = 0
        $writeSuccess = $false
        Write-Host "    Write FAILED: $_" -ForegroundColor Red
        if ($fs) { $fs.Close() }
    }

    # ── シーケンシャルリード ──
    Write-Host "  Read test ($SizeMB MB)..." -ForegroundColor Gray

    # キャッシュフラッシュ
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    $readSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $fs = [System.IO.FileStream]::new(
            $TestFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None,
            $BufferSize,
            [System.IO.FileOptions]::SequentialScan -bor [System.IO.FileOptions]::Asynchronous
        )
        $buf = New-Object byte[] $BufferSize
        $totalRead = 0L
        while ($true) {
            $bytesRead = $fs.Read($buf, 0, $BufferSize)
            if ($bytesRead -eq 0) { break }
            $totalRead += $bytesRead
        }
        $fs.Close()
        $readSw.Stop()
        $readTime = $readSw.Elapsed.TotalSeconds
        $readMBs = [math]::Round($SizeMB / $readTime, 1)
        $readSuccess = $true
        Write-Host "    Read:  ${readMBs} MB/s ($([math]::Round($readTime, 2))s)" -ForegroundColor Green
    } catch {
        $readSw.Stop()
        $readTime = $readSw.Elapsed.TotalSeconds
        $readMBs = 0
        $readSuccess = $false
        Write-Host "    Read FAILED: $_" -ForegroundColor Red
        if ($fs) { $fs.Close() }
    }

    $results += [ordered]@{
        run          = $run
        write_mbs    = $writeMBs
        write_time_s = [math]::Round($writeTime, 3)
        write_ok     = $writeSuccess
        read_mbs     = $readMBs
        read_time_s  = [math]::Round($readTime, 3)
        read_ok      = $readSuccess
        size_mb      = $SizeMB
        buffer_mb    = $BufferSize / 1MB
        timestamp    = (Get-Date -Format "o")
    }

    # テストファイル削除（次の run 用）
    if (Test-Path $TestFile) { Remove-Item $TestFile -Force }
}

# 中央値計算
$writeVals = $results | Where-Object { $_.write_ok } | ForEach-Object { $_.write_mbs } | Sort-Object
$readVals  = $results | Where-Object { $_.read_ok }  | ForEach-Object { $_.read_mbs }  | Sort-Object

function Get-Median([double[]]$arr) {
    if ($arr.Count -eq 0) { return $null }
    $mid = [math]::Floor($arr.Count / 2)
    if ($arr.Count % 2 -eq 0) { return ($arr[$mid - 1] + $arr[$mid]) / 2 }
    else { return $arr[$mid] }
}

$writeMedian = Get-Median $writeVals
$readMedian  = Get-Median $readVals

# ストレージ情報取得
$diskInfo = @{}
try {
    $phys = Get-PhysicalDisk | Where-Object { $_.FriendlyName -like "*$(((Get-CimInstance Win32_DiskDrive | Where-Object { $_.DeviceID -like '*' }) | ForEach-Object { $_.Model.Trim() })[0])*" } | Select-Object -First 1
    # ドライブに対応する物理ディスクを取得
    $diskDrive = Get-CimInstance Win32_DiskDrive | Sort-Object Index
    foreach ($dd in $diskDrive) {
        $parts = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($dd.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
        foreach ($p in $parts) {
            $logicals = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
            foreach ($l in $logicals) {
                if ($l.DeviceID -eq "${Drive}:") {
                    $matchPhys = Get-PhysicalDisk | Where-Object { $dd.Model -like "*$($_.FriendlyName)*" -or $_.FriendlyName -like "*$($dd.Model.Trim())*" } | Select-Object -First 1
                    $diskInfo = [ordered]@{
                        model     = $dd.Model.Trim()
                        serial    = if ($matchPhys.SerialNumber) { $matchPhys.SerialNumber.Trim() } else { $null }
                        unique_id = if ($matchPhys.UniqueId) { $matchPhys.UniqueId.Trim() } else { $null }
                        bus_type  = "$($matchPhys.BusType)"
                        firmware  = if ($matchPhys.FirmwareVersion) { $matchPhys.FirmwareVersion.Trim() } else { $null }
                    }
                }
            }
        }
    }
} catch {}

# 結果出力
$outFile = Join-Path $OutputDir "diskspeed_${Drive}.json"
$summary = [ordered]@{
    experiment      = "disk-speed-bench"
    test            = "sequential"
    drive           = $Drive
    disk_info       = $diskInfo
    size_mb         = $SizeMB
    runs            = $Runs
    write_median_mbs = $writeMedian
    read_median_mbs  = $readMedian
    results         = $results
    generated       = (Get-Date -Format "o")
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8

# クリーンアップ
if (Test-Path $TestDir) {
    Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Yellow
Write-Host "  Write median: ${writeMedian} MB/s" -ForegroundColor $(if ($writeMedian -gt 1000) {"Green"} else {"Gray"})
Write-Host "  Read median:  ${readMedian} MB/s" -ForegroundColor $(if ($readMedian -gt 1000) {"Green"} else {"Gray"})
Write-Host "  Saved: $outFile" -ForegroundColor Green
