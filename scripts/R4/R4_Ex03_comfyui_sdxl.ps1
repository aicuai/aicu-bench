<#
.SYNOPSIS
  Ex3: ComfyUI 画像生成 (SDXL Checkpoint 単体)
  ドライブごとに ComfyUI を再起動してコールドスタートを計測
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex3: ComfyUI SDXL Image Gen ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if ($proc) {
        & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" `
            --workflow "$benchDir\workflows\sdxl.json" `
            --drive $drive --runs $Runs `
            --host "http://127.0.0.1:${Port}" `
            --output-dir "$benchDir\results\comfyui-imggen-bench-R4" `
            --timeout 60
        Stop-ComfyUI -Proc $proc
    }
}

Push-Results "Ex3" "R4 Ex3: ComfyUI SDXL image gen complete"
Write-Host "`n=== Ex3 Complete ===" -ForegroundColor Green
