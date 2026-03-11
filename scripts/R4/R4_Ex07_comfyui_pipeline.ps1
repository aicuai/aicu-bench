<#
.SYNOPSIS
  Ex7: ComfyUI LTX 2.3 ia2v パイプライン (AiCuty画像 + TTS音声 → 動画)
#>
param([int]$Runs = 1, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

# 推論中はディスクアクセスがほぼないため、各ドライブ1回のみ
$Runs = 1
Write-Host "`n=== Ex7: ComfyUI LTX 2.3 ia2v Pipeline ===" -ForegroundColor Yellow
Write-Host "  AiCuty image + TTS audio -> LTX 2.3 video" -ForegroundColor Cyan
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if ($proc) {
        $wfPath = "$benchDir\workflows\video_ltx2_3_ia2v_AiCuty.json"
        Write-Host "  Workflow: $(Split-Path $wfPath -Leaf)" -ForegroundColor Cyan

        & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
            --workflow $wfPath `
            --drive $drive --runs $Runs `
            --host "http://127.0.0.1:${Port}" `
            --output-dir "$benchDir\results\comfyui-pipeline-bench-R4" `
            --timeout 180

        Stop-ComfyUI -Proc $proc
    }
}

Push-Results "Ex7" "R4 Ex7: LTX 2.3 ia2v pipeline complete"
Write-Host "`n=== Ex7 Complete ===" -ForegroundColor Green
