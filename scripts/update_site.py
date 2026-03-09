#!/usr/bin/env python3
"""
結果 JSON → LP 更新スクリプト

results/ 配下の JSON を読み込み、site/data.json を生成。
LP (index.html) は data.json を fetch して結果テーブルを動的に表示する。

ファイル名規則:
  load_C_qwen3_8b.json   → drive=C, model=qwen3:8b
  codegen_D_qwen3_1.7b.json → drive=D, model=qwen3:1.7b
  load_D.json             → drive=D (旧形式、後方互換)

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
        with open(sysinfo_path, encoding="utf-8-sig") as f:
            data["sysinfo"] = json.load(f)

    # 各実験ディレクトリ
    experiments = [
        ("vibe-local-bench", "load_*.json", "vibe_local_load"),
        ("vibe-local-bench", "codegen_*.json", "vibe_local_codegen"),
        ("disk-speed-bench", "diskspeed_*.json", "disk_speed"),
        ("comfyui-imggen-bench", "imggen_*.json", "comfyui_imggen"),
        ("comfyui-ltx-bench", "comfyui_*.json", "comfyui_ltx"),
        ("qwen3tts-bench", "tts_*.json", "qwen3tts"),
    ]

    for subdir, pattern, base_key in experiments:
        exp_dir = results_dir / subdir
        if not exp_dir.exists():
            continue

        # モデル別にグループ化
        model_groups: dict[str, dict] = {}
        for json_file in sorted(exp_dir.glob(pattern)):
            with open(json_file, encoding="utf-8-sig") as f:
                result = json.load(f)

            drive = result.get("drive", "?")
            model = result.get("model", "unknown")
            model_tag = model.replace(":", "_")

            # 成功した結果がなければスキップ
            successful = [r for r in result.get("results", []) if r.get("success")]
            # disk-speed-bench は success ではなく read_ok/write_ok を使う
            if not successful:
                successful = [r for r in result.get("results", []) if r.get("read_ok") or r.get("write_ok")]
            if not successful and result.get("median_s") is None and result.get("read_median_mbs") is None:
                continue

            if model_tag not in model_groups:
                model_groups[model_tag] = {"model": model, "drives": {}}

            entry = {
                "drive": drive,
                "median_s": result.get("median_s")
                or result.get("ttfa_median_s")
                or result.get("cold_start_median_s")
                or result.get("read_median_mbs"),  # disk-speed uses read MB/s as main metric
                "runs": result.get("runs"),
                "generated": result.get("generated"),
            }

            # Ollama 内部タイミング
            for r in successful:
                internal = r.get("ollama_internal", {})
                if internal.get("runner_started_s"):
                    entry["runner_started_s"] = internal["runner_started_s"]
                    break

            # 実験固有メトリクス
            if "warm_batch_median_s" in result:
                entry["warm_median_s"] = result["warm_batch_median_s"]
            if "tokens_per_sec" in str(result):
                tps_list = [
                    r.get("tokens_per_sec", 0)
                    for r in successful
                    if r.get("tokens_per_sec", 0) > 0
                ]
                if tps_list:
                    entry["avg_tokens_per_sec"] = round(
                        sum(tps_list) / len(tps_list), 2
                    )
            # ディスク速度ベンチ
            if result.get("write_median_mbs") is not None:
                entry["write_mbs"] = result["write_median_mbs"]
            if result.get("read_median_mbs") is not None:
                entry["read_mbs"] = result["read_median_mbs"]
            if result.get("disk_info"):
                entry["disk_info"] = result["disk_info"]

            model_groups[model_tag]["drives"][drive] = entry

        # 実験キーにモデル名を含める（モデルが1つだけなら元のキー名を維持）
        for model_tag, group in model_groups.items():
            if not group["drives"]:
                continue
            # キー名: モデルが複数あれば model_tag 付き
            if len(model_groups) == 1:
                exp_key = base_key
            else:
                exp_key = f"{base_key}_{model_tag}"

            # drive_order を実データから生成
            all_drives = sorted(group["drives"].keys())
            data["experiments"][exp_key] = {
                "drives": group["drives"],
                "drive_order": all_drives,
                "model": group["model"],
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
        model = exp.get("model", "")
        print(f"    {key} ({model}): drives {drives}")
    print(f"\nPush to main to deploy to bench.aicu.jp")


if __name__ == "__main__":
    main()
