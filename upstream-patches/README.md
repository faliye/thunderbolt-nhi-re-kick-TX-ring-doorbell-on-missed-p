# Thunderbolt-Net Patches for ASM4242 / USB4 Host-to-Host

## 中文 | English | 日本語

---

## 中文

### 简介

两台主机经板载 **ASMedia ASM4242** USB4 直连,跑 `thunderbolt-net`。
在这套硬件上发现多个缺陷,对应多个补丁。目前包括(2026-08-19 现查状态):

- **0001**: E2E 流控(TX 环)—— ✅ 已合入 Linus 主线
- **0003/v2**: DMA 路径拆除顺序修复 —— ✅ 已合入 Linus 主线
- **0004/v2**: 限制 DMA 隧道信用到寄存器容量 —— 已被维护者收入 `next`,等待合并窗口
- **0006**: 使用 min 函数计算 DMA 路径信用上限 —— 同上
- **0007**: 修正 tbnet 接收统计(误把帧数当包数)—— 已提交,已获评审者 Reviewed-by
- **0009/v3**: 释放 Rx HopID 不匹配时分配的 ID —— ✅ 已合入 netdev 树
- **0010/v3**: 设置连接状态为 down 当建立失败时 —— ✅ 已合入 netdev 树
- **0011**: 向调用者报告 DMA 路径拆除失败 —— ❌ 已放弃,不会提交
- **0012/v3**: 处理 ASM4242 pending bit 不清零的特性 —— 已提交,等待评审

> **重要**: 各补丁相互独立,解决不同问题,可按任意顺序应用。逐条详情见下文,
> 上游落地状态会随时间变化,请以各节的「状态」行为准。

---

## 0001 — E2E on TX (厂商 workaround)

**文件**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**问题**: 上游把 `RING_FLAG_E2E` 也加到 TX 环。按 USB4 规范,TX 环开 E2E 就必须先拿到端到端信用才能发;
而 ASM4242 **从不产生 E2E 信用** → TX 消费者永久停摆,大流量传不动。

**状态**: ✅ 已被上游接受 —— 2026-07-30 由 netdev maintainer Jakub Kicinski 收入
`net-next`(commit `1881f2efbf7f`,`Acked-by: Mika Westerberg`),现已在 Linus 的
`master` 中。

---

## 0003/v2 — DMA 路径拆除顺序

**文件**: `0003-v2-net-thunderbolt-Tear-down-DMA-paths-before-stoppin.patch`

**问题**:

- `tbnet_tear_down()` 先 `tb_ring_stop()` 再 `tb_xdomain_disable_paths()`
- 停 ring 会清零 descriptor base,其后备页被立即 dma_unmap_page + __free_pages
- 在飞的 DMA 从此无处可落
- 随后 `__tb_path_deactivate_hop()` 轮询 hop 的 `pending` 位,在某些 host router 上永远等不到清零
- 500ms 超时后返回 `-ETIMEDOUT`,但 `tb_xdomain_disable_paths()` 仍返回 0(静默失败)

**解决**: 调整拆除顺序,先拆 paths 再停 ring,确保在飞 DMA 有目标缓冲区。

**验证**: 在纯净 v6.17 树上(不含其他补丁)单独应用本补丁,拆除时间从 0.503s 降至 0.003s。

**状态**: ✅ 已被上游接受(`Acked-by: Mika Westerberg`),已在 Linus 的 `master` 中
(commit `68bf02b6b4ad`)。

---

## 0004/v2 — 限制 DMA 隧道信用

**文件**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**问题**:

- `struct tb_regs_hop::initial_credits` 是 7 bits 宽(最大 127)
- `dma_credits` 模块参数和 host router 的 `baMaxHI` 都没有上限检查
- 超大值在 `tb_path_activate()` 时被截断,路径以错误的信用数运行

**解决**: 在 `tb_tunnel_alloc_dma()` 中将信用数钳制到 127。

**测试**: ASM4242 报告 174 个缓冲区,请求 172 个信用时,修复前读回 44(172 & 0x7f),修复后读回 127。

**状态**: 已被 thunderbolt 维护者 Mika Westerberg 直接收入他的 `next` 分支
(commit `86feaba911f2`),已打包进 `thunderbolt-for-v7.3-rc1` 标签,
等待下一次内核合并窗口进入 Linus 主线。

---

## 0006 — 使用 min 计算信用上限

**文件**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**说明**: 简化信用上限计算,使用 min 函数。

**状态**: 与 0004/v2 同批收入维护者 `next` 分支(commit `e8158c8a6a23`),
同样等待合并窗口。

---

## 0007 — 修正 tbnet 接收统计

**文件**: `0007-net-thunderbolt-Count-delivered-packets-in-rx_packe.patch`

**问题**:

- `rx_packets` 在收到每一**帧**时就自增,但一个逻辑包在 MTU 超过单帧上限
  (`TBNET_MAX_PAYLOAD_SIZE`)时会被拆成多帧传输
- 于是 `rx_packets` 数的其实是帧数,`rx_bytes` 也统计了尚未拼完、随后
  可能被丢弃的半包
- MTU 65330 时,接收端上报的包数约为发送端的 16 倍

**解决**: 把计数挪到包真正拼完、交付协议栈的那一刻。

**测试**: `rx_packets` 与对端 `InReceives` 的比值从 15.899 降到 0.992;
`rx_bytes/rx_packets` 从 4083.9(帧大小)恢复到 65308.3(实际包大小)。

**状态**: 已提交,已获 Simon Horman 的 `Reviewed-by`,尚未被维护者合并。

---

## 0009/v3 — 释放 Rx HopID

**文件**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**问题**:

- `tb_xdomain_alloc_in_hopid()` 将所需 HopID 作为下限传给分配器,返回第一个空闲 ID
- `tbnet_connected_work()` 期望得到特定 ID,其他 ID 视为失败
- 分配的 ID 没有被释放,导致该 allocation 在 XDomain 连接期间一直占用,没有引用计数

**解决**: 当 ID 不是期望的那个时释放它。

**Fixes**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

**状态**: ✅ 已被 netdev maintainer Jakub Kicinski 收入 `net.git`/`net-next.git`
的 `main`(2026-08-17,commit `2f1463554d05`,`Acked-by: Mika Westerberg` +
`Reviewed-by: Simon Horman`),尚未到 Linus 的 `master`。

---

## 0010/v3 — 标记连接为 down

**文件**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**问题**:

- `tbnet_connected_work()` 中所有失败路径都不清除 `login_sent` 标志
- 连接仍然看起来已建立
- 随后的 `tbnet_tear_down()` 会重复拆除:停止已停止的 ring(触发 dev_WARN),释放不属于本端的 HopID

**解决**: 在这些失败路径上清除 `login_sent` 标志,让 `tbnet_tear_down()` 忽略该连接。

**Fixes**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

**状态**: ✅ 已被 netdev maintainer Jakub Kicinski 收入 `net.git`/`net-next.git`
的 `main`(2026-08-17,commit `3c8b26ebf525`,`Acked-by: Mika Westerberg` +
`Reviewed-by: Simon Horman`),尚未到 Linus 的 `master`。

---

## 0011 — 报告 DMA 路径拆除失败(已放弃)

**文件**: `0011-ABANDONED-v2-thunderbolt-Report-DMA-path-teardown-fai.patch`
(留存作证据存档,不要提交)

**问题**:

- `tb_disconnect_xdomain_paths()` 无条件返回 0
- 内层失败(hop 拒绝 drain, `-ETIMEDOUT`)被隐藏
- 连接管理器报告成功,上层 tbnet 看不到失败

**解决**:

- 传播拆除过程中的第一个错误
- 返回值通过 `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()` 传递
- 拆除仍继续至完成(路径标记为 inactive、信用释放、隧道释放)
- 只改变返回值,调用者看得到真实状态

**状态**: ❌ 已放弃,不会提交上游 —— 同一个返回值在 ICM 与软件连接管理器上含义
不同(前者非 0 表示隧道可能还在,后者非 0 表示隧道已拆、只是某一跳没排空),
公共头只给调用方一个不透明指针,分不清自己在跟哪一种通信,给不出统一契约。

---

## 0012/v3 — ASM4242 pending bit 特性处理

**文件**: `0012-v3-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**问题**:

- ASM4242 host interface adapter 在 DMA ring 经历足够多帧后,pending bit 锁定不再变化
- 每次拆除都要等 500ms 才超时
- 频繁 down/up 会累积大量超时

**观察**:

- bit 行为分两个阶段,帧数量决定阶段转换
- ring 大小决定临界帧数(ring 128 时约 120 帧,ring 256 时约 260 帧)
- 其他 hop 正常清零,只有 host 端受影响

**解决(v3)**: 把 500ms 等待做成 host router 自己的属性,对 ASM4242(`1b21:2425`)
按 quirk 置为 0——循环仍读一次:排得空的那次上报排空,排不空的直接返回
`-ETIMEDOUT`,不再空等 500ms。上一版(v2)是全局跳过检查,v3 改成了按硬件 ID 的
quirk,粒度更细。

**状态**: 已提交(v3),设计与实现细节已在邮件里和维护者(Mika Westerberg)谈妥
并获认可("Sounds good")。维护者说明他的 `next` 分支已为当前发布周期冻结,
要等下一个版本发布后才会开始处理排队的补丁——v3 就是照此有意提前发出、排队
等待的,当前的"无评审动态"是预期状态,不是被忽略。上一版(v2)已废弃,不要再用。

---

## 补丁关系

所有补丁相互独立:

| 补丁 | 依赖 | 应用顺序 |
|---|---|---|
| 0001 | 无 | 任意 |
| 0003/v2 | 无 | 任意 |
| 0004/v2 | 无 | 任意 |
| 0006 | 可选依赖 0004 | 0004 之后 |
| 0007 | 无 | 任意 |
| 0009/v3 | 无 | 任意 |
| 0010/v3 | 依赖 0009/v3 | 0009 之后 |
| 0011 | 无(已放弃,不提交) | — |
| 0012/v3 | 无 | 任意 |

---

---

## English

### Overview

Two hosts connected directly via on-board **ASMedia ASM4242** USB4 running `thunderbolt-net`.
Multiple defects found on this hardware, with corresponding patches
(status as of 2026-08-19):

- **0001**: E2E flow control (TX ring) — ✅ merged into Linus's mainline
- **0003/v2**: DMA path teardown order fix — ✅ merged into Linus's mainline
- **0004/v2**: Clamp DMA tunnel credits to register capacity — in maintainer's `next`, awaiting merge window
- **0006**: Use min() for DMA path credit cap — same as above
- **0007**: Fix tbnet Rx statistics (frames miscounted as packets) — submitted, has a reviewer's Reviewed-by
- **0009/v3**: Release Rx HopID on allocation mismatch — ✅ merged into the netdev tree
- **0010/v3**: Mark connection down when bring-up fails — ✅ merged into the netdev tree
- **0011**: Report DMA path teardown failures to caller — ❌ abandoned, will not be submitted
- **0012/v3**: Handle ASM4242 pending bit that never clears — submitted, awaiting review

> **Important**: Patches are independent, solve different problems, can be applied in
> any order. See each section below for details; upstream status changes over time,
> trust the "Status" line in each section over this summary.

---

## 0001 — E2E on TX (Vendor Workaround)

**File**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**Issue**: Upstream adds `RING_FLAG_E2E` to TX ring. Per USB4 spec, enabling E2E on TX requires end-to-end credits before sending;
but ASM4242 **never generates E2E credits** → TX consumer permanently stalled, large flows cannot pass.

**Status**: ✅ Accepted upstream — merged into `net-next` by netdev maintainer
Jakub Kicinski on 2026-07-30 (commit `1881f2efbf7f`, `Acked-by: Mika Westerberg`),
now in Linus's `master`.

---

## 0003/v2 — DMA Path Teardown Order

**File**: `0003-v2-net-thunderbolt-Tear-down-DMA-paths-before-stoppin.patch`

**Issue**:

- `tbnet_tear_down()` calls `tb_ring_stop()` then `tb_xdomain_disable_paths()`
- Stopping ring clears descriptor base, backing pages immediately dma_unmap_page + __free_pages
- In-flight DMAs have nowhere to land
- Then `__tb_path_deactivate_hop()` polls hop's `pending` bit, on some host routers never sees it clear
- After 500ms timeout returns `-ETIMEDOUT`, but `tb_xdomain_disable_paths()` still returns 0 (silent failure)

**Fix**: Reorder teardown: disable paths first, then stop ring, ensuring in-flight DMA has target buffers.

**Verification**: Apply only this patch on clean v6.17 tree, teardown time drops from 0.503s to 0.003s.

**Status**: ✅ Accepted upstream (`Acked-by: Mika Westerberg`), now in Linus's
`master` (commit `68bf02b6b4ad`).

---

## 0004/v2 — Clamp DMA Tunnel Credits

**File**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**Issue**:

- `struct tb_regs_hop::initial_credits` is 7 bits wide (max 127)
- Neither `dma_credits` module parameter nor host router `baMaxHI` have upper bounds
- Oversized value gets truncated when `tb_path_activate()` writes to register, path runs with wrong credit count

**Fix**: Clamp credits to 127 in `tb_tunnel_alloc_dma()`.

**Test**: ASM4242 reports 174 buffers, requesting 172 credits: before fix reads 44 (172 & 0x7f), after fix reads 127.

**Status**: Applied directly by thunderbolt maintainer Mika Westerberg into his
`next` branch (commit `86feaba911f2`), tagged `thunderbolt-for-v7.3-rc1`,
awaiting the next kernel merge window to reach Linus's mainline.

---

## 0006 — Use min() for Credit Cap

**File**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**Note**: Simplify credit cap calculation using min() function.

**Status**: Landed in the maintainer's `next` branch in the same batch as
0004/v2 (commit `e8158c8a6a23`), same merge-window wait.

---

## 0007 — Fix tbnet Rx Statistics

**File**: `0007-net-thunderbolt-Count-delivered-packets-in-rx_packe.patch`

**Issue**:

- `rx_packets` increments once per received **frame**, but a logical packet
  is split across multiple frames once MTU exceeds the per-frame payload
  limit (`TBNET_MAX_PAYLOAD_SIZE`)
- So `rx_packets` actually counts frames, and `rx_bytes` includes partial
  packets that may later be dropped during reassembly
- At MTU 65330, the receiver reports about 16x the packet count the sender
  actually sent

**Fix**: Move the counting to the point where a packet is fully reassembled
and handed to the network stack.

**Test**: `rx_packets` vs. peer `InReceives` ratio dropped from 15.899 to
0.992; `rx_bytes/rx_packets` recovered from 4083.9 (frame size) to 65308.3
(actual packet size).

**Status**: Submitted, received `Reviewed-by` from Simon Horman, not yet
merged by the maintainer.

---

## 0009/v3 — Release Rx HopID

**File**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**Issue**:

- `tb_xdomain_alloc_in_hopid()` passes desired HopID as lower bound to allocator, returns first free ID above it
- `tbnet_connected_work()` expects specific ID, treats any other as failure
- Allocated ID is never released, stays live for entire XDomain connection with no refcount

**Fix**: Release ID when it's not the one we asked for.

**Fixes**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

**Status**: ✅ Merged by netdev maintainer Jakub Kicinski into `net.git`/`net-next.git`
`main` (2026-08-17, commit `2f1463554d05`, `Acked-by: Mika Westerberg` +
`Reviewed-by: Simon Horman`), not yet in Linus's `master`.

---

## 0010/v3 — Mark Connection Down

**File**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**Issue**:

- All failure paths in `tbnet_connected_work()` fail to clear `login_sent` flag
- Connection still looks established
- Subsequent `tbnet_tear_down()` repeats teardown: stops already-stopped rings (triggers dev_WARN), releases HopID we never owned

**Fix**: Clear `login_sent` flag on these failure paths, let `tbnet_tear_down()` skip this connection.

**Fixes**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

**Status**: ✅ Merged by netdev maintainer Jakub Kicinski into `net.git`/`net-next.git`
`main` (2026-08-17, commit `3c8b26ebf525`, `Acked-by: Mika Westerberg` +
`Reviewed-by: Simon Horman`), not yet in Linus's `master`.

---

## 0011 — Report Teardown Failures (Abandoned)

**File**: `0011-ABANDONED-v2-thunderbolt-Report-DMA-path-teardown-fai.patch`
(kept for reference, do not submit)

**Issue**:

- `tb_disconnect_xdomain_paths()` unconditionally returns 0
- Internal failures (hop refuses drain, `-ETIMEDOUT`) hidden
- Connection manager reports success, upper layer tbnet sees nothing

**Fix**:

- Propagate first error seen while deactivating hops
- Return value flows through `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()`
- Teardown still runs to completion (paths marked inactive, credits released, tunnel freed)
- Only changes return value; callers that check it now get truth

**Status**: ❌ Abandoned, will not be submitted — the same return value means
different things on ICM vs. the software connection manager (non-zero means
"tunnel may still be up" on one, "tunnel torn down, one hop just didn't
drain" on the other), and the public header only gives the caller an opaque
pointer with no way to tell which one it's talking to, so no consistent
contract could be given.

---

## 0012/v3 — ASM4242 Pending Bit Quirk

**File**: `0012-v3-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**Issue**:

- ASM4242 host interface adapter's pending bit latches after enough frames through DMA ring, never clears again
- Every teardown waits full 500ms before timeout
- Frequent down/up cycles accumulate many timeouts

**Observation**:

- Bit behaves in two regimes, frame count determines transition
- Ring size determines frame threshold (ring 128 ~120 frames, ring 256 ~260 frames)
- Other hops clear normally, only host adapter affected

**Fix (v3)**: Turn the 500ms wait into a property of the host router itself,
quirked to 0 for ASM4242 (`1b21:2425`) — the loop still reads the bit once:
a drained hop reports drained on that read, a stuck one returns
`-ETIMEDOUT` immediately instead of waiting the full 500ms. v2 skipped the
check globally; v3 narrows it to a per-hardware-ID quirk.

**Status**: Submitted (v3). Design and implementation details were agreed
with the maintainer (Mika Westerberg) by email and got a "Sounds good".
He noted his `next` branch is frozen for the current release cycle and he
won't start picking up queued patches again until after the next kernel
release ships — v3 was sent early, on purpose, to be ready and waiting;
the current lack of review activity is the expected state, not neglect.
Previous version (v2) is deprecated, don't
use it.

---

## Patch Relationships

All patches are independent:

| Patch | Dependencies | Order |
|---|---|---|
| 0001 | None | Any |
| 0003/v2 | None | Any |
| 0004/v2 | None | Any |
| 0006 | Optional after 0004 | After 0004 |
| 0007 | None | Any |
| 0009/v3 | None | Any |
| 0010/v3 | Requires 0009/v3 | After 0009 |
| 0011 | None (abandoned, not submitted) | — |
| 0012/v3 | None | Any |

---

---

## 日本語

### 概要

ASMedia ASM4242 USB4 でホスト間に直接接続された 2 台のマシンで `thunderbolt-net` を実行。
このハードウェアで複数の欠陥を発見し、対応するパッチを用意しました
(2026-08-19 時点のステータス):

- **0001**: E2E フロー制御(TX リング)—— ✅ Linus のメインラインに合流済み
- **0003/v2**: DMA パス破棄順序の修正 —— ✅ Linus のメインラインに合流済み
- **0004/v2**: DMA トンネルクレジットをレジスタ容量に制限 —— メンテナの `next` に入り、マージウィンドウ待ち
- **0006**: DMA パスクレジット上限に min() を使用 —— 同上
- **0007**: tbnet 受信統計の修正(フレーム数をパケット数と誤カウント)—— 提出済み、レビュアーの Reviewed-by 獲得
- **0009/v3**: 割り当てミスマッチ時の Rx HopID を解放 —— ✅ netdev ツリーに合流済み
- **0010/v3**: ブリングアップ失敗時に接続を down にマーク —— ✅ netdev ツリーに合流済み
- **0011**: DMA パス破棄失敗を呼び出し者に報告 —— ❌ 放棄、提出しません
- **0012/v3**: クリアされない ASM4242 pending bit に対応 —— 提出済み、レビュー待ち

> **重要**: パッチは独立しており、異なる問題を解決し、任意の順序で適用できます。
> 詳細は各セクションを参照してください。アップストリームの状況は時間とともに
> 変化するため、この要約より各セクションの「ステータス」行を優先してください。

---

## 0001 — E2E on TX (ベンダー回避策)

**ファイル**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**問題**: アップストリームが `RING_FLAG_E2E` を TX リングにも追加します。USB4 仕様によれば、TX リングで E2E を有効にするには送信前にエンドツーエンドクレジットを取得する必要があります。
しかし ASM4242 は **E2E クレジットを生成しない** → TX コンシューマが永続的に停止、大きなフローが通過できません。

**ステータス**: ✅ アップストリームに採用済み —— 2026-07-30 に netdev メンテナ
Jakub Kicinski により `net-next` に取り込まれ(commit `1881f2efbf7f`、
`Acked-by: Mika Westerberg`)、現在は Linus の `master` に入っています。

---

## 0003/v2 — DMA パス破棄順序

**ファイル**: `0003-v2-net-thunderbolt-Tear-down-DMA-paths-before-stoppin.patch`

**問題**:

- `tbnet_tear_down()` は `tb_ring_stop()` を呼び出してから `tb_xdomain_disable_paths()` を呼び出します
- リングを停止するとディスクリプタベースがクリアされ、バッキングページが dma_unmap_page + __free_pages で即座に解放されます
- 飛行中の DMA には着地点がありません
- その後 `__tb_path_deactivate_hop()` は hop の `pending` ビットをポーリングしますが、一部の host router ではクリアを見ることができません
- 500ms タイムアウト後に `-ETIMEDOUT` を返しますが、`tb_xdomain_disable_paths()` は依然として 0 を返します(静かな失敗)

**修正**: 破棄順序を変更: パスを無効にしてからリングを停止し、飛行中 DMA にターゲットバッファがあることを確認します。

**検証**: クリーンな v6.17 ツリーでこのパッチのみを適用すると、破棄時間は 0.503s から 0.003s に短縮されます。

**ステータス**: ✅ アップストリームに採用済み(`Acked-by: Mika Westerberg`)、
現在 Linus の `master` に入っています(commit `68bf02b6b4ad`)。

---

## 0004/v2 — DMA トンネルクレジットを制限

**ファイル**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**問題**:

- `struct tb_regs_hop::initial_credits` は 7 ビット幅(最大 127)
- `dma_credits` モジュールパラメータも host router の `baMaxHI` も上限チェックがありません
- オーバーサイズ値は `tb_path_activate()` がレジスタに書き込むときに切り詰められ、パスは間違ったクレジット数で実行されます

**修正**: `tb_tunnel_alloc_dma()` でクレジットを 127 に制限します。

**テスト**: ASM4242 は 174 バッファを報告、172 クレジットをリクエスト: 修正前は 44(172 & 0x7f)を読み取り、修正後は 127 を読み取ります。

**ステータス**: thunderbolt メンテナ Mika Westerberg により彼の `next` ブランチに
直接取り込まれ(commit `86feaba911f2`)、`thunderbolt-for-v7.3-rc1` としてタグ
付け済み、次のマージウィンドウで Linus のメインラインに入るのを待っています。

---

## 0006 — min() を使用してクレジット上限を計算

**ファイル**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**注記**: min() 関数を使用してクレジット上限計算を簡略化します。

**ステータス**: 0004/v2 と同時にメンテナの `next` ブランチに取り込まれ
(commit `e8158c8a6a23`)、同様にマージウィンドウ待ちです。

---

## 0007 — tbnet 受信統計の修正

**ファイル**: `0007-net-thunderbolt-Count-delivered-packets-in-rx_packe.patch`

**問題**:

- `rx_packets` は受信した**フレーム**ごとに加算されるが、MTU がフレームあたりの
  ペイロード上限(`TBNET_MAX_PAYLOAD_SIZE`)を超えると 1 つの論理パケットが
  複数フレームに分割される
- そのため `rx_packets` は実質フレーム数を数えており、`rx_bytes` も後で破棄され
  得る未完成のパケットを含んでしまう
- MTU 65330 では、受信側が送信側の約 16 倍のパケット数を報告する

**修正**: パケットが完全に再構築されプロトコルスタックに渡される時点で
カウントするように変更。

**テスト**: `rx_packets` と対向の `InReceives` の比が 15.899 から 0.992 に改善、
`rx_bytes/rx_packets` が 4083.9(フレームサイズ)から 65308.3(実際のパケット
サイズ)に回復。

**ステータス**: 提出済み、Simon Horman から `Reviewed-by` を獲得、メンテナに
よるマージはまだ。

---

## 0009/v3 — Rx HopID を解放

**ファイル**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**問題**:

- `tb_xdomain_alloc_in_hopid()` は目的の HopID をアロケータの下限として渡し、その上の最初の空き ID を返します
- `tbnet_connected_work()` は特定の ID を期待し、他の ID を失敗として扱います
- 割り当てられた ID は解放されず、XDomain 接続全体にわたって生き続け、参照カウンターがありません

**修正**: 要求した ID でない場合は ID を解放します。

**修正対象**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

**ステータス**: ✅ netdev メンテナ Jakub Kicinski により `net.git`/`net-next.git`
の `main` に取り込まれ済み(2026-08-17、commit `2f1463554d05`、
`Acked-by: Mika Westerberg` + `Reviewed-by: Simon Horman`)、Linus の `master`
にはまだ入っていません。

---

## 0010/v3 — 接続を down にマーク

**ファイル**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**問題**:

- `tbnet_connected_work()` のすべての失敗パスが `login_sent` フラグをクリアしません
- 接続はまだ確立されているように見えます
- その後の `tbnet_tear_down()` は破棄を繰り返します: 既に停止しているリングを停止(dev_WARN をトリガー)、所有していない HopID を解放します

**修正**: これらの失敗パスで `login_sent` フラグをクリアし、`tbnet_tear_down()` がこの接続をスキップするようにします。

**修正対象**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

**ステータス**: ✅ netdev メンテナ Jakub Kicinski により `net.git`/`net-next.git`
の `main` に取り込まれ済み(2026-08-17、commit `3c8b26ebf525`、
`Acked-by: Mika Westerberg` + `Reviewed-by: Simon Horman`)、Linus の `master`
にはまだ入っていません。

---

## 0011 — 破棄失敗を報告(放棄)

**ファイル**: `0011-ABANDONED-v2-thunderbolt-Report-DMA-path-teardown-fai.patch`
(記録として保持、提出しないこと)

**問題**:

- `tb_disconnect_xdomain_paths()` は無条件に 0 を返します
- 内部失敗(hop が drain を拒否、`-ETIMEDOUT`)は隠されます
- 接続マネージャーはすべてのエラーを成功として報告し、その上層 tbnet は何も表示されません

**修正**:

- hop を無効化する際に見られた最初のエラーを伝播します
- 戻り値は `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()` を通じて流れます
- 破棄は依然として完了まで実行されます(パスは inactive にマーク、クレジット解放、トンネル解放)
- 戻り値のみが変わり、チェックする呼び出し元は真実を取得します

**ステータス**: ❌ 放棄——提出しません。ICM とソフトウェア接続マネージャで
同じ戻り値の意味が異なり(片方では非 0 が「トンネルがまだ生きている可能性」、
もう片方では「トンネルは破棄済みで、1 つの hop が排水できなかっただけ」を
意味する)、公開ヘッダは呼び出し側に不透明なポインタしか渡さないため、
どちらと通信しているか区別できず、一貫した契約を提供できません。

---

## 0012/v3 — ASM4242 Pending Bit Quirk

**ファイル**: `0012-v3-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**問題**:

- ASM4242 host interface adapter の pending ビットは DMA リングを十分なフレーム数が通過した後にラッチし、二度とクリアされません
- すべての破棄は 500ms 待機してからタイムアウトします
- 頻繁な down/up サイクルは多くのタイムアウトを累積します

**観察**:

- ビットは 2 つのレジーム で動作し、フレーム数が遷移を決定します
- リングサイズがフレームしきい値を決定します(リング 128 ~120 フレーム、リング 256 ~260 フレーム)
- 他の hop は正常にクリアされ、host adapter のみが影響を受けます

**修正(v3)**: 500ms の待機を host router 自身のプロパティにし、ASM4242
(`1b21:2425`)には quirk で 0 を設定——ループは依然として 1 回はビットを
読みます:排水済みの hop はその 1 回で排水済みと報告され、詰まっている
hop はフルの 500ms を待たずに即座に `-ETIMEDOUT` を返します。v2 は
チェックを全体でスキップしていましたが、v3 はハードウェア ID 単位の
quirk に絞り込みました。

**ステータス**: 提出済み(v3)。設計と実装の詳細はメールでメンテナ
(Mika Westerberg)と合意済みで、"Sounds good" の返答を得ています。
メンテナによれば、彼の `next` ブランチは今期リリースサイクル分で
凍結済みで、次のカーネルリリース後でないとキューのパッチを拾い始め
ないとのこと —— v3 はそれを見越して意図的に早めに送って待機させている
もので、現在レビュー動きがないのは想定どおりであり、放置されている
わけではありません。旧版(v2)は非推奨のため使用しないこと。

---

## パッチの関係

すべてのパッチは独立しています:

| パッチ | 依存関係 | 順序 |
|---|---|---|
| 0001 | なし | 任意 |
| 0003/v2 | なし | 任意 |
| 0004/v2 | なし | 任意 |
| 0006 | 0004 の後で依存 | 0004 の後 |
| 0007 | なし | 任意 |
| 0009/v3 | なし | 任意 |
| 0010/v3 | 0009/v3 が必須 | 0009 の後 |
| 0011 | なし(放棄、提出しない) | — |
| 0012/v3 | なし | 任意 |
