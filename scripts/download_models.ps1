<#
.SYNOPSIS
    全ベンチマーク用モデルの一括ダウンロード (計測付き)

.DESCRIPTION
    各実験に必要なモデルをダウンロードし、所要時間とサイズを記録する。
    ダウンロード速度自体もストレージベンチマークの計測対象。

.PARAMETER Drive
    モデル保存先ドライブレター (デフォルト: D)

.PARAMETER ComfyUIPath
    ComfyUI インストールパス (デフォルト: {Drive}:\ComfyUI)

.PARAMETER SkipOllama
    Ollama モデルのダウンロードをスキップ

.PARAMETER SkipComfyUI
    ComfyUI モデルのダウンロードをスキップ

.EXAMPLE
    .\scripts\download_models.ps1 -Drive D
    .\scripts\download_models.ps1 -Drive E -SkipOllama
#>

param(
    [ValidatePattern("^[A-Z]$")]
    [string]$Drive = "D",

    [string]$ComfyUIPath = "",

    [switch]$SkipOllama,
    [switch]$SkipComfyUI
)

$ErrorActionPreference = "Stop"

if (-not $ComfyUIPath) {
    $ComfyUIPath = "${Drive}:\ComfyUI"
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path) }
$resultsDir = Join-Path (Split-Path $scriptDir -Parent) "results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }

$downloadLog = @()

function Measure-Download {
    param(
        [string]$Name,
        [string]$Category,
        [scriptblock]$Action
    )
    Write-Host "`n--- $Name ---" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $error_msg = $null
    try {
        & $Action
        $sw.Stop()
        $success = $true
    } catch {
        $sw.Stop()
        $success = $false
        $error_msg = $_.Exception.Message
        Write-Host "  ERROR: $error_msg" -ForegroundColor Red
    }
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    $record = [ordered]@{
        name      = $Name
        category  = $Category
        elapsed_s = $elapsed
        success   = $success
        error     = $error_msg
        timestamp = (Get-Date -Format "o")
    }
    Write-Host "  Time: ${elapsed}s | $(if ($success) {'OK'} else {'FAILED'})" -ForegroundColor $(if ($success) {"Green"} else {"Red"})
    $script:downloadLog += $record
    return $record
}

# =============================================================================
# Model definitions
# =============================================================================

# --- URLs ---
# HuggingFace models (huggingface_hub でダウンロード)
$HF_MODELS = @(
    # SDXL Checkpoint (AiCuty workflow)
    @{
        name     = "Animagine XL 4.0"
        repo     = "cagliostrolab/animagine-xl-4.0"
        file     = "animagine-xl-4.0-opt.safetensors"
        dest     = "models\checkpoints"
        size_est = "7.0 GB"
        url      = "https://huggingface.co/cagliostrolab/animagine-xl-4.0"
    },
    # LTX-Video
    @{
        name     = "LTX-Video 2B v0.9.5"
        repo     = "Lightricks/LTX-Video"
        file     = "ltx-video-2b-v0.9.5.safetensors"
        dest     = "models\checkpoints"
        size_est = "9.5 GB"
        url      = "https://huggingface.co/Lightricks/LTX-Video"
    },
    # T5 encoder for LTX-Video
    @{
        name     = "T5-XXL FP16"
        repo     = "comfyanonymous/flux_text_encoders"
        file     = "t5xxl_fp16.safetensors"
        dest     = "models\clip"
        size_est = "9.8 GB"
        url      = "https://huggingface.co/comfyanonymous/flux_text_encoders"
    },
    # RealESRGAN upscaler
    @{
        name     = "RealESRGAN x4plus Anime 6B"
        repo     = "nateraw/real-esrgan"
        file     = "RealESRGAN_x4plus_anime_6B.pth"
        dest     = "models\upscale_models"
        size_est = "17 MB"
        url      = "https://huggingface.co/nateraw/real-esrgan"
    },
    # --- LTX 2.3 (22B) ---
    @{
        name     = "LTX 2.3 22B FP8"
        repo     = "Lightricks/LTX-2.3-fp8"
        file     = "ltx-2.3-22b-dev-fp8.safetensors"
        dest     = "models\checkpoints"
        size_est = "22 GB"
        url      = "https://huggingface.co/Lightricks/LTX-2.3-fp8"
    },
    @{
        name     = "Gemma 3 12B IT FP4 (LTX 2.3 text encoder)"
        repo     = "Comfy-Org/ltx-2"
        file     = "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors"
        dest     = "models\text_encoders"
        size_est = "6.5 GB"
        url      = "https://huggingface.co/Comfy-Org/ltx-2"
    },
    @{
        name     = "LTX 2.3 Distilled LoRA"
        repo     = "Lightricks/LTX-2.3"
        file     = "ltx-2.3-22b-distilled-lora-384.safetensors"
        dest     = "models\loras"
        size_est = "700 MB"
        url      = "https://huggingface.co/Lightricks/LTX-2.3"
    },
    # --- Wan 2.2 14B ---
    @{
        name     = "Wan 2.2 T2V High Noise 14B FP8"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
        dest     = "models\diffusion_models"
        size_est = "14 GB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    },
    @{
        name     = "Wan 2.2 T2V Low Noise 14B FP8"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
        dest     = "models\diffusion_models"
        size_est = "14 GB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    },
    @{
        name     = "UMT5-XXL FP8 (Wan 2.2 CLIP)"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
        dest     = "models\clip"
        size_est = "4.9 GB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    },
    @{
        name     = "Wan 2.1 VAE"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/vae/wan_2.1_vae.safetensors"
        dest     = "models\vae"
        size_est = "200 MB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    },
    @{
        name     = "Wan 2.2 LightX2V LoRA High Noise"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
        dest     = "models\loras"
        size_est = "1.4 GB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    },
    @{
        name     = "Wan 2.2 LightX2V LoRA Low Noise"
        repo     = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
        file     = "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
        dest     = "models\loras"
        size_est = "1.4 GB"
        url      = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
    }
)

# CivitAI models (要 CIVITAI_API_KEY)
$CIVITAI_MODELS = @(
    @{
        name       = "Niji Anime Illustrious LoRA"
        file       = "Niji_anime_illustrious.safetensors"
        dest       = "models\loras"
        size_est   = "435 MB"
        url        = "https://civitai.com/models/1261988"
        version_id = 1939768
        note       = "CivitAI login required"
    },
    @{
        name       = "Enchanting Eyes Illustrious LoRA"
        file       = "eyecolle_xl_code191.safetensors"
        dest       = "models\loras"
        size_est   = "52 MB"
        url        = "https://civitai.com/models/974076"
        version_id = 1463317
        note       = "CivitAI login required"
    }
)

# Ollama models
$OLLAMA_MODELS = @(
    @{ name = "qwen3:8b";   size_est = "5.2 GB"; url = "https://ollama.com/library/qwen3" },
    @{ name = "qwen3:1.7b"; size_est = "1.4 GB"; url = "https://ollama.com/library/qwen3" }
)

# =============================================================================
# Main
# =============================================================================

Write-Host "=== AICU-bench Model Downloader ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | ComfyUI: $ComfyUIPath"
Write-Host "Start: $(Get-Date -Format 'o')`n"

# --- Pre-flight checks ---
$preflightOk = $true

if (-not $SkipOllama) {
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaCmd) {
        Write-Host "WARNING: ollama not found. Ollama models will be skipped." -ForegroundColor Yellow
        Write-Host "  Install from: https://ollama.com/" -ForegroundColor Yellow
        $SkipOllama = $true
    }
}

if (-not $SkipComfyUI) {
    if (-not (Test-Path $ComfyUIPath)) {
        Write-Host "ComfyUI not found at $ComfyUIPath. Cloning..." -ForegroundColor Yellow
        Measure-Download -Name "ComfyUI Clone" -Category "setup" -Action {
            git clone https://github.com/comfyanonymous/ComfyUI.git $ComfyUIPath --depth 1
        }
    }

    # Check HF_TOKEN
    if (-not $env:HF_TOKEN) {
        Write-Host "INFO: HF_TOKEN not set. Some models may require authentication." -ForegroundColor Yellow
        Write-Host "  Set with: `$env:HF_TOKEN = 'hf_...'" -ForegroundColor Yellow
    }

    # Check CIVITAI_API_KEY
    if (-not $env:CIVITAI_API_KEY) {
        Write-Host "INFO: CIVITAI_API_KEY not set. CivitAI LoRA downloads will be skipped." -ForegroundColor Yellow
        Write-Host "  Set with: `$env:CIVITAI_API_KEY = '...'" -ForegroundColor Yellow
        Write-Host "  Get key from: https://civitai.com/user/account (API Keys)" -ForegroundColor Yellow
    }
}

# --- Ollama models ---
if (-not $SkipOllama) {
    Write-Host "`n=== Ollama Models ===" -ForegroundColor Yellow
    $modelsPath = "${Drive}:\ollama\models"
    if (-not (Test-Path $modelsPath)) {
        New-Item -ItemType Directory -Path $modelsPath -Force | Out-Null
    }

    foreach ($m in $OLLAMA_MODELS) {
        Measure-Download -Name "Ollama: $($m.name)" -Category "ollama" -Action {
            $env:OLLAMA_MODELS = $modelsPath
            & ollama pull $m.name
            Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue
        }
    }
}

# --- HuggingFace models ---
if (-not $SkipComfyUI) {
    Write-Host "`n=== HuggingFace Models ===" -ForegroundColor Yellow

    foreach ($m in $HF_MODELS) {
        $destDir = Join-Path $ComfyUIPath $m.dest
        # file にサブディレクトリが含まれる場合（split_files/...）はファイル名だけを使う
        $localFileName = Split-Path $m.file -Leaf
        $destFile = Join-Path $destDir $localFileName

        if (Test-Path $destFile) {
            $size = [math]::Round((Get-Item $destFile).Length / 1GB, 2)
            Write-Host "SKIP: $($m.name) already exists (${size} GB)" -ForegroundColor DarkYellow
            continue
        }

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        Measure-Download -Name "HF: $($m.name)" -Category "huggingface" -Action {
            py -c @"
from huggingface_hub import hf_hub_download
import os, shutil
path = hf_hub_download(
    repo_id='$($m.repo)',
    filename='$($m.file)',
    local_dir=r'$destDir'
)
# サブディレクトリにDLされた場合、destDir直下に移動
dest_final = os.path.join(r'$destDir', os.path.basename(path))
if os.path.abspath(path) != os.path.abspath(dest_final):
    shutil.move(path, dest_final)
    path = dest_final
size_gb = os.path.getsize(path) / (1024**3)
print(f'  Downloaded: {size_gb:.2f} GB -> {path}')
"@
        }
    }

    # --- CivitAI models ---
    if ($env:CIVITAI_API_KEY) {
        Write-Host "`n=== CivitAI Models ===" -ForegroundColor Yellow
        foreach ($m in $CIVITAI_MODELS) {
            $destDir = Join-Path $ComfyUIPath $m.dest
            $destFile = Join-Path $destDir $m.file

            if (Test-Path $destFile) {
                Write-Host "SKIP: $($m.name) already exists" -ForegroundColor DarkYellow
                continue
            }

            Write-Host "  CivitAI model: $($m.name)" -ForegroundColor Yellow
            Write-Host "  Manual download required: $($m.url)" -ForegroundColor Yellow
            Write-Host "  Save to: $destFile" -ForegroundColor Yellow
        }
    } else {
        Write-Host "`nSKIP: CivitAI LoRA models (CIVITAI_API_KEY not set)" -ForegroundColor DarkYellow
        foreach ($m in $CIVITAI_MODELS) {
            Write-Host "  - $($m.name): $($m.url)" -ForegroundColor Gray
        }
    }
}

# --- Summary ---
Write-Host "`n=== Download Summary ===" -ForegroundColor Yellow

$outFile = Join-Path $resultsDir "download_log.json"
$summary = [ordered]@{
    drive      = $Drive
    comfyui    = $ComfyUIPath
    downloads  = $downloadLog
    total_s    = [math]::Round(($downloadLog | ForEach-Object { [PSCustomObject]$_ } | Where-Object { $_.success } | Measure-Object -Property elapsed_s -Sum).Sum, 2)
    failed     = ($downloadLog | ForEach-Object { [PSCustomObject]$_ } | Where-Object { -not $_.success }).Count
    generated  = (Get-Date -Format "o")
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8

foreach ($d in $downloadLog) {
    $status = if ($d.success) { "OK" } else { "FAIL" }
    Write-Host ("  [{0}] {1}: {2}s" -f $status, $d.name, $d.elapsed_s) -ForegroundColor $(if ($d.success) {"Green"} else {"Red"})
}
Write-Host "`nTotal download time: $($summary.total_s)s"
Write-Host "Log saved: $outFile"
Write-Host "`n=== Done ===" -ForegroundColor Green
