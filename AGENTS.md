# AGENTS.md — AI Storage Benchmark Suite
## ai-storage-bench

> **目的**: ストレージ速度（NVMe Gen5 / SATA SSD / HDD）が AI ワークロードのパフォーマンスに与える影響を定量的に計測し、オープンな再現可能な形で公開する。

本リポジトリは [Impress AKIBA PC Hotline!](https://akiba-pc.watch.impress.co.jp/) の取材協力として実施した実験のソースコードおよび結果データを含みます。

---

## 実験環境（Reference Machine）

| 項目 | 値 |
|------|-----|
| CPU | AMD Ryzen Threadripper PRO 7975WX (32コア) |
| RAM | DDR5-4800 192GB (32GB×6) |
| GPU | NVIDIA RTX PRO 6000 Blackwell MAX-Q 96GB |
| OS | Windows 11 PRO |

### ストレージ構成

| ドライブ | デバイス | インターフェース | 用途 |
|---------|---------|----------------|------|
| C: | Samsung 9100 PRO 2TB | PCIe Gen5 M.2 | OS・アプリ |
| D: | Samsung 9100 PRO 8TB | PCIe Gen5 M.2 | **ベンチ対象①** |
| E: | Samsung 870 QVO 8TB | SATA SSD | **ベンチ対象②** |
| F: | HDD 8TB | SATA HDD | **ベンチ対象③** |
| G: | Samsung 9100 PRO 8TB (ICY DOCK MB842M5P-B) | PCIe Gen5 M.2 リムーバブル | **ベンチ対象④** |

---

## 実験一覧

### Experiment 1: vibe-local / Ollama モデルロード & コード生成ベンチ
→ [`vibe-local-bench/`](./vibe-local-bench/)

### Experiment 2: ComfyUI z-image-turbo 画像生成ベンチ
→ [`comfyui-imggen-bench/`](./comfyui-imggen-bench/)

### Experiment 3: ComfyUI LTX-Video 2.3 動画生成ベンチ
→ [`comfyui-ltx-bench/`](./comfyui-ltx-bench/)

### Experiment 4: Qwen3-TTS 音声合成ベンチ
→ [`qwen3tts-bench/`](./qwen3tts-bench/)

---

## エージェントへの指示（AI Agent Instructions）

このリポジトリをエージェントが操作する際は以下のルールに従うこと：

1. **結果は必ず `results/` ディレクトリに JSON + CSV で保存する**
2. **計測は各ドライブで同条件で3回以上繰り返し、中央値を採用する**
3. **モデルキャッシュはベンチ前に必ずクリアする**（手順は各サブディレクトリの README 参照）
4. **システム情報（GPU使用率・VRAM使用量・CPU温度）を同時記録する**
5. **スクリプトはべき等（idempotent）であること**：再実行しても結果が上書きされるだけで壊れない

---

## スクリプト構成

```
ai-storage-bench/
├── AGENTS.md                          # 本ファイル
├── README.md
├── .gitignore
├── site/                              # LP (bench.aicu.jp)
│   ├── index.html                     # LP 本体（data.json を fetch して結果表示）
│   ├── style.css
│   └── data.json                      # 計測結果データ（update_site.py で生成）
├── CLAUDE.md                          # Claude Code スキルファイル
├── workflows/                         # ComfyUI ワークフロー JSON（aicubench 由来）
│   ├── z_image_turbo.json             # z-image-turbo (UNETLoader+Qwen3+AuraFlow)
│   ├── flux1_schnell.json             # FLUX.1 Schnell
│   └── sd15.json                      # Stable Diffusion 1.5
├── scripts/                           # 共通スクリプト
│   ├── collect_sysinfo.ps1            # nvidia-smi・CPU・RAM・ストレージ情報収集
│   ├── run_all_benchmarks.ps1         # 全実験一括実行（ランスルーテスト）
│   └── update_site.py                 # results/ → site/data.json 生成
├── vibe-local-bench/                  # Experiment 1
│   ├── bench_load.ps1                 # モデルロード時間計測
│   ├── bench_codegen.ps1              # コード生成時間計測
│   └── run_all.ps1                    # 全ドライブ一括実行
├── comfyui-imggen-bench/              # Experiment 2
│   └── bench_imggen.py               # z-image-turbo 画像生成ベンチマーク
├── comfyui-ltx-bench/                 # Experiment 3
│   └── bench_comfyui.py              # LTX-Video 2.3 動画生成ベンチマーク
├── qwen3tts-bench/                    # Experiment 4
│   └── bench_tts.py                   # TTS ベンチマーク
├── results/                           # 計測結果出力先（自動生成）
│   ├── sysinfo.json                   # システム情報
│   ├── nvidia_smi_full.txt            # nvidia-smi フル出力
│   ├── vibe-local-bench/
│   │   ├── load_D.json
│   │   ├── codegen_D.json
│   │   └── ...
│   ├── comfyui-imggen-bench/
│   │   ├── comfyui_info.json          # ComfyUI バージョン情報
│   │   ├── imggen_D.json
│   │   └── ...
│   ├── comfyui-ltx-bench/
│   │   ├── comfyui_info.json          # ComfyUI バージョン情報
│   │   ├── comfyui_D.json
│   │   └── ...
│   └── qwen3tts-bench/
│       ├── tts_D.json
│       └── ...
└── .github/
    └── workflows/
        └── deploy.yml                 # Cloudflare Pages デプロイ
```

---

## 結果 JSON スキーマ

### 共通フィールド

全実験の JSON 結果には以下の共通フィールドが含まれる：

```json
{
  "experiment": "実験名",
  "drive": "D",
  "runs": 3,
  "median_s": 12.345,
  "results": [
    {
      "run": 1,
      "success": true,
      "gpu_before": {
        "gpu_name": "NVIDIA RTX PRO 6000",
        "vram_used_mb": 1024,
        "vram_total_mb": 98304,
        "temp_c": 42,
        "power_w": 85.5
      },
      "gpu_after": { "..." : "..." },
      "timestamp": "2025-06-01T12:00:00+09:00"
    }
  ],
  "generated": "2025-06-01T12:30:00+09:00"
}
```

### vibe-local-bench 固有フィールド

- `load_time_s`: モデルロード時間（秒）
- `gen_time_s`: コード生成時間（秒）
- `token_count`: 生成トークン数
- `tokens_per_sec`: トークン/秒

### comfyui-imggen-bench 固有フィールド

- `cold_start_s`: コールドスタート時間（モデルロード込み、秒）
- `warm_batch_s`: ウォームバッチ合計時間（秒）
- `image_results[]`: プロンプトごとの `elapsed_s`, `cold_start` フラグ
- `model`: ワークフロー構成情報（unet, clip, vae, sampler, steps, cfg, resolution）

### comfyui-ltx-bench 固有フィールド

- `total_time_s`: 動画生成トータル時間（秒）
- `workflow_type`: `ltxv_native` or `generic_fallback`
- `comfyui_info`: ComfyUI system_stats / object_info / ltx_nodes

### qwen3tts-bench 固有フィールド

- `first_audio_s`: Time-to-First-Audio（秒）
- `batch_total_s`: バッチ全体の処理時間（秒）
- `text_results[]`: テキストごとの `elapsed_s`, `file_size_bytes`

---

## ComfyUI ログ分析ガイドライン

ComfyUI ベンチマークの再現性を確保するため：

1. **ComfyUI コアバージョン**を記録する（`/system_stats` API で取得）
2. **カスタムノード一覧**と各バージョンを記録
3. **モデルファイルのハッシュ**（SHA256）を検証に利用
4. **ログからの解析項目**:
   - `Prompt executed in X.XX seconds` — 実行時間
   - `Loading model:` — モデルロード開始のログ
   - VRAM allocation/deallocation メッセージ
5. **ComfyUI 起動パラメータ**（`--highvram`, `--gpu-only` 等）を記録

---

## Claude Code スキル / コマンド

Claude Code でこのリポジトリを操作する際に使える操作パターン：

### ベンチマーク実行
```powershell
# 全実験一括実行
.\scripts\run_all_benchmarks.ps1 -Runs 3

# 個別実験
.\vibe-local-bench\run_all.ps1 -Runs 3
python .\comfyui-imggen-bench\bench_imggen.py --all-drives --runs 3
python .\comfyui-ltx-bench\bench_comfyui.py --all-drives --runs 3
python .\qwen3tts-bench\bench_tts.py --all-drives --runs 3
```

### システム情報収集
```powershell
.\scripts\collect_sysinfo.ps1
```

### 結果レビュー
```powershell
# 結果 JSON を確認
Get-Content .\results\vibe-local-bench\load_D.json | ConvertFrom-Json

# 全結果ファイル一覧
Get-ChildItem .\results -Recurse -Filter "*.json"
```

### 結果 → LP 反映 → デプロイ

計測結果を LP に反映するパイプライン：

```powershell
# 1. ベンチマーク実行（results/ に JSON 出力）
.\scripts\run_all_benchmarks.ps1 -Runs 3

# 2. results/ の JSON から site/data.json を生成
python .\scripts\update_site.py

# 3. コミット & push → Cloudflare Pages に自動デプロイ
git add site/data.json
git commit -m "Update benchmark results"
git push
```

LP (`site/index.html`) は `data.json` を fetch して計測結果テーブルを動的に表示する。
`main` に push すると GitHub Actions → Cloudflare Pages に自動デプロイされる。

### ワークフロー JSON（aicubench 由来）

`workflows/` ディレクトリに ComfyUI API 形式のテスト済みワークフローを配置。
ベンチマークスクリプトはこれを読み込んで実行する。

| ファイル | モデル構成 | ステップ |
|---------|----------|---------|
| `z_image_turbo.json` | UNETLoader + CLIPLoader(qwen_3_4b) + VAELoader(ae) + AuraFlow | 4 steps, cfg=1 |
| `flux1_schnell.json` | CheckpointLoaderSimple(flux1-schnell-fp8) | 4 steps, cfg=1 |
| `sd15.json` | CheckpointLoaderSimple(v1-5-pruned-emaonly-fp16) | 20 steps, cfg=8 |

### Claude Code によるセットアップ

トラブルシューティングや初期の実験環境のセットアップを高速に進めるため、**[Claude Code](https://j.aicu.ai/_Claude)** を使用。無料で利用可能。

本リポジトリの `CLAUDE.md` を読み込ませるだけで、環境構築からベンチマーク実行、結果分析まで AI が支援する。

```powershell
claude   # CLAUDE.md を自動読み込み
```

---

## ライセンス

MIT License — 実験スクリプト・結果データともにオープン公開。
計測結果の引用時は本リポジトリへのリンクをお願いします。
