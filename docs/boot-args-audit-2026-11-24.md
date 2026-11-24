# boot-args 审计：32 条 → 14 条（2026-11-24）

> 目标：只删「在本机当前状态下不可能起作用」的参数，其余一律保留并写明理由。
> 判据分级：①源码 ②上游文档原文 ③本机实测事实。凡把握 <80% 的一律标「未知」，不当结论用。

## 0. 结论

| 项 | 数值 |
|---|---|
| 改前 | 32 条 |
| 改后 | **14 条** |
| 删除 | 17 条 `-itlawdl*` + `itlawdlintcoal=4` 等（见 §3）；`igfxonln=1`（重复项，见 §8） |
| 保留不动 | 14 条（每条都有证据，见 §2） |
| 前置动作 | ForbiddenItlwm 0.6.0-beta.4 → **0.7.0-alpha.2**；BTLEAdvFixup 0.9.4 → **0.9.6** |
| 验证状态 | ✅ **已于 2026-11-24 16:03 重启验证通过，零回退**（逐项实测见 §5.2） |

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

> 后续变更：`igfxonln=1` 已删除（与属性 `force-online` 重复），见 §8；当前实为 **14 条**。

| 参数 | 归属 | 判定依据 |
|---|---|---|
| `-igfxblr` | WhateverGreen | 源码 L38，CFL 背光寄存器修复。与 BLT 功能重叠，但删错的表现是**开机背光黑屏**，收益为零 ⇒ 保留 |
| `-igfxblt` | WhateverGreen | 源码 L247 + 注释：macOS 13.4 起 Apple 把寄存器写内联进 `hwSetBacklight`，BLR 的 hook **失效**，由 BLT 接管。本机 Darwin 25 ⇒ 这是实际生效的那条 |
| `-igfxhdmidivs` | WhateverGreen | README：修 SKL/KBL/CFL 平台「高像素时钟 HDMI 连接死循环」；本机 CFL 系 + HDMI 1080p60（148.5MHz）正属该场景 |
| ~~`igfxonln=1`~~ | WhateverGreen | **已删除（§8）**：与 `DeviceProperties` 的 `force-online=<01000000>` 完全重复，WEG 源码是 if/else 二选一 |
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

## 5. 生效验证（2026-11-24 16:03 已执行，全部通过）

### 5.1 验证清单

```bash
# 1. Wi-Fi 正常（能连上、能上网）
# 2. 驱动版本确实换了
ioreg -l -w0 | grep -E '"ItlwmAWDL(InterfaceBuild|BuildCheck|Defaults)"'
#    InterfaceBuild 应为 0.7.0-alpha.2；BuildCheck 应为 verified
# 3. AWDL 接口在
ifconfig awdl0
# 4. AirDrop 双向实测（Mac ↔ iPhone）
```

### 5.2 实测结果（重启于 15:59:57，macOS 26.7.3 / Darwin 25.6.0）

| 项 | 实测值 | 判定 |
|---|---|---|
| 启动 | `kern.boottime` = 15:59:57，`/Library/Logs/DiagnosticReports` 无 panic 文件 | ✅ 无 panic |
| boot-args | `nvram boot-args` = **14 条**，不含 `igfxonln=1` | ✅ config 已写入 NVRAM |
| 驱动版本 | `kmutil`：`ForbiddenItlwm (0.7.0)`、`BTLEAdvFixup (0.9.6)` | ✅ 已换版 |
| AWDL 构建 | `ItlwmAWDLInterfaceBuild = "forbidden-0.7.0-alpha.2"`、`BuildCheck = "verified"` | ✅ |
| **AWDL 默认值** | `ItlwmAWDLDefaults = "on: the tested set needs no Wi-Fi flags"` | ✅ **驱动自证 17 条参数已内置默认** |
| AWDL 接口 | `awdl0` UP/RUNNING、`NativeUp = Yes`、`MiState = on` | ✅ |
| Wi-Fi 连接 | Connected，802.11ac，5GHz ch44 | ✅ |
| `igfxonln=1` 兜底 | `ioreg -p IODeviceTree -n IGPU -r -l` → `"force-online" = <01000000>` | ✅ 属性在，不依赖 boot-arg |
| `-tgldmiclilu` | `TGLDmic`：`LiluHook = Yes`、`LiluMode = Yes`、`PlatformFamily = Comet Lake / Cannon Lake (cAVS 1.8)` | ✅ 数字麦注入仍在 |
| `-vi2c-force-polling` | VoodooI2C 2.9.1 + VoodooI2CHID 已加载，触控板 `Magic Trackpad 2 / Transport = I2C` | ✅ |
| 蓝牙 | `State = On`（芯片报 `THIRD_PARTY_DONGLE`，Intel 卡正常识别） | ✅ |
| 显示 | 双屏 1920x1080@60，Mirror Off，内屏为主屏 | ✅ |
| 修屏 agent | pid 3839 自启；16:03:36 开机握手判 hotplug → 16:03:48 修 → `err=0/0`；8 个尾随事件被 15s 窗口吸收，未成循环 | ✅ |

**最有价值的一条是 `ItlwmAWDLDefaults`**：它由运行中的驱动自己报出「测试集已默认开启、无需任何 Wi-Fi 参数」，
等于把 §3「删掉 17 条不改变行为」从「依据官方文档推断」升级为「运行态实证」。

**仍待人工确认**（非阻塞）：① 屏幕颜色是否正常 ② AirDrop 双向 ③ 睡眠+唤醒不 panic
（③ 属 `igfxonlnfbs=0` 的独立遗留项，与本轮参数精简无关）。

## 6. 回滚

```bash
cd /Volumes/Common/workplace/zbookpowerg7
# 1. 旧 kext 回到 workspace
rm -rf EFI/OC/Kexts/ForbiddenItlwm.kext EFI/OC/Kexts/BTLEAdvFixup.kext
cp -R ~/automation-workspace/wifi-kext-rollback-0.6.0b4/ForbiddenItlwm.kext \
      ~/automation-workspace/wifi-kext-rollback-0.6.0b4/BTLEAdvFixup.kext EFI/OC/Kexts/
# 2. 双写到 ESP
rm -rf /Volumes/ESP/EFI/OC/Kexts/ForbiddenItlwm.kext /Volumes/ESP/EFI/OC/Kexts/BTLEAdvFixup.kext
cp -R EFI/OC/Kexts/ForbiddenItlwm.kext EFI/OC/Kexts/BTLEAdvFixup.kext /Volumes/ESP/EFI/OC/Kexts/
# 3. boot-args 复原（32 条原文）
/usr/libexec/PlistBuddy -c "Set :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args $(cat ~/automation-workspace/wifi-kext-rollback-0.6.0b4/boot-args.before.txt)" EFI/OC/config.plist
cp EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
plutil -lint EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
```

或直接 `git checkout <改前提交> -- EFI/OC/Kexts/ForbiddenItlwm.kext EFI/OC/Kexts/BTLEAdvFixup.kext EFI/OC/config.plist`
（git 里有 0.6.0-beta.4 完整原件），再 `cp` 同步到 ESP。

> 注：只回滚 kext 而不回滚 boot-args 也能工作——旧驱动会忽略那 17 条已删的参数名，
> 但 AirDrop 会关闭；反之只回滚 boot-args 无意义（新驱动不依赖它们）。

## 7. 还能再删吗？（2026-11-24 15:50 复核）

**结论：不建议再删。** 15 条里只有 3 条属于「当前可能无作用」，而删它们的收益是 0、风险不是 0。

| 参数 | 当前是否生效 | 判定 | 把握 |
|---|---|---|---|
| `-lilubetaall` | 可能无作用 | Lilu README L27–28：`-lilubeta` 已默认覆盖「macOS 26 及以下」；`-lilubetaall` 只在**某插件声明不支持当前 OS** 时才起作用 | ~75–80% 无作用 |
| `-igfxblr` | 很可能无作用 | WEG `kern_igfx_backlight.cpp` L247 注释（FireWolf 2023.06）：macOS 13.4 起 Apple 把寄存器写内联进 `hwSetBacklight()`，`WriteRegister32` hook 不再被调用 ⇒ BLR 失效、由 BLT 接管 | ~85% 无作用 |
| `-btlfxallowanyaddr` | 条件为假 | BrcmPatchRAM README L265：仅在「两台蓝牙设备地址相同」时绕过 `bluetoothd` 地址检查；本机单控制器 | ~80% 无作用 |

**为什么还是不删**：

1. 收益是字面意义的 0——15 条合计约 190 字节，离 NVRAM 变量上限（~1KB）很远，对启动时间影响在微秒级。
2. 三个的失效模式都不好：`-lilubetaall` 去掉后若有插件静默拒载，是**无日志的功能缺失**；`-igfxblr` 去掉后若 BLT 在某次系统更新后失效，表现是**开机背光黑屏**；`-btlfxallowanyaddr` 去掉后蓝牙问题已关档、不值得动。
3. 验证成本：每删一条都要重启一次才知道，且都属「删对了看不出、删错了很明显」。

**11 条确认在起作用（删了会坏）**（`igfxonln=1` 已按 §8 作重复项删除）：

| 参数 | 证据 |
|---|---|
| `-igfxblt` | WEG 源码：Darwin ≥ 13.4 由它接管背光寄存器修复；本机 Darwin 25 ⇒ 这是实际生效的那条 |
| `-igfxhdmidivs` | WEG README L103：修 SKL/KBL/CFL 上「高像素时钟 HDMI 连接死循环」；失效表现是**开不了机** |
| `igfxonlnfbs=0` | WEG `ForceOnlineDisplay::processKernel`：**只有写了这条 `customised` 才为真**；删掉 ⇒ 回退成「所有 framebuffer 一律强制 online」（同段还解析属性 `force-online-framebuffers`，本机**没有**该属性，所以这条不能删） |
| `igfxrpsc=1` | CometLake 分支 `available = true` ⇒ 真打 RPS 补丁 |
| `-amfipassbeta` | AMFIPass 1.4.1 的 `DTPlatformVersion = 14.2`、`BuildMachineOSBuild = 22G630`；`-amfipassbeta` 的作用是「覆盖内核版本检查」，Tahoe 上靠它才加载 |
| `revpatch=sbvmm` | RestrictEvents：让不受支持机型拿到 OTA 更新 |
| `rtcfx_exclude=0E-FF` | 屏蔽 RTC 存储区写入，踩了就是 POST 005 起不来 |
| `keepsyms=1` | panic 保留符号（本机仍在查睡眠） |
| `-vi2c-force-polling` | VoodooI2C 强制轮询；是否可去必须实测触控板 |
| `-tgldmiclilu` | ioreg 实测 `LiluHook = Yes` / `LiluMode = Yes`；kext 内有消息「Lilu hook disabled (boot without -tgldmiclilu/-tgldmicinject)」⇒ 删了内建数字麦的 AppleHDAEngine 注入就停 |
| `-btleadv` | ForbiddenItlwm 0.7.0-alpha.2 下**唯一仍需手写**的 flag |

## 8. `igfxonln=1` 已删（15 → 14，2026-11-24 15:55）

**它是唯一一条「重复表达」的参数，删掉是去重，不是赌。**

WEG `kern_igfx.cpp` L689–697 是 if / else if，二选一：

```cpp
if (PE_parse_boot_argn("igfxonln", &forceOnline, sizeof(forceOnline)))
    enabled = forceOnline != 0;                                  // boot-arg 优先
else if (WIOKit::getOSDataValue(info->videoBuiltin, "force-online", forceOnline))
    enabled = forceOnline != 0;                                  // 否则读属性
```

而本机 `DeviceProperties` 的 `PciRoot(0x0)/Pci(0x2,0x0)` 里**早就有** `force-online = <01000000>`，
且 `ioreg -p IODeviceTree -n IGPU -r -l` 实测该属性**已注入到 IGPU 节点**（不是只躺在 config 里）：

```
"force-online" = <01000000>
```

⇒ 删掉 boot-arg 后 `enabled` 仍为真，来源从 boot-arg 换成属性，`getDisplayStatus` 行为不变。
WEG README L120 也把二者列为同一功能的两种写法（`igfxonln=1` ↔ `force-online` 属性）。

**为什么保留属性、删 boot-arg**：属性是「按设备配置」，与 `ig-platform-id`、`enable-lspcon-support`
等放在一起，一眼能看出这台机器的 iGPU 配了什么；boot-arg 是全局串，两条同时存在只会有两份来源不同步的风险。

**没动的**：`igfxonlnfbs=0`。它虽然也有对应属性 `force-online-framebuffers`，但本机没有该属性，
删 boot-arg 就会回退成「全部 framebuffer 强制 online」。把它搬成属性只是搬家、不改条数，故不做。

**失效风险与验证**：改后行为应当完全无变化。若休眠唤醒出现 IGPU `SafeForceWake` MEDIA 域超时硬冻
（#967 复现），说明属性没被读到 —— 把 `igfxonln=1` 加回 boot-args 即可，一条命令。

| 项 | 值 |
|---|---|
| 改后条数 | **14 条** |
| config sha256 | `c98cf1f7…9bc37`（workspace 与 ESP 一致） |
| 其他改动 | 仅 boot-args 一行；`diff -rq EFI/OC /Volumes/ESP/EFI/OC` 无差异；`plutil -lint` 两侧 OK |

## 9. `-amfipassbeta` 与 `rtcfx_exclude=0E-FF`：都不删（2026-11-24 16:00 复核）

### 9.1 `-amfipassbeta` —— 它是 AMFIPass 在 Tahoe 上能加载的前提

| 证据 | 内容 |
|---|---|
| 本机 kext 元信息 | `AMFIPass.kext` 1.4.1：`DTPlatformVersion = 14.2`、`BuildMachineOSBuild = 22G630`、`LSMinimumSystemVersion = 10.15` |
| ioreg 运行态 | `VersionInfo = "REL-141-2024-06-28"`、`IOMatchedAtBoot = Yes` ⇒ 靠 boot 时的这条 flag 才匹配起来 |
| 二进制 | 只导出 `-amfipassoff` / `-amfipassdbg` / `-amfipassbeta` 三个旗，无其他开关 |
| 上游说明 | 该旗的作用是**覆盖内核版本检查**，让 kext 在「尚未声明支持」的 macOS 上加载 |

⇒ 这个 2024-06 编译的 kext 不可能声明支持 Tahoe；删掉旗，AMFIPass 大概率**直接不加载**（~85–90%）。

**删了会怎样**：本机 SIP 已是 Custom Configuration（`Kext Signing: disabled`）、无 OCLP 根补丁、`/Library/Extensions` 只有 HP 的 HighPoint RAID 两个 kext ⇒ 短期内可能**看不出任何异常**（~70%）。但一旦需要 AMFI 放行（打根补丁、往 L/E 装第三方驱动、某些依赖未签名代码的 app），就会突然坏，且症状与 AMFIPass 无关、极难归因。⇒ 保留。

### 9.2 `rtcfx_exclude=0E-FF` —— 保留，但要说清它现在大概率是"空闲的安全网"

| 事实 | 值 |
|---|---|
| 本机 `hibernatemode` | **0** |
| 本机 `standby` | **0** |
| 该参数已知拦截的写路径 | RTC **0x80–0xAB**（`AppleRTCHibernateVars`：'AAPL' 签名 + booterSignature + wiredCryptKey），只在休眠模式下由 xnu 写入 |
| 实测前科 | 本机做 S4 实验时确实踩过 `RTC/POST 005`；HP 官方定义是 **load factory defaults**（比"按 Esc 过"重得多） |

⇒ 在 `hibernatemode 0 / standby 0` 下，**那条已知写路径本来就不会触发**；至于是否有其他路径写 0x0E–0xFF，本机**未知（<80%）**——`-rtcfxdbg` 的日志只进 IOLog，本机 IOLog 不进 unified log，读不到，所以没有廉价验证手段。

**结论**：删它的收益是 0（RTCMemoryFixup 在没有该参数时等同不工作），失效模式是 CMOS 被写坏 / BIOS 恢复出厂设置；把握不足 80% 就不赌。保留。

> 与 §7 的判据一致：`igfxonln=1` 之所以能删，是因为有**属性兜底 + 源码 if/else + ioreg 实证**三重证据；
> 这两条都没有等价兜底，属于"删了也没好处、错了很麻烦"，不动。
