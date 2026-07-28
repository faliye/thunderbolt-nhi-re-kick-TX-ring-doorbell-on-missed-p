#!/usr/bin/env bash
# host-B:换上补丁版 thunderbolt 模块(可秒回退)。只动 thunderbolt,不碰无线/内核/其他服务/docker。
KVER=$(uname -r)
MODDIR=/lib/modules/$KVER
SRC=$HOME/tb-modules
TB=$SRC/thunderbolt.ko
TBNET=$SRC/thunderbolt_net.ko

echo "== 内核: $KVER / 模块 vermagic: $(modinfo "$TB" | awk -F: '/vermagic/{print $2}') =="

echo "== 1) 备份原始模块 =="
mkdir -p "$HOME/tb-modules/orig"
sudo cp -n "$MODDIR/kernel/drivers/thunderbolt/thunderbolt.ko.zst"        "$HOME/tb-modules/orig/" 2>/dev/null || true
sudo cp -n "$MODDIR/kernel/drivers/net/thunderbolt/thunderbolt_net.ko.zst" "$HOME/tb-modules/orig/" 2>/dev/null || true
ls "$HOME/tb-modules/orig/"

echo "== 2) 补丁模块放进 updates/ =="
sudo mkdir -p "$MODDIR/updates"
sudo cp "$TB"    "$MODDIR/updates/thunderbolt.ko"
sudo cp "$TBNET" "$MODDIR/updates/thunderbolt_net.ko"
sudo depmod -a
echo "modprobe 将加载: $(modinfo thunderbolt | awk -F: '/^filename/{print $2}')"

echo "== 3) 卸载旧 + 加载补丁版 =="
sudo modprobe -r thunderbolt_net 2>/dev/null || true
sudo modprobe -r thunderbolt     2>/dev/null || true
lsmod | grep -qi thunderbolt && echo "⚠ 残留:$(lsmod|grep -i thunderbolt)" || echo "卸载干净"
sudo modprobe thunderbolt     && echo "✓ thunderbolt(patched)"
sudo modprobe thunderbolt_net && echo "✓ thunderbolt_net(patched)"

echo "== 4) 状态 =="
lsmod | grep -i thunderbolt || true
ls /sys/bus/thunderbolt/devices/
ip -br addr show thunderbolt0 2>/dev/null || echo "暂无 thunderbolt0(重插线后回来)"

echo
echo "== 回退命令 =="
echo "sudo rm $MODDIR/updates/thunderbolt*.ko && sudo depmod -a && sudo modprobe -r thunderbolt_net thunderbolt && sudo modprobe thunderbolt thunderbolt_net"
