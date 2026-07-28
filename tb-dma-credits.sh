#!/usr/bin/env bash
# TB DMA 隧道信用实验:sudo bash tb-dma-credits.sh <N>   (两台都要跑,先 B 后 A 或反之均可)
# 背景:tbnet 单流 5.15G 硬顶已定位为字节带宽墙(与协议/流数/包长/CPU 无关),
#       最强假说 = dma_credits(默认14)×256B 在途 ÷ ASM4242 信用返还延迟(~5.5µs)≈ 645MB/s
# 预测:吞吐 ∝ N 线性增长(理论坐实);若 N 翻倍吞吐不动 → 转查路由器仲裁/TDM(改 TB_DMA_WEIGHT 重编)
set -e
N=${1:?用法: sudo bash tb-dma-credits.sh <credits>   建议序列: 28 → 64 → 120}
echo "== 重载 thunderbolt(dma_credits=$N;clx=0/asym=0/e2e=0 由 modprobe.d 保留)=="
modprobe -r thunderbolt_net 2>/dev/null || true
modprobe -r thunderbolt
modprobe thunderbolt dma_credits=$N
modprobe thunderbolt_net
echo -n "dma_credits 现值: "; cat /sys/module/thunderbolt/parameters/dma_credits
for i in $(seq 1 15); do
  sleep 2
  ip -br addr show thunderbolt0 2>/dev/null | grep -q 192.168.101 && { echo "✓ tbnet 已重连"; exit 0; }
done
echo "⚠ 30s 未重连:确认对端也已重载;仍不通则重插一次 TB 线"
