# 0002-SUPERSEDED-hand-written-do-not-send.patch —— 已作废,不要发送

这是 2026-07-22 手写整理的版本,存在以下问题(2026-07-23 核实):

1. **diff 与真实上游代码对不上** —— 它是照着本地魔改过的多环 tbnet 写的,
   引入了上游不存在的 `rx_flags` 变量。上游的正确修法只需让 `tb_ring_alloc_tx()`
   传回 `RING_FLAG_FRAME`,是一行。
2. **`Fixes:` 缺 SHA,且引用的是 v1 旧标题**。上游合入时 Mika 要求改名,
   最终标题是 `net: thunderbolt: Enable end-to-end flow control also in transmit`,
   SHA `a8065af3346e`。
3. 不是 `git format-patch` 产物,缺 index 行,未必能 `git am`。
4. **该形态从未编译或运行测试过。**

**请使用 `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`**
(checkpatch --strict 全清,已在 v6.17 真机上前后对照验证)。

> 2026-07-27 更新:本文原先指向
> `0001-net-thunderbolt-do-not-enable-E2E-flow-control-on-th.patch`,
> 该文件已改名为 `0001-SUPERSEDED-do-not-enable-E2E-on-Tx-do-not-send.patch`
> 并作废,原因见 `0001-SUPERSEDED-README.md`。
