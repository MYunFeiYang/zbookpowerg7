固件台账 · 证据包 README
==========================
建立：2026-09-20 10:2x
对应正文：docs/firmware-facts-ledger.md
本轮**零配置 / 零 EFI 改动**；所有命令均为只读。

—— 文件清单 ——
  01-ioreg-efi-node.txt               macOS 侧真实固件标识（firmware-vendor / firmware-revision）+ system_profiler 假值对照
  02-win-hive-systeminformation.txt   Windows SYSTEM hive 的 SystemInformation 解码 + HP 固件包 .inf 全文关键段
  03-hp-setup-varnames-01.24.02.txt   本机 01.24.02 的 HpSetup 复核（标识符命中 / 变量名表 / UI 邻接 / 三语互斥文案 / 无 HII 判据 / 明文标识符归属）
  04-firmware-image-sha256.txt        本机实跑固件镜像的存证（sha256 / 大小 / 出处 / 与旧样本的差异）

—— 一键复验（全部只读）——
  # 1) 真实 BIOS 版本（macOS 侧，不用进 Windows）
  ioreg -p IODeviceTree -n efi -r -d 1 -w0 | grep -aE 'firmware-(vendor|revision)'

  # 2) Windows 卷是否可控（本机平时就只读挂载）
  mount | grep TZBOOK

  # 3) hive 交叉验证（注意 hive 文件名是小写）
  ls -la /Volumes/TZBOOK/Windows/System32/config/ | grep -E ' (system|software)$'

  # 4) 本机实跑固件镜像是否还在盘上
  shasum -a 256 "/Volumes/TZBOOK/Windows/System32/DriverStore/FileRepository/t75_01240200.inf_amd64_42ecb2ad108e0833/T75_01240200.bin"
  # 期望：f89292026932be691d59904311cb50b4fbc55379aa554f89479665e04ae6970b

  # 5) 重新解包（若要复核固件结构）
  #    UEFIExtract NE A75（universal_mac）：
  #    ./UEFIExtract T75_01240200.bin all     → .dump/ + .report.txt + .guids.csv

—— ⚠️ 复验时的已知坑（详见 docs/tooling-gotchas.md）——
  · 内置 Grep 工具**不搜二进制文件**⇒ 对固件 dump 会给出**假否定**。必须用 Python 字节级检索或 `grep -a`。
  · 15,718 文件 / 302 MB 的 dump 上跑递归全量扫描（Python os.walk 或 grep -r）会被**沙箱 SIGKILL（exit 137）**。
    省力替代：① `grep -r "<模块GUID>" --include=info.txt <dump>` 反查模块目录；② 只在单模块 `body.bin`（1–2 MB）上搜；
              ③ 原始镜像里的明文标识符可直接单文件搜（本包 03 号证据 D 段就是这么拿到的）。
  · 固件里**两套命名并存**：UI 文本 = UTF-16LE、内部标识符 = ASCII。只搜一种会漏掉最有力的证据。
  · 0 命中必须配**正向对照**才作数（本包 02 号证据 C 段示范）。

—— 来源分级（沿用项目纪律）——
  可当判据：本机 EFI System Table 读数、Windows 卷上的 HP 官方 .inf/.cat、固件镜像自身的字符串与结构
  仅方向：厂商文档（QuickSpecs）、单篇技术博客
  不可用：AI 内容农场
