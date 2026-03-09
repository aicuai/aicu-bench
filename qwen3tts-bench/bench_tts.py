#!/usr/bin/env python3
"""
Qwen3-TTS ベンチマーク

Ollama 経由で Qwen3-TTS の音声合成パフォーマンスを計測。
Time-to-First-Audio (TTFA) と MP3 バッチ生成速度を測定。

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

OLLAMA_HOST = "http://localhost:11434"
MODEL_NAME = "qwen3-tts"
DRIVES = ["D", "E", "F", "G"]
DEFAULT_RUNS = 3

# テストテキスト (短・中・長 + 青空文庫 + 技術文)
TEST_TEXTS = [
    # 短文
    {"id": "S1", "label": "短文・挨拶", "text": "こんにちは、今日はいい天気ですね。"},
    {"id": "S2", "label": "短文・技術", "text": "ストレージ速度のベンチマークを開始します。"},
    {"id": "S3", "label": "短文・ニュース", "text": "Samsung 9100 PRO が PCIe Gen5 NVMe SSD の新しい基準を打ち立てました。"},
    # 中文
    {
        "id": "M1",
        "label": "中文・AI解説",
        "text": "人工知能の発展により、ローカル環境でも高品質な音声合成が可能になりました。ストレージの速度がモデルのロード時間に大きく影響します。",
    },
    {
        "id": "M2",
        "label": "中文・青空文庫（夏目漱石『吾輩は猫である』）",
        "text": "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
    },
    {
        "id": "M3",
        "label": "中文・青空文庫（宮沢賢治『銀河鉄道の夜』）",
        "text": "カムパネルラが手をあげました。それから四、五人手をあげました。ジョバンニも手をあげようとして、急いでそのままやめました。",
    },
    # 長文
    {
        "id": "L1",
        "label": "長文・技術記事",
        "text": "近年のAI技術の急速な発展に伴い、テキストから音声への変換技術も飛躍的に進歩しています。"
        "特にローカル環境で動作する音声合成モデルは、プライバシーの観点からも注目されており、"
        "ストレージ速度がモデルのロード時間やバッチ処理の効率に直接影響を与えることが予想されます。"
        "本ベンチマークでは、PCIe Gen5 NVMe、SATA SSD、HDDの3種類のストレージで比較検証を行います。",
    },
    {
        "id": "L2",
        "label": "長文・青空文庫（太宰治『走れメロス』）",
        "text": "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。"
        "メロスには政治がわからぬ。メロスは、村の牧人である。笛を吹き、羊と遊んで暮して来た。"
        "けれども邪悪に対しては、人一倍に敏感であった。きょう未明メロスは村を出発し、"
        "野を越え山越え、十里はなれた此のシラクスの市にやって来た。",
    },
    {
        "id": "L3",
        "label": "長文・英語混じり技術文",
        "text": "Samsung 9100 PRO は PCIe Gen5 x4 インターフェースを採用し、シーケンシャルリードで最大14,500メガバイト毎秒を実現します。"
        "これは従来の Gen4 NVMe の約2倍、SATA SSD の約26倍の速度です。"
        "AI ワークロードにおいては、Large Language Model のロード時間が劇的に短縮され、"
        "ComfyUI での Stable Diffusion チェックポイント切り替えも瞬時に完了します。",
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


def clear_ollama_cache():
    """Ollama のモデルキャッシュをクリア"""
    try:
        import urllib.request

        payload = json.dumps({"model": MODEL_NAME, "keep_alive": 0}).encode()
        req = urllib.request.Request(
            f"{OLLAMA_HOST}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass
    time.sleep(2)


def synthesize_speech(text: str, output_path: Path) -> dict:
    """Ollama 経由で TTS を実行"""
    import urllib.request
    import urllib.error

    payload = json.dumps(
        {"model": MODEL_NAME, "prompt": text, "stream": False}
    ).encode()

    req = urllib.request.Request(
        f"{OLLAMA_HOST}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode())
        elapsed = round(time.time() - start, 3)

        # レスポンスからオーディオデータを保存（base64 エンコード想定）
        if "response" in data and data["response"]:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(data["response"])
            file_size = output_path.stat().st_size
        else:
            file_size = 0

        return {
            "elapsed_s": elapsed,
            "file_size_bytes": file_size,
            "success": True,
        }
    except Exception as e:
        elapsed = round(time.time() - start, 3)
        return {
            "elapsed_s": elapsed,
            "file_size_bytes": 0,
            "success": False,
            "error": str(e),
        }


def run_benchmark(
    drive: str, run_number: int, runs: int, output_dir: Path
) -> dict:
    """1回分のベンチマークを実行"""
    print(f"[{drive}] Run {run_number}/{runs}")

    # キャッシュクリア（コールドスタート計測）
    print("  Clearing cache...")
    clear_ollama_cache()

    gpu_before = get_nvidia_smi()
    batch_start = time.time()
    text_results = []
    first_audio_time = None

    for idx, test in enumerate(TEST_TEXTS):
        text_id = test["id"]
        label = test["label"]
        text = test["text"]
        char_count = len(text)

        audio_path = output_dir / "audio" / f"{drive}_run{run_number}_{text_id}.txt"
        print(f"  [{text_id}] {label} ({char_count}文字)...", end=" ")

        result = synthesize_speech(text, audio_path)

        if idx == 0 and result["success"]:
            first_audio_time = result["elapsed_s"]

        text_results.append(
            {
                "text_id": text_id,
                "label": label,
                "char_count": char_count,
                **result,
            }
        )

        status = f"{result['elapsed_s']}s" if result["success"] else "FAIL"
        print(status)

    batch_total = round(time.time() - batch_start, 3)
    gpu_after = get_nvidia_smi()

    return {
        "experiment": "qwen3tts-bench",
        "drive": drive,
        "run": run_number,
        "first_audio_s": first_audio_time,
        "batch_total_s": batch_total,
        "text_results": text_results,
        "gpu_before": gpu_before,
        "gpu_after": gpu_after,
        "timestamp": datetime.now().isoformat(),
    }


def main():
    parser = argparse.ArgumentParser(description="Qwen3-TTS Benchmark")
    parser.add_argument("--drive", choices=DRIVES, help="テスト対象ドライブ")
    parser.add_argument("--all-drives", action="store_true", help="全ドライブで実行")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="計測回数")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "qwen3tts-bench"),
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else DRIVES)

    print("\n=== qwen3tts-bench: Qwen3-TTS Benchmark ===")
    print(f"Drives: {drives} | Runs: {args.runs}\n")

    for drive in drives:
        print(f"\n--- Drive {drive} ---")
        results = []

        for i in range(1, args.runs + 1):
            result = run_benchmark(drive, i, args.runs, output_dir)
            results.append(result)

        # TTFA 中央値
        ttfa_times = sorted(
            [r["first_audio_s"] for r in results if r["first_audio_s"] is not None]
        )
        if ttfa_times:
            mid = len(ttfa_times) // 2
            ttfa_median = (
                (ttfa_times[mid - 1] + ttfa_times[mid]) / 2
                if len(ttfa_times) % 2 == 0
                else ttfa_times[mid]
            )
        else:
            ttfa_median = None

        summary = {
            "experiment": "qwen3tts-bench",
            "drive": drive,
            "model": MODEL_NAME,
            "runs": args.runs,
            "ttfa_median_s": ttfa_median,
            "test_texts": [
                {"id": t["id"], "label": t["label"], "char_count": len(t["text"])}
                for t in TEST_TEXTS
            ],
            "results": results,
            "generated": datetime.now().isoformat(),
        }

        out_file = output_dir / f"tts_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"TTFA Median: {ttfa_median}s")
        print(f"Results saved: {out_file}")

    print("\n=== qwen3tts-bench: Complete! ===\n")


if __name__ == "__main__":
    main()
