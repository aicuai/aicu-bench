<#
.SYNOPSIS
  Ex8: Qwen3-TTS 長文音声合成実験
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"))
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex8: Qwen3-TTS Long Text TTS ===" -ForegroundColor Yellow
Ensure-Clean

& py "$benchDir\qwen3tts-bench\bench_tts.py" --all-drives --runs $Runs --save-audio `
    --output-dir "$benchDir\results\qwen3tts-bench-R4"

Push-Results "Ex8" "R4 Ex8: Qwen3-TTS long text TTS complete"
Write-Host "`n=== Ex8 Complete ===" -ForegroundColor Green
