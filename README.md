# tb-build

Research notes, scripts, and kernel patches from debugging and tuning the
Linux `thunderbolt` / `thunderbolt_net` (tbnet) drivers over a direct
USB4/Thunderbolt link between two Linux hosts.

**English** | [中文](#中文) | [日本語](#日本語)

---

## English

### What is this

A small, unofficial working set used to chase a hard throughput ceiling on
`thunderbolt-net` (tbnet) links and to test kernel-side fixes against it —
not a packaged project, no support implied.

### Contents

- `tb-dma-credits.sh` — reloads the `thunderbolt` module with a given
  `dma_credits` value and waits for the `thunderbolt0` link to come back up.
  Used to test whether tbnet's single-stream throughput ceiling scales with
  the DMA credit count (in-flight 256B credits vs. the host controller's
  credit-return latency).
- `swap-tb.sh` / `swap-tb-hostB.sh` — swap a locally-built, patched
  `thunderbolt.ko` / `thunderbolt_net.ko` into `/lib/modules/$(uname -r)/updates/`
  (which takes priority over the distro-shipped module) on each of the two
  test hosts, with a one-line rollback. They expect the patched modules to
  already be built from a patched kernel source tree (not included here —
  see `patches/` and `upstream-patches/` below) at the `SRC` path set near
  the top of each script; adjust it to match your own build layout.
- `monitor*.log` — sample output from watching link renegotiation across a
  handful of DMA-credit values.
- `patches/` — upstream Thunderbolt/USB4 kernel patches (from LKML) used as
  a reference/cherry-pick set while building a testing kernel.
- `upstream-patches/` — an original patch: `thunderbolt: nhi: re-kick TX ring
  doorbell on missed producer update`. Fixes a spurious ~200ms stall on a
  small fraction of tbnet round trips, caused by the ASM4242 USB4 host
  router occasionally not acting on a TX ring doorbell write. Not yet sent
  upstream.

### Status

Experimental / research only. Scripts assume root, a matching kernel
version between host and prebuilt module (`vermagic`), and two hosts
directly connected over Thunderbolt/USB4. The `.patch` files are
GPL-2.0-only, matching the licensing of the kernel sources they target.

---

## 中文

### 这是什么

一组非正式的调试笔记、脚本和内核补丁,用来排查两台 Linux 主机通过 USB4/Thunderbolt
直连时 `thunderbolt` / `thunderbolt_net`(tbnet)驱动的吞吐硬顶问题,并测试针对性的
内核修复。不是打包发布的正式项目,不提供支持。

### 目录内容

- `tb-dma-credits.sh` — 用指定的 `dma_credits` 值重载 `thunderbolt` 模块,并等待
  `thunderbolt0` 链路重连。用来验证 tbnet 单流吞吐硬顶是否随 DMA 信用数线性变化
  (在途 256B 信用 vs. 主控芯片的信用返还延迟)。
- `swap-tb.sh` / `swap-tb-hostB.sh` — 把本地编译好的、打过补丁的 `thunderbolt.ko` /
  `thunderbolt_net.ko` 放进 `/lib/modules/$(uname -r)/updates/`(优先级高于发行版
  自带模块),分别用于两台测试主机,可一行回退。脚本假设补丁模块已经从打过补丁的
  内核源码树构建好(源码树本身未包含在本仓库中,见下面的 `patches/` 和
  `upstream-patches/`),构建产物路径写在每个脚本开头的 `SRC` 变量里,需按你自己的
  构建目录调整。
- `monitor*.log` — 在几个不同 DMA 信用值下观察链路重新协商的样例输出。
- `patches/` — 来自 LKML 的上游 Thunderbolt/USB4 内核补丁,构建测试内核时作为参考
  / cherry-pick 集合使用。
- `upstream-patches/` — 一个原创补丁:`thunderbolt: nhi: re-kick TX ring doorbell
  on missed producer update`。修复了 ASM4242 USB4 主控芯片偶尔不响应 TX 环形缓冲区
  门铃写入,导致极小比例的 tbnet 往返出现约 200ms 虚假停顿的问题。尚未提交上游。

### 状态

仅供实验/研究用途。脚本假设以 root 运行、主机内核版本与预编译模块的 `vermagic`
匹配、且两台主机通过 Thunderbolt/USB4 直连。`.patch` 文件采用 GPL-2.0-only 许可,
与其所针对的内核源码许可一致。

---

## 日本語

### これは何か

2 台の Linux ホストを USB4/Thunderbolt で直結した際に発生する `thunderbolt` /
`thunderbolt_net`(tbnet)ドライバのスループット上限を調査し、その修正を検証するための、
非公式な作業記録・スクリプト・カーネルパッチ一式です。パッケージ化された正式プロジェクト
ではなく、サポートは提供されません。

### 内容

- `tb-dma-credits.sh` — 指定した `dma_credits` 値で `thunderbolt` モジュールを
  再読み込みし、`thunderbolt0` リンクの復帰を待ちます。tbnet の単一ストリーム
  スループット上限が DMA クレジット数(転送中の 256B クレジット数 vs. ホスト
  コントローラのクレジット返却レイテンシ)に比例するかを検証するためのものです。
- `swap-tb.sh` / `swap-tb-hostB.sh` — ローカルでビルドしたパッチ適用済みの
  `thunderbolt.ko` / `thunderbolt_net.ko` を `/lib/modules/$(uname -r)/updates/`
  (ディストリビューション標準モジュールより優先される)に配置します。2 台の
  検証ホストそれぞれ用で、ワンライン・ロールバック付きです。パッチ済みモジュールは
  パッチ適用済みのカーネルソースツリー(本リポジトリには含まれません。下記の
  `patches/` および `upstream-patches/` を参照)から事前にビルドされている前提で、
  各スクリプト冒頭の `SRC` 変数のパスを自分のビルド構成に合わせて調整してください。
- `monitor*.log` — いくつかの DMA クレジット値でリンク再ネゴシエーションを
  観察したサンプル出力。
- `patches/` — テスト用カーネルをビルドする際の参考/cherry-pick 用として使った、
  LKML 由来の上流 Thunderbolt/USB4 カーネルパッチ。
- `upstream-patches/` — オリジナルのパッチ:`thunderbolt: nhi: re-kick TX ring
  doorbell on missed producer update`。ASM4242 USB4 ホストルーターが TX リング
  のドアベル書き込みに対して稀に反応しないことが原因で、tbnet の往復通信のごく
  一部に約 200ms の疑似スタントが発生する問題を修正します。上流にはまだ未送信です。

### ステータス

実験・研究目的のみ。スクリプトは root 権限での実行、ホストとビルド済みモジュール間の
カーネルバージョン(`vermagic`)の一致、そして 2 台のホストが Thunderbolt/USB4 で
直結されていることを前提としています。`.patch` ファイルは対象のカーネルソースと同じ
GPL-2.0-only ライセンスです。
