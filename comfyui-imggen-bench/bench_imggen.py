#!/usr/bin/env python3
"""
ComfyUI z-image-turbo 画像生成ベンチマーク

ComfyUI HTTP API 経由で z-image-turbo による画像生成時間を計測。
モデルロード（ストレージ依存）と推論（GPU 依存）を分離して定量化。

ワークフロー構成:
  UNETLoader (z_image_turbo_bf16) → ModelSamplingAuraFlow
  CLIPLoader (qwen_3_4b, lumina2) → CLIPTextEncode
  VAELoader (ae.safetensors)
  EmptySD3LatentImage → KSampler (4 steps, res_multistep) → VAEDecode → SaveImage

Usage:
    python bench_imggen.py --drive D --runs 3
    python bench_imggen.py --all-drives
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

# ワークフロー JSON を外部ファイルから読み込み (workflows/z_image_turbo.json)
# フォールバック用にインライン定義も持つ
WORKFLOW_INLINE = {
    "1": {
        "class_type": "UNETLoader",
        "inputs": {
            "unet_name": "z_image_turbo_bf16.safetensors",
            "weight_dtype": "default",
        },
        "_meta": {"title": "UNET Loader (Z-Image-Turbo)"},
    },
    "2": {
        "class_type": "CLIPLoader",
        "inputs": {
            "clip_name": "qwen_3_4b.safetensors",
            "type": "lumina2",
            "device": "default",
        },
        "_meta": {"title": "CLIP Loader (Qwen)"},
    },
    "3": {
        "class_type": "VAELoader",
        "inputs": {"vae_name": "ae.safetensors"},
        "_meta": {"title": "VAE Loader"},
    },
    "4": {
        "class_type": "ModelSamplingAuraFlow",
        "inputs": {"shift": 3, "model": ["1", 0]},
        "_meta": {"title": "Model Sampling AuraFlow"},
    },
    "5": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "", "clip": ["2", 0]},
        "_meta": {"title": "Positive Prompt"},
    },
    "6": {
        "class_type": "ConditioningZeroOut",
        "inputs": {"conditioning": ["5", 0]},
        "_meta": {"title": "Negative (Zero Out)"},
    },
    "7": {
        "class_type": "EmptySD3LatentImage",
        "inputs": {"width": 832, "height": 1216, "batch_size": 1},
        "_meta": {"title": "Empty Latent (SD3)"},
    },
    "8": {
        "class_type": "KSampler",
        "inputs": {
            "seed": 42,
            "steps": 4,
            "cfg": 1,
            "sampler_name": "res_multistep",
            "scheduler": "simple",
            "denoise": 1,
            "model": ["4", 0],
            "positive": ["5", 0],
            "negative": ["6", 0],
            "latent_image": ["7", 0],
        },
        "_meta": {"title": "KSampler"},
    },
    "9": {
        "class_type": "VAEDecode",
        "inputs": {"samples": ["8", 0], "vae": ["3", 0]},
        "_meta": {"title": "VAE Decode"},
    },
    "10": {
        "class_type": "SaveImage",
        "inputs": {"filename_prefix": "bench_imggen", "images": ["9", 0]},
        "_meta": {"title": "Save Image"},
    },
}

TEST_PROMPTS = [
    {
        "id": "ssd_lightning",
        "prompt": "A high-speed SSD hard drive glowing with electric energy, surrounded by dramatic lightning bolts, serving as the AI core, product photography, cinematic lighting, ultra detailed 8k",
    },
    {
        "id": "landscape",
        "prompt": "A professional photograph of a mountain landscape at sunset, golden hour lighting, dramatic clouds, 8k ultra detailed",
    },
    {
        "id": "portrait",
        "prompt": "A portrait of a young woman in a cafe, natural lighting, bokeh background, professional photography",
    },
    {
        "id": "product",
        "prompt": "A Samsung NVMe SSD product shot on white background, studio lighting, commercial photography, ultra detailed",
    },
    {
        "id": "abstract",
        "prompt": "Abstract digital art, flowing neon colors, cyber aesthetic, high resolution, 4k",
    },
]


def get_nvidia_smi() -> dict:
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
    try:
        req = urllib.request.Request(f"{COMFYUI_HOST}/system_stats")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {}


def free_comfyui_memory():
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
    time.sleep(2)


def queue_prompt(workflow: dict) -> str:
    payload = json.dumps({"prompt": workflow}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_HOST}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read().decode())
    return result.get("prompt_id", "")


def wait_for_completion(prompt_id: str, timeout: int = 300) -> dict:
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(f"{COMFYUI_HOST}/history/{prompt_id}")
            with urllib.request.urlopen(req, timeout=10) as resp:
                history = json.loads(resp.read().decode())
            if prompt_id in history:
                entry = history[prompt_id]
                outputs = entry.get("outputs", {})
                # 画像出力があれば完了
                for node_id, node_output in outputs.items():
                    if "images" in node_output:
                        return {"success": True, "outputs": outputs}
                status = entry.get("status", {})
                if status.get("status_str") == "error":
                    return {"success": False, "error": "ComfyUI execution error"}
        except Exception:
            pass
        time.sleep(1)
    return {"success": False, "error": "timeout"}


def load_workflow() -> dict:
    """外部 JSON があればそれを使い、なければインライン定義"""
    wf_path = Path(__file__).parent.parent / "workflows" / "z_image_turbo.json"
    if wf_path.exists():
        with open(wf_path, encoding="utf-8") as f:
            return json.load(f)
    return json.loads(json.dumps(WORKFLOW_INLINE))


def make_workflow(prompt_text: str, seed: int = 42) -> dict:
    wf = load_workflow()
    # プロンプト注入 (_meta.title に "Positive" を含むノード、または node "5")
    for node_id, node in wf.items():
        ct = node.get("class_type", "")
        meta_title = node.get("_meta", {}).get("title", "").lower()
        inputs = node.get("inputs", {})
        if ct == "CLIPTextEncode" and ("positive" in meta_title or node_id == "5"):
            inputs["text"] = prompt_text
        if ct in ("KSampler", "SamplerCustomAdvanced"):
            if "seed" in inputs:
                inputs["seed"] = seed
            if "noise_seed" in inputs:
                inputs["noise_seed"] = seed
        if ct == "SaveImage":
            inputs["filename_prefix"] = "bench_imggen"
    return wf


def run_single(prompt_id_label: str, prompt_text: str, is_cold: bool, seed: int = 42) -> dict:
    if is_cold:
        free_comfyui_memory()

    gpu_before = get_nvidia_smi()
    wf = make_workflow(prompt_text, seed)

    start = time.time()
    try:
        pid = queue_prompt(wf)
        if not pid:
            raise RuntimeError("Failed to queue prompt")
        result = wait_for_completion(pid, timeout=300)
        elapsed = round(time.time() - start, 3)
        success = result.get("success", False)
    except Exception as e:
        elapsed = round(time.time() - start, 3)
        success = False
        print(f"    ERROR: {e}")

    gpu_after = get_nvidia_smi()

    return {
        "prompt_id": prompt_id_label,
        "cold_start": is_cold,
        "elapsed_s": elapsed,
        "success": success,
        "gpu_before": gpu_before,
        "gpu_after": gpu_after,
    }


def run_benchmark(drive: str, run_number: int, runs: int) -> dict:
    print(f"\n[{drive}] Run {run_number}/{runs}")
    results = []

    # コールドスタート（1枚目 = モデルロード込み）
    first = TEST_PROMPTS[0]
    print(f"  [cold] {first['id']}...", end=" ")
    r = run_single(first["id"], first["prompt"], is_cold=True)
    print(f"{r['elapsed_s']}s ({'OK' if r['success'] else 'FAIL'})")
    cold_start_time = r["elapsed_s"] if r["success"] else None
    results.append(r)

    # ウォームスタート（残り）
    for tp in TEST_PROMPTS[1:]:
        print(f"  [warm] {tp['id']}...", end=" ")
        r = run_single(tp["id"], tp["prompt"], is_cold=False)
        print(f"{r['elapsed_s']}s ({'OK' if r['success'] else 'FAIL'})")
        results.append(r)

    warm_results = [r for r in results[1:] if r["success"]]
    warm_total = round(sum(r["elapsed_s"] for r in warm_results), 3) if warm_results else None

    return {
        "experiment": "comfyui-imggen-bench",
        "test": "z_image_turbo",
        "drive": drive,
        "run": run_number,
        "cold_start_s": cold_start_time,
        "warm_batch_s": warm_total,
        "warm_count": len(warm_results),
        "image_results": results,
        "timestamp": datetime.now().isoformat(),
    }


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return None
    mid = n // 2
    return (s[mid - 1] + s[mid]) / 2 if n % 2 == 0 else s[mid]


def main():
    global COMFYUI_HOST
    parser = argparse.ArgumentParser(description="ComfyUI Image Generation Benchmark")
    parser.add_argument("--drive", choices=DRIVES, help="テスト対象ドライブ")
    parser.add_argument("--all-drives", action="store_true", help="全ドライブで実行")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="計測回数")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "comfyui-imggen-bench"),
    )
    parser.add_argument("--host", type=str, default=COMFYUI_HOST, help="ComfyUI ホスト")
    parser.add_argument("--workflow", type=str, default=None,
                        help="外部ワークフロー JSON パス (workflows/sdxl.json 等)")
    args = parser.parse_args()

    COMFYUI_HOST = args.host

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else DRIVES)

    # 外部ワークフローが指定された場合はそれを使用
    external_workflow = None
    workflow_name = "z_image_turbo"
    if args.workflow:
        wf_path = Path(args.workflow)
        if wf_path.exists():
            with open(wf_path, encoding="utf-8") as f:
                external_workflow = json.load(f)
            workflow_name = wf_path.stem
            print(f"\n=== comfyui-imggen-bench: {workflow_name} Benchmark ===")
            print(f"Workflow: {args.workflow}")
        else:
            print(f"WARNING: Workflow not found: {args.workflow}, using default")

    if not external_workflow:
        print("\n=== comfyui-imggen-bench: z-image-turbo Benchmark ===")
        print(f"Model: UNETLoader(z_image_turbo_bf16) + CLIPLoader(qwen_3_4b) + VAELoader(ae)")
        print(f"Sampler: res_multistep, 4 steps, cfg=1")
    print(f"Drives: {drives} | Runs: {args.runs}")

    sys_stats = get_comfyui_system_stats()
    if sys_stats:
        info_file = output_dir / "comfyui_info.json"
        with open(info_file, "w", encoding="utf-8") as f:
            json.dump(sys_stats, f, indent=2, ensure_ascii=False)
        print(f"ComfyUI info saved: {info_file}")

    for drive in drives:
        print(f"\n{'='*40}")
        print(f"  Drive {drive}")
        print(f"{'='*40}")

        if external_workflow:
            # 外部ワークフローモード: cold/warm を各 runs 回計測
            all_runs = []
            for i in range(1, args.runs + 1):
                print(f"\n[{drive}] Run {i}/{args.runs}")

                # コールドスタート
                print(f"  [cold] {workflow_name}...", end=" ")
                free_comfyui_memory()
                gpu_before = get_nvidia_smi()
                start = time.time()
                try:
                    pid = queue_prompt(external_workflow)
                    result = wait_for_completion(pid, timeout=600)
                    elapsed = round(time.time() - start, 3)
                    success = result.get("success", False) if isinstance(result, dict) else bool(result)
                except Exception as e:
                    elapsed = round(time.time() - start, 3)
                    success = False
                    print(f"ERROR: {e}")
                gpu_after = get_nvidia_smi()
                print(f"{elapsed}s ({'OK' if success else 'FAIL'})")
                cold_time = elapsed if success else None

                # ウォームスタート
                print(f"  [warm] {workflow_name}...", end=" ")
                gpu_before_w = get_nvidia_smi()
                start = time.time()
                try:
                    pid = queue_prompt(external_workflow)
                    result = wait_for_completion(pid, timeout=600)
                    elapsed_w = round(time.time() - start, 3)
                    success_w = result.get("success", False) if isinstance(result, dict) else bool(result)
                except Exception as e:
                    elapsed_w = round(time.time() - start, 3)
                    success_w = False
                gpu_after_w = get_nvidia_smi()
                print(f"{elapsed_w}s ({'OK' if success_w else 'FAIL'})")
                warm_time = elapsed_w if success_w else None

                all_runs.append({
                    "run": i,
                    "cold_start_s": cold_time,
                    "warm_start_s": warm_time,
                    "gpu_before": gpu_before,
                    "gpu_after_cold": gpu_after,
                    "gpu_after_warm": gpu_after_w,
                    "timestamp": datetime.now().isoformat(),
                })

            cold_median = median([r["cold_start_s"] for r in all_runs if r["cold_start_s"] is not None])
            warm_median = median([r["warm_start_s"] for r in all_runs if r["warm_start_s"] is not None])

            summary = {
                "experiment": "comfyui-imggen-bench",
                "test": workflow_name,
                "drive": drive,
                "runs": args.runs,
                "cold_start_median_s": cold_median,
                "warm_start_median_s": warm_median,
                "workflow_file": str(args.workflow),
                "comfyui_info": sys_stats,
                "results": all_runs,
                "generated": datetime.now().isoformat(),
            }
        else:
            # デフォルトモード: z-image-turbo (複数プロンプト)
            all_runs = []
            for i in range(1, args.runs + 1):
                result = run_benchmark(drive, i, args.runs)
                all_runs.append(result)

            cold_median = median([r["cold_start_s"] for r in all_runs if r["cold_start_s"] is not None])
            warm_median = median([r["warm_batch_s"] for r in all_runs if r["warm_batch_s"] is not None])

            summary = {
                "experiment": "comfyui-imggen-bench",
                "test": "z_image_turbo",
                "drive": drive,
                "runs": args.runs,
                "cold_start_median_s": cold_median,
                "warm_batch_median_s": warm_median,
                "model": {
                    "unet": "z_image_turbo_bf16.safetensors",
                    "clip": "qwen_3_4b.safetensors",
                    "vae": "ae.safetensors",
                    "sampler": "res_multistep",
                    "steps": 4,
                    "cfg": 1,
                    "resolution": "832x1216",
                },
                "prompts": [{"id": p["id"], "prompt": p["prompt"]} for p in TEST_PROMPTS],
                "comfyui_info": sys_stats,
                "results": all_runs,
                "generated": datetime.now().isoformat(),
            }

        out_file = output_dir / f"imggen_{workflow_name}_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"\n  Cold start median: {cold_median}s")
        print(f"  Warm start median: {warm_median}s")
        print(f"  Results saved: {out_file}")

    print("\n=== comfyui-imggen-bench: Complete! ===\n")


if __name__ == "__main__":
    main()
