<#
.SYNOPSIS
  R3 共通関数: ComfyUI 起動/停止, Ollama 停止, Push, プロセスクリーンアップ
#>

$script:benchDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Runs)   { $Runs = 3 }
# -Drives "D,E,F,G" (単一文字列) を配列に変換
if (-not $Drives) { $Drives = @("D", "E", "F", "G") }
if ($Drives.Count -eq 1 -and $Drives[0] -match ",") {
    $Drives = $Drives[0] -split ","
}
if (-not $Port)   { $Port = 8188 }

function Stop-AllOllama {
    Get-Process "ollama*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "  Ollama stopped" -ForegroundColor DarkGray
}

function Stop-AllPython {
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  Python stopped" -ForegroundColor DarkGray
}

function Start-ComfyUI {
    param([string]$Drive)
    $comfyPath = "${Drive}:\ComfyUI"
    Stop-AllPython
    Write-Host "  Starting ComfyUI from $comfyPath..." -ForegroundColor Cyan
    # ブラウザで表示 (動作確認用)
    Start-Process "http://127.0.0.1:${Port}" -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath "py" -ArgumentList "main.py --listen 0.0.0.0 --port $Port" `
        -WorkingDirectory $comfyPath -WindowStyle Normal -PassThru
    $ready = $false
    for ($w = 0; $w -lt 30; $w++) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/system_stats" -TimeoutSec 3 | Out-Null
            $ready = $true; break
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { Write-Host "ERROR: ComfyUI failed to start from $comfyPath" -ForegroundColor Red; return $null }
    Write-Host "  ComfyUI ready (PID: $($proc.Id), Drive: $Drive)" -ForegroundColor Green
    return $proc
}

function Stop-ComfyUI {
    param($Proc)
    if ($Proc) {
        Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  ComfyUI stopped (PID: $($Proc.Id))" -ForegroundColor DarkGray
    }
    Stop-AllPython
}

function Push-Results {
    param([string]$ExName, [string]$Message)
    Set-Location $script:benchDir
    try { & py scripts/update_site.py } catch { Write-Host "  update_site.py skipped" -ForegroundColor DarkYellow }
    git add site/data.json Results-P8/ logs/ -f 2>$null
    git add results/ -f 2>$null
    git add scripts/ workflows/ -f 2>$null
    git commit -m "$Message`n`nCo-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>" 2>$null
    git push 2>$null
    Write-Host "  Pushed: $ExName" -ForegroundColor Green
}

function Ensure-Clean {
    <# 全プロセス終了・ポート確認 #>
    Stop-AllPython
    Stop-AllOllama
    $listening = netstat -ano | Select-String ":8188 |:11434 |:11435 |:11436 |:11437 |:11438 "
    if ($listening) {
        Write-Host "  WARNING: Ports still in use:" -ForegroundColor Yellow
        $listening | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else {
        Write-Host "  All ports clean" -ForegroundColor Green
    }
}
