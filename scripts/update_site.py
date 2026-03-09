#!/usr/bin/env python3
"""
結果 JSON → LP 更新スクリプト

results/ 配下の JSON を読み込み、site/data.json を生成。
LP (index.html) は data.json を fetch して結果テーブルを動的に表示する。

Usage:
    python scripts/update_site.py
    python scripts/update_site.py --results-dir ./results --output ./site/data.json
"""

import argparse
import json
import os
from datetime import datetime
from pathlib import Path


def load_results(results_dir: Path) -> dict:
    """results/ 配下の全 JSON を読み込んで統合"""
    data = {
        "sysinfo": None,
        "experiments": {},
        "updated": datetime.now().isoformat(),
    }

    # sysinfo.json
    sysinfo_path = results_dir / "sysinfo.json"
    if sysinfo_path.exists():
        with open(sysinfo_path, encoding="utf-8") as f:
            data["sysinfo"] = json.load(f)

    # 各実験ディレクトリ
    experiments = [
        ("vibe-local-bench", "load_*.json", "vibe_local_load"),
        ("vibe-local-bench", "codegen_*.json", "vibe_local_codegen"),
        ("comfyui-imggen-bench", "imggen_*.json", "comfyui_imggen"),
        ("comfyui-ltx-bench", "comfyui_*.json", "comfyui_ltx"),
        ("qwen3tts-bench", "tts_*.json", "qwen3tts"),
    ]

    for subdir, pattern, key in experiments:
        exp_dir = results_dir / subdir
        if not exp_dir.exists():
            continue

        drive_results = {}
        for json_file in sorted(exp_dir.glob(pattern)):
            with open(json_file, encoding="utf-8") as f:
                result = json.load(f)
            drive = result.get("drive", json_file.stem.split("_")[-1])
            drive_results[drive] = {
                "drive": drive,
                "median_s": result.get("median_s")
                or result.get("ttfa_median_s")
                or result.get("cold_start_median_s"),
                "runs": result.get("runs"),
                "generated": result.get("generated"),
            }

            # 実験固有メトリクス
            if "warm_batch_median_s" in result:
                drive_results[drive]["warm_median_s"] = result["warm_batch_median_s"]
            if "tokens_per_sec" in str(result):
                # codegen の場合、平均 tokens/sec
                tps_list = [
                    r.get("tokens_per_sec", 0)
                    for r in result.get("results", [])
                    if r.get("success")
                ]
                if tps_list:
                    drive_results[drive]["avg_tokens_per_sec"] = round(
                        sum(tps_list) / len(tps_list), 2
                    )

        if drive_results:
            data["experiments"][key] = {
                "drives": drive_results,
                "drive_order": ["D", "E", "F", "G"],
            }

    return data


def main():
    parser = argparse.ArgumentParser(description="Update site data from benchmark results")
    parser.add_argument(
        "--results-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results"),
    )
    parser.add_argument(
        "--output",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "site", "data.json"),
    )
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output)

    if not results_dir.exists():
        print(f"No results directory: {results_dir}")
        print("Run benchmarks first, then re-run this script.")
        return

    data = load_results(results_dir)

    exp_count = len(data["experiments"])
    if exp_count == 0:
        print("No experiment results found.")
        return

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    print(f"Site data updated: {output_path}")
    print(f"  Experiments: {exp_count}")
    for key, exp in data["experiments"].items():
        drives = list(exp["drives"].keys())
        print(f"    {key}: drives {drives}")
    print(f"\nPush to main to deploy to bench.aicu.jp")


if __name__ == "__main__":
    main()
