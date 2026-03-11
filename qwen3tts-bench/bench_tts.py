#!/usr/bin/env python3
"""
Qwen3-TTS ベンチマーク

HuggingFace/PyTorch 直接実行で Qwen3-TTS の音声合成パフォーマンスを計測。
モデルロード時間 (cold start) と各テキストの生成時間を測定。

モデルは HF cache に保存されるため、ドライブ別計測には
HF_HOME 環境変数でキャッシュ先を切り替える。

Usage:
    python bench_tts.py --drive D --runs 3
    python bench_tts.py --all-drives
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
import soundfile as sf
import torch

MODEL_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
DRIVES = ["D", "E", "F", "G"]
DEFAULT_RUNS = 3
DEFAULT_SPEAKER = "ono_anna"

# テストテキスト (短・中・長)
TEST_TEXTS = [
    {
        "id": "S1",
        "label": "短文・挨拶",
        "text": "こんにちは、今日はいい天気ですね。",
    },
    {
        "id": "M1",
        "label": "中文・青空文庫（夏目漱石『吾輩は猫である』）",
        "text": (
            "吾輩は猫である。名前はまだ無い。"
            "どこで生れたかとんと見当がつかぬ。"
            "何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。"
        ),
    },
    {
        "id": "M2",
        "label": "中文・青空文庫（宮沢賢治『銀河鉄道の夜』）",
        "text": (
            "カムパネルラが手をあげました。それから四、五人手をあげました。"
            "ジョバンニも手をあげようとして、急いでそのままやめました。"
        ),
    },
    {
        "id": "L1",
        "label": "長文・青空文庫（太宰治『走れメロス』）",
        "text": (
            "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。"
            "メロスには政治がわからぬ。メロスは、村の牧人である。笛を吹き、羊と遊んで暮して来た。"
            "けれども邪悪に対しては、人一倍に敏感であった。きょう未明メロスは村を出発し、"
            "野を越え山越え、十里はなれた此のシラクスの市にやって来た。"
        ),
    },
    {
        "id": "L2",
        "label": "長文・AI解説",
        "text": (
            "Samsung 9100 PRO は PCIe Gen5 x4 インターフェースを採用し、"
            "シーケンシャルリードで最大14,500メガバイト毎秒を実現します。"
            "これは従来の Gen4 NVMe の約2倍、SATA SSD の約26倍の速度です。"
            "AI ワークロードにおいては、Large Language Model のロード時間が劇的に短縮され、"
            "ComfyUI での Stable Diffusion チェックポイント切り替えも瞬時に完了します。"
        ),
    },
]


def get_nvidia_smi() -> dict:
    """nvidia-smi から GPU 情報を取得"""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=gpu_name,memory.used,memory.total,temperature.gpu,power.draw",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            return {
                "gpu_name": parts[0],
                "vram_used_mb": int(parts[1]),
                "vram_total_mb": int(parts[2]),
                "temp_c": int(parts[3]),
                "power_w": float(parts[4]),
            }
    except Exception:
        pass
    return {}


def load_model(device: str = "cuda:0", dtype=torch.float16):
    """Qwen3-TTS モデルをロード（時間計測付き）"""
    from qwen_tts import Qwen3TTSModel

    print(f"  Loading {MODEL_ID} on {device} ({dtype})...")
    t0 = time.time()
    model = Qwen3TTSModel.from_pretrained(MODEL_ID, device_map=device, dtype=dtype)
    load_time = round(time.time() - t0, 3)
    print(f"  Model loaded in {load_time}s")
    return model, load_time


def synthesize(model, text: str, speaker: str, language: str = "Auto") -> dict:
    """1 テキストの音声合成を実行"""
    t0 = time.time()
    try:
        wavs, sr = model.generate_custom_voice(
            text=text,
            language=language,
            speaker=speaker,
            instruct="",
            do_sample=True,
            top_k=50,
            top_p=0.9,
            temperature=0.7,
            repetition_penalty=1.05,
        )
        elapsed = round(time.time() - t0, 3)
        wav = wavs[0] if isinstance(wavs, list) else wavs
        duration_sec = round(len(wav) / sr, 2)
        return {
            "elapsed_s": elapsed,
            "duration_sec": duration_sec,
            "sample_rate": sr,
            "samples": len(wav),
            "success": True,
        }
    except Exception as e:
        elapsed = round(time.time() - t0, 3)
        return {
            "elapsed_s": elapsed,
            "duration_sec": 0,
            "success": False,
            "error": str(e),
        }


def save_audio(model, text: str, speaker: str, output_path: Path, language: str = "Auto"):
    """音声生成してファイルに保存"""
    wavs, sr = model.generate_custom_voice(
        text=text,
        language=language,
        speaker=speaker,
        instruct="",
        do_sample=True,
        top_k=50,
        top_p=0.9,
        temperature=0.7,
        repetition_penalty=1.05,
    )
    wav = wavs[0] if isinstance(wavs, list) else wavs
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(output_path), wav, sr)
    return len(wav) / sr


def run_benchmark(model, drive: str, run_number: int, runs: int, speaker: str, output_dir: Path) -> dict:
    """1回分のベンチマークを実行"""
    print(f"\n[{drive}] Run {run_number}/{runs}")
    gpu_before = get_nvidia_smi()
    results = []

    for test in TEST_TEXTS:
        text_id = test["id"]
        label = test["label"]
        text = test["text"]
        char_count = len(text)

        print(f"  [{text_id}] {label} ({char_count}文字)...", end=" ", flush=True)
        result = synthesize(model, text, speaker)
        result["text_id"] = text_id
        result["label"] = label
        result["char_count"] = char_count

        if result["success"]:
            print(f"{result['elapsed_s']}s ({result['duration_sec']}s audio)")
        else:
            print(f"FAIL: {result.get('error', '')}")

        results.append(result)

    gpu_after = get_nvidia_smi()

    return {
        "run": run_number,
        "text_results": results,
        "gpu_before": gpu_before,
        "gpu_after": gpu_after,
        "timestamp": datetime.now().isoformat(),
    }


def main():
    parser = argparse.ArgumentParser(description="Qwen3-TTS Benchmark")
    parser.add_argument("--drive", choices=DRIVES, help="テスト対象ドライブ")
    parser.add_argument("--all-drives", action="store_true", help="全ドライブで実行")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="計測回数")
    parser.add_argument("--speaker", type=str, default=DEFAULT_SPEAKER, help="話者名")
    parser.add_argument("--save-audio", action="store_true", help="音声ファイルを保存")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "qwen3tts-bench"),
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else ["D"])

    print("\n=== qwen3tts-bench: Qwen3-TTS Benchmark ===")
    print(f"Model: {MODEL_ID}")
    print(f"Speaker: {args.speaker}")
    print(f"Drives: {drives} | Runs: {args.runs}")
    print(f"Device: cuda:0 | Dtype: float16\n")

    for drive in drives:
        print(f"\n{'='*50}")
        print(f"=== Drive {drive} ===")
        print(f"{'='*50}")

        # HF cache をドライブ別に設定
        hf_home = f"{drive}:\\hf_cache"
        os.environ["HF_HOME"] = hf_home
        print(f"  HF_HOME = {hf_home}")

        # VRAM クリア
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            torch.cuda.synchronize()

        # モデルロード (cold start)
        model, load_time = load_model()

        # サンプル音声を保存
        if args.save_audio:
            for test in TEST_TEXTS:
                audio_path = output_dir / "audio" / f"{drive}_{test['id']}.wav"
                print(f"  Saving audio: {audio_path}")
                dur = save_audio(model, test["text"], args.speaker, audio_path)
                print(f"    -> {dur:.1f}s audio")

        # ベンチマーク実行
        all_runs = []
        for i in range(1, args.runs + 1):
            result = run_benchmark(model, drive, i, args.runs, args.speaker, output_dir)
            all_runs.append(result)

        # 集計
        # 各テキストの中央値を計算
        text_medians = {}
        for test in TEST_TEXTS:
            tid = test["id"]
            times = sorted([
                r["elapsed_s"]
                for run in all_runs
                for r in run["text_results"]
                if r["text_id"] == tid and r["success"]
            ])
            if times:
                mid = len(times) // 2
                text_medians[tid] = times[mid] if len(times) % 2 else (times[mid - 1] + times[mid]) / 2

        # 全テキスト合計の中央値
        total_times = sorted([
            sum(r["elapsed_s"] for r in run["text_results"] if r["success"])
            for run in all_runs
        ])
        if total_times:
            mid = len(total_times) // 2
            total_median = total_times[mid] if len(total_times) % 2 else (total_times[mid - 1] + total_times[mid]) / 2
        else:
            total_median = None

        # TTFA (最初のテキストの中央値)
        ttfa_median = text_medians.get("S1")

        summary = {
            "experiment": "qwen3tts-bench",
            "drive": drive,
            "model": MODEL_ID,
            "speaker": args.speaker,
            "runs": args.runs,
            "model_load_s": load_time,
            "ttfa_median_s": ttfa_median,
            "total_median_s": total_median,
            "text_medians": text_medians,
            "test_texts": [
                {"id": t["id"], "label": t["label"], "char_count": len(t["text"])}
                for t in TEST_TEXTS
            ],
            "results": all_runs,
            "generated": datetime.now().isoformat(),
        }

        out_file = output_dir / f"tts_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"\n  Model load: {load_time}s")
        print(f"  TTFA median: {ttfa_median}s")
        print(f"  Total median: {total_median}s")
        for tid, med in text_medians.items():
            print(f"    {tid}: {med}s")
        print(f"  Results: {out_file}")

        # モデル解放
        del model
        if torch.cuda.is_available():
            torch.cuda.empty_cache()

    print("\n=== qwen3tts-bench: Complete! ===\n")


if __name__ == "__main__":
    main()
