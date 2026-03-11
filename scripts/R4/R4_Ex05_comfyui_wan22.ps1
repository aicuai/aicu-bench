<#
.SYNOPSIS
  Ex5: ComfyUI 動画生成 (Wan 2.2 14B t2v / i2v) 公式ワークフロー API
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex5: ComfyUI Wan 2.2 Video Gen ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if ($proc) {
        # t2v
        $wfT2v = "$benchDir\workflows\wan2_2_14B_t2v_api.json"
        if (Test-Path $wfT2v) {
            Write-Host "  Workflow: Wan 2.2 t2v" -ForegroundColor Cyan
            & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
                --workflow $wfT2v `
                --drive $drive --runs $Runs `
                --host "http://127.0.0.1:${Port}" `
                --output-dir "$benchDir\results\comfyui-wan2-bench-R4" `
                --timeout 60
        } else {
            Write-Host "  SKIP: wan2_2_14B_t2v_api.json not found" -ForegroundColor DarkYellow
        }

        # TODO: i2v ワークフロー追加
        # $wfI2v = "$benchDir\workflows\wan2_2_14B_i2v_api.json"

        Stop-ComfyUI -Proc $proc
    }
}

Push-Results "Ex5" "R4 Ex5: ComfyUI Wan 2.2 video gen complete"
Write-Host "`n=== Ex5 Complete ===" -ForegroundColor Green
