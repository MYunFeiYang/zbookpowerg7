# boot-args 审计：32 条 → 15 条（2026-11-24）

> 目标：只删「在本机当前状态下不可能起作用」的参数，其余一律保留并写明理由。
> 判据分级：①源码 ②上游文档原文 ③本机实测事实。凡把握 <80% 的一律标「未知」，不当结论用。

## 0. 结论

| 项 | 数值 |
|---|---|
| 改前 | 32 条 |
| 改后 | **15 条** |
| 删除 | 17 条 `-itlawdl*` + `itlawdlintcoal=4` 等（见 §3） |
| 保留不动 | 15 条（每条都有证据，见 §2） |
| 前置动作 | ForbiddenItlwm 0.6.0-beta.4 → **0.7.0-alpha.2**；BTLEAdvFixup 0.9.4 → **0.9.6** |

**为什么这些能删**：那 17 条是 ForbiddenItlwm **旧版**的 AWDL 测试集。官方 `docs/BOOT-FLAGS.md` 原文：

- 「0.7.0-alpha.2 及以后：**无必需 flag**（唯一例外：`-btleadv`）。测试集已内置为默认行为，包括 `itlawdlintcoal=4` 与 `itlawdltxqueue=4096`」
- 「0.7.0-alpha.1 及更早：**整套测试集，缺一不可**。不加任何 flag 时，行为等同 AirportItlwm，AirDrop 关闭」

⇒ 在 0.6.0-beta.4 上删它们是**错的**（AirDrop 直接失效）；只有先升级，这些参数才变成纯冗余。
官方还写明升级后「旧测试集的每个 flag 仍被读取且不改变任何行为」，所以删除本身不承担行为差异。

## 1. 取证方法

逐个 boot-arg 在**加载的 kext 二进制里搜字符串**，先确定「谁在解析这条参数」——没有解析者的才是真死参数：

```bash
for d in EFI/OC/Kexts/*.kext; do
  for f in "$d"/Contents/MacOS/*; do
    strings -a "$f" | grep -q -F -- "$key" && echo "命中 $(basename $d .kext)"
  done
done
```

结果：**32 条全部命中某个已加载 kext**（`keepsyms=1` 除外，它由 XNU 解析）。
⇒ 第一步就排除了「参数名写错 / 驱动已删除」这一整类死参数。

然后对每条查上游源码或 README 判定生效条件是否成立。证据源：

| 来源 | 用法 |
|---|---|
| `WhateverGreen/kern_igfx_backlight.cpp`（master，本地拉取） | L38 `-igfxblr`、L247 `-igfxblt` 的解析与平台门控 |
| `WhateverGreen/kern_igfx_pm.cpp` L142 | `igfxrpsc` → `enabled = rpsc > 0 && available` |
| `WhateverGreen/kern_igfx.cpp` L119–137（CometLake 分支） | `modRPSControlPatch.available = true` |
| `Lilu/README.md` L27–28 | `-lilubeta` / `-lilubetaall` 的触发条件 |
| `RestrictEvents/README.md` L31 | `revpatch=sbvmm` 的作用 |
| `BrcmPatchRAM/README.md` L265 | `-btlfxallowanyaddr` 的触发条件 |
| `ForbiddenItlwm/docs/BOOT-FLAGS.md` | 17 条 itlawdl 的归属与版本规则 |
| 本机 `ioreg` / `kmutil` / `uname` | 硬件与加载事实 |

## 2. 保留的 15 条（逐条理由）

| 参数 | 归属 | 判定依据 |
|---|---|---|
| `-igfxblr` | WhateverGreen | 源码 L38，CFL 背光寄存器修复。与 BLT 功能重叠，但删错的表现是**开机背光黑屏**，收益为零 ⇒ 保留 |
| `-igfxblt` | WhateverGreen | 源码 L247 + 注释：macOS 13.4 起 Apple 把寄存器写内联进 `hwSetBacklight`，BLR 的 hook **失效**，由 BLT 接管。本机 Darwin 25 ⇒ 这是实际生效的那条 |
| `-igfxhdmidivs` | WhateverGreen | README：修 SKL/KBL/CFL 平台「高像素时钟 HDMI 连接死循环」；本机 CFL 系 + HDMI 1080p60（148.5MHz）正属该场景 |
| `igfxonln=1` | WhateverGreen | 修 IGPU 唤醒 panic（前情见 `docs/hdmi-audio-a348-spoof-2026-11-24.md` §12） |
| `igfxonlnfbs=0` | WhateverGreen | 只对内建强制 online，外接恢复真实检测（同上 §12.10） |
| `igfxrpsc=1` | WhateverGreen | CometLake 分支 `available = true`（源码 L135）⇒ 真的会打补丁，提升 iGPU 性能 |
| `-amfipassbeta` | AMFIPass 1.4.1 | 绕过内核版本检查使 kext 在未声明支持的版本上加载；去掉后若 kext 不加载，依赖 AMFI 放行的功能会坏 ⇒ 保留 |
| `-lilubetaall` | Lilu | **未知（~70% 已无用）**：Lilu README 写明「macOS 26 及以下默认启用」，触发条件「不受支持的系统」当前为假。但它对版本较旧的插件仍是保险，删掉的收益为零、代价是插件静默不加载 ⇒ 保留并标注 |
| `revpatch=sbvmm` | RestrictEvents | README L31：「forces VMM SB model, allowing **OTA updates for unsupported models**」。本机 `MacBookPro16,4` 在 Tahoe 已属不受支持机型 ⇒ 正需要 |
| `rtcfx_exclude=0E-FF` | RTCMemoryFixup | 屏蔽 RTC 存储区写入，否则会踩 POST 005 起不来 ⇒ 安全网，保留 |
| `keepsyms=1` | XNU | panic 时保留符号，本机长期在查 panic ⇒ 保留 |
| `-vi2c-force-polling` | VoodooI2C | 强制 I2C 轮询；是否可去掉必须实测触控板，无法静态证伪 ⇒ 保留 |
| `-btlfxallowanyaddr` | BlueToolFixup_Mod | BrcmPatchRAM README L265：仅在「**两台蓝牙设备地址相同**」触发地址检查时才需要；本机单控制器 ⇒ 条件基本为假，但蓝牙已关档、不值得为省一条参数去冒险 ⇒ 保留并标注 |
| `-tgldmiclilu` | TGLDmic 0.6.4 | 本机实测 `ioreg -rc TGLDmic`：`PlatformFamily = Comet Lake / Cannon Lake (cAVS 1.8)`、`Ready = Yes` ⇒ 内建数字麦克风真的靠它，**不是** Tiger Lake 遗留物 |
| `-btleadv` | BTLEAdvFixup | 官方文档：开启 BTLEAdvFixup 使 `bluetoothd` 能在 Intel 网卡上启动 BLE 广播；0.7.0-alpha.2 起是**唯一仍需手写**的 flag |

## 3. 删除的 17 条

`-itlawdlcoexprobe -itlawdliface -itlawdlnativeup -itlawdlcoexrx -itlawdlcoextx -itlawdlcoexmulti -itlawdlcoexdata -itlawdlmitx -itlawdlelicit -itlawdlcaps -itlawdlsvcmerge -itlawdlawsync itlawdlintcoal=4 -itlawdlcoexbatx -itlawdlcoexpeerpause -itlawdlcoexbatrace itlawdltxqueue=4096`

全部是 0.6.0-beta.4 时代的 AWDL 测试集成员；0.7.0-alpha.2 已内置为默认值（`itlawdlintcoal=4`、`itlawdltxqueue=4096` 的默认值就是这两个数）。

⚠️ 注意：在 0.6.0-beta.4 上**不能**删——那时它们不是默认值而是开关，删掉即 AirDrop 失效。

## 4. 本次改动

| 项 | 内容 |
|---|---|
| kext | `ForbiddenItlwm.kext` 0.6.0-beta.4 → **0.7.0-alpha.2**（`CFBundleVersion` 0.7.0） |
| kext | `BTLEAdvFixup.kext` 0.9.4 → **0.9.6** |
| 来源 | GitHub release `v0.7.0-alpha.2`（2026-11-24 04:32），官方 asset `*-Tahoe.zip` |
| 校验 | 两个 zip 的 SHA-256 与 release 里的 `SHA256SUMS.txt` **逐字符一致** |
| bundle id | 未变（`org.forbiddenitlwm.*`）⇒ `Kernel/Add` 路径无需改动 |
| 内核范围 | 条目 `MaxKernel` 仍是 `25.99.99`；本机 `uname -r` = **25.6.0**（macOS 26 的内核是 Darwin 25）⇒ 仍在范围内 |
| config 注释 | 两条 `Comment` 同步为 0.9.6 / 0.7.0-alpha.2 |
| 双写 | workspace 与 ESP 的 config、两个 kext 全部 sha 一致；`diff -rq EFI/OC /Volumes/ESP/EFI/OC` 无差异 |
| 语法 | `plutil -lint` OK；config diff 仅 3 行（1 行 boot-args + 2 行 Comment） |
| 改前 sha | config `c1d12c77…bf0669` |
| 改后 sha | config `d974207c…a74f1a7` |

## 5. 生效验证（需重启一次）

重启后依次确认：

```bash
# 1. Wi-Fi 正常（能连上、能上网）
# 2. 驱动版本确实换了
ioreg -l -w0 | grep -E '"ItlwmAWDL(InterfaceBuild|BuildCheck|Defaults)"'
#    InterfaceBuild 应为 0.7.0-alpha.2；BuildCheck 应为 verified
# 3. AWDL 接口在
ifconfig awdl0
# 4. AirDrop 双向实测（Mac ↔ iPhone）
```

## 6. 回滚

```bash
cd /Volumes/Common/workplace/zbookpowerg7
cp -R ~/automation-workspace/wifi-kext-rollback-0.6.0b4/*.kext EFI/OC/Kexts/
cp EFI/OC/Kexts/ForbiddenItlwm.kext -R /Volumes/ESP/EFI/OC/Kexts/
# boot-args 复原
/usr/libexec/PlistBuddy -c "Set :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args $(cat ~/automation-workspace/wifi-kext-rollback-0.6.0b4/boot-args.before.txt)" EFI/OC/config.plist
```

或直接 `git checkout` 上一版 `EFI/OC/Kexts/ForbiddenItlwm.kext EFI/OC/Kexts/BTLEAdvFixup.kext EFI/OC/config.plist`（git 里有 0.6.0-beta.4 完整原件）。
