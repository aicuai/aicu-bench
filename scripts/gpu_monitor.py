#!/usr/bin/env python3
"""
GPU/CPU リアルタイムモニター

nvidia-smi + psutil で VRAM, GPU温度, GPU電力, CPU使用率, CPU温度を
定期記録。ベンチマーク実行中にバックグラウンドで動かして時系列データを取得。

Usage:
    python scripts/gpu_monitor.py --output results/monitor_R3.csv --interval 5
    python scripts/gpu_monitor.py --output results/monitor_R3.csv --interval 5 --duration 3600
"""

import argparse
import csv
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False


def get_gpu_stats() -> dict:
    """nvidia-smi から GPU 情報を取得"""
    try:
        result = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=gpu_name,memory.used,memory.total,memory.free,temperature.gpu,power.draw,utilization.gpu,clocks.sm,pstate",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            return {
                "gpu_name": parts[0],
                "vram_used_mb": int(parts[1]),
                "vram_total_mb": int(parts[2]),
                "vram_free_mb": int(parts[3]),
                "gpu_temp_c": int(parts[4]),
                "gpu_power_w": float(parts[5]),
                "gpu_util_pct": int(parts[6]),
                "gpu_clock_mhz": int(parts[7]),
                "gpu_pstate": parts[8],
            }
    except Exception:
        pass
    return {}


def get_cpu_stats() -> dict:
    """CPU 使用率と温度を取得"""
    stats = {}
    if HAS_PSUTIL:
        stats["cpu_pct"] = psutil.cpu_percent(interval=0)
        stats["ram_used_gb"] = round(psutil.virtual_memory().used / (1024**3), 1)
        stats["ram_total_gb"] = round(psutil.virtual_memory().total / (1024**3), 1)
        # CPU 温度 (Windows では利用できない場合が多い)
        try:
            temps = psutil.sensors_temperatures()
            if temps:
                for name, entries in temps.items():
                    if entries:
                        stats["cpu_temp_c"] = entries[0].current
                        break
        except Exception:
            pass
    return stats


def main():
    parser = argparse.ArgumentParser(description="GPU/CPU Monitor")
    parser.add_argument("--output", type=str, default="results/gpu_monitor.csv")
    parser.add_argument("--interval", type=int, default=5, help="Sampling interval (seconds)")
    parser.add_argument("--duration", type=int, default=0, help="Max duration (0=unlimited)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "timestamp", "elapsed_s",
        "vram_used_mb", "vram_total_mb", "vram_free_mb",
        "gpu_temp_c", "gpu_power_w", "gpu_util_pct", "gpu_clock_mhz", "gpu_pstate",
        "cpu_pct", "ram_used_gb", "ram_total_gb", "cpu_temp_c",
    ]

    file_exists = output.exists()
    f = open(output, "a", newline="", encoding="utf-8")
    writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
    if not file_exists:
        writer.writeheader()

    start = time.time()
    print(f"GPU/CPU Monitor started. Output: {output} (interval={args.interval}s)")
    if not HAS_PSUTIL:
        print("  Warning: psutil not installed. CPU stats unavailable. Install: pip install psutil")

    try:
        while True:
            elapsed = round(time.time() - start, 1)
            if args.duration > 0 and elapsed > args.duration:
                break

            gpu = get_gpu_stats()
            cpu = get_cpu_stats()

            row = {
                "timestamp": datetime.now().isoformat(),
                "elapsed_s": elapsed,
                **gpu, **cpu,
            }
            writer.writerow(row)
            f.flush()

            if not args.quiet:
                vram = f"VRAM {gpu.get('vram_used_mb', '?')}/{gpu.get('vram_total_mb', '?')}MB"
                temp = f"GPU {gpu.get('gpu_temp_c', '?')}°C"
                power = f"{gpu.get('gpu_power_w', '?')}W"
                util = f"GPU {gpu.get('gpu_util_pct', '?')}%"
                cpu_info = f"CPU {cpu.get('cpu_pct', '?')}%"
                ram = f"RAM {cpu.get('ram_used_gb', '?')}/{cpu.get('ram_total_gb', '?')}GB"
                print(f"  [{elapsed:>7.1f}s] {vram} | {temp} {power} {util} | {cpu_info} {ram}")

            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nMonitor stopped.")
    finally:
        f.close()
        print(f"Data saved: {output} ({elapsed:.0f}s, {int(elapsed/args.interval)} samples)")


if __name__ == "__main__":
    main()
