# disk-speed-bench

ストレージのシーケンシャルリード・ライト速度を計測するベンチマーク。

AI モデルファイルと同等サイズ（デフォルト 1GB）のテストファイルを生成し、
`WriteThrough`（OS キャッシュバイパス）でライト、`SequentialScan` でリードを計測。

## 使い方

```powershell
# 基本（1GB, 3回）
.\disk-speed-bench\bench_diskspeed.ps1 -Drive D -Runs 3

# 小さいサイズで高速テスト
.\disk-speed-bench\bench_diskspeed.ps1 -Drive D -Runs 3 -SizeMB 256

# 大きいサイズでより正確に
.\disk-speed-bench\bench_diskspeed.ps1 -Drive D -Runs 3 -SizeMB 5120
```

## 出力

`results/disk-speed-bench/diskspeed_{DRIVE}.json` に以下を記録:
- `read_median_mbs`: シーケンシャルリード中央値 (MB/s)
- `write_median_mbs`: シーケンシャルライト中央値 (MB/s)
- `disk_info`: ドライブ型番、シリアル番号、UniqueId、バスタイプ、ファームウェア
