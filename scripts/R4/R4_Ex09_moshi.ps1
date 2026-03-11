<#
.SYNOPSIS
  Ex9: llm-jp-moshi 高速音声応答実験
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"))
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex9: llm-jp-moshi Voice Response ===" -ForegroundColor Yellow
Ensure-Clean

& py "$benchDir\llm-jp-moshi-bench\bench_moshi.py" --all-drives --runs $Runs `
    --output-dir "$benchDir\results\llm-jp-moshi-bench-R4"

Push-Results "Ex9" "R4 Ex9: llm-jp-moshi voice response complete"
Write-Host "`n=== Ex9 Complete ===" -ForegroundColor Green
