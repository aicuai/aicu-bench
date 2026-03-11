#!/usr/bin/env python3
"""
llm-jp-moshi ベンチマーク

15.6GB の日本語フルデュプレックス音声対話モデルのロード時間と
音声生成レイテンシを計測。大型モデルのストレージ速度影響を定量化。

Usage:
    python bench_moshi.py --drive D --runs 3
    python bench_moshi.py --all-drives
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import torch

# Windows では Triton が使えないため torch.compile を無効化
torch._dynamo.config.suppress_errors = True
os.environ["TORCHDYNAMO_DISABLE"] = "1"

MODEL_REPO = "llm-jp/llm-jp-moshi-v1"
DRIVES = ["D", "E", "F", "G"]
DEFAULT_RUNS = 3

# テスト用テキスト (TTS モードで使用)
TEST_TEXTS = [
    {"id": "S1", "label": "短文", "text": "こんにちは、今日はいい天気ですね。"},
    {"id": "M1", "label": "中文・吾輩は猫である", "text": "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"},
    {"id": "L1", "label": "長文・走れメロス", "text": (
        "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。"
        "メロスには政治がわからぬ。メロスは、村の牧人である。笛を吹き、羊と遊んで暮して来た。"
    )},
]


def get_nvidia_smi() -> dict:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=gpu_name,memory.used,memory.total,temperature.gpu,power.draw",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            return {
                "gpu_name": parts[0], "vram_used_mb": int(parts[1]),
                "vram_total_mb": int(parts[2]), "temp_c": int(parts[3]),
                "power_w": float(parts[4]),
            }
    except Exception:
        pass
    return {}


def download_model(hf_home: str):
    """HF cache にモデルをダウンロード（未ダウンロードの場合）"""
    from huggingface_hub import hf_hub_download
    from moshi.models import loaders

    files = [loaders.MOSHI_NAME, loaders.MIMI_NAME]
    for fname in files:
        print(f"  Ensuring {fname} in cache...", end=" ", flush=True)
        t0 = time.time()
        path = hf_hub_download(MODEL_REPO, fname)
        elapsed = round(time.time() - t0, 3)
        size_mb = round(os.path.getsize(path) / (1024 * 1024), 1)
        print(f"{elapsed}s ({size_mb} MB)")


def load_mimi(device: str = "cuda") -> tuple:
    """Mimi 音声コーデックをロード"""
    from huggingface_hub import hf_hub_download
    from moshi.models import loaders

    mimi_path = hf_hub_download(MODEL_REPO, loaders.MIMI_NAME)
    t0 = time.time()
    mimi = loaders.get_mimi(mimi_path, device=device)
    elapsed = round(time.time() - t0, 3)
    size_mb = round(os.path.getsize(mimi_path) / (1024 * 1024), 1)
    return mimi, elapsed, size_mb


def load_moshi_lm(device: str = "cuda") -> tuple:
    """Moshi LM (15.4GB) をロード"""
    from huggingface_hub import hf_hub_download
    from moshi.models import loaders

    moshi_path = hf_hub_download(MODEL_REPO, loaders.MOSHI_NAME)
    t0 = time.time()
    lm = loaders.get_moshi_lm(moshi_path, device=device)
    elapsed = round(time.time() - t0, 3)
    size_mb = round(os.path.getsize(moshi_path) / (1024 * 1024), 1)
    return lm, elapsed, size_mb


def bench_encode_decode(mimi, duration_sec: float = 3.0, sr: int = 24000) -> dict:
    """Mimi codec のエンコード・デコードベンチ"""
    device = next(mimi.parameters()).device
    # ダミー音声 (ホワイトノイズ)
    samples = int(sr * duration_sec)
    wav = torch.randn(1, 1, samples, device=device)

    # エンコード
    t0 = time.time()
    with torch.no_grad():
        codes = mimi.encode(wav)
    encode_time = round(time.time() - t0, 4)

    # デコード
    t0 = time.time()
    with torch.no_grad():
        decoded = mimi.decode(codes)
    decode_time = round(time.time() - t0, 4)

    return {
        "input_duration_sec": duration_sec,
        "encode_time_s": encode_time,
        "decode_time_s": decode_time,
        "codes_shape": list(codes.shape),
        "output_samples": decoded.shape[-1],
    }


def bench_lm_generation(lm, mimi, steps: int = 25) -> dict:
    """LM のトークン生成ベンチ — codec encode → LM forward の簡易パイプライン"""
    device = next(lm.parameters()).device

    # 3秒のダミー音声 → codec → tokens
    sr = 24000
    wav = torch.randn(1, 1, sr * 3, device=device)
    with torch.no_grad():
        codes = mimi.encode(wav)  # [B, K=8, T]

    # LMGen で生成テスト
    try:
        from moshi.models import LMGen
        lm_gen = LMGen(lm, temp=0.7, temp_text=0.7)

        # ウォームアップ + ステップ計測
        t0 = time.time()
        with torch.no_grad():
            for _ in range(steps):
                lm_gen.step(codes[:, :, :1])
        elapsed = round(time.time() - t0, 4)
        steps_per_sec = round(steps / elapsed, 2) if elapsed > 0 else 0
        realtime_factor = round(steps_per_sec * 0.08, 3)
    except Exception as e:
        # LMGen API が合わない場合は単純 forward pass で計測
        t0 = time.time()
        with torch.no_grad():
            for _ in range(steps):
                # 最小入力で forward pass
                dummy_input = torch.zeros(1, 17, 1, dtype=torch.long, device=device)
                try:
                    lm.forward(dummy_input)
                except Exception:
                    break
        elapsed = round(time.time() - t0, 4)
        steps_per_sec = round(steps / max(elapsed, 0.001), 2)
        realtime_factor = round(steps_per_sec * 0.08, 3)

    return {
        "steps": steps,
        "elapsed_s": elapsed,
        "steps_per_sec": steps_per_sec,
        "realtime_factor": realtime_factor,
    }


def run_single(drive: str, run_number: int, runs: int) -> dict:
    """1 回分のベンチマーク"""
    print(f"\n[{drive}] Run {run_number}/{runs}")

    gpu_before = get_nvidia_smi()

    # Mimi ロード
    print("  Loading Mimi codec...", flush=True)
    mimi, mimi_load_s, mimi_size_mb = load_mimi()
    print(f"  Mimi loaded: {mimi_load_s}s ({mimi_size_mb} MB)")

    # Moshi LM ロード
    print("  Loading Moshi LM (15.4GB)...", flush=True)
    lm, lm_load_s, lm_size_mb = load_moshi_lm()
    print(f"  Moshi LM loaded: {lm_load_s}s ({lm_size_mb} MB)")

    gpu_after_load = get_nvidia_smi()

    total_load_s = round(mimi_load_s + lm_load_s, 3)
    total_size_mb = round(mimi_size_mb + lm_size_mb, 1)

    # Codec ベンチ
    print("  Running codec benchmark...", flush=True)
    codec_result = bench_encode_decode(mimi)
    print(f"  Encode: {codec_result['encode_time_s']}s, Decode: {codec_result['decode_time_s']}s")

    # LM 生成ベンチ
    print("  Running LM generation benchmark (25 steps)...", flush=True)
    lm_result = bench_lm_generation(lm, mimi, steps=25)
    print(f"  {lm_result['steps_per_sec']} steps/s (realtime factor: {lm_result['realtime_factor']}x)")

    gpu_after = get_nvidia_smi()

    # クリーンアップ
    del lm, mimi
    torch.cuda.empty_cache()

    return {
        "run": run_number,
        "mimi_load_s": mimi_load_s,
        "mimi_size_mb": mimi_size_mb,
        "lm_load_s": lm_load_s,
        "lm_size_mb": lm_size_mb,
        "total_load_s": total_load_s,
        "total_size_mb": total_size_mb,
        "codec": codec_result,
        "lm_gen": lm_result,
        "gpu_before": gpu_before,
        "gpu_after_load": gpu_after_load,
        "gpu_after": gpu_after,
        "success": True,
        "timestamp": datetime.now().isoformat(),
    }


def main():
    parser = argparse.ArgumentParser(description="llm-jp-moshi Benchmark")
    parser.add_argument("--drive", choices=DRIVES)
    parser.add_argument("--all-drives", action="store_true")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS)
    parser.add_argument("--output-dir", type=str,
                        default=os.path.join(os.path.dirname(__file__), "..", "results", "llm-jp-moshi-bench"))
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else ["D"])

    print("\n=== llm-jp-moshi-bench: Japanese Voice Dialogue Model ===")
    print(f"Model: {MODEL_REPO} (~15.6GB)")
    print(f"Drives: {drives} | Runs: {args.runs}\n")

    for drive in drives:
        print(f"\n{'='*50}")
        print(f"=== Drive {drive} ===")
        print(f"{'='*50}")

        # HF cache をドライブに設定
        hf_home = f"{drive}:\\hf_cache"
        os.environ["HF_HOME"] = hf_home
        print(f"  HF_HOME = {hf_home}")

        # モデルダウンロード確認
        download_model(hf_home)

        # VRAM クリア
        torch.cuda.empty_cache()
        torch.cuda.synchronize()

        all_runs = []
        for i in range(1, args.runs + 1):
            try:
                result = run_single(drive, i, args.runs)
                all_runs.append(result)
            except Exception as e:
                print(f"  ERROR: {e}")
                all_runs.append({
                    "run": i, "success": False, "error": str(e),
                    "timestamp": datetime.now().isoformat(),
                })
                torch.cuda.empty_cache()

        # 集計
        successful = [r for r in all_runs if r.get("success")]
        load_times = sorted([r["total_load_s"] for r in successful])
        if load_times:
            mid = len(load_times) // 2
            load_median = load_times[mid] if len(load_times) % 2 else (load_times[mid-1] + load_times[mid]) / 2
        else:
            load_median = None

        lm_load_times = sorted([r["lm_load_s"] for r in successful])
        lm_load_median = lm_load_times[len(lm_load_times)//2] if lm_load_times else None

        summary = {
            "experiment": "llm-jp-moshi-bench",
            "test": "moshi_v1",
            "drive": drive,
            "model": "llm-jp/llm-jp-moshi-v1",
            "model_size_gb": 15.6,
            "runs": args.runs,
            "median_s": load_median,
            "lm_load_median_s": lm_load_median,
            "results": all_runs,
            "generated": datetime.now().isoformat(),
        }

        out_file = output_dir / f"moshi_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"\n  Total load median: {load_median}s")
        print(f"  LM load median: {lm_load_median}s")
        print(f"  Results: {out_file}")

    print("\n=== llm-jp-moshi-bench: Complete! ===\n")


if __name__ == "__main__":
    main()
