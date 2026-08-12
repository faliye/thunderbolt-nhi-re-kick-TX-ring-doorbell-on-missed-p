# Thunderbolt-Net Patches for ASM4242 / USB4 Host-to-Host

## 中文 | English | 日本語

---

## 中文

### 简介

两台主机经板载 **ASMedia ASM4242** USB4 直连,跑 `thunderbolt-net`。
在这套硬件上发现多个缺陷,对应多个补丁。目前包括:

- **0001**: E2E 流控(TX 环)的厂商 workaround
- **0003/v2**: DMA 路径拆除顺序修复
- **0004/v2**: 限制 DMA 隧道信用到寄存器容量
- **0006**: 使用 min 函数计算 DMA 路径信用上限
- **0009/v3**: 释放 Rx HopID 不匹配时分配的 ID
- **0010/v3**: 设置连接状态为 down 当建立失败时
- **0011**: 向调用者报告 DMA 路径拆除失败
- **0012/v2**: 处理 ASM4242 pending bit 不清零的特性

> **重要**: 各补丁相互独立,解决不同问题,可按任意顺序应用。

---

## 0001 — E2E on TX (厂商 workaround)

**文件**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**问题**: 上游把 `RING_FLAG_E2E` 也加到 TX 环。按 USB4 规范,TX 环开 E2E 就必须先拿到端到端信用才能发;
而 ASM4242 **从不产生 E2E 信用** → TX 消费者永久停摆,大流量传不动。

**状态**: 该上游 commit 在 Intel 上是正确的,这是 ASMedia 专属 workaround,上游大概率不收,本机自用。

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

---

## 0004/v2 — 限制 DMA 隧道信用

**文件**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**问题**:

- `struct tb_regs_hop::initial_credits` 是 7 bits 宽(最大 127)
- `dma_credits` 模块参数和 host router 的 `baMaxHI` 都没有上限检查
- 超大值在 `tb_path_activate()` 时被截断,路径以错误的信用数运行

**解决**: 在 `tb_tunnel_alloc_dma()` 中将信用数钳制到 127。

**测试**: ASM4242 报告 174 个缓冲区,请求 172 个信用时,修复前读回 44(172 & 0x7f),修复后读回 127。

---

## 0006 — 使用 min 计算信用上限

**文件**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**说明**: 简化信用上限计算,使用 min 函数。

---

## 0009/v3 — 释放 Rx HopID

**文件**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**问题**:

- `tb_xdomain_alloc_in_hopid()` 将所需 HopID 作为下限传给分配器,返回第一个空闲 ID
- `tbnet_connected_work()` 期望得到特定 ID,其他 ID 视为失败
- 分配的 ID 没有被释放,导致该 allocation 在 XDomain 连接期间一直占用,没有引用计数

**解决**: 当 ID 不是期望的那个时释放它。

**Fixes**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

---

## 0010/v3 — 标记连接为 down

**文件**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**问题**:

- `tbnet_connected_work()` 中所有失败路径都不清除 `login_sent` 标志
- 连接仍然看起来已建立
- 随后的 `tbnet_tear_down()` 会重复拆除:停止已停止的 ring(触发 dev_WARN),释放不属于本端的 HopID

**解决**: 在这些失败路径上清除 `login_sent` 标志,让 `tbnet_tear_down()` 忽略该连接。

**Fixes**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

---

## 0011 — 报告 DMA 路径拆除失败

**文件**: `0011-thunderbolt-Report-DMA-path-teardown-failures-to-the.patch`

**问题**:

- `tb_disconnect_xdomain_paths()` 无条件返回 0
- 内层失败(hop 拒绝 drain, `-ETIMEDOUT`)被隐藏
- 连接管理器报告成功,上层 tbnet 看不到失败

**解决**:

- 传播拆除过程中的第一个错误
- 返回值通过 `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()` 传递
- 拆除仍继续至完成(路径标记为 inactive、信用释放、隧道释放)
- 只改变返回值,调用者看得到真实状态

---

## 0012/v2 — ASM4242 pending bit 特性处理

**文件**: `0012-v2-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**问题**:

- ASM4242 host interface adapter 在 DMA ring 经历足够多帧后,pending bit 锁定不再变化
- 每次拆除都要等 500ms 才超时
- 频繁 down/up 会累积大量超时

**观察**:

- bit 行为分两个阶段,帧数量决定阶段转换
- ring 大小决定临界帧数(ring 128 时约 120 帧,ring 256 时约 260 帧)
- 其他 hop 正常清零,只有 host 端受影响

**解决**: 为 ASM4242 添加 quirk,在 pending bit 检查中跳过该特殊 host adapter(或超时更短)。

---

## 补丁关系

所有补丁相互独立:

| 补丁 | 依赖 | 应用顺序 |
|---|---|---|
| 0001 | 无 | 任意 |
| 0003/v2 | 无 | 任意 |
| 0004/v2 | 无 | 任意 |
| 0006 | 可选依赖 0004 | 0004 之后 |
| 0009/v3 | 无 | 任意 |
| 0010/v3 | 依赖 0009/v3 | 0009 之后 |
| 0011 | 无 | 任意 |
| 0012/v2 | 无 | 任意 |

---

---

## English

### Overview

Two hosts connected directly via on-board **ASMedia ASM4242** USB4 running `thunderbolt-net`.
Multiple defects found on this hardware, with corresponding patches:

- **0001**: E2E flow control (TX ring) vendor workaround
- **0003/v2**: DMA path teardown order fix
- **0004/v2**: Clamp DMA tunnel credits to register capacity
- **0006**: Use min() for DMA path credit cap
- **0009/v3**: Release Rx HopID on allocation mismatch
- **0010/v3**: Mark connection down when bring-up fails
- **0011**: Report DMA path teardown failures to caller
- **0012/v2**: Handle ASM4242 pending bit that never clears

> **Important**: Patches are independent, solve different problems, can be applied in any order.

---

## 0001 — E2E on TX (Vendor Workaround)

**File**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**Issue**: Upstream adds `RING_FLAG_E2E` to TX ring. Per USB4 spec, enabling E2E on TX requires end-to-end credits before sending;
but ASM4242 **never generates E2E credits** → TX consumer permanently stalled, large flows cannot pass.

**Status**: The upstream commit is correct on Intel; this is ASMedia-specific workaround, upstream unlikely to merge, local use only.

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

---

## 0004/v2 — Clamp DMA Tunnel Credits

**File**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**Issue**:

- `struct tb_regs_hop::initial_credits` is 7 bits wide (max 127)
- Neither `dma_credits` module parameter nor host router `baMaxHI` have upper bounds
- Oversized value gets truncated when `tb_path_activate()` writes to register, path runs with wrong credit count

**Fix**: Clamp credits to 127 in `tb_tunnel_alloc_dma()`.

**Test**: ASM4242 reports 174 buffers, requesting 172 credits: before fix reads 44 (172 & 0x7f), after fix reads 127.

---

## 0006 — Use min() for Credit Cap

**File**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**Note**: Simplify credit cap calculation using min() function.

---

## 0009/v3 — Release Rx HopID

**File**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**Issue**:

- `tb_xdomain_alloc_in_hopid()` passes desired HopID as lower bound to allocator, returns first free ID above it
- `tbnet_connected_work()` expects specific ID, treats any other as failure
- Allocated ID is never released, stays live for entire XDomain connection with no refcount

**Fix**: Release ID when it's not the one we asked for.

**Fixes**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

---

## 0010/v3 — Mark Connection Down

**File**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**Issue**:

- All failure paths in `tbnet_connected_work()` fail to clear `login_sent` flag
- Connection still looks established
- Subsequent `tbnet_tear_down()` repeats teardown: stops already-stopped rings (triggers dev_WARN), releases HopID we never owned

**Fix**: Clear `login_sent` flag on these failure paths, let `tbnet_tear_down()` skip this connection.

**Fixes**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

---

## 0011 — Report Teardown Failures

**File**: `0011-thunderbolt-Report-DMA-path-teardown-failures-to-the.patch`

**Issue**:

- `tb_disconnect_xdomain_paths()` unconditionally returns 0
- Internal failures (hop refuses drain, `-ETIMEDOUT`) hidden
- Connection manager reports success, upper layer tbnet sees nothing

**Fix**:

- Propagate first error seen while deactivating hops
- Return value flows through `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()`
- Teardown still runs to completion (paths marked inactive, credits released, tunnel freed)
- Only changes return value; callers that check it now get truth

---

## 0012/v2 — ASM4242 Pending Bit Quirk

**File**: `0012-v2-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**Issue**:

- ASM4242 host interface adapter's pending bit latches after enough frames through DMA ring, never clears again
- Every teardown waits full 500ms before timeout
- Frequent down/up cycles accumulate many timeouts

**Observation**:

- Bit behaves in two regimes, frame count determines transition
- Ring size determines frame threshold (ring 128 ~120 frames, ring 256 ~260 frames)
- Other hops clear normally, only host adapter affected

**Fix**: Add quirk for ASM4242 to skip pending bit wait on this special host adapter.

---

## Patch Relationships

All patches are independent:

| Patch | Dependencies | Order |
|---|---|---|
| 0001 | None | Any |
| 0003/v2 | None | Any |
| 0004/v2 | None | Any |
| 0006 | Optional after 0004 | After 0004 |
| 0009/v3 | None | Any |
| 0010/v3 | Requires 0009/v3 | After 0009 |
| 0011 | None | Any |
| 0012/v2 | None | Any |

---

---

## 日本語

### 概要

ASMedia ASM4242 USB4 でホスト間に直接接続された 2 台のマシンで `thunderbolt-net` を実行。
このハードウェアで複数の欠陥を発見し、対応するパッチを用意しました:

- **0001**: E2E フロー制御(TX リング)ベンダー回避策
- **0003/v2**: DMA パス破棄順序の修正
- **0004/v2**: DMA トンネルクレジットをレジスタ容量に制限
- **0006**: DMA パスクレジット上限に min() を使用
- **0009/v3**: 割り当てミスマッチ時の Rx HopID を解放
- **0010/v3**: ブリングアップ失敗時に接続を down にマーク
- **0011**: DMA パス破棄失敗を呼び出し者に報告
- **0012/v2**: クリアされない ASM4242 pending bit に対応

> **重要**: パッチは独立しており、異なる問題を解決し、任意の順序で適用できます。

---

## 0001 — E2E on TX (ベンダー回避策)

**ファイル**: `0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**問題**: アップストリームが `RING_FLAG_E2E` を TX リングにも追加します。USB4 仕様によれば、TX リングで E2E を有効にするには送信前にエンドツーエンドクレジットを取得する必要があります。
しかし ASM4242 は **E2E クレジットを生成しない** → TX コンシューマが永続的に停止、大きなフローが通過できません。

**ステータス**: アップストリームコミットは Intel では正しく、これは ASMedia 固有の回避策で、アップストリームではマージされない可能性があり、ローカル使用のみです。

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

---

## 0004/v2 — DMA トンネルクレジットを制限

**ファイル**: `0004-v2-thunderbolt-Clamp-DMA-tunnel-credits-to-what-a-ho.patch`

**問題**:

- `struct tb_regs_hop::initial_credits` は 7 ビット幅(最大 127)
- `dma_credits` モジュールパラメータも host router の `baMaxHI` も上限チェックがありません
- オーバーサイズ値は `tb_path_activate()` がレジスタに書き込むときに切り詰められ、パスは間違ったクレジット数で実行されます

**修正**: `tb_tunnel_alloc_dma()` でクレジットを 127 に制限します。

**テスト**: ASM4242 は 174 バッファを報告、172 クレジットをリクエスト: 修正前は 44(172 & 0x7f)を読み取り、修正後は 127 を読み取ります。

---

## 0006 — min() を使用してクレジット上限を計算

**ファイル**: `0006-thunderbolt-Use-min-for-the-DMA-path-credit-cap.patch`

**注記**: min() 関数を使用してクレジット上限計算を簡略化します。

---

## 0009/v3 — Rx HopID を解放

**ファイル**: `0009-v3-net-thunderbolt-Release-the-Rx-HopID-that-was-hand.patch`

**問題**:

- `tb_xdomain_alloc_in_hopid()` は目的の HopID をアロケータの下限として渡し、その上の最初の空き ID を返します
- `tbnet_connected_work()` は特定の ID を期待し、他の ID を失敗として扱います
- 割り当てられた ID は解放されず、XDomain 接続全体にわたって生き続け、参照カウンターがありません

**修正**: 要求した ID でない場合は ID を解放します。

**修正対象**: `180b0689425c` ("thunderbolt: Allow multiple DMA tunnels over a single XDomain connection")

---

## 0010/v3 — 接続を down にマーク

**ファイル**: `0010-v3-net-thunderbolt-Mark-the-connection-down-when-brin.patch`

**問題**:

- `tbnet_connected_work()` のすべての失敗パスが `login_sent` フラグをクリアしません
- 接続はまだ確立されているように見えます
- その後の `tbnet_tear_down()` は破棄を繰り返します: 既に停止しているリングを停止(dev_WARN をトリガー)、所有していない HopID を解放します

**修正**: これらの失敗パスで `login_sent` フラグをクリアし、`tbnet_tear_down()` がこの接続をスキップするようにします。

**修正対象**: `e69b6c02b4c3` ("net: Add support for networking over Thunderbolt cable")

---

## 0011 — 破棄失敗を報告

**ファイル**: `0011-thunderbolt-Report-DMA-path-teardown-failures-to-the.patch`

**問題**:

- `tb_disconnect_xdomain_paths()` は無条件に 0 を返します
- 内部失敗(hop が drain を拒否、`-ETIMEDOUT`)は隠されます
- 接続マネージャーはすべてのエラーを成功として報告し、その上層 tbnet は何も表示されません

**修正**:

- hop を無効化する際に見られた最初のエラーを伝播します
- 戻り値は `tb_path_deactivate()` → `tb_tunnel_deactivate()` → `tb_deactivate_and_free_tunnel()` を通じて流れます
- 破棄は依然として完了まで実行されます(パスは inactive にマーク、クレジット解放、トンネル解放)
- 戻り値のみが変わり、チェックする呼び出し元は真実を取得します

---

## 0012/v2 — ASM4242 Pending Bit Quirk

**ファイル**: `0012-v2-thunderbolt-Stop-waiting-on-a-path-pending-bit-tha.patch`

**問題**:

- ASM4242 host interface adapter の pending ビットは DMA リングを十分なフレーム数が通過した後にラッチし、二度とクリアされません
- すべての破棄は 500ms 待機してからタイムアウトします
- 頻繁な down/up サイクルは多くのタイムアウトを累積します

**観察**:

- ビットは 2 つのレジーム で動作し、フレーム数が遷移を決定します
- リングサイズがフレームしきい値を決定します(リング 128 ~120 フレーム、リング 256 ~260 フレーム)
- 他の hop は正常にクリアされ、host adapter のみが影響を受けます

**修正**: ASM4242 の quirk を追加して、この特別な host adapter での pending ビット待機をスキップします。

---

## パッチの関係

すべてのパッチは独立しています:

| パッチ | 依存関係 | 順序 |
|---|---|---|
| 0001 | なし | 任意 |
| 0003/v2 | なし | 任意 |
| 0004/v2 | なし | 任意 |
| 0006 | 0004 の後で依存 | 0004 の後 |
| 0009/v3 | なし | 任意 |
| 0010/v3 | 0009/v3 が必須 | 0009 の後 |
| 0011 | なし | 任意 |
| 0012/v2 | なし | 任意 |
