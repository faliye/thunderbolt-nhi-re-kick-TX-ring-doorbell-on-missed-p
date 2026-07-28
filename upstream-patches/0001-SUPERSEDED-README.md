# 0001-SUPERSEDED-do-not-enable-E2E-on-Tx-do-not-send.patch —— 已作废,不要发送

这是 2026-07-23 发出的 v1(标题 `net: thunderbolt: do not enable E2E flow
control on the Tx ring`)。**功能上没有错**,在 ASM4242 上实测通过,checkpatch
也是干净的。作废原因是形式问题,不是正确性问题。

## 作废原因(2026-07-27)

Mika 回信:"Why not simply send revert for a8065af3346e?"

这个意见成立:

1. **本补丁与 revert 功能完全等价** —— 它给 Tx 环传的是无条件的
   `RING_FLAG_FRAME`,和 `a8065af3346e` 之前的代码一模一样。两者对所有硬件
   (包括华为提交者的硬件)的影响是同一件事,写成新 commit 并不能为谁保住什么。
2. **它留下了死动作** —— `flags` 仍在 Tx 分配之前算好、却只给 Rx 用,这是
   `a8065af3346e` 挪上来的残留。revert 会一并清干净。
3. 回归修复走 revert 是 netdev 的常规做法,也更利于 stable 回溯。

## 请使用

**`0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`**(v2)

已于 2026-07-27 发出至 netdev,标题
`[PATCH net v2] Revert "net: thunderbolt: Enable end-to-end flow control also in transmit"`,
在 lore.kernel.org 搜该标题可找到投稿存档。

由 `git revert` 生成的真正原状还原,已核对 `tbnet_open` 中
`RING_FLAG` / `tb_ring_alloc*` / `flags =` 三类行与 `a8065af3346e` 之前逐字一致;
checkpatch --strict 全清;对 net base 干净应用;`make W=1
drivers/net/thunderbolt/main.o` 编译通过零警告。v1 的 ASM4242 实测数据已完整
保留在 v2 的 changelog 中,并加了 `Cc:` 原作者让对方有机会指出是否存在依赖
Tx 侧 E2E 的真实负载。
