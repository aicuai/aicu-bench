<#
.SYNOPSIS
  Ex4: ComfyUI 画像生成 (AiCuty 複数モデル比較: SDXL, WAI, AnimagineXL4, Mellow Pencil)
  各モデルの Checkpoint を切り替えながら計測
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex4: ComfyUI AiCuty Multi-Model ===" -ForegroundColor Yellow
Ensure-Clean

$workflows = @(
    @{ name = "aicuty_sdxl"; file = "aicuty_sdxl.json" }
    # TODO: 以下の WF を準備後に有効化
    # @{ name = "aicuty_wai"; file = "aicuty_wai.json" }
    # @{ name = "aicuty_animagine"; file = "aicuty_animagine.json" }
    # @{ name = "aicuty_mellow_pencil"; file = "aicuty_mellow_pencil.json" }
)

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if ($proc) {
        foreach ($wf in $workflows) {
            $wfPath = "$benchDir\workflows\$($wf.file)"
            if (Test-Path $wfPath) {
                Write-Host "  Workflow: $($wf.name)" -ForegroundColor Cyan
                & py "$benchDir\comfyui-imggen-bench\bench_imggen.py" `
                    --workflow $wfPath `
                    --drive $drive --runs $Runs `
                    --host "http://127.0.0.1:${Port}" `
                    --output-dir "$benchDir\results\comfyui-aicuty-bench-R4" `
                    --timeout 60
            } else {
                Write-Host "  SKIP: $($wf.file) not found" -ForegroundColor DarkYellow
            }
        }
        Stop-ComfyUI -Proc $proc
    }
}

Push-Results "Ex4" "R4 Ex4: ComfyUI AiCuty multi-model comparison complete"
Write-Host "`n=== Ex4 Complete ===" -ForegroundColor Green
