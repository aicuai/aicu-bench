#!/usr/bin/env python3
"""
ComfyUI LTX-Video 2.3 動画生成ベンチマーク

ComfyUI HTTP API 経由で LTX-Video 2.3 の動画生成パイプラインを実行し、
モデルロード～動画出力までのトータル時間を計測。
ストレージ速度がモデルロード（8-12GB）に与える影響を定量化する。

前提:
  - ComfyUI が起動済み (http://127.0.0.1:8188)
  - ComfyUI-LTXVideo カスタムノードがインストール済み
  - LTX-Video モデルが各ドライブの ComfyUI models ディレクトリに配置済み

Usage:
    python bench_comfyui.py --drive D --runs 3
    python bench_comfyui.py --all-drives
"""

import argparse
import json
import os
import subprocess
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

COMFYUI_HOST = "http://127.0.0.1:8188"
DRIVES = ["D", "E", "F", "G"]
DEFAULT_RUNS = 3

# LTX-Video 2.3 ワークフロー
# LTXVLoader → T5 TextEncode → LTXVConditioning → LTXVScheduler → KSampler → LTXVDecode → SaveAnimatedWEBP
#
# ノード構成:
#   1: LTXVLoader         - LTX-Video チェックポイント読み込み
#   2: CLIPLoader         - T5 テキストエンコーダー読み込み
#   3: CLIPTextEncode     - ポジティブプロンプト
#   4: CLIPTextEncode     - ネガティブプロンプト
#   5: EmptyLTXVLatentVideo - 空のビデオ潜在空間
#   6: LTXVConditioning   - コンディショニング
#   7: LTXVScheduler      - スケジューラー
#   8: KSampler           - サンプリング
#   9: LTXVDecode         - デコード（潜在空間→ビデオ）
#  10: VHS_VideoCombine   - ビデオ保存 (or SaveAnimatedWEBP)
WORKFLOW_LTX = {
    "1": {
        "class_type": "CheckpointLoaderSimple",
        "inputs": {
            "ckpt_name": "ltx-video-2b-v0.9.5.safetensors",
        },
    },
    "3": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "A cat walking gracefully through a sunlit garden, cinematic quality, smooth motion, 24fps",
            "clip": ["1", 1],
        },
    },
    "4": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "blurry, low quality, distorted, watermark",
            "clip": ["1", 1],
        },
    },
    "5": {
        "class_type": "EmptyLatentImage",
        "inputs": {
            "width": 512,
            "height": 320,
            "batch_size": 9,  # 9フレーム
        },
    },
    "8": {
        "class_type": "KSampler",
        "inputs": {
            "model": ["1", 0],
            "positive": ["3", 0],
            "negative": ["4", 0],
            "latent_image": ["5", 0],
            "seed": 42,
            "steps": 20,
            "cfg": 7.0,
            "sampler_name": "euler",
            "scheduler": "normal",
            "denoise": 1.0,
        },
    },
    "9": {
        "class_type": "VAEDecode",
        "inputs": {
            "samples": ["8", 0],
            "vae": ["1", 2],
        },
    },
    "10": {
        "class_type": "SaveImage",
        "inputs": {
            "images": ["9", 0],
            "filename_prefix": "bench_ltxvideo",
        },
    },
}

# LTX-Video 専用ノードが利用可能な場合のワークフロー
# (ComfyUI-LTXVideo がインストール済みの場合)
WORKFLOW_LTX_NATIVE = {
    "1": {
        "class_type": "LTXVLoader",
        "inputs": {
            "ckpt_name": "ltx-video-2b-v0.9.5.safetensors",
        },
    },
    "2": {
        "class_type": "CLIPLoader",
        "inputs": {
            "clip_name": "t5xxl_fp16.safetensors",
            "type": "ltxv",
        },
    },
    "3": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "A cat walking gracefully through a sunlit garden, cinematic quality, smooth motion, 24fps",
            "clip": ["2", 0],
        },
    },
    "4": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "blurry, low quality, distorted, watermark",
            "clip": ["2", 0],
        },
    },
    "5": {
        "class_type": "EmptyLTXVLatentVideo",
        "inputs": {
            "width": 512,
            "height": 320,
            "length": 41,   # 41フレーム (~1.7秒 @24fps)
        },
    },
    "6": {
        "class_type": "LTXVConditioning",
        "inputs": {
            "positive": ["3", 0],
            "negative": ["4", 0],
            "frame_rate": 24,
        },
    },
    "7": {
        "class_type": "LTXVScheduler",
        "inputs": {
            "model": ["1", 0],
            "steps": 20,
            "max_shift": 2.05,
            "base_shift": 0.95,
        },
    },
    "8": {
        "class_type": "SamplerCustom",
        "inputs": {
            "model": ["1", 0],
            "positive": ["6", 0],
            "negative": ["6", 1],
            "latent_image": ["5", 0],
            "noise_seed": 42,
            "cfg": 1.0,
            "sampler": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
            "sigmas": ["7", 0],
        },
    },
    "9": {
        "class_type": "LTXVDecode",
        "inputs": {
            "samples": ["8", 0],
            "vae": ["1", 1],
        },
    },
    "10": {
        "class_type": "SaveAnimatedWEBP",
        "inputs": {
            "images": ["9", 0],
            "filename_prefix": "bench_ltxvideo",
            "fps": 24,
            "lossless": False,
            "quality": 85,
            "method": "default",
        },
    },
}


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


def get_comfyui_system_stats() -> dict:
    """ComfyUI /system_stats からシステム情報を取得"""
    try:
        req = urllib.request.Request(f"{COMFYUI_HOST}/system_stats")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {}


def check_ltxv_nodes() -> bool:
    """LTX-Video 専用ノードが利用可能か確認"""
    try:
        req = urllib.request.Request(f"{COMFYUI_HOST}/object_info")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        return "LTXVLoader" in data
    except Exception:
        return False


def get_node_list() -> dict:
    """利用可能なノード一覧を取得（再現性のため）"""
    try:
        req = urllib.request.Request(f"{COMFYUI_HOST}/object_info")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        # LTX 関連ノードを抽出
        ltx_nodes = [k for k in data.keys() if "LTX" in k.upper()]
        return {
            "total_nodes": len(data),
            "ltx_nodes": ltx_nodes,
        }
    except Exception:
        return {}


def free_comfyui_memory():
    """ComfyUI の VRAM キャッシュを解放（モデルアンロード）"""
    try:
        req = urllib.request.Request(
            f"{COMFYUI_HOST}/free",
            data=json.dumps({"unload_models": True, "free_memory": True}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass
    time.sleep(3)


def queue_prompt(workflow: dict) -> str:
    """ワークフローをキューに投入し prompt_id を返す"""
    payload = json.dumps({"prompt": workflow}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_HOST}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read().decode())
    return result["prompt_id"]


def wait_for_completion(prompt_id: str, timeout: int = 600) -> dict:
    """prompt_id の完了を待ち、history を返す"""
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(f"{COMFYUI_HOST}/history/{prompt_id}")
            with urllib.request.urlopen(req, timeout=10) as resp:
                history = json.loads(resp.read().decode())
            if prompt_id in history:
                entry = history[prompt_id]
                status = entry.get("status", {})
                if status.get("completed", False) or entry.get("outputs"):
                    return entry
                if status.get("status_str") == "error":
                    return {"error": True, "details": entry}
        except Exception:
            pass
        time.sleep(1)
    return {"error": True, "timeout": True}


def run_benchmark(drive: str, run_number: int, runs: int, workflow: dict, workflow_type: str, timeout: int = 600) -> dict:
    """1回分のベンチマークを実行（コールドスタート）"""
    print(f"[{drive}] Run {run_number}/{runs} - Freeing memory...")
    free_comfyui_memory()

    gpu_before = get_nvidia_smi()
    print(f"[{drive}] Run {run_number}/{runs} - Queuing {workflow_type} workflow...")

    start_time = time.time()
    try:
        prompt_id = queue_prompt(workflow)
        result = wait_for_completion(prompt_id, timeout=timeout)
        elapsed = round(time.time() - start_time, 3)
        success = "error" not in result
    except Exception as e:
        elapsed = round(time.time() - start_time, 3)
        success = False
        print(f"  ERROR: {e}")

    gpu_after = get_nvidia_smi()

    entry = {
        "experiment": "comfyui-ltx-bench",
        "test": "video_generation",
        "workflow_type": workflow_type,
        "drive": drive,
        "run": run_number,
        "total_time_s": elapsed,
        "success": success,
        "gpu_before": gpu_before,
        "gpu_after": gpu_after,
        "timestamp": datetime.now().isoformat(),
    }

    status = "OK" if success else "FAIL"
    print(f"  Total time: {elapsed}s ({status})")
    return entry


def calc_median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return None
    mid = n // 2
    return (s[mid - 1] + s[mid]) / 2 if n % 2 == 0 else s[mid]


def main():
    global COMFYUI_HOST
    parser = argparse.ArgumentParser(description="ComfyUI Video Generation Benchmark")
    parser.add_argument("--drive", choices=DRIVES, help="テスト対象ドライブ")
    parser.add_argument("--all-drives", action="store_true", help="全ドライブで実行")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="計測回数")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "comfyui-video-bench"),
    )
    parser.add_argument("--host", type=str, default=COMFYUI_HOST, help="ComfyUI ホスト")
    parser.add_argument("--force-fallback", action="store_true", help="LTXVノード未使用で汎用ワークフロー強制")
    parser.add_argument("--workflow", type=str, default=None,
                        help="外部ワークフロー JSON パス (workflows/wan2_2_14B_t2v_api.json 等)")
    parser.add_argument("--timeout", type=int, default=600,
                        help="1回あたりのタイムアウト秒数 (デフォルト: 600, R4推奨: 60)")
    args = parser.parse_args()

    COMFYUI_HOST = args.host

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else DRIVES)

    # ComfyUI 環境情報
    sys_stats = get_comfyui_system_stats()
    node_info = get_node_list()

    comfyui_info = {
        "system_stats": sys_stats,
        "node_info": node_info,
    }

    info_file = output_dir / "comfyui_info.json"
    with open(info_file, "w", encoding="utf-8") as f:
        json.dump(comfyui_info, f, indent=2, ensure_ascii=False)
    print(f"ComfyUI info saved: {info_file}")

    # ワークフロー選択
    if args.workflow:
        wf_path = Path(args.workflow)
        if wf_path.exists():
            with open(wf_path, encoding="utf-8") as f:
                workflow = json.load(f)
            workflow_type = wf_path.stem
            print(f"\n=== comfyui-video-bench: {workflow_type} ===")
            print(f"Workflow: {args.workflow}")
        else:
            print(f"ERROR: Workflow not found: {args.workflow}")
            return
    else:
        has_ltxv = check_ltxv_nodes() and not args.force_fallback
        if has_ltxv:
            workflow = WORKFLOW_LTX_NATIVE
            workflow_type = "ltxv_native"
            print("\n=== comfyui-video-bench: LTX-Video 2.3 (native nodes) ===")
        else:
            workflow = WORKFLOW_LTX
            workflow_type = "generic_fallback"
            print("\n=== comfyui-video-bench: LTX-Video (generic fallback) ===")

    print(f"Drives: {drives} | Runs: {args.runs}\n")

    for drive in drives:
        print(f"\n--- Drive {drive} ---")
        results = []

        for i in range(1, args.runs + 1):
            result = run_benchmark(drive, i, args.runs, workflow, workflow_type, timeout=args.timeout)
            results.append(result)

        # 中央値
        times = sorted([r["total_time_s"] for r in results if r["success"]])
        median_val = calc_median(times) if times else None

        summary = {
            "experiment": "comfyui-video-bench",
            "test": workflow_type,
            "drive": drive,
            "runs": args.runs,
            "median_s": median_val,
            "workflow_file": args.workflow,
            "comfyui_info": comfyui_info,
            "results": results,
            "generated": datetime.now().isoformat(),
        }

        out_file = output_dir / f"video_{workflow_type}_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"Median: {median_val}s")
        print(f"Results saved: {out_file}")

    print(f"\n=== comfyui-video-bench ({workflow_type}): Complete! ===\n")


if __name__ == "__main__":
    main()
