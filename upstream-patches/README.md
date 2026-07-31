# thunderbolt-net 补丁集(ASM4242 / USB4 host-to-host)

两台主机经板载 **ASMedia ASM4242** USB4 直连,跑 `thunderbolt-net`。
在这套硬件上发现两个缺陷,对应两个补丁。

> **两个补丁相互独立,不要绑在一起看。**
> 各自解决不同的问题、各自能单独应用、各自单独验证过。
> 尤其 `0003` 是可提交上游的通用 bugfix,**不依赖** `0001` 那个厂商 workaround ——
> 已在**纯净 v6.17 树**(E2E 保持上游原状)上单独编译验证。

---

## 0003 — 拆除顺序(拟以 RFC 发上游)

`0003-net-thunderbolt-Tear-down-DMA-paths-before-stopping-t.patch`

**为什么发 RFC 而不是 PATCH**:唯一的短板是**没有 Intel host router 做回归对照**
(tbnet 维护者在 Intel,这是他第一个会问的)。与其发 PATCH 然后被要求补测,
不如以"我在 ASMedia 上观察到这个、机制分析如下、但无 Intel 硬件、请指教"的姿态发出去 ——
维护者手上就有 Intel 设备,他们一测便知。

**提交时不要提 0001**:0001 是本机自用的厂商 workaround,与本 bug 无关。
提了只会让维护者怀疑"你的环境不干净,谁知道是不是那个 revert 引起的"。
这也正是要在**纯净 v6.17 树**上单独验证的原因 —— 见下面「独立性验证」。

投递:`netdev@vger.kernel.org` + `linux-usb@vger.kernel.org`,
CC Mika Westerberg / Andreas Noever,主题 `[RFC PATCH net]`。

**问题**:`tbnet_tear_down()` 先 `tb_ring_stop()` 再 `tb_xdomain_disable_paths()`。
停 ring 会清零 descriptor base,其后备页随即被 dma_unmap_page + __free_pages,在飞的 DMA 从此无处可落;
随后 `__tb_path_deactivate_hop()` 轮询 hop 的 `pending` 位,在某些 host router 上
永远等不到清零,烧满 500ms 超时后 `-ETIMEDOUT`。

**状态**:基于 mainline 生成,带 `Fixes: 4944269305df`("thunderbolt: Properly disable path",
2019-04-18,v5.2 引入 drain-wait 的那个 commit)。**不是** tbnet 初版 `e69b6c02b4c3`——
初版那会儿 `__tb_path_deactivate_hop()` 还没有 pending-bit 轮询,是 4944269305df 才加上的,
所以失败模式由它引入,Fixes 应指向它。mainline master 至今仍是原顺序。

### 独立性验证(关键)

在 **v6.17 原版树**上只应用本补丁,**完全不碰 E2E**:

| 模块 | E2E 状态 | 顺序 | `__tb_path_deactivate_hop` 返回值 | `down` |
|---|---|---|---|---|
| v6.17 原版 | 上游原状(带 E2E) | 原顺序 | `0`,然后 **`-110`** | 0.503s |
| v6.17 + 仅 0003 | **上游原状(带 E2E)** | 修复 | `0`,然后 **`0`** | **0.003s** |

两个模块出自同一棵树,机器码级**唯一差异是 `tbnet_tear_down`**。
=> **0003 单独就能修复,不需要 0001。**

### 其余证据

- **发行版原封不动的模块**(Ubuntu `D7911981177766626E5B3E0`)3 轮全部 `-ETIMEDOUT`
  —— bug 存在于每个人正在跑的内核里,不是自编译引入的。
- ABBA 对照(每档 4 轮 × 三档负载,每轮前验证链路 up 且带流量):

  | 负载 | 未打补丁 | 打上补丁 |
  |---|---|---|
  | idle | 中位 0.503s,失败 8/8 | 中位 0.003s,失败 0/8 |
  | light | 0.503s,7/7 | 0.003s,0/8 |
  | heavy | 0.503s,6/6 | 0.003s,0/8 |

  ⚠️ 未打补丁的组里,**只有 light 与 heavy 被链路打死而提前中止**(各 1 个臂),
  **idle 那档 4 轮全部跑完、链路未死**。每档仅 1 次死亡观测、idle 右删失、
  三档按顺序跑未随机化 —— **方向与机制一致,但不能当成实测的剂量效应**。

### 为什么能藏 7 年

1. **失败是静默的** —— 内层 `-ETIMEDOUT`,而 `tb_xdomain_disable_paths()` 仍返回 **0**,
   tbnet 只在返回非 0 时 `netdev_warn`,于是用户空间和驱动层都看不见;
2. **只在不容忍的硬件上触发** —— Intel host router 能在 500ms 内排空,ASMedia 排不空;
3. **单次无感** —— 要反复 `down/up` 才累积到打死 XDomain,正常使用不会反复拆网卡。

---

## 0001 — E2E on TX(厂商 workaround,不指望上游收)

`0001-Revert-net-thunderbolt-Enable-end-to-end-flow-contro.patch`

**问题**:上游把 `RING_FLAG_E2E` 也加到 TX 环。按 USB4 规范,TX 环开 E2E 就必须先拿到
端到端信用才能发;而 ASM4242 **从不产生 E2E 信用** → TX 消费者永久停摆、大流量传不动。

**状态**:那个上游 commit 在 Intel 上是**正确的**,这是 ASMedia 专属 workaround,
**上游大概率不收**。本机自用。

独立印证:`hellas-ai/thunderbolt-ibverbs` 的 `tbv_native_e2e_auto_enabled()` 按厂商关 E2E,
注释提到 "Strix Halo has reproduced TX completion wedges with multiple native E2E rings active"。

---

## 两者的关系

**没有依赖关系。** 各自独立应用、独立生效:

- 只打 0003:拆除干净了,但 ASM4242 上大流量仍传不动(E2E 问题还在)
- 只打 0001:能传数据了,但反复 `down/up` 仍会把 XDomain 打死
- 本机两个都打,是因为这套硬件两个毛病都有 —— **不是因为它们互相需要**

hunk 位置也不重叠(0001 在 `tbnet_open`,0003 在 `tbnet_tear_down`),
可按任意顺序应用,已实测共存无冲突。

---

## 已作废,不要发

| 文件 | 原因 |
|---|---|
| `0001-SUPERSEDED-do-not-enable-E2E-on-Tx-*.patch` | 被 `0001-Revert-*` 取代 |
| `0002-SUPERSEDED-hand-written-*.patch` | 手写版,已废 |
| `0001-thunderbolt-nhi-re-kick-TX-ring-doorbell-*.patch` | 复评为冗余(E2E revert 落地后 `kick_stuck=0`) |
| `dma-wall-rescue-worktree.patch` | 5.1G 带宽墙的实验残留,非修复 |

## 模块身份对照(本机)

**按实际源码内容核实(2026-07-31),不要信目录名:**

| 目录 / 模块 | srcversion | 拆除顺序 | MAC ndo | TX E2E |
|---|---|---|---|---|
| 发行版原版 | `D7911981177766626E5B3E0` | 原顺序 | 无 | 带 E2E |
| `v617-independence/v617-stock.ko` | `5F59B1ACF3F639A7FCC48EA` | 原顺序 | 无 | 带 E2E |
| `v617-independence/v617-fix.ko` | `AFB83C35024747B5A67D991` | **已修复** | 无 | 带 E2E |
| `tbnet-ctrl` | `695E9AC63CB1D9B494DCA04` | 原顺序 | 有 | 已 revert |
| `tbnet-orderswap` | `B5B3B9087470F3CDF56F427` | **已修复** | 有 | 已 revert(**生产在用**) |
| `tbnet-macfix` | `AFB83C35024747B5A67D991` | **已修复** | **无** | **带 E2E** |
| `tbnet-test` | (无 .ko) | 原顺序 | 无 | 已 revert |

⚠️ **`tbnet-macfix` 这个目录名是误导的**:它里面**没有** MAC 修复,也**没有** E2E revert,
实际内容 = **v6.17 原版 + 仅 0003**,与 `v617-fix.ko` 机器码完全相同(srcversion 也相同)。
这个目录是调查早期留下的,名字起错了。**以内容为准,不要以目录名为准。**

⚠️ **`srcversion` 对注释不敏感**:实测改了代码注释后重新编译,srcversion 与机器码均不变。
它能区分"代码逻辑变了",但**不是源码内容的唯一指纹** —— 做模块身份核对时要意识到这一点。

> 另有一处非上游改动:`.ndo_set_mac_address = eth_mac_addr`。
> mainline 已有此行,属 6.17 backport 落后,**不需要提交**。
> 没有它 `ip link set thunderbolt0 address` 返回 -95,TB 进不了 bond。
