# CLAUDE.md — ai-storage-bench スキル

> このファイルを Claude Code に読み込ませることで、ベンチマーク実験の環境構築・実行・トラブルシューティングを AI が支援します。

## プロジェクト概要

ストレージ速度（PCIe Gen5 NVMe / SATA SSD / HDD）が AI ワークロードに与える影響を定量計測するベンチマークスイートです。

- **リポジトリ**: https://github.com/aicuai/aicu-bench
- **LP**: https://bench.aicu.jp
- **対象環境**: Windows 11 + PowerShell

---

## 実験一覧

| # | ディレクトリ | 内容 | スクリプト |
|---|-------------|------|-----------|
| 1 | `vibe-local-bench/` | Ollama qwen3:8b モデルロード & コード生成 | `bench_load.ps1`, `bench_codegen.ps1` |
| 2 | `comfyui-imggen-bench/` | ComfyUI z-image-turbo 画像生成 | `bench_imggen.py` |
| 3 | `comfyui-ltx-bench/` | ComfyUI LTX-Video 2.3 動画生成 | `bench_comfyui.py` |
| 4 | `qwen3tts-bench/` | Qwen3-TTS 音声合成 | `bench_tts.py` |

---

## 環境セットアップ手順

### 1. 基本環境
```powershell
# リポジトリ取得
git clone https://github.com/aicuai/aicu-bench
cd aicu-bench

# Python 3.10+ 確認
python --version

# nvidia-smi 動作確認
nvidia-smi
```

### 2. Ollama セットアップ（Experiment 1, 4）
```powershell
# Ollama インストール（公式サイトから）
# https://ollama.com/

# 各ドライブにモデルを配置
# D: ドライブの例
$env:OLLAMA_MODELS = "D:\ollama\models"
ollama pull qwen3:8b

# E: ドライブ
$env:OLLAMA_MODELS = "E:\ollama\models"
ollama pull qwen3:8b

# F: ドライブ
$env:OLLAMA_MODELS = "F:\ollama\models"
ollama pull qwen3:8b

# G: ドライブ
$env:OLLAMA_MODELS = "G:\ollama\models"
ollama pull qwen3:8b
```

### 3. ComfyUI セットアップ（Experiment 2, 3）
```powershell
# ComfyUI を各ドライブにインストール or モデルパスを設定
# extra_model_paths.yaml でドライブごとのモデルパスを切り替え

# 必要なモデル:
# - z-image-turbo (画像生成)
# - ltx-video-2b-v0.9.5.safetensors (動画生成)
# - LTX-Video 用 T5 テキストエンコーダー

# ComfyUI 起動
cd <ComfyUI_DIR>
python main.py --listen 0.0.0.0 --port 8188

# 起動確認
curl http://127.0.0.1:8188/system_stats
```

### 4. ComfyUI カスタムノード確認
```powershell
# LTX-Video に必要なカスタムノード
# ComfyUI Manager でインストール or git clone:
# - ComfyUI-LTXVideo (LTXVLoader, LTXVScheduler, LTXVConditioning 等)

# インストール確認
curl http://127.0.0.1:8188/object_info | python -c "import sys,json; d=json.load(sys.stdin); print([k for k in d if 'LTX' in k])"
```

---

## ベンチマーク実行

### 全実験一括
```powershell
.\scripts\run_all_benchmarks.ps1 -Runs 3
```

### 個別実験
```powershell
# Exp 1: vibe-local (Ollama)
.\vibe-local-bench\bench_load.ps1 -Drive D -Runs 3
.\vibe-local-bench\bench_codegen.ps1 -Drive D -Runs 3

# Exp 2: 画像生成 (ComfyUI z-image-turbo)
python .\comfyui-imggen-bench\bench_imggen.py --drive D --runs 3

# Exp 3: 動画生成 (ComfyUI LTX-Video)
python .\comfyui-ltx-bench\bench_comfyui.py --drive D --runs 3

# Exp 4: TTS (Qwen3-TTS)
python .\qwen3tts-bench\bench_tts.py --drive D --runs 3
```

### システム情報
```powershell
.\scripts\collect_sysinfo.ps1
```

---

## トラブルシューティング

### Ollama が応答しない
```powershell
# Ollama サービスの状態確認
Get-Process ollama -ErrorAction SilentlyContinue
# 再起動
ollama serve
# API テスト
Invoke-RestMethod -Uri "http://localhost:11434/api/tags"
```

### ComfyUI が起動しない / ノードエラー
```powershell
# ComfyUI ログ確認
# main.py の出力をチェック

# system_stats で状態確認
Invoke-RestMethod -Uri "http://127.0.0.1:8188/system_stats"

# VRAM 不足の場合
python main.py --lowvram
# or
python main.py --cpu
```

### nvidia-smi エラー
```powershell
# パス確認
where.exe nvidia-smi
# ドライババージョン確認
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

### モデルが見つからない
```powershell
# Ollama モデル一覧
$env:OLLAMA_MODELS = "D:\ollama\models"
ollama list

# ComfyUI モデルパス確認
# extra_model_paths.yaml を確認
```

### ベンチマーク結果が異常
```powershell
# 前回の結果確認
Get-Content .\results\vibe-local-bench\load_D.json | ConvertFrom-Json | Select-Object -ExpandProperty results

# GPU 温度確認（サーマルスロットリング）
nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv -l 1

# キャッシュクリア確認
# Windows ファイルキャッシュもクリアする場合:
# RAMMap (Sysinternals) で Empty Standby List
```

---

## 結果データの扱い

### JSON 結果の確認
```powershell
# 全結果一覧
Get-ChildItem .\results -Recurse -Filter "*.json" | Select-Object FullName, Length

# 中央値の一覧抽出
Get-ChildItem .\results -Recurse -Filter "*.json" | ForEach-Object {
    $d = Get-Content $_.FullName | ConvertFrom-Json
    if ($d.median_s) {
        [PSCustomObject]@{
            Experiment = $d.experiment
            Drive = $d.drive
            Median_s = $d.median_s
        }
    }
} | Format-Table
```

### 結果を LP に反映
```powershell
# 1. results/ の JSON から site/data.json を生成
python .\scripts\update_site.py

# 2. main に push → Cloudflare Pages に自動デプロイ
git add site/data.json
git commit -m "Update benchmark results"
git push
```

LP は `data.json` を fetch して計測結果テーブルを動的に表示する。

---

## テスト対象ストレージ

| ドライブ | デバイス | 速度 |
|---------|---------|------|
| D: | Samsung 9100 PRO 8TB (Gen5 NVMe) | ~14,500 MB/s |
| E: | Samsung 870 QVO 8TB (SATA SSD) | ~560 MB/s |
| F: | HDD 8TB | ~180 MB/s |
| G: | 9100 PRO 8TB (ICY DOCK リムーバブル) | ~14,500 MB/s |

---

## コーディング規約

- スクリプトは**べき等**（再実行しても安全）
- 計測は **3回以上**、**中央値**を採用
- モデルキャッシュは計測前に**必ずクリア**
- GPU 情報（VRAM, 温度, 電力）を **before/after** で記録
- 結果は `results/` に JSON 出力
- ComfyUI ベンチでは **コアバージョン** と **ノード一覧** を記録
