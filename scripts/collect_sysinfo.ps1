<#
.SYNOPSIS
  システム情報収集スクリプト
.DESCRIPTION
  nvidia-smi、CPU、メモリ、ストレージ情報を JSON で出力。
  ベンチマーク実行前に環境をスナップショットする。
.PARAMETER OutputDir
  出力先ディレクトリ
#>
param(
    [string]$OutputDir = "$PSScriptRoot\..\results"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "`n=== System Info Collection ===" -ForegroundColor Yellow

# GPU 情報
$gpu = @{}
try {
    $smiLines = & nvidia-smi --query-gpu=gpu_name,driver_version,memory.total,memory.free,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>$null
    if ($smiLines) {
        $parts = $smiLines.Split(",") | ForEach-Object { $_.Trim() }
        $gpu = [ordered]@{
            name          = $parts[0]
            driver        = $parts[1]
            vram_total_mb = if ($parts[2] -match '^\d+') { [int]$parts[2] } else { $null }
            vram_free_mb  = if ($parts[3] -match '^\d+') { [int]$parts[3] } else { $null }
            temp_c        = if ($parts[4] -match '^\d+') { [int]$parts[4] } else { $null }
            power_draw_w  = if ($parts[5] -match '^[\d.]+') { [double]$parts[5] } else { $null }
            power_limit_w = if ($parts[6] -match '^[\d.]+') { [double]$parts[6] } else { $null }
        }
    }

    # nvidia-smi フル出力も保存
    $smiFullOutput = & nvidia-smi 2>$null
    if ($smiFullOutput) {
        $smiFullOutput | Set-Content -Path (Join-Path $OutputDir "nvidia_smi_full.txt") -Encoding UTF8
        Write-Host "nvidia-smi full output saved" -ForegroundColor Green
    }
} catch {
    Write-Host "nvidia-smi not available: $_" -ForegroundColor DarkYellow
}

# CPU 情報
$cpu = @{}
try {
    $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpu = [ordered]@{
        name           = $cpuInfo.Name.Trim()
        cores          = $cpuInfo.NumberOfCores
        logical_procs  = $cpuInfo.NumberOfLogicalProcessors
        max_clock_mhz  = $cpuInfo.MaxClockSpeed
    }
} catch {
    Write-Host "CPU info not available: $_" -ForegroundColor DarkYellow
}

# メモリ情報
$memory = @{}
try {
    $memInfo = Get-CimInstance Win32_PhysicalMemory
    $totalGB = [math]::Round(($memInfo | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
    $dimms = $memInfo | ForEach-Object {
        [ordered]@{
            capacity_gb = [math]::Round($_.Capacity / 1GB, 1)
            speed_mhz   = $_.ConfiguredClockSpeed
            type         = $_.SMBIOSMemoryType
        }
    }
    $memory = [ordered]@{
        total_gb  = $totalGB
        dimm_count = $memInfo.Count
        dimms     = $dimms
    }
} catch {
    Write-Host "Memory info not available: $_" -ForegroundColor DarkYellow
}

# OS 情報
$osInfo = @{}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osInfo = [ordered]@{
        name    = $os.Caption
        version = $os.Version
        build   = $os.BuildNumber
        arch    = $os.OSArchitecture
    }
} catch {}

# ストレージ情報（シリアル番号・UniqueId 含む）
$storage = @()
try {
    $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    $drives = Get-CimInstance Win32_DiskDrive | Sort-Object Index
    foreach ($d in $drives) {
        $partitions = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($d.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
        $letters = @()
        foreach ($p in $partitions) {
            $logicals = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
            foreach ($l in $logicals) {
                $letters += $l.DeviceID
            }
        }
        # Get-PhysicalDisk からシリアル番号と UniqueId を取得
        $serial = $null; $uniqueId = $null; $busType = $null; $firmware = $null
        if ($physDisks) {
            $match = $physDisks | Where-Object { $d.Model -like "*$($_.FriendlyName)*" -or $_.FriendlyName -like "*$($d.Model.Trim())*" } | Select-Object -First 1
            if ($match) {
                $serial   = if ($match.SerialNumber) { $match.SerialNumber.Trim() } else { $null }
                $uniqueId = if ($match.UniqueId) { $match.UniqueId.Trim() } else { $null }
                $busType  = "$($match.BusType)"
                $firmware = if ($match.FirmwareVersion) { $match.FirmwareVersion.Trim() } else { $null }
            }
        }
        $storage += [ordered]@{
            model     = $d.Model.Trim()
            serial    = $serial
            unique_id = $uniqueId
            firmware  = $firmware
            size_gb   = [math]::Round($d.Size / 1GB, 1)
            interface = $d.InterfaceType
            bus_type  = $busType
            letters   = $letters -join ", "
        }
    }
} catch {
    Write-Host "Storage info not available: $_" -ForegroundColor DarkYellow
}

# まとめ
$sysinfo = [ordered]@{
    hostname  = $env:COMPUTERNAME
    os        = $osInfo
    cpu       = $cpu
    gpu       = $gpu
    memory    = $memory
    storage   = $storage
    collected = (Get-Date -Format "o")
}

$outFile = Join-Path $OutputDir "sysinfo.json"
$sysinfo | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`nSystem info saved: $outFile" -ForegroundColor Green

# 画面表示
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "CPU: $($cpu.name)"
Write-Host "GPU: $($gpu.name) (VRAM: $($gpu.vram_total_mb) MB)"
Write-Host "RAM: $($memory.total_gb) GB ($($memory.dimm_count) DIMMs)"
Write-Host "OS:  $($osInfo.name) ($($osInfo.build))"
Write-Host "Storage:" -ForegroundColor Cyan
foreach ($s in $storage) {
    Write-Host "  [$($s.letters)] $($s.model) ($($s.size_gb) GB, $($s.interface))"
}
