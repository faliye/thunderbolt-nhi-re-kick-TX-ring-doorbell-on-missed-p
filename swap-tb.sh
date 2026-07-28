#!/usr/bin/env bash
# 换上打了 0004 补丁的 thunderbolt 模块(可秒回退)。只动 thunderbolt,不碰无线/内核/启动。
KVER=$(uname -r)
MODDIR=/lib/modules/$KVER
SRC=$HOME/tb-build/linux617
TB=$SRC/drivers/thunderbolt/thunderbolt.ko
TBNET=$SRC/drivers/net/thunderbolt/thunderbolt_net.ko

echo "== 1) 备份原始模块 =="
mkdir -p "$HOME/tb-build/orig-modules"
sudo cp -n "$MODDIR/kernel/drivers/thunderbolt/thunderbolt.ko.zst"        "$HOME/tb-build/orig-modules/" 2>/dev/null || true
sudo cp -n "$MODDIR/kernel/drivers/net/thunderbolt/thunderbolt_net.ko.zst" "$HOME/tb-build/orig-modules/" 2>/dev/null || true
ls "$HOME/tb-build/orig-modules/"

echo "== 2) 补丁模块放进 updates/(优先级高于原版) =="
sudo mkdir -p "$MODDIR/updates"
sudo cp "$TB"    "$MODDIR/updates/thunderbolt.ko"
sudo cp "$TBNET" "$MODDIR/updates/thunderbolt_net.ko"
sudo depmod -a
echo "modprobe 将加载: $(modinfo thunderbolt | awk -F: '/^filename/{print $2}')"

echo "== 3) 卸载旧 + 加载补丁版 =="
sudo modprobe -r thunderbolt_net 2>/dev/null || true
sudo modprobe -r thunderbolt     2>/dev/null || true
lsmod | grep -qi thunderbolt && echo "⚠ 仍有残留(可能被占用):$(lsmod|grep -i thunderbolt)" || echo "卸载干净"
sudo modprobe thunderbolt     && echo "✓ thunderbolt(patched) 已载"
sudo modprobe thunderbolt_net && echo "✓ thunderbolt_net(patched) 已载"

echo "== 4) 状态 =="
lsmod | grep -i thunderbolt || true
echo "--- 设备树 ---"; ls /sys/bus/thunderbolt/devices/
echo "--- 网卡 ---";   ip -br addr show thunderbolt0 2>/dev/null || echo "暂无 thunderbolt0(大概率需重插一次 TB 线)"
echo "--- dmesg 尾部 ---"; sudo dmesg | grep -iE 'thunderbolt|xdomain' | tail -8

echo
echo "== 回退命令(需要时粘这一行) =="
echo "sudo rm $MODDIR/updates/thunderbolt*.ko && sudo depmod -a && sudo modprobe -r thunderbolt_net thunderbolt && sudo modprobe thunderbolt thunderbolt_net"
