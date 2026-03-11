<#
.SYNOPSIS
  Ex2: Local LLM (Ollama qwen3) コールドスタート & コード生成
  ドライブごとに Ollama を再起動してコールドスタートを計測
#>
param([int]$Runs = 3, [string[]]$Drives = @("D","E","F","G"))
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex2: Ollama LLM Load + Codegen ===" -ForegroundColor Yellow
Ensure-Clean

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    Stop-AllOllama

    $env:OLLAMA_MODELS = "${drive}:\ollama\models"
    Write-Host "  OLLAMA_MODELS = $($env:OLLAMA_MODELS)" -ForegroundColor DarkGray

    # モデルロード計測
    & powershell -ExecutionPolicy Bypass -File "$benchDir\vibe-local-bench\bench_load.ps1" `
        -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\vibe-local-bench-R4"

    # コード生成計測
    & powershell -ExecutionPolicy Bypass -File "$benchDir\vibe-local-bench\bench_codegen.ps1" `
        -Drive $drive -Runs $Runs -OutputDir "$benchDir\results\vibe-local-bench-R4"

    Stop-AllOllama
}

Push-Results "Ex2" "R4 Ex2: Ollama LLM cold start + codegen complete"
Write-Host "`n=== Ex2 Complete ===" -ForegroundColor Green
