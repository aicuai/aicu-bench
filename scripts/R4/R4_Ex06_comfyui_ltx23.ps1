<#
.SYNOPSIS
  Ex6: ComfyUI 動画生成 (LTX 2.3 t2v / i2v)
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex6: ComfyUI LTX 2.3 Video Gen ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if ($proc) {
        # t2v: LTX 2.3 優先、なければ LTX 2B にフォールバック
        $wfPath = "$benchDir\workflows\ltx2_3_t2v.json"
        if (-not (Test-Path $wfPath)) { $wfPath = "$benchDir\workflows\ltx_2b_t2v_bench.json" }
        Write-Host "  Workflow: $(Split-Path $wfPath -Leaf)" -ForegroundColor Cyan

        & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
            --workflow $wfPath `
            --drive $drive --runs $Runs `
            --host "http://127.0.0.1:${Port}" `
            --output-dir "$benchDir\results\comfyui-ltx2-bench-R4" `
            --timeout 60

        # TODO: i2v ワークフロー追加

        Stop-ComfyUI -Proc $proc
    }
}

Push-Results "Ex6" "R4 Ex6: ComfyUI LTX 2.3 video gen complete"
Write-Host "`n=== Ex6 Complete ===" -ForegroundColor Green
