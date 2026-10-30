# S4 休眠改走 NVRAM（2026-10-28）

> 取代 `docs/s4-hibernate-principle-2026-10-28.md`（那份是「放开 RTC 0x80–0xAB」路线）。

## 一、为什么放弃 RTC 路线

Apple 的休眠密钥位置是硬编码的：

```c
// Include/Apple/IndustryStandard/AppleRtc.h
#define APPLE_RTC_HIBERNATION_KEY_ADDR    0x80
#define APPLE_RTC_HIBERNATION_KEY_LENGTH  0x2C   // "effectively equals sizeof (AppleRTCHibernateVars)"
#define APPLE_RTC_CHECKSUM_START          0x0E
#define APPLE_RTC_TOTAL_SIZE              0x100
#define APPLE_RTC_MAIN_CHECKSUM_ADDR1     0x58   // 校验范围 [0x0E, 0x100)
#define APPLE_RTC_MAIN_CHECKSUM_ADDR2     0x59
```

`0x2C = 44` 字节，正好 `0x80–0xAB`，与 `AppleRTCHibernateVars`
（`signature[4]+revision+booterSignature[20]+wiredCryptKey[16]`）完全吻合。

**问题在于主校验和覆盖 `[0x0E, 0x100)`，包含 `0x80–0xAB`。**

而 OpenCore 的 `rtc-blacklist` 不是「拦截写」，是**内存模拟**：

```c
// Library/OcRtcLib/AppleRtcRam.c  :: OcAppleRtcRamInstallProtocol
GetVariable2 (OC_RTC_BLACKLIST_VARIABLE_NAME, &gOcVendorVariableGuid, ...);
for (Index = 0; Index < RtcBlacklistSize; ++Index)
    mEmulatedRtcStatus[RtcBlacklist[Index]] = TRUE;

// SyncRtcWrite: 命中 mEmulatedRtcStatus ⇒ 只写内存，永不落真实 RTC
```

⇒ 若「封 0x58/0x59、放开 0x80–0xAB」，就会内容变、校验和不跟
⇒ boot.efi 判 mismatch ⇒ 调 `AppleRtcRamReset` 把 `0x40–0xFF` 清零 ⇒ **密钥自毁**。
（`AppleRtcRam.c:354` 注释："Apple implementation calls AppleRtcRamReset on checksum mismatch."）
这正是本机历史上「坏 RTC 2 次」的机制。

**两条路只能选一条：**要么两边一起放开（=让 Apple 自由改 BIOS 的 CMOS 区 0x10–0x2F），
要么两边都别碰。选后者。

## 二、NVRAM 腿此前为什么不存在

HibernationFixup 的设计目标只覆盖「RTC 只有 1 bank（128 B）」的机器，README 开篇原话：

> But in case if you have to limit your RTC memory to **1 bank (128 bytes)**, it doesn't work

本机 RTC 是 256 B，于是：

```c
// HibernationFixup 1.5.4  kern_hbfx.cpp:89-100
if (result == KERN_SUCCESS || ioHibernateState == kIOHibernateStateHibernating) {
    if (!callbackHBFX->checkRTCExtendedMemory()) {        // ← 本机恒为 true，整段跳过
        ...
        OSData *rtc = OSDynamicCast(OSData, getPMRootDomain()->getProperty(kIOHibernateRTCVariablesKey));
        if (rtc && !nvstorage.exists(...)) nvstorage.write(...);
    }
}
```

```c
// Lilu  kern_rtc.cpp:44
bool RTCStorage::checkExtendedMemory() {
    uint8_t off = 0xB4; /* APPLERTC_POWER_BYTE_PM_ADDR */
    return read(off, 1, &dst);          // 能读到 0xB4 就算"RTC 够用"
}
```

⇒ 判定恒 true ⇒ **一个字节都不写**。实证：`nvram -p | grep -c -i hiber` 至今 = **0**。
09-16 那次装同版本 1.5.4 + `HibernateMode=NVRAM` 的 6 次失败，根因就在这里——
`HibernateMode=NVRAM` 让 OpenCore 去读一个**永远为空**的变量，比不设还差。

没有任何 boot-arg 能绕过这个门控（`hbfx-dump-nvram` 也不行：它路由的 `packA`
写的是 `AAPL,PanicInfo%04d`，是 panic 信息 dump，与休眠变量无关）。

## 三、改动：自编译 fork，新增 `-hbfxforce`

上游 1.5.4 源码，3 个文件 4 处：

| 文件 | 改动 |
|---|---|
| `kern_config.hpp` | 加 `bootargForceNvram {"-hbfxforce"}`；加 `bool forceNvram {false}` |
| `kern_start.cpp` | `readArguments()` 里解析 `-hbfxforce` |
| `kern_hbfx.cpp:91` | `if (!checkRTCExtendedMemory() \|\| ADDPR(hbfx_config).forceNvram)` |
| `kern_hbfx.cpp:96` | 加两条 `DBGLOG`：打印 PMRootDomain 里该键是 present 还是 MISSING，以及字节数 |

构建（本机已具备：clang 21 / Xcode 26.5 / `~/MacKernelSDK` / 本地 `Lilu.kext` 自带 `Resources/Headers`）：

```bash
# 1) 源码解压后，把依赖软链进项目目录
ln -sfn <repo>/EFI/OC/Kexts/Lilu.kext  ./Lilu.kext
ln -sfn ~/MacKernelSDK                 ./MacKernelSDK

# 2) 带日志编译（DBGLOG 在纯 Release 下会被编译掉，必须 -DDEBUG=1）
xcodebuild -project HibernationFixup.xcodeproj -scheme HibernationFixup \
  -configuration Release -derivedDataPath /tmp/hbfx_build_dbg \
  GCC_PREPROCESSOR_DEFINITIONS='DEBUG=1 $(inherited)' build
```

产物 `87488 B`（上游 release `58112 B`），校验点：

- `strings ... | grep -c -e "-hbfxforce"` = 1
- `strings ... | grep -c "NVStorage path entered"` = 1
- `otool -l | grep -c __DWARF` = 0（确认非 debug 目标）
- `OSBundleLibraries as.vit9696.Lilu = 1.2.4`（本机 1.7.3 满足）

日志只在 `-hbfxdbg` 时输出（`ADDPR(debugEnabled)` 控制），平时零开销。

## 四、配置（`EFI/OC/config.plist`）

| 项 | 新值 | 说明 |
|---|---|---|
| `Kernel/Add[1]` | `HibernationFixup.kext` | fork 版，紧跟 Lilu |
| `Misc/Boot/HibernateMode` | `NVRAM` | 只读 NVRAM。`Auto` 会先读 RTC，见下方「为什么不用 Auto」 |
| `Misc/Boot/HibernateSkipsPicker` | `true` | 恢复时跳过选择器 |
| `Misc/Debug/Target` | `69`（`0x45`） | `0x01\|0x04\|0x40`。0x40 是原计划的 boot-log 通道，**实测无效**（见第五节） |
| `boot-args` | `rtcfx_exclude=0E-FF … -hbfxdbg -hbfxforce` | 全封 RTC + 强制 NVRAM + 日志 |
| `rtc-blacklist` | `242 B`（`0x0E–0xFF`） | 全封，含 `0x80–0xAB` |
| `Kernel/Quirks/PowerTimeoutKernelPanic` | `false` | 超时不 panic，免污染判读 |
| `UEFI/Drivers` | `ResetNvramEntry.efi` 启用 | 真正的 Reset NVRAM 逃生口，另有 `CMD+OPT+P+R` |
| `Misc/Security/AllowNvramReset` | **已删除** | OC 1.0.x 移除了该键，留着 ocvalidate 报 `No schema`，且不生效 |

相对上一版（RTC 路线）的实质变化：`rtcfx_exclude` 与 `rtc-blacklist` **从「留出 80–AB」改回「全封」**。

### `AllowNvramReset` 是死配置（2026-10-28 纠正）

此前把 `Misc/Security/AllowNvramReset=true` 当成「Reset NVRAM 逃生口」，**错了**。

- `ocvalidate`（1.0.9 MOD）报：`OCS: No schema for AllowNvramReset at 0 index, context <Security>`
- 官方 `Docs/Configuration.tex` 全文搜不到该键，`Library/OcMainLib/OpenCoreMisc.c` 也没有解析
- 官方给的替代品是驱动 `ResetNvramEntry.efi`：*"Adds a menu entry which resets NVRAM and
  immediately restarts. Additionally adds support for hotkey `CMD+OPT+P+R`"*（conf.tex:7320）

本机 `EFI/OC/Drivers/ResetNvramEntry.efi` 早已存在且 `UEFI/Drivers` 里 Enabled ⇒ 逃生口**其实一直是好的**，
只是不在那个键上。注意代价（conf.tex Note 2）：Reset NVRAM 会清掉非 `BlessOverride` 的启动项，
`LauncherOption=Short` 时 OC 自身启动项受保护，Windows 的 `Windows Boot Manager` 条目会被清，
但 OC 仍能从 EFI 文件扫到并启动，可事后重建。

### 为什么不用 `Auto`

`Auto` = `RTC | NVRAM`，而 RTC 分支在前：

```c
// Library/OcBootManagementLib/AppleHibernate.c:134-146
if (HibernateMask & HIBERNATE_MODE_RTC) {
  for (Index = 0; Index < sizeof (AppleRTCHibernateVars); Index++)
    RtcRawVars[Index] = OcRtcRead (Index + 128);
  HasHibernateInfoInRTC = RtcVars.signature[0] == 'A' && ... == 'L';
  HasHibernateInfo = HasHibernateInfoInRTC;
}
```

它会校验 `'AAPL'` 签名（所以纯垃圾不会误判），但 `OcRtcRead` 是直读硬件、**不经过** `rtcfx_exclude`
（那只拦 AppleRTC kext）。本机 09-16/09-17 那几次失败很可能在 RTC 里留下过 `AAPL` 签名，
一旦命中就会被优先采信、盖掉 NVRAM 的正确 44 B，而且日志看起来像 "RTC hibernation is 1"。
既然 NVRAM 腿已经打通，RTC 分支只剩负价值 ⇒ 改成 `NVRAM`（官方 toolTip 明确支持该值）。

## 五、必要条件清单（2026-10-28 17:35 状态）

macOS 走 S4 要同时满足 9 条，任一条断了就恢复不了。按链路顺序：

| # | 条件 | 状态 | 依据 / 缺口 |
|---|---|---|---|
| 1 | 固件支持 S4 | ✅ | `FACP-1.aml` `FLAGS=0x002384A5`：bit7 `RTC_S4`=1、bit16 `S4_RTC_STS`=1；Windows/Linux 同机实测可 S4 |
| 2 | 磁盘能放下镜像 | ✅ | 16 GB 内存 / 系统卷 193 GB 可用 |
| 3 | macOS 侧开启休眠 | ✅ | `s4-arm.sh arm` 设 25，已生效 |
| 3b | **`standby` 必须为 1** | ✅ | 17:04 卡在这（`standby 0` 彻底关掉镜像写入，见 1.1）；已改并实测生效 |
| 3c | **内核持有写镜像路径** | ⏳ | 17:23 卡在这：`sysctl kern.hibernatefile` 为空 ⇒ `IOHibernateIO.cpp:504` return Unsupported ⇒ `HibernateError`（见 1.2）。已加 `hfile=` boot-arg，**重启后 `sysctl kern.hibernatefile` 非空才算过** |
| 4 | macOS 把 44 B 密钥交出来 | ❓ | 需 `PMRootDomain` 提供 `kIOHibernateRTCVariables`，macOS 26 上未验证 |
| 5 | kext 把它写进 NVRAM | ✅ | fork + `-hbfxforce` 绕过 `checkRTCExtendedMemory()` 门控 |
| 6 | OC 从 NVRAM 读回 | ✅ | `HibernateMode=NVRAM`；读到后校验长度必须 **= 44**、签名必须 **`AAPL`** |
| 7 | OC 交出 `boot-image-key`/`boot-signature` | ✅ | `AppleHibernate.c:189-204` 自动写，格式对了就必定执行 |
| 8 | boot.efi 解密 sleepimage 并恢复 | ❓ | 只能实测 |
| 9 | 出问题能判读 | ⚠️ | 主判据改走内核侧（见下）。OC 侧 `boot-log` 实测取不到 |

`⏳` 是待执行动作，`❓` 是只能靠一次实测回答的未知。

### 1.1 2026-10-28 17:04 第一次实测：没进休眠；根因是 `standby 0` 抑制了镜像写入

`arm` 成功（AC 侧 `hibernatemode 25`、`sleep 0`），17:04:19 菜单睡眠、17:08:35 按电源键唤醒，
睡了 256 秒。**但走的是 Deep Idle，不是 S4**：

| 判据 | 实测 | 读法 |
|---|---|---|
| `pmset -g log` | `Entering Sleep state due to 'Software Sleep pid=217'` | 普通睡眠，**没有** `Entering Hibernate` |
| 唤醒类型 | `Wake from Deep Idle [CDNVA] : due to PWRB/User` | S0ix，不是 S4 |
| `WakeTime` | 2.443 sec | 与历史 Deep Idle 唤醒一致（S4 恢复不可能是这个量级） |
| `kern.hibernatecount` | **0** | 从未成功 |
| `/System/Volumes/VM/sleepimage` | **不存在** | 镜像从未被写 |
| VM 卷 `disk1s6` 已用 | 1.0 MB（只有 `kernelcore`） | 从未放过镜像 |
| `vm.swapusage` | `total = 0.00M` | VM 子系统没有任何文件 |
| NVRAM `boot-image*` | 无 | 从未写成过 |

#### 根因：`standby = 0` 会直接关掉休眠镜像写入

`man pmset` 原文（本机手册，逐字）：

> `hibernatemode` supports values of 0, 3, or 25. **Whether or not a hibernation
> image gets written is also dependent on the values of standby and autopoweroff**
>
> To disable hibernation images completely, ensure hibernatemode standby and
> autopoweroff are all set to 0.

反过来读：**`standby 0` ⇒ 不写镜像**。此时 `hibernatemode 25` 是个空标志，睡眠照常走
普通睡眠（本机即 Deep Idle）。第一次 `arm` 时脚本把 `standby` 设成了 0 —— 依据是
"25 是立刻落盘、与 standby 的渐进逻辑无关"，**这个判断是错的**，被上面这句手册原文直接否掉。

正确的组合是 `hibernatemode 25` **加** `standby 1`：`standby` 负责"允许写镜像"这个开关，
`hibernatemode 25` 负责"写完就断内存电"。`standbydelay` 在 25 下不参与（它管的是
3 模式"先睡 RAM、若干分钟后再落盘"），但设一个 300 s 的值可以作为兜底退路。

#### 已被证伪的旧判断（留档，避免再犯）

17:04 之后曾判断"macOS 只在启动时按当时的 hibernatemode 分配 sleepimage，所以改完 25 必须重启"，
并据此在脚本里加了硬门槛。**17:17 重启后该判断被实测推翻**：`hibernatemode` 仍是 25，
`/System/Volumes/VM/sleepimage` **依然不存在**，VM 卷仍只有 `kernelcore`，
`dynamic_pager` 仍是 `not running`（`launchctl print system/com.apple.dynamic_pager` → `state = not running`）。

结论：`sleepimage` 不是"启动时预分配"的前置条件，而是休眠动作的结果 —— 只有真的决定写镜像时
内核才会去创建/扩展它。所以它不存在**不构成阻塞**，脚本里那条硬门槛已降级为提示。

**位置（17:30 修正）**：两台卷上都有同名文件，但**写镜像的目标是 `hfile` 指定的那个**：

```
/var/vm/sleepimage                 ← Data 卷（disk1s4）；本机 pmset 与 hfile 都指向这里，这才是写目标
/System/Volumes/VM/sleepimage      ← VM 卷（disk1s6，nobrowse,noexec），swap / 内核转储用
```

`stat -f "inode=%i dev=%d"` 可证两者 `dev` 不同（16777226 vs 16777227）。
早前把 `/var/vm` 那份判成「0 字节残留」是**错的**：它是 XNU 的写目标，0 字节只说明从未真正写入过。

### 1.2 2026-10-28 17:23 第二次实测：进了 Standby，报 `HibernateError`

`standby 1` 生效后这次不一样了：不再是 Deep Idle，而是**真的进入 Standby 并尝试写镜像**，
但 10 秒内退回，唤醒原因 `(HibernateError)`。

两道门是串联的：17:04 那次卡在第一道（`standby 0` ⇒ 连尝试都没有，直接降级普通睡眠）；
改掉之后才撞上第二道（内核没有写镜像路径 ⇒ 尝试了但立刻失败）。

```
17:23:38  PMRD: phase 0, standby 1 delay 300, hibernate 0x19
17:23:39  PMRD: phase 1 / phase 2, hibernateMode 0x19
17:23:49  (AppleACPIPlatform) AppleACPIPlatformPower Wake reason: (HibernateError)
17:24:35  PMRD: sleep factors …, StandbyForced, ExternalDisplay, HibernateFailed
```

`kern.hibernatecount` 仍是 0，镜像没有生成。

### 根因：内核根本没拿到写镜像的路径（源码 + 实测双证）

`IOHibernateIO.cpp:496-506`（XNU main）：

```c
if ((obj = IOService::getPMRootDomain()->copyProperty(kIOHibernateFileKey))) {   // "Hibernate File"
    if ((str = OSDynamicCast(OSString, obj))) {
        strlcpy(gIOHibernateFilename, str->getCStringNoCopy(), sizeof(gIOHibernateFilename));
    }
    obj->release();
}
if (!gIOHibernateMode || !gIOHibernateFilename[0]) {
    return kIOReturnUnsupported;        // ← 直接返回，不写镜像、不 panic
}
```

`gIOHibernateFilename` 全文件只有两处赋值（`grep -n gIOHibernateFilename IOHibernateIO.cpp`）：

| # | 位置 | 条件 |
|---|---|---|
| 1 | `IOHibernateIO.cpp:496-502` | `IOPMrootDomain` 上存在 `"Hibernate File"` 属性 |
| 2 | `IOHibernateIO.cpp:1617` | boot-arg `hfile=<path>`（`PE_parse_boot_argn`） |

本机实测：

```bash
ioreg -lw0 | grep -c '"Hibernate File"'      # → 0   （全系统 0 命中）
sysctl -n kern.hibernatefile                 # → 空  （SYSCTL_STRING 直指该数组，见 1520 行）
```

所以走了 504 行的 `return kIOReturnUnsupported`：**不写镜像、不 panic、几秒内退回** ——
这正好解释「10 秒就回来 + 没有 panic + `hibernatecount` 仍为 0 + 镜像不生成」。

顺带纠正两条旧判断：

- `kern.hibernatefile` **不是**"只是显示用"：`IOHibernateIO.cpp:1520` 的
  `SYSCTL_STRING(_kern, OID_AUTO, hibernatefile, …, gIOHibernateFilename, …)` 直接指该数组，
  它**实时**就是内核里的写镜像路径 ⇒ **重启后可立即验证，不必先睡一次**。
- `pmset -g` 显示 `hibernatefile /var/vm/sleepimage` 只说明**配置文件**里有这个值
  （`/Library/Preferences/com.apple.PowerManagement.<UUID>.plist` 的 `"Hibernate File"` 键），
  **不代表内核收到了**。

### 修法

- `boot-args` 增加 `hfile=/var/vm/sleepimage`（走第 2 条来源，不依赖 powerd 是否下发属性）。
- **免重启通道（2026-10-28 17:40 补）**：上表"只有两处赋值"只统计了代码里的显式赋值，
  还有第三条路——sysctl 处理函数**直接写同一个数组**：

  ```c
  // IOHibernateIO.cpp:1519
  SYSCTL_STRING(_kern, OID_AUTO, hibernatefile,
      CTLFLAG_RW | CTLFLAG_KERN | CTLFLAG_LOCKED,
      gIOHibernateFilename, sizeof(gIOHibernateFilename), "");
  ```

  `CTLFLAG_RW` ⇒ root 可写：`sudo sysctl -w kern.hibernatefile=/var/vm/sleepimage`，
  写完立刻生效，**不必重启**。实测（未提权时）报 `Operation not permitted` 而非 `unknown OID`
  ⇒ 键存在且可写，只差权限。
  为什么它不会被覆盖：`IOHibernateSystemSleep` 只在 `IOPMrootDomain` 真有 `"Hibernate File"`
  属性时才覆盖（`:496-502`），本机该属性 0 命中 ⇒ 运行态写入的值能活到 `:504` 判据。
  反例：`pmset <src> hibernatefile` 走的是 `IOPMrootDomain.cpp:2002/2051` 的
  `kIOHibernateFileKey ⇒ setProperty` 那条，本机实测写完 `ioreg` 仍无该属性、sysctl 仍为空
  ⇒ **别把它当主路**。
- `s4-arm.sh` 增加两级判据：A 段查 config 里有没有 `hfile=`，B 段**硬判** `sysctl kern.hibernatefile` 非空；
  `arm` 门槛在发现为空时会先 `sysctl -w` 直写（成功则免重启），失败才要求重启。

**sleepimage 0 字节不是阻塞**（2026-10-28 17:40 核实）：`ioreg` 里
`"Hibernate File Min" = 1073741824`（1 GiB）非零 ⇒ `IOHibernateIO.cpp:578` 的
`if (vars->fileMinSize || …)` 成立，preflight 会算出 `setFileSizeMin`，
`:629` 的 `IOPolledFileOpen(..., kIOPolledFileCreate, setFileSizeMin, …)` 自行创建/扩展该文件。

**下一步**：重启后先看 `sysctl kern.hibernatefile`。非空才睡 —— 这条让"白重启"变成可判读。

**HBFX 日志不是判据（2026-10-28 17:40 结论）**：`kern_hbfx.cpp` 里
`"IOHibernateSystemSleep is called, result is: 0x…"` 那行包在 `#ifdef DEBUG` 内，
官方 release kext 根本没编进去 ⇒ 加 `-hbfxdbg` 也不会出现，`log show … CONTAINS "HBFX"` 为空是**预期**。
另外 HBFX 的 NVRAM 写入有前置条件（`kern_hbfx.cpp:87`）：
`if (result == KERN_SUCCESS || ioHibernateState == kIOHibernateStateHibernating)`——
hfile 为空时内核返回 `kIOReturnUnsupported`，HBFX 直接跳过写 NVRAM
⇒ 顺序上必须先把 hfile 修好，HBFX 才有机会干活。**判据改用 `sysctl kern.hibernatecount`。**

**第 9 条的实测结果（2026-10-28 16:50，重启后）**：`Target` 已从 5 改成 69 并确认运行态生效，
但 `ioreg -lw0 | grep -c '"boot-log"'` = **0**，`IODeviceTree` 里根本没有该属性。
本机 OC 文件日志此前也是坏的（13 份 262144 B 全零）⇒ **OC 的 `OCB:` 日志在本机拿不到**，
`Target` 那一位开不开都一样。判读改走内核侧，且这套判据足以区分第 4 条成立与否：

| 要看什么 | 命令 | 读法 |
|---|---|---|
| macOS 有没有交出密钥 | `log show --last 30m --predicate 'eventMessage CONTAINS "HBFX"'` | `PMRootDomain key present` + `is N bytes` = 交了；`MISSING` = 没交（第 4 条不成立）。**必须在你的终端跑**：AI 沙箱里会报 `Cannot run while sandboxed` |
| 是否真的 hibernation | `sysctl kern.hibernatecount` | 成功一次 +1（当前 **0**，从未成功） |
| 镜像是否写了 | `ls -lh /var/vm/sleepimage`（或用 `sysctl -n kern.hibernatefile` 得到的路径） | 应 ≈16 GB、mtime 是刚才 |
| 系统怎么记的 | `pmset -g log \| grep -e Hibernat -e "Entering Sleep"` | 出现 `Entering Hibernate` 而非 `Entering Sleep` |

## 六、验证与判读

### 6.1 操作前提：**接屏测**、不许合盖

**外屏不拔** —— 日常就是接外屏使用，拔屏测出来的"成功"没有意义；S4 必须在接屏状态下成立才算数。

外屏也确实不需要被当成变量排除，理由三条：

1. **S4 恢复是完整重新初始化**，不是 S0ix 式的"保电、只关部分电路"。`hibernatemode 25` 断内存电后，唤醒走的是 boot.efi 读镜像 → 内核接棒 → 驱动重新 probe，IGPU 从零 init，外屏链路训练路径与**冷启动完全一致**。冷启动时外屏能出图，S4 恢复时就没有理由不行。
2. **内建屏是主屏**（`Main Display: Yes`、`port 0`、`connector-type 0x0002`），唤醒后它先亮，本身就是判读窗口。外屏（`port 6`/`port 7`、`connector-type 0x0004`）回没回来是**独立观测项**，记下来即可，不影响成败判定。
3. 真要出问题，把外屏当**对照变量**比当**前置条件**更有价值：第一次带屏失败，第二次拔屏 —— 这样才区分得出"是 S4 本身不行"还是"多屏拖累"。先拔了反而把这个信息永久丢掉。

**不许合盖** —— 本机 `ioreg -n IOPMrootDomain` 实测：

```
"AppleClamshellCausesSleep" = No
"AppleClamshellState" = No
```

合盖判定是 **AC + 外接显示器 ⇒ clamshell 模式 ⇒ 合盖不睡、继续用外屏跑**。你以为"合盖就睡了"，实际上机器的睡眠路径根本不是要测的那条；测出来的"没进休眠"会被误读成 S4 失败。

另外 DSDT 里挂了**两个 LID 设备**（`ioreg -c AppleACPIDevice` 可见两个 `LID` → `AppleACPILid`，`IOPMrootDomain` 里 `"AppleACPILid"=2`），合盖事件的归属本身不可靠，行为不可复现。一次实验只能有一个变量，合盖会同时引入 clamshell 判定 + LID 事件归属两个未知。

**唤醒只按电源键** —— 本机 `pmset -g` / `pmset -g custom` 里**没有 `lidwake` 项**，开盖唤醒不可依赖。合盖睡下去再开盖，很可能不动，容易被误判成"醒不来"。

**唤醒后若内建屏也不亮** —— 先拔插一次 HDMI 等 10 s；仍黑则长按电源键重启，开机后查 `pmset -g log`，就能区分「恢复了但屏没亮」和「压根没恢复」。不要凭黑屏直接判失败。

```bash
bash EFI/scripts/s4-arm.sh check        # 只读体检，A 段 11 项静态判据
bash EFI/scripts/rtc-protect-verify.sh  # 四层防护核验
sudo bash EFI/scripts/s4-arm.sh arm     # 武装当前电源源
# ... 睡一次 ...
sudo bash EFI/scripts/s4-arm.sh disarm  # 无论成败先回滚
```

`rtc-blacklist` 的运行态**可以读到**（之前判断读不到是错的）：

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:rtc-blacklist
```

一次睡眠后判读。**注意判据方向**：OC 读到 `IOHibernateRTCVariables` 后会立刻把它擦掉——

```c
// AppleHibernate.c:173-183
if (!EFI_ERROR (Status)) {
  gRT->SetVariable (L"IOHibernateRTCVariables", &gAppleBootVariableGuid, ..., 0, NULL);  // 长度 0 = 删除
```

所以**醒来后 `nvram` 里还有这个变量 = OC 压根没消费它**，是坏信号；
看不到它才是正常（前提是 boot-log 显示读到过）。

| 现象 | 含义 | 下一步 |
|---|---|---|
| `kern.hibernatecount` 从 0 变 1，且系统恢复原会话 | NVRAM 路线成立 | 转日常配置，`-hbfxdbg` 可移除 |
| 计数变了，但唤醒黑屏 / 半途重启 / 回到登录界面重开 App | 卡在 boot.efi 解密或镜像 | 查 sleepimage 大小与加密；再考虑 `ReservedMemory` / CSM |
| `pmset -g log` 里只有 `Entering Sleep`、没有 `Entering Hibernate`，计数仍 0 | 没走休眠路径 | 先查 `pmset -g \| grep standby` 是否为 **1**（`standby 0` 会关掉镜像写入）；再核对 `hibernatemode 25` 与 boot-args 的 `-hbfxforce` |
| 醒后 `nvram` 里仍能查到 `IOHibernateRTCVariables` | 没被识别成休眠唤醒（或 HibernateMode 未生效） | 查 boot-args 是否真带上 `-hbfxforce`、OC 版本是否吃到新 config |

**本机取不到 OC 侧 `OCB:` 日志**（实测依据见下），所以判读走内核侧四条：

```bash
sysctl kern.hibernatecount                             # 基线 0，成功一次 +1
ls -lh /System/Volumes/VM/sleepimage                   # 应 ≈16 GB、mtime 是刚才（别用 /var/vm/）
pmset -g log | grep -e Hibernat -e 'Entering Sleep' | tail -5
log show --last 30m --predicate 'eventMessage CONTAINS "HBFX"' | tail -30
```

`boot-log` 取法**在本机无效**，留档备查（`Target` 已含 `0x40` 也取不到，
`ioreg -lw0 | grep -c '"boot-log"'` = **0**，且 ESP 根目录 13 份 `opencore-*.txt` 全是 262144 B 零字节）：

```bash
ioreg -lw0 -p IODeviceTree | grep boot-log | sed 's/.*<\(.*\)>.*/\1/' | xxd -r -p | grep -a OCB
```

v3 的日志判据（`-hbfxdbg` 开着）：

```
HBFX: NVStorage path entered (forceNvram=1), PMRootDomain key present
HBFX: kIOHibernateRTCVariables is 44 bytes
```

注意第二条在二进制里是格式化串 `is %u bytes`（`strings` 实测确认），所以 grep 时用
`kIOHibernateRTCVariables is` 这个前缀，别拿固定的 `44 bytes` 去匹配。

若字节数不是 44，说明结构变了；若是 `MISSING`，说明前提不成立。

## 七、回滚

| 层级 | 动作 |
|---|---|
| 只关 fork 逻辑 | boot-args 去掉 `-hbfxforce`（kext 留着无害，此时行为等于上游） |
| 回上游 kext | `cp -R docs/backups/hbfx-fork-20261028-1630/HibernationFixup.kext.upstream EFI/OC/Kexts/` |
| 回整个配置 | `cp docs/backups/hbfx-fork-20261028-1630/config.plist.before EFI/OC/config.plist` |

不改固件、不写 RTC ⇒ 无不可逆风险。最坏情况是「睡下去醒不来，需长按电源键」，
NVRAM 里的 `IOHibernateRTCVariables` 可用 OpenCore 的 Reset NVRAM 清掉。

## 3b 卡点二：sleepimage 带 `uchg` 导致 IOPolledFileOpen 0 ms 失败（2026-10-28 17:44 实测）

hfile 修好后的那次睡眠（17:44:53–17:44:55）内核日志给出唯一失败点：

```
17:44:54.499  hibernate image path: /var/vm/sleepimage
17:44:54.853  hibernate_page_list_setall preflight pageCount 675942 est comp 50 \
              setfilemin 1484783616 setfilemax 1484783616 min 1073741824
17:44:54.853  IOPolledFileOpen(e00002db)          ← 与上一行同一毫秒 = 0 ms 失败
17:44:55.205  AppleACPIPlatformPower Wake reason: (HibernateError)
```

**`e00002db` = `kIOReturnNoSpace`，但它不是"磁盘满"**：`IOPolledInterface.cpp:628-653`
把 `kern_open_file_for_direct_io()` 的任何失败都统一映射成这个码

```c
vars->fileRef = kern_open_file_for_direct_io(filename, flags, ...);
if (!vars->fileRef) { err = kIOReturnNoSpace; }        // :651-652
```

真正的 `errno` 被丢弃。根因在文件自身的标志位：

```
$ ls -lO /var/vm/sleepimage
-rw-r--r--  1 root  wheel  uchg  0 Oct 27 12:37
$ stat -f '%z %b %Sf' /var/vm/sleepimage
0 0 uchg
```

`uchg`（`UF_IMMUTABLE`）下**即使 root 也不能写、不能扩、不能截断** ⇒ 直写方式打开立即被拒。
这也同时解释了三个现象：0 ms 失败、文件一直是 0 字节、mtime 停在 10-27 不动。

除尺寸之外可以排除的因素：磁盘剩余 193 GiB（`kIOHibernateDiskFreeSpace` 只要 1 GiB）、
swap 正常（1024 MB 已加密）、FileVault 关闭、`"Hibernate File Min" = 1 GiB` 已存在
⇒ `IOHibernateIO.cpp:578` 的 preflight 分支本就该把文件扩到 1.38 GiB，只因不可变标志而没做成。

休眠路径自身不会清这些标志（xnu 休眠相关文件 grep `chflags`/`IMMUTABLE` = 0 命中），必须外部清：
`s4-arm.sh` 的 arm 门槛与 check 体检均已加入 `uchg`/`schg` 判据，arm 会自动 `chflags nouchg`。

## 3c 卡点三：HP POST 报 `005 Real-Time Clock Power Loss`（2026-10-28 18:00 那次）

18:00:12 睡下、18:01:56 冷启动，开机屏幕出现 HP 三位码 **005**。

**HP 官方定义**（三处文档口径一致：support.hp.com 中文页、`hp.com/go/techcenter/startup`、
HP Z Series Maintenance and Service Guide 表 7-1）：

> 005-Real-Time Clock Power Loss：Invalid time or date in configuration memory.
> RTC battery may need to be replaced. —— 且该错误会 **load factory defaults**（BIOS 载入出厂默认设置）。

这条一次性解释了三个此前"解释不通"的现象：

| 现象 | 由 005 解释 |
|---|---|
| 冷启动而非从镜像恢复 | 休眠状态存于 RTC/NVRAM，CMOS 被重置后失效 ⇒ 无恢复依据 |
| `sleepimage` mtime = `2019-01-01 08:00:57` | CMOS 重置后时钟回落到 BIOS 默认值，开机早期写文件用的就是这个错时间；NTP 之后才校正 |
| "又出现了 005" | 每次 S4 断电后开机都会复现 |

注意 **003 才是"主板故障"**，005 不是硬件报废，可恢复。

## 3d 主因：`HibernateMode=NVRAM` 在本机必然失败（2026-10-28 18:15 源码确认）

`OcBootManagementLib/AppleHibernate.c` 的两个分支（掩码定义在
`Include/Acidanthera/Library/OcBootManagementLib.h:1168-1170`：`NONE=0`、`RTC=1`、`NVRAM=2`）：

```c
if (HibernateMask & HIBERNATE_MODE_RTC) {          // :134
  for (Index = 0; Index < sizeof (AppleRTCHibernateVars); Index++)
    RtcRawVars[Index] = OcRtcRead (Index + 128);   // 读 CMOS 0x80–0xAB
  HasHibernateInfoInRTC = 签名 == 'AAPL';
  HasHibernateInfo      = HasHibernateInfoInRTC;
}

if (HibernateMask & HIBERNATE_MODE_NVRAM) {        // :148
  // If RTC variables is still written to NVRAM (and RTC is broken).
  // Prior to 10.13.6.                                ← 注释原文
  Status = GetVariable2 (L"IOHibernateRTCVariables", &gAppleBootVariableGuid, ...);
  if (!HasHibernateInfo && !EFI_ERROR (Status) && (Size == sizeof (RtcVars))) { ... }
}
```

`NVRAM` 只置第 2 位 ⇒ RTC 分支整段不执行 ⇒ `HasHibernateInfo` 恒为 FALSE，
只能靠 `IOHibernateRTCVariables` 这个 NVRAM 变量翻盘。而源码注释写明它只存在于
**10.13.6 之前**；本机 `nvram -p | grep -i hiber` 为空、`ioreg` 里
`IOHibernateRTCVariables` 属性命中 0 ⇒ OC 永远判定"不是休眠唤醒" ⇒ 走正常启动。

这就是 18:00 那次"睡下 → 断电 → 冷启动、会话丢失"的直接原因。

**已改**：`Misc/Boot/HibernateMode` `NVRAM` → **`RTC`**。

## 3e 三层封锁：为什么 RTC 里从来没有密钥

本机同时叠了三层，任一未解开都不成立。

| # | 位置 | 旧值 | 作用 |
|---|---|---|---|
| ① | `Kernel/Quirks/DisableRtcChecksum` | **true** | 阻止 AppleRTC 更新主校验和 `0x58/0x59` |
| ② | boot-args `rtcfx_exclude` | **0E-FF** | RTCMemoryFixup 在内核端口层拦写，覆盖 `0x80–0xAB` |
| ③ | `UEFI/ProtocolOverrides/AppleRtcRam` + NVRAM `rtc-blacklist` | true + `[0x0E..0xFF]` | 固件层模拟，拦 EfiBoot 的 EFI_RTC 访问 |

**① 是最隐蔽的一层**：`DisableRtcChecksum=true` 让校验和永不更新。即使内容区放开，
写进去的密钥也会让主校验和失配 ⇒ boot.efi 判 mismatch ⇒ 调 `AppleRtcRamReset` 清 `0x40–0xFF`
⇒ 密钥自毁。这正是本机历史上「坏 RTC 2 次」的机制。

**② 覆盖了密钥区**：`AppleRTCHibernateVars`（`AppleHibernate.h:123-128`）
= `signature[4] + revision[4] + booterSignature[20] + wiredCryptKey[16]` = **44 字节**，
OC 从 `0x80` 起读 ⇒ 正好 `0x80–0xAB`。RTCMemoryFixup README 原文：

> Offsets from **0x80 to 0xAB** are used to store some hibernation information (IOHibernateRTCVariables).
> If any offset in this range causes a conflict, you can exclude it, **but hibernation won't work**.

该 kext 的 offset 空间是 `bank0 0x00–0x7F + bank1 0x80–0xFF`，由
`RTCMemoryFixup.cpp:167-175` 的
`safe_offset = (cmd_reg == CMOS_ADDREG2 ? 0x80 : 0) + (cmd_offset & 0x7F)` 决定；
hook 的是 **I/O 端口层**（`:321-323` `routeVirtual(provider, ioRead8/ioWrite8, ...)`），
所以内核休眠路径写 RTC 同样被拦。

**③ 不影响内核写入**：AppleRtcRam 替换的是 EFI_RTC 协议，只作用于 EfiBoot；
OC 自己用 `OcRtcRead` 直读端口，macOS 走内核 hook，都不经过它 ⇒ **保留不动**。

### Apple 的 RTC 布局（`Include/Apple/IndustryStandard/AppleRtc.h`）

| 区域 | 用途 |
|---|---|
| `0x58` / `0x59` | 主校验和（`APPLE_RTC_MAIN_CHECKSUM_ADDR1/2`），覆盖 `[0x0E, 0x100)` |
| `0x78–0x7F` | 保留区（填 `FF`，PRAM 复位不清） |
| `0x80–0xAB` | 休眠密钥（`APPLE_RTC_HIBERNATION_KEY_ADDR=0x80`，长度 `0x2C`） |
| `0xB0–0xB6` | trace 区（唤醒进度日志，EfiBoot 写） |

### 已改（三处，必须同时生效）

- `Misc/Boot/HibernateMode`：`NVRAM` → **`RTC`**
- `Kernel/Quirks/DisableRtcChecksum`：`true` → **`false`**
- `rtcfx_exclude`：`0E-FF` → **`0E-57,5A-7F`**
  即封 BIOS 设置区、放开校验和 `0x58/0x59` 与密钥区 `0x80–0xAB`。

> 005 在 `0E-FF` 期间同样出现，说明它的成因不在被封锁的范围内；
> 改成放开校验和后 005 是否变化，只作观察，不作成败判据。

## 3f `pmset hibernatemode` 与内核态可以长期不一致（2026-10-29 08:56 实测）

```
$ pmset -g custom            # AC 侧
 hibernatemode        25
$ sysctl -n kern.hibernatemode
1
```

**成因**：`pmset` 只在目标值相对当前偏好**发生变化**时才把设置推给 powerd；
重启后内核的 `gIOHibernateMode` 回到默认值 1，而 plist 里早就是 25 ⇒
`pmset -c hibernatemode 25` 属于"无变化"，不触发下发 ⇒ 内核态永远停在 1。
此时睡下去是**普通睡眠**（不写镜像），日志里连 `hibernate image path` 都不会出现。

**修法**：`kern.hibernatemode` 是 `SYSCTL_UINT` + `CTLFLAG_RW`，直接指向 `gIOHibernateMode`
（`IOHibernateIO.cpp:1526-1528`）⇒ root 可直写：

```
sudo sysctl -w kern.hibernatemode=25
```

**已加固**：`s4-arm.sh` 的 arm 段在下发后**硬核对**内核态，不是 25 就 sysctl 直写；
仍不是 25 则回滚到安全档并中止武装。check 的 C 段也会把"pmset vs 内核态"不一致判成 ✘，
避免"看着武装好、其实按模式 1 睡"这种不可判读的测试。

## 3g RTC 路线的实测否决 + 回到 NVRAM（2026-10-29 09:20）

**现场时间线**（`pmset -g log`，都是本机原话，非推断）：

```
09:03:31  Display is turned off
09:04:01  Entering Sleep state due to 'Software Sleep pid=219' … Using AC (Charge:100%)
09:04:02  Wake Requests  … [*process=powerd request=UserWake deltaSecs=23
                            wakeAt=2026-10-29 09:04:26
                            info="com.apple.alarm.user-invisible-GaugingMitigationActions,104"]
09:05:27  ShutdownCause  SMC shutdown cause: 5: Software initiated shutdown
09:05:27  Start          powerd process is started
```

- 09:04:01 睡下去，`hibernatemode=25` ⇒ 写镜像后**真断电**（09:05:27 记到的
  「SMC shutdown cause 5: Software initiated shutdown」就是这次 S4 掉电）。
- 09:04:26 那个 23 秒的 `GaugingMitigationActions` 闹钟把机器从断电状态叫了回来，
  POST + OC + boot 约 60 s，09:05:27 起 powerd ⇒ 这是一次**冷启动**，日志里没有任何 Wake 条目。
- **决定性证据**：`HibernateSkipsPicker=true` 时 OC 只要认出休眠唤醒就必然跳过选择界面，
  而这次仍然弹了选择界面 ⇒ `OcActivateHibernateWake` 在 CMOS `0x80–0xAB` 没读到 `'AAPL'`。

**为什么不是「密钥没生成」**：密钥生成过，而且现在就躺在 NVRAM 里，44 字节、签名完整：

```
$ nvram IOHibernateRTCVariables
IOHibernateRTCVariables  AAPL%01%00%00%003M%16%09…     # 4+4+20+16 = 44 B
$ ioreg -lw0 -p IODeviceTree | grep -A0 IOHibernateRTCVariables
IOHibernateRTCVariables = <4141504c 01000000 …>        # 与上面逐字节一致
```

⇒ 断点在**「RTC 跨断电没保住」**，属固件行为（与历史 005 = RTC Power Loss 同源），
用户侧改不动。RTC 这条腿到此为止。

**回到 NVRAM 腿**。`Library/OcBootManagementLib/AppleHibernate.c` 的真实逻辑：

| 行 | 行为 |
|---|---|
| `:134-146` | `RTC` 掩码：`OcRtcRead(0x80..0xAB)` 校验 `'AAPL'` ⇒ 本机恒为 0 |
| `:148-181` | `NVRAM` 掩码：读变量 `IOHibernateRTCVariables`，要求 `Size == sizeof(AppleRTCHibernateVars)`（44）且签名 `AAPL` |
| `:171-181` | **读到后立刻把该 NVRAM 变量删掉** ⇒ 一次性消费，不会残留造成下次误判 |
| `:189-204` | 判定成立后写 `boot-image-key` / `boot-signature`（`BOOTSERVICE` 易失） |
| `:232-268` | `OcIsAppleHibernateWake()` 只看这两个变量在不在 ⇒ 决定是否跳选择器 |

`:151` 那句注释 `Prior to 10.13.6` 说的是**上游 macOS 自己不再往这个变量里写**，
不是「这个变量没用」：本机装的是自编译 fork，`-hbfxforce` 绕过了
`checkRTCExtendedMemory()` 门控（改动见本文第三节），**变量确实被写出来了** ——
08-28 记的「`nvram -p | grep -i hiber` 至今 = 0」只对上游 1.5.4 成立。
7a5fc09 那次「NVRAM 必失败」的判定就是漏算了这一点。

**配置（2026-10-29 已改并同步 ESP，`adbde6f`）**

| 项 | 值 | 理由 |
|---|---|---|
| `Misc/Boot/HibernateMode` | `RTC` → **`NVRAM`** | 只读 NVRAM；不带 RTC 分支，避免对固件行为下注 |
| `HibernateSkipsPicker` | `true`（不变） | 同时充当**识别指示器**：不弹选择器 = OC 认了 |
| `DisableRtcChecksum` / `rtcfx_exclude` | `false` / `0E-57,5A-7F`（不变） | 让「内容改了就跟着改校验和」成立，避免 `AppleRtcRamReset` 清 `0x40–0xFF` ⇒ 这是 005 的机制；换个路子后这条仍要留着 |

**`s4-arm.sh` 新增**：睡前 `nvram -d IOHibernateRTCVariables`。
fork 的写入门控是 `!nvstorage.exists(...)`（只在不存在时写）⇒ 旧 key 会永久占位、
永不更新；不清掉它，下次休眠交出的可能是上一轮的 key，与当前镜像不匹配。
睡下后 fork 会重新写一份，开机时 OC 消费并删除，正好形成闭环。

**下一步的唯一判据**：改完配置**必须重启**（OC 只在启动时读 config）。
重启前先 `sudo nvram -d IOHibernateRTCVariables` 清掉旧 key ——
否则这一次开机 OC 会拿旧 key 当真、去解一张已被截断的镜像。

## 3h 首次真正走到恢复段：OC 认了，boot.efi 挂住（2026-10-29 09:30）

**现场（用户口述 + 本机取证）**

| 观测量 | 结果 |
|---|---|
| 电源灯 | 睡下后熄灭（= 真断电写法），**未动它自己又亮了** |
| OC 选择界面 | **没出现**（`HibernateSkipsPicker=true` 下这是唯一判据） |
| 之后 | 黑屏、一直挂着，按电源键才重启 |
| 重启后 | HP POST **005**（RTC Power Loss，会 load factory defaults） |

**硬证据**

```
09:30:13  Entering Sleep state due to 'Software Sleep pid=218'  Using AC (Charge:100%)
09:30:14  Wake Requests … [*powerd request=UserWake deltaSecs=254
                            wakeAt=09:34:29 info="com.apple.alarm.user-invisible-GaugingMitigationActions,104"]
本次开机：09:33:29（= 用户强制重启那一次）
NVRAM   ：boot-image / boot-signature / IOHibernateRTCVariables 全为空
last -x ：console 09:24–09:33 直接接 console 09:33 —— **中间没有任何登录会话**
          （09:33 也没有 "reboot time" 条目 = 上一次关机不是干净关机）
```

09:30:13 之后 `pmset -g log` 里**没有一条 Wake、也没有一条 Start**，`last` 里也没有中间会话
⇒ 黑屏那一段**从未进入用户态**。这不是「恢复了但屏没亮」，是**挂在恢复段**。

**进展（本轮唯一的实质结论）**：OC 跳过了选择界面，只可能来自 `AppleHibernate.c:148-181`
—— 它从 NVRAM 读到了那 44 字节、校验通过、写下 `boot-image-key` / `boot-signature` 并删掉源变量。
**NVRAM 这条腿在 OC 段已经验证通过**，前几轮争的「NVRAM 到底能不能用」到此结案（能用）。

**失败点前移**到 boot.efi → 内核恢复段。一条重要的旁证：如果 boot.efi 找不到镜像或密钥对不上，
按 Apple 的设计会**回落到正常启动**（能进系统），而本机是**硬挂、无 fallback**
⇒ 镜像头是读成功了的，密钥也对得上，挂的是**恢复阶段的物理布局/硬件状态**。

`sleepimage` 大小 1.0 GiB 不是异常：`IOPMrootDomain` 的 `Hibernate File Min` 就是 1 GiB
（`stat` 的 mtime/ctime = `2019-01-01 08:00:54` 是内核给该文件打的固定标记，不能用它判写入时间）。

**社区先例（同症状，已核对原文）**

`5T33Z0/Lenovo-T530-Hackintosh-OpenCore` issue #48：*"before these fixes I was only getting a
black screen or a restart when trying to wake from hibernation"*，处方为

1. `HibernateFixup` + `RTCMemoryFixup` —— 本机已有
2. `HibernateMode = NVRAM` —— 本机已有
3. `RebuildAppleMemoryMap = false`（Booter/Quirks）—— 本机是 **true**
4. `ReservedMemory` 条目 —— 本机**没有**（值随机型，暂不猜）
5. `rtcfx_exclude=80-AB` —— 本机是 `0E-57,5A-7F`（未封 0x80–0xAB）
6. `HibernateSkipsPicker = true` —— 本机已有

同帖 #10（Dell Precision 5550，"black screen & KP upon every wake"）用同一组改动修好。

**本次只改一个键**：`Booter/Quirks/DiscardHibernateMap` `false → true`。
理由是它只作用于唤醒路径（OC 文档：*forces the XNU kernel to ignore a newly supplied memory map
and assume that it did not change after waking from hibernation*；Windows S4 亦要求如此），
**正规启动不受影响，也就不可能把机器搞到开不了机**。
`RebuildAppleMemoryMap=false` 会改变每次开机的内存映射，有启动风险，留作下一步（届时需准备可回滚的 USB / Windows 侧改 config）。

**判据升级**：黑屏时按 Caps Lock——
指示灯能亮灭 = 内核活着（问题在显示）；毫无反应 = 真挂死（问题在恢复）。

## 3i DiscardHibernateMap 无效；改 RebuildAppleMemoryMap（2026-10-29 10:05）

**09:55 那一轮**（已修正用户口误：电源灯**灭过**）

```
09:54:58  Display is turned off
09:55:28  Entering Sleep state due to 'Software Sleep pid=217'   Using AC
09:55:29  Wake Requests … UserWake deltaSecs=59 wakeAt=09:56:29
                            info="com.apple.alarm.user-invisible-GaugingMitigationActions,104"
本次开机：09:57:38（无 Start powerd 记录 = 上次为非正常断电）
```

三条观察：选择界面**不出现**、电源灯**灭过**、黑屏时 **Caps Lock 灯无反应**。

- 灯灭 ⇒ S4 真的断电了；选择界面不弹 ⇒ OC 又认了（NVRAM 腿第二次验证）；
- **Caps Lock 完全无反应 ⇒ 内核从未跑起来** ⇒ 这不是「恢复了但屏没亮」，是死在 **boot.efi 装载镜像**阶段，
  与「没有 Apple 标志」互相印证（UI 都还没画出来）。
- `DiscardHibernateMap=true` 对这个症状**无效**，已判定。

**顺带排除 FileVault**：`fdesetup status` = Off，`diskutil apfs list` 五个卷 `FileVault: No`
⇒ 不是「读不了加密卷」这类原因。

**本次改动（`Booter/Quirks`）**

| 键 | 原 | 新 | 理由 |
|---|---|---|---|
| `RebuildAppleMemoryMap` | true | **false** | 镜像必须落回写盘时记录的物理地址；OC 每次开机重建映射会移动/占用这些区域 ⇒ 装载当场死、UI 都来不及画。社区同症状处方（T530 issue #48、Dell 5550 #10）都是置 false |
| boot-args | — | 前置 `-v` | 纯观察项：恢复路径若打印任何文字就能定位；不改变行为 |

**风险与回滚（已就位）**

`RebuildAppleMemoryMap=false` 会改变每次开机的内存映射，**存在开不了机的可能**（OC 文档也写明这一族
quirk「即使在相似机器上也没有确定做法」）。回滚件：

```
/Volumes/ESP/config.plist.safe                         # 放在 ESP 根，避开 EFI/OC 的单向镜像（会同步删除）
docs/backups/config-2026-10-29-knowngood.plist         # 仓库内副本（Discard=false / Rebuild=true，已验证可启动）
```

若开不了机：OC 选择界面 → **空格**（`HideAuxiliary=true` 会藏 Recovery）→ Recovery → 终端：

```
diskutil mount disk0s1
cp /Volumes/ESP/config.plist.safe /Volumes/ESP/EFI/OC/config.plist
```

**注意**：`/Volumes/ESP/EFI/OC/config.plist.safe` 会被 EFI→ESP 的单向镜像删掉（仓库里没有同名文件，
镜像连删除一起同步）。所以回滚件必须放在 `EFI/OC/` 之外。

## 3j RebuildAppleMemoryMap=false 直接打进启动 panic —— 路线到此为止（2026-10-29 10:28）

**现场（10:05 改键 → 10:11 长按断电 → 10:22 Windows 改回 → 10:24:35 正常开机）**

用户拍下的内核 panic 屏（`-v` 生效后第一次启动即崩，循环重启）：

```
Mac OS version: Not yet set
Darwin Kernel Version 25.6.0 ... root:xnu-12377.161.15.701.40~2/RELEASE_X86_64
roots installed: 0
System shutdown begun: NO
Panic diags file unavailable, panic occurred prior to initialization
Hibernation exit count: 0
System uptime in nanoseconds: 317417283
Last Sleep:   Uptime : 0x0000000037f30331
              Sleep  : 0x0   Wake : 0x0
Last started kext at 649002036: as.lvs1974.HibernationFixup  1.5.4
** In Memory Panic Stackshot Succeeded **
MACH Reboot
```

**判定：这是正常启动路径的崩溃，不是休眠恢复路径**，三条独立证据：

| 证据 | 含义 |
|---|---|
| `Mac OS version: Not yet set` + `panic occurred prior to initialization` | 死在 `version_init()` 之前，即内核最早段 |
| `Sleep : 0 / Wake : 0`（全零） | 本次会话**从未发生过睡眠/唤醒** |
| `Hibernation exit count: 0` | 没有休眠退出 |
| `uptime = 317417283 ns` = 0.317 s | 开机 0.3 秒即崩 |

**机制（OC 官方文档原话，不是推断）**

`Booter/Quirks/RebuildAppleMemoryMap` 条目 Description 的第一段：

> The Apple kernel has several limitations on parsing the UEFI memory map:
> **The Memory map size must not exceed 4096 bytes** as the Apple kernel maps it as a single 4K page.
> As some types of firmware can have very large memory maps, potentially over 100 entries,
> **the Apple kernel will crash on boot.**

也就是说：这个 quirk 存在的作用**正是防止内核在启动时崩溃**（把固件原始映射整理成 Apple 能吃的形态）。
置 `false` = 把固件原始映射原封不动交给内核 ⇒ 本机映射不合 Apple 要求 ⇒ 启动即 panic。
**这条路在本机不成立，不存在"再调调参数"的空间。**

同一文档尾段亦承认此类 quirk 无确定解：

> Unfortunately for some quirks such as `RebuildAppleMemoryMap`, `EnableWriteUnprotector`,
> `ProtectMemoryRegions`, `SetupVirtualMap`, and `SyncRuntimePermissions` there is no definite
> approach even on similar systems, so trying all their combinations may be required for optimal setup.

**社区处方在本机不适用的原因**：T530 issue #48 / Dell 5550 #10 那两台把 `RebuildAppleMemoryMap`
设为 `false` 还能正常启动，说明它们的固件内存映射本身就是 Apple 兼容的；本机的不是。
所以那条处方抄不过来。

**已回滚（`60deb40d`，= 09:17 那版已验证可启动）**

| 键 | 值 |
|---|---|
| `RebuildAppleMemoryMap` | `true` |
| `DiscardHibernateMap` | `false`（实测对恢复无帮助，一并撤掉） |
| `boot-args` | 去掉前置 `-v` |

仓库与 ESP 两侧 sha 一致，`ocvalidate` 0 问题。

**结论：S4 恢复在本机无低成本可推进路径**，四条理由：

1. **OC 段已通**：`HibernateMode=NVRAM` 两次都让 OC 跳过选择器（`AppleHibernate.c:148-181` 读 44 B → 写 `boot-image-key`/`boot-signature` → 删源变量）。
2. **失败点前移到 boot.efi**：黑屏时无 Apple 标志、`Caps Lock` 灯无反应 ⇒ 内核从未运行。
3. **能动那一段的两个 quirk 都已出局**：`DiscardHibernateMap` 实测无效；`RebuildAppleMemoryMap=false` 直接搞坏正常启动。
4. **诊断通道关闭**：OC 文件日志在本机全为零字节、`boot-log` 在 IODeviceTree 里取不到、无串口 —— 再往下只能盲猜，**每猜一次 = 一次重启 + 一次可能开不了机**。

保留现状：普通睡眠（`hibernatemode=3` 侧 / `standby`）在本机工作是正常的（基线 5.5–5.6 %/h），
S4 属加分项，不值得用"可能开不了机"去换。

**订正**：3i 里写的「`s4-arm.sh` 里也加了这两个键的体检项」不成立 —— 脚本里实际没有这两项检查（`grep` 无匹配）。

## 3k 打开 boot.efi 日志转发（`Misc/Debug/AppleDebug`）—— 这是唯一能看见恢复段的通道（2026-10-29 10:35）

**为什么之前看不到**：`Misc/Debug/Target` 这类开关只能记录 **OpenCore 自己**的动作，
故障点在 OC 把控制权交给 `boot.efi` **之后**，所以一直看不见。但 OC 有一个专门的转发键：

> `Misc/Debug/AppleDebug` — **Enable writing the `boot.efi` debug log to the OpenCore log.**
> *Note*: This option only applies to 10.15.4 and newer.

本机此键**一直是 `false`**，等于把唯一能看到恢复段的通道关着。

**顺带发现：现在连"上屏"都是关的**

`Target = 69 = 0x45`，按官方位表拆开：

| 位 | 值 | 含义 | 本机 |
|---|---|---|---|
| bit 0 | `0x01` | 总开关（不开则全部丢弃） | ✔ |
| bit 1 | `0x02` | **basic console（上屏）日志** | ✘ **未开** |
| bit 2 | `0x04` | Data Hub | ✔ |
| bit 6 | `0x40` | 文件 | ✔ |

所以这轮之前，屏幕上根本没有 OC 日志可看。

**四条读取通道的真实状态**

| 通道 | 状态 |
|---|---|
| 屏幕（`0x02`） | 可开。但 boot.efi 一旦重新设显示模式屏就黑、字全没 ⇒ **必须手机录像兜住最后一帧** |
| 文件（`0x40`） | **当前坏的**：ESP 上最后一份日志是 `2026-10-29 02:24`，之后 8 次开机一份都没生成；剩余 740 MiB 不是满盘 ⇒ 原因未掌握，需单独查 |
| Data Hub（`0x04`）/ UEFI 变量（`0x10`/`0x20`） | **每次开机覆盖** ⇒ 失败那次的日志会被下一次开机冲掉，**天然救不了失败现场** |
| 串口（`0x08`） | 本机无串口 |

官方另注：文件日志 *"attempted in the safest manner and thus, is very slow. Ensure that `DisableWatchDog` is set to `true` when a slow drive is used."* —— 本机 `DisableWatchDog` 原是 `false`。

**本轮改动（全部是观察项，不动任何功能键）**

| 键 | 原 | 新 | 作用 |
|---|---|---|---|
| `Misc/Debug/AppleDebug` | false | **true** | 把 boot.efi 的日志转发进 OC 日志（本轮核心） |
| `Misc/Debug/Target` | 69 (`0x45`) | **71 (`0x47`)** | 加 `0x02`，让日志真的出现在屏幕上 |
| `Misc/Debug/DisableWatchDog` | false | **true** | 官方为慢速文件日志推荐 |
| `boot-args` | — | 加回 `-v` | boot.efi 自身的 `AAPL:` 行在 verbose 下才吐 |

`DisplayLevel = 0x80000042`（ERROR+INFO+WARN）不动。`ocvalidate` 0 问题，sha `8402ac43` 两侧一致。
顺手清掉 ESP 根 18 份废日志（4.5 MB，17 份全零、1 份只有两行 config 警告）。

**必须先验证通道再谈故障**：下次开机能正常进系统后，第一件事是看 ESP 根上有没有新的
`opencore-YYYY-MM-DD-HHMMSS.txt`。**有内容 = 文件通道活了**，那以后失败现场可以直接落盘事后读，不用抢拍；
仍然为空/不存在 = 只剩余屏上文字，且只能靠录像。

## 3l 10:36 那版配置启动不了系统 —— 逐键比对与结论（2026-10-29 11:50）

**事实链（全部本机可核）**

```
10:24:35  banner 60deb40d 启动成功
10:36:30  f27dc63 提交并写入 ESP（AppleDebug/Target/DisableWatchDog/-v 四项）
   ~10:4x  重启 → 进不了系统（用户操作：进 Windows，改 config）
10:58:26  ESP 上 config.plist 被改写（Windows 侧保存）
11:43:59  正常启动
```

`pmset -g log` 在 10:24:50 与 11:44:11 之间**零记录**，`last` 无会话 ⇒ 这 79 分钟里没有任何一次成功进入系统。

**三份配置的逐键差异（plistlib 深比对，非文本 diff）**

| 键 | 60deb40d（10:24 成功） | f27dc63（失败） | 8af3023a（11:43 成功） |
|---|---|---|---|
| `Misc/Debug/AppleDebug` | false | **true** | **true** |
| `Misc/Debug/Target` | 69 (`0x45`) | **71 (`0x47`)** | **71** |
| `Misc/Debug/DisableWatchDog` | false | **true** | false |
| `boot-args` 含 `-v` | 无 | **有** | **有** |
| `Misc/Boot/HibernateMode` | NVRAM | NVRAM | **None** |
| `Misc/Boot/HibernateSkipsPicker` | true | true | **false** |
| `boot-args` 含 `-hbfxdbg -hbfxforce hfile=` | 有 | 有 | **无** |

**关键推论**：8af3023a 仍然开着 `AppleDebug=true` / `Target=71` / `-v` 并成功启动 ⇒ 这三项**已被本机实测排除**。
与 10:24 成功那版相比，只有在失败版里存在、而现在被去掉的项才落在嫌疑范围内 ——
即 **`DisableWatchDog = true`**。休眠三项（`HibernateMode` / `HibernateSkipsPicker` / `-hbfx* hfile=`）
在 10:24 的成功启动里全都存在过，因此不是它们。

**但这条推论有两点必须讲明，不能当定论**

1. 只有一次观测、没有日志（OC 文件日志自 03:43 之后一份没生成），**单点无法排除偶发**；
   `DisableWatchDog=true` 的机制上也谈不上"必然起不来"（OC 只调 `SetWatchdogTimer` 关狗），
   所以它是**嫌疑最大**，不是**已证**。
2. 另有一条独立异常支持"写盘不干净"这条竞争解释：**10:37 删掉的 18 份 `opencore-*.txt`，
   现在有 7 份仍在，mtime 还是凌晨原值**（`ls /Volumes/ESP/opencore-*.txt | wc -l` = 7）。
   说明在这个 `msdos, fskit` 挂载点上**删除操作可能没有真正落盘**（`sync` 之后仍然如此）。
   如果写的持久性都不可靠，那 10:36 那次 config 落盘是否完整也无法自证。

**当前状态（8af3023a，正在运行中，ocvalidate 0 问题）**

| 项 | 值 | 含义 |
|---|---|---|
| `HibernateMode` | `None` | 彻底关掉 OC 的休眠唤醒识别 |
| `HibernateSkipsPicker` | `false` | 恢复默认，不再跳过选择器 |
| `-hbfxdbg / -hbfxforce / hfile=` | 已移除 | 内核态 `kern.hibernatefile` 变空 ⇒ 休眠写盘从根上不可能发生 |
| `AppleDebug` / `Target` / `-v` | 仍开 | 实测可启动；**建议下次要重启时一并收回**（纯输出项） |

**备份（Windows 侧也能直接取）**

```
docs/backups/config-2026-10-29-1143-knowngood.plist   8af3023a  ← 当前在跑，11:43 验证可启动
docs/backups/config-2026-10-29-knowngood.plist        60deb40d  ← 10:24 验证可启动
/Volumes/ESP/config.plist.safe                        60deb40d  ← ESP 根，避开 EFI/OC
```

`docs/backups/` 位于 Common 卷（ExFAT，Windows 侧同盘可直接访问）⇒ 下次再进不了系统，
**不需要在 Windows 里手改 plist**，直接把这个文件拷到 `EFI\OC\config.plist` 覆盖即可。

**操作规则（针对本机 ESP 写的不可靠性）**

1. 改 config 后**不要立刻重启**，先 `shasum -a 256` 双侧比对，再 `diskutil unmount` 干净卸载；
2. 任何一次 ESP 写入前，先确认 `docs/backups/` 里有一份已验证可启动的副本；
3. 优先在 Windows 侧改 ESP（Windows 对 FAT 的写入路径比 macOS fskit 稳），
   再由 macOS 侧读回来比对 sha。

## 3m 体检：本机 BIOS 根本没有 CSM/Legacy 开关 —— ReservedMemory 路线作废（2026-10-29 12:45）

**问题的由来**：3k/3l 之后我提议「进 BIOS 开/关 CSM，各导一份内存映射，diff 出 S4 缺失区，
写成 `Booter/ReservedMemory`」。但**我从没确认过这台机器的 BIOS 里到底有没有这个开关**。

**查证结果：没有。HP 官方 BIOS 白皮书把 ZBook Power G7 明确列在「UEFI only」表里。**

出处：*HP PC Commercial BIOS (UEFI) Setup*，HP 官方技术白皮书，文档号 **919946-004**，July 2020，
§2.1「Supported models – 2020 (UEFI only)」：

> The models covered in this first section **only support UEFI based operating systems.
> There is no support for legacy DOS, Windows, or Linux configurations** in the products listed below:
>
> **Table 1 Notebook Generations (UEFI only)** — Platforms 2020 (most are 'S' Family)，UEFI Spec 2.7：
> HP ZBook Firefly 14, 15 G7 / HP ZBook Fury 15, 17 G7 / HP ZBook Create G7 / HP ZBook Studio G7 /
> **HP ZBook Power G7** / HP EliteBook 850·840·830·855·845·835 G7

同一文档 §2.2 才是「Supported models – prior generations (**with legacy support**)」，
列的是 N(2015)/P(2016)/Q(2017-2018)/R(2019) 家族（ZBook G3–G6 等）—— **Power G7 不在其中**。
文档开头亦写明本代是「'S' family of BIOS, introduced in 2020」。

**我先前的取证错误（必须记下）**

提出该路线时我引用了两份「HP 维护手册里有 `Configure Legacy Support and Secure Boot` 三个选项」，
但那两份经核对机型为：

| 手册号 | 实际机型 |
|---|---|
| `c06440089` | **HP ProDesk 400 G5 Desktop Mini**（台式迷你机） |
| `c06072587` | **HP EliteOne 800 G4**（一体机） |

两份都不是 ZBook Power G7。**这是「拿同品牌别机型的手册当本机依据」，属共性当可比性，与上午
`RebuildAppleMemoryMap` 那次同类错误。** 正确做法是先核对文档封面机型再引用。

**这对 C 路线是致命的，不是「有风险」而是「前提不存在」**

OC 文档里 `ReservedMemory` 的原文是：

> Some types of firmware may not allocate memory areas used by S3 (sleep) and S4 (hibernation) code
> **unless CSM is enabled** causing wake failures. **After comparing the memory maps with CSM disabled
> and enabled**, these areas can be found in the lower memory and can be fixed up by doing the reservation.

三个前提逐条对照本机：

| 前提 | 本机 |
|---|---|
| 固件存在 CSM 开关 | ✘ 无（UEFI only，见上） |
| 能做「CSM 关 vs 开」两态内存映射对比 | ✘ 只有一个态，无从对比 |
| 能据此定位「S4 缺失的低端内存区」 | ✘ 失掉唯一定位方法 |

⇒ 处方本身依赖「修好 CSM 那台机器的对照实验」来取地址；本机没有 CSM，
**`ReservedMemory` 就退化成手工猜地址填表**。而猜错的后果已有实例：
10:05 那次 `RebuildAppleMemoryMap=false` 直接把正常启动打成 0.3 s 内核 panic。
**因此 `ReservedMemory` 在本机判为不可执行，不是「高风险」，是「没有可依循的方法」。**

**顺带一个反向收获**：本机是 UEFI-only / 'S' family BIOS，说明固件里不存在为 legacy BIOS/SMI
保留低端内存区的需求 —— 而 OC 文档所指的「CSM 开启才分配」的正是这类 legacy 区域。
这从另一侧解释了为什么 `RebuildAppleMemoryMap` 不能置 false：S family 的内存映射本身就复杂，
必须由 OC 整理成 Apple 能吃（≤4096 字节、单 4K 页）的形态。

**剩余候选的重新归零**

| 候选 | 状态 |
|---|---|
| `Booter/ReservedMemory` | **作废**（无 CSM 可对比，只剩猜地址） |
| `DevirtualiseMmio=false` + `MmioWhitelist` | 本机 `MmioWhitelist` = 0 条 ⇒ 同样需要自己找地址；置 false 有启动风险，成功率无法给出 |
| `Booter/Quirks/ResetHwSig` | 单键可试，但症状不符（签名不符会回落正常启动，本机是无 UI 硬挂） |

**结论：本机能动的层已经全部出局。** ⑥ 层（boot.efi 恢复内部）的两个有文档依据的候选，
一个因本机无 CSM 失去方法、一个因白名单为空失去输入；加上诊断通道关闭（3e/3k），
再往下只能是纯猜地址，代价是可能开不了机。S4 在本机到此为止。

## 3n 归因定稿：固件支持 S4，卡点在「绝对物理地址还原」这条契约（2026-10-29 12:50）

这一节只回答一个问题：**当前的固件能不能进 S4？进不去是配置问题还是固件问题？**

### 事实侧：固件的 S4 能力齐备（四条，均为一手或官方）

| # | 证据 | 读数 | 出处 |
|---|---|---|---|
| ① | 本机真实 BIOS 版本 | `firmware-revision=<00001901>` → LE `0x01190000` = **T75 01.25.00** | 本轮实测 `ioreg -p IODeviceTree -n efi -r -d 1 -w0` |
| ② | Windows `powercfg /a` 原文 | *「此系统上有以下睡眠状态: 待机 (S0 低电量待机) 连接的网络 ／ **休眠** ／ 快速启动」*；S1/S2 明写**「系统固件不支持此待机状态」**，S4 无此备注 | `docs/firmware-facts-ledger.md` §8.1b（2026-09-20 Windows 侧只读导出） |
| ③ | `hiberfil.sys` 在位且已配置 | `6,588,555,264 B` = 6.14 GiB ≈ 16 GiB RAM × 38.4%（Windows 默认 reduced 40%） | 本轮实测 `/Volumes/TZBOOK/hiberfil.sys` |
| ④ | 固件升版未动 ACPI | 01.24.02 → 01.25.00 全部 **51 张 ACPI 表逐字节一致** ⇒ ②的 S4 声明在 01.25.00 上继续成立 | `docs/firmware-facts-ledger.md` §1.1 |

外加用户一手见证：**Windows 与 Linux 在本机都能休眠并正常恢复**。

⇒ **「固件不支持 S4」这个说法可以被 `powercfg /a` 直接推翻。** S4 声明有、休眠文件在用、断电与冷 POST 都正常。
**HP 官方已把 01.25.00 标为最新**（ish_15558503，2026-08 芯片组固件安全更新）⇒ 刷固件无效。

### 机制侧：同一个「S4」，两个恢复模型

| | Windows / Linux 休眠 | macOS 休眠（hibernatemode 25） |
|---|---|---|
| 谁读镜像 | bootmgr / GRUB，**用户态软件** | **boot.efi**（BootX），不是内核 |
| 页表 | 重建（可重定位） | **不重建**，内核页表直接从镜像恢复 |
| 页落点 | 相对可调整 | **必须是写盘时的绝对物理地址**（`IOHibernateIO.cpp:78-88`） |
| 跳转 | 正常内核入口 | `hibernate_kernel_entrypoint()`，**translation off** |
| 对固件的要求 | 只需断电 + POST | 额外要求 **POST 后物理内存布局与写盘时逐字节一致** |

Windows 天天成功，证明的是「①②③④⑤ 段固件没毛病」——这一点与本项目 3h 的实测完全一致
（电源灯灭 = 真断电、冷 POST 正常、OC 认出休眠唤醒并跳过选择器）。**它证明不了 ⑥ 段。**

### 配置侧：能动的键已穷尽，且每条都有实测或原文依据

| 手段 | 判定 | 依据 |
|---|---|---|
| `Booter/Quirks/DiscardHibernateMap = true` | **无效** | 10:05 实测，症状不变（层错：作用于内核收到的映射，而挂在内核启动之前） |
| `RebuildAppleMemoryMap = false` | **打坏普通启动** | 10:21 实测 panic；OC 文档原文 *"the Apple kernel will crash on boot"* |
| `Booter/ReservedMemory` | **不可执行** | 文档要求 CSM 开/关两态映射对比取地址；本机 UEFI-only 无 CSM（HP 白皮书 919946-004 Table 1） |
| `DevirtualiseMmio=false` / `MmioWhitelist` | **无输入** | 白名单 0 条；文档要求「需虚拟地址才能工作的 NVRAM/休眠区域」地址清单，本机无从取得 |
| `Booter/Quirks/ResetHwSig` | **症状不符** | FACS 签名不符时 macOS 回落正常启动，本机是无 UI 硬挂 |
| 诊断通道 | **官方关闭** | `wake-save-log=4` / `console=2` 在 OC 1.0.9 已 unavailable；`serial` 本机无串口 |

### 断点定位（为什么能确定在 ⑥ 而不是更前/更后）

Apple 的设计：boot.efi 若读不到镜像头或密钥对不上，**回落到正常启动**（能进系统、镜像丢弃）。
本机是**无 UI 硬挂、Caps Lock 无反应、`last` 里没有任何登录会话** ⇒ 镜像头读到了、密钥对上了，
死在**把 wired pages 装回绝对物理地址 / 拷 `__HIB`** 这一步。

### 诚实边界

无法直接观测「S4 恢复后的物理布局 vs 写盘时的布局」——该段唯一可信通道是串口（本机无）。
所以「布局不一致」是由症状反推的**唯一剩余解释**，不是直接测到的量。
严格表述：**已排除「配置可修」，未证实「布局必然不一致」，且已无手段分辨。**

### 定性

- ❌ 不是「固件不支持 S4」——`powercfg /a` 与 `hiberfil.sys` 直接否掉。
- ❌ 不是「配置还没调对」——能在该段起作用的键已穷尽，且全部出局。
- ✅ 是**「固件不提供 macOS 所需的绝对物理地址还原保证」这条契约缺失**，落在黑苹果引导层，
  OC 已无手段补齐（补它需要地址，而地址来源已被无 CSM / 白名单为空双重切断）。

**后续**：不动固件（已最新）、不再试键。日常用普通睡眠（5.5–5.6 %/h）+ 出门关机替代。

## 3o ★★ 首次拿到恢复段完整分段证据：全流程成功，死在 ExitBootServices 之后（2026-10-29 13:00）

这是 S4 攻关以来第一次**不是靠症状反推**，而是按 boot.efi 自己的分段标记读出死点。

### 实验

12:53 恢复 3h 基线（`Misc/Boot/HibernateMode`=`NVRAM`、`HibernateSkipsPicker`=`true`、
boot-args 前置 `-hbfxdbg -hbfxforce hfile=/var/vm/sleepimage`、kext 换回 fork 1.5.4）。
用户 13:00 arm 后睡眠，现象四段：电源灯灭 → 灯自己亮 → **OC 选择界面没出现** → 黑屏卡住。

产生日志 `ESP/opencore-2026-10-29-050032.txt`（4596 B，UTC 05:00:32 = 北京 13:00:32）。
同机 04:57:03（12:57）那份 8790 B 是重启后的冷启动，作天然对照组。

### 分段证据（原文摘录，非解读）

| 阶段 | 冷启动 04:57 的表现 | 恢复 05:00 的表现 | 判定 |
|---|---|---|---|
| 认出休眠 | `#[EB.H.IS|!] Err(0xE) <- RT.GV boot-signature`、`boot-image-key` 两条 NOT_FOUND | **无这两条**，直接 `#[EB|H:IS] 1` ×3 | **NVRAM 密钥在，OC 第 ⑤ 段成功** |
| 镜像头校验 | `#[EB.H.CHK|BM] 0x0` | `#[EB.H.CHK|BM] 0x0` | 通过 |
| 定位镜像 | 后接 `EB.H.LV|!] Err(0xE) <- RT.GV boot-image` ×3 + `RT.SV-` ×3 | `#[EB|H:BI] <02010c00d041030a…7fff0400>`（设备路径） | **拿到镜像位置** |
| 签名 | — | `#[EB|H:SIG] 0x73696D65` | — |
| 读回镜像 | 无 | `LOG:REAN:START` → **`LOG:REAN:END`（耗时 534 ms）** → `#[EB|H:RDEND]` | **镜像读完并处理** |
| HB 阶段 | 无 | `#[EB.H.HB|DT] 3 0` | 完成 |
| 退出引导服务 | `LOG:EXITBS:START` | `LOG:EXITBS:START` | **无 `EB.H.HB|!] … <- BS.Exit` ⇒ 成功** |
| 之后 | 进系统 | 黑屏卡住，无任何日志 | 死在 EXITBS 之后 |

两处非致命报错，均**不阻断流程**（其后仍有进度标记并继续）：

- `#[EB.H.CHK|!] Err(0xE) <- BS.LocDP 5B27263B-9083-415E-889E-6432CAA9B813` — LocateDevicePath NOT_FOUND
- `#[EB.H.HB|!] Err(0x84) <- 17407E5A-AF6C-4EE8-98A8-00210453CDD9.R MSWr` — 读 NVRAM 变量 `MSWr` 失败

### 判据来源（可复验）

日志模板全部取自本机 `boot.efi`（`/System/Volumes/Preboot/324C1FDC…/System/Library/CoreServices/boot.efi`，723512 B）的字符串表：

```
#[EB|H:IS] %d                      0=冷启动 1=认出休眠
#[EB.H.CHK|BM] 0x%016qx            镜像头校验位图
#[EB|H:BI] <%.*b>                  镜像设备路径
#[EB.H.HB|DT] %d %d                HB 阶段结果
#[EB.H.HB|!] %r <- BS.Exit         ← ExitBootServices 失败专用；日志里**没有**这一行
LOG:EXITBS:START / EXITBS:END      ← EXITBS:END 在成功/失败两次里都没出现
RESET:FAIL:POSTEXITBS              ← ExitBootServices 之后复位的专用标记；也没有
```

`EXITBS:END` 之所以两次都缺席：boot.efi 的日志能力经 Data Hub/文件，而 ExitBootServices
之后这两条服务都已不可用 ⇒ **EXITBS 是观测能力的物理上限，末行相同不代表结果相同**。
（这推翻了 12:53 版脚本「末行含 EXITBS:START 就不是失败现场」的判据，已重写。）

### 死点定论

**boot.efi 的恢复流程全部成功：认出休眠 → 密钥在 → 校验通过 → 定位镜像 → 读回并处理
（534 ms）→ HB 阶段完成 → ExitBootServices 成功。黑屏发生在交给 `hibernate_kernel_entrypoint()`
之后，即内核侧把页表与 wired pages 装回绝对物理地址、MMU 关闭状态下跳进内核的那一刻。**

⇒ 与 12:50（§3n）的定性一致，但精度大幅提升：不再是"⑥ 段某处"，而是"⑥ 段的最后一跳"。
**密钥、验签、读盘、解密、退出引导服务全部排除。**

### 下一步仅剩两条，性质不同

| 方案 | 需要什么 | 能证明什么 | 风险 |
|---|---|---|---|
| **A. memmap 冷启动 vs 恢复态对比** | 加 `Misc/Tools` 一条（`OpenShell.efi` 已在 ESP）；设 `HibernateSkipsPicker=false` 让恢复时弹 picker，在 picker 里进 Shell 跑 `memmap` | **直接验证「POST 后物理布局在两种路径下是否一致」**——这是"绝对物理地址"假设唯一的直接检验 | 只读命令，无破坏性；但需一次重启 + 一次睡眠 + 手动操作 |
| B. `DevirtualiseMmio=false` | 单键，不需要地址 | 相关性弱（该 quirk 影响的是交给内核前的 MMIO 虚拟映射，而失败在 EXITBS 之后） | 置 false 可能打坏启动，有 `config.plist.safe` 兜底 |

A 优先：它是把"猜地址"变成"读地址"的唯一动作，且无论结果如何都能收敛问题——
一致 ⇒ 问题在内核恢复代码与硬件状态（IGPU 等在断电后复位），本机无解；
不一致 ⇒ 拿到具体差异区，`ReservedMemory` 才有目标。

## 3p 执行方案 A：memmap 冷启动 vs S4 恢复态对比（2026-10-29 13:13）

§3o 把死点缩到「boot.efi 交给 `hibernate_kernel_entrypoint()` 之后」。剩下唯一能直接检验的事，
是确认**S4 恢复后的物理内存布局与冷启动是否一致**。本节是把这件事做成可重复采样的动作。

### 采样点选在 picker，语义是「boot.efi 的上游输入」

`Misc/Tools` 里跑 Shell 时，OC 的 `Booter/Quirks`（含 `RebuildAppleMemoryMap` 等）**尚未应用**——
那些处理发生在选定条目、`OcBooterSupport` 阶段。所以 picker 里的 `memmap` 反映的是
**OC 给 boot.efi 的输入布局**，正是需要对比的量。冷启动与 S4 恢复两条路径的采样点语义完全一致。

并且 OC 的 Booter 变换是确定性的：输入相同 ⇒ 输出相同。因此「输入一致」可以支撑「boot.efi 看到的一致」。

**局限（必须写明）**：仍然看不到 boot.efi 装页那一刻的真实映射。它看的是上游。
但足以二分——一致 ⇒ 固件布局没问题，问题在内核恢复代码与断电后硬件状态；不一致 ⇒ 固件侧坐实。

### 配置改动（三键 + 一个工具 + 一个脚本）

| 项 | 改前 | 改后 | 理由 |
|---|---|---|---|
| `Misc/Tools` | `<array/>` 0 条 | 1 条 `OpenShell`（`Tools/OpenShell.efi`，`Auxiliary=false`、`TextMode=true`、`Enabled=true`） | `OpenShell.efi` 早在 ESP 上（1,187,840 B），只是没入口。`Auxiliary=false` 才能在 `HideAuxiliary=true` 下显示 |
| `Misc/Boot/HibernateSkipsPicker` | `true` | `false` | 恢复时停在 picker 才能进 Shell 采样 |
| `Misc/Boot/Timeout` | `5` | `0` | 无限等待，避免 5 秒自动跳过导致采样失败 |

新增 `EFI/OC/Tools/startup.nsh`：UEFI Shell 启动时自动执行，`memmap > memmap.txt` 存文件
（屏幕上也打一份供拍照兜底），无需手抄。

新增 `EFI/scripts/s4-memmap.py`：`status` / `save cold|s4` / `diff`。
解析兼容两种排版（旧 `Type Start-End Pages Attrs`、新 `Start-End Pages Attrs Type`），
按 `(start,end)` 建表比对，输出「仅基线有 / 仅 S4 有 / 地址同类型变 / 差异区间汇总」。

### 采样流程

1. 重启 → picker（`Timeout=0` 会一直等）→ 选 **OpenShell** → 自动跑 `startup.nsh` → 屏幕出现 memmap
   → 输 `exit` 回 picker → 选 macOS 正常进系统
2. 进系统后：`python3 EFI/scripts/s4-memmap.py save cold`
3. `bash EFI/scripts/s4-arm.sh arm` → 菜单睡眠
4. 恢复时 picker 会**必然出现**（`SkipsPicker=false`），这是预期，不是失败
   → 选 **OpenShell** → 采样 → `exit` → 选 macOS 继续恢复（仍会黑屏，已知）
5. 强制重启进系统后：`python3 EFI/scripts/s4-memmap.py save s4` → `diff`

### 判读矩阵

| diff 结果 | 结论 | 下一步 |
|---|---|---|
| **完全一致** | 固件在 S4 后恢复了相同布局 ⇒「绝对物理地址还原失败」假设被推翻 | 问题落内核恢复代码 + 断电后硬件状态（IGPU 等），本机无解，S4 收工 |
| **存在差异** | 固件布局确实变了 ⇒ 假设成立 | 差异区间即 `Booter/ReservedMemory` 候选目标，首次有了具体地址 |

### 已知风险与退路

- `HibernateSkipsPicker=false` 下恢复时必弹 picker，**不再能用「不弹 picker」当OC 认出休眠的判据**；
  但该判据已有更硬的替代：日志 `#[EB|H|IS] 1`（§3o 实测）。
- `Timeout=0` 若无人操作会一直停在 picker，属预期。
- 采样用 `memmap.txt`，两次之间由 `save` 自动把源文件改名为 `memmap-<tag>-sampled.txt`，避免覆盖混淆。
- 万一启动异常：Windows 下把 `/Volumes/ESP/config.plist.safe`（`60deb40d`，09:17 验证可启动）覆盖回去；
  本轮改动前版本另存 `docs/backups/config-2026-10-29-1313-memmap-probe.plist`（`ecfd4cab`）。

### 3p-补 `Misc/Tools/Path` 语义实录（2026-10-29 14:05）

首版把 `Path` 写成 `Tools/OpenShell.efi`，picker 里能看到条目但选不进去。
13:58 那次启动的 OC 日志（`ESP/opencore-2026-10-29-055846.txt`）给出直接原因：

```
00:000 OC: Tool Tools\Tools\OpenShell.efi cannot be found!
00:003 OCB: Custom read failed - Not Found
00:006 OCB: LoadImage failed - Not Found
（同一组在其后 05:233 / 10:135 / 19:950 各重试一次，共 4 次）
```

**OC 自己会拼 `Tools\` 前缀** ⇒ `Path` 实际基准是 `EFI/OC/Tools/`，只能写文件名：
`Path` = `OpenShell.efi`。

文档侧同构验证：OpenCore 手册里 `ACPI/Add/Path` 的原文是「ACPI tables are loaded from
the `OC/ACPI` directory」，即配置里只写 `DSDT.aml` 这类相对名，子目录由加载器拼。
`Misc/Tools` 遵循同一约定。**文档与实测一致。**

同时排除的：`OpenShell.efi` 本身没问题——`file` 与 PE 头实测为
**PE32+ / x86_64 / Subsystem=10 (EFI Application) / 1,187,840 B**，不是坏镜像。

操作流程相应调整为「先验证 Shell 可用，再走完整采样」：重启 → picker 选 OpenShell →
看到 memmap 或 Shell 提示符 → `exit` → 进系统 → 检查 `memmap.txt`。这一步通过后再 arm 睡眠。

## 3q ★★ memmap 实测结果：物理布局无结构性差异 —— 「绝对物理地址」假设被推翻（2026-10-29 14:40）

§3p 的采样已完成（用户实机：冷启动一次、S4 恢复一次，均在 picker 里进 OpenShell 执行
`fs0:` → `memmap > memmap.txt`）。本节只报数据与由数据直接推出的结论。

### 原始计数

| 项 | 值 |
|---|---|
| 冷启动基线段数 | 55 |
| S4 恢复态段数 | 39 |
| 逐段（start,end,type 全等）相同 | 35 |
| 仅基线有 | 20 段 |
| 仅 S4 有 | 4 段 |
| 地址相同但类型变 | 0 段 |

表面看是"存在差异"，但把 24 段差异按**类型归属**切开后，结论反转。

### 关键一：差异全部落在自由池，固件固定区一字未动

| 类别 | 冷启动 | S4 | 判定 |
|---|---|---|---|
| Reserved | 630,267,904 B | 630,267,904 B | 一致 |
| ACPI_NVS | 2,097,152 B | 2,097,152 B | 一致 |
| ACPI_Recl | 720,896 B | 720,896 B | 一致 |
| MMIO | 16,777,216 B | 16,777,216 B | 一致 |
| RT_Code | 5,242,880 B | 5,242,880 B | 一致 |
| RT_Data | 3,031,040 B | 3,031,040 B | 一致 |
| **固定区合计** | **658,137,088 B** | **658,137,088 B** | **完全一致** |
| 自由池合计（Available+BS_*+Loader*） | 16,471,400,448 B | 16,471,400,448 B | **完全一致** |

逐类型净变化只有三项，且加起来为 0：`Available +76 KiB`、`BS_Data −84 KiB`、`LoaderData +8 KiB`。
总覆盖字节两边都是 **17,129,537,536 B**，最高地址两边都是 `0x45F7FFFFF`。

再用更硬的判据复核：**把两个差异窗口剔除后，两边各剩 35 段，列表逐元素相等**（Python 元组列表
`==` 为 True）。也就是说窗口之外没有任何一段的起止地址或类型发生变化。

### 关键二：两个"差异窗口"内部，总量也完全相同

| 窗口 | 冷启动 | S4 | 差异性质 |
|---|---|---|---|
| `0x64DAC000-0x64DBAFFF`（60 KiB） | Available 52 KiB + LoaderData 8 KiB | Available 44 KiB + LoaderData 16 KiB | LoaderData 多要了 8 KiB，边界移动 |
| `0x6F913000-0x74CBAFFF`（85,664 KiB） | 18 段，Available/BS_Data 交替（5416+32+16+52+4+12+4+4+28 KiB 可用） | 2 段：Available 5652 KiB + BS_Data 80012 KiB | 描述符被合并，边界起止点相同 |

两个窗口的起止地址两边**完全一致**，窗口内字节总量两边也**完全一致**（60 KiB / 85,664 KiB）。
区别只是 `Available` 与 `BS_Data` 之间的分界线画在哪 —— 这是引导器与 OpenShell 自己分配的临时内存，
两次运行的分配量本就不同，属 UEFI 描述符打包粒度问题。

### 结论（三层，均可由上表复验）

1. **「S4 之后固件把物理内存布局改了，导致 wired pages 装回绝对地址时落错」这一假设被实测推翻。**
   没有 Reserved 块增减，没有保留区移位，没有 ACPI/MMIO 边界变动。
2. **`Booter/ReservedMemory` 没有目标可填。** 该 quirk 的作用是保护"指定的物理区间"不被内核占用，
   前提是知道哪一段在两次启动间位置不同。本机测下来一段都不同，**该手段作废**。
3. **`s4-memmap.py` 首版那句"差异区间即 ReservedMemory 候选目标"是错的**（它把自由池打包差异
   当成了结构性差异）。已改为按类型分类：只有落在 Reserved/ACPI/MMIO/RT* 的差异才判为结构性，
   落在 Available/BS_*/Loader* 的判为打包差异，并在无结构性差异时明确输出"ReservedMemory 作废"。

### 与 §3o 的衔接：死点定位不变，归因变了

§3o 已用 boot.efi 自己的分段标记证明：认出休眠 → 密钥在 → 校验 → 定位镜像 → 读盘 534 ms →
`[EB.H.HB|DT] 3 0` → ExitBootServices 成功，之后黑屏。**现在又排除了"布局不一致"这个解释。**

⇒ 剩余可能性只有：内核自己把页面装回绝对地址那段代码在本机环境下失败（硬件/固件不提供它需要的
某种状态），而该段**没有任何外部观测通道**：`AppleDebug` 的日志经 Data Hub/文件，而 ExitBootServices
之后这两条服务已不可用（§3o 已证），本机无串口。

### 附带核对的次要疑点（均不构成阻塞）

| 项 | 读数 | 判定 |
|---|---|---|
| `/var/vm/sleepimage` 大小 | 1,073,741,824 B = 1.00 GiB（16 GiB RAM） | 与 IOPMrootDomain 属性 **`Hibernate File Min` = 1073741824 完全相等**，是系统自己的下限值，非异常 |
| 是否稀疏 | 分配块 ×512 = 1,073,741,824 = 文件长度 | 完全分配，非稀疏 |
| `boot-image` / `boot-signature` / `boot-image-key` 残留 | **全部不存在** | 与 boot.efi 自己删 `boot-image` 的设计一致（§3o 引 `:1250-1252`），也印证它确实走完了这段 |
| `H:BI` 设备路径解出的文件名 | `91a344f000`（10 位十六进制，非 `sleepimage`） | APFS 下 boot.efi 的设备路径以文件对象 ID 表示，不是可读文件名；与"镜像写在 sleepimage"不矛盾 |
| sleepimage 的 mtime | `2019-01-01 08:01:05` | **仅作观察，不作判据**：内核写休眠镜像走裸块 I/O，不保证更新 VFS 时间戳。我无法独立验证这一点，故不据此推断"镜像没写" |

## 3r 社区方案核查（2026-10-29 14:50）

用户问"网上也没说法吗"。本节把公开资料逐条核过，并标注每条对本机的适用性。

### 来源可信度分级（按本项目约定）

| 等级 | 来源 |
|---|---|
| **可作判据** | `github.com/lvs1974/HibernationFixup` README；`github.com/5T33Z0/Lenovo-T530-Hackintosh-OpenCore` issue #48；`github.com/balopez83/Surface-Pro-7-Hackintosh` issue #7（引用 Tyler Nguyen 的 `x1c6-hackintosh`）；`docs.chrultrabook.com`（MrChromebox 项目文档） |
| 仅方向 | 上述 issue 里转述的他人经验 |
| **不可作判据** | `ask.csdn.net` / `blog.csdn.net/gitblog_*` / `ufcn.cn` 等中文聚合站。它们声称 HibernationFixup 能"强制重写内存休眠文件头""绕过 ACPI_PRW 检查""唤醒失败时自动 fallback"，**上游 README 全文没有这些能力**（README 只声明四件事：把 `IOHibernateRTCVariables` 从系统注册表同步进 NVRAM、dump NVRAM 到文件、打 IOPCIFamily 补丁避免恢复后挂起/黑屏、自动休眠策略）。属编造，直接排除 |

### 社区处方的完整清单，以及对本机的判定

| 处方 | 出处 | 对本机 |
|---|---|---|
| `Misc/Boot/HibernateMode = NVRAM` | 全部三个 repo | **已做**（OC 第 ⑤ 段成功，§3o 已证 `[EB\|H:IS] 1`） |
| `Misc/Boot/HibernateSkipsPicker = true` | 同上 | 已做（采样时临时改 false） |
| `Booter/Quirks/DiscardHibernateMap = true` | 同上 | **已做，无效果**（§3i 实测症状不变） |
| `Booter/Quirks/RebuildAppleMemoryMap = false` | 同上，**三个 repo 全部要求** | **本机置 false 直接 panic**（§3j 实测）。这是与所有社区处方的**硬冲突**：它们的前提条件本机不满足 |
| `Booter/ReservedMemory`：Address `569344`(0x8B000) / Size `4096` / Type `RuntimeCode` / 注释 "Fix hibernate mode 25 black screen on wake" | `x1c6-hackintosh` → chrultrabook 文档 → Surface #7，三处一致 | **未试**。本机 memmap 实测该区段 `0x88000-0x9EFFF` 为 Available，冷启动与 S4 两份**完全一致**，故该 4 KiB 存在且可用作保留区 |
| `RTCMemoryFixup` + `rtcfx_exclude=80-AB` | Lenovo T530 issue #48 | **不适用**：走 NVRAM 路线后作者本人确认"不需要 RTCMemoryFixup"；且本机 `rtcfx_exclude=0E-57,5A-7F` 不与 0x80-0xAB 重叠 |
| GPRW 即时唤醒补丁 | Surface #7 | **已有**（`EFI/OC/ACPI/SSDT-GPRW.aml`） |
| `pmset restoredefaults` + `rm /var/vm/sleepimage` 让其重建 | Surface #7 明确列入"若仍不工作"的步骤 | **未试**。本机 sleepimage 为 1.00 GiB（= `Hibernate File Min`），mtime 停留在 2019-01-01，从未重建过 |
| BIOS 必须 UEFI-only、CSM 关闭 | Lenovo T530 issue #48 | **满足**（HP 白皮书 919946-004 §2.1，本代无 CSM） |

### 一条可直接排除的关键项：SS3 已经是 One

Surface #7 称"修复的关键是在 DSDT 里启用 ACPI S3"（把 `Name (SS3, Zero)` 改成 `One`）。
本机 `docs/SysReport/ACPI/DSDT.dsl` 实测：

```
5708:    Name (SS3, One)
5709:    Name (SS4, One)
...
38259:    If (SS3) { Name (_S3, Package (0x04) { 0x05, Zero, Zero, Zero }) }
38270:    If (SS4) { Name (_S4, Package (0x04) { 0x06, Zero, Zero, Zero }) }
```

⇒ 本机 `_S3` 与 `_S4` 均已导出，**该"关键步骤"对本机无意义**，不需要任何 ACPI 补丁。
这也解释了为什么普通睡眠（S3）在本机工作正常。

### 社区里"同一处方在不同系统版本上结局不同"的记录

- Lenovo T530 issue #48 第 10 条（Dell Precision 5550 用户）：照抄整套处方（含
  `RebuildAppleMemoryMap=false`）**在 Monterey 上完整可用**，但 *"Now, while this all worked
  beautifully under Moneterey, it fails miserably for Ventura. So, the research continues…"*
- 同一 issue 第 11 条：去掉 RTC blacklist、只留 ReservedMemory 后，*"I still have black screen
  wake and likely KP as fan runs full on wake."*
- 本机是 macOS 26.7.2，比 Ventura 又晚三代。

⇒ 社区共识不是"有通用解"，而是"**2018–2021 年代的处方在 Monterey 前后有效，Ventura 起大面积失效**"。

### 结论：网上有说法，但对本机只剩两条未验证项

1. `Booter/ReservedMemory` 加一条 `0x8B000 / 4096 / RuntimeCode`（三个独立项目一致，本机地址可用）。
2. 重建休眠镜像 + 重置电源管理偏好（`pmset restoredefaults`、`rm /var/vm/sleepimage`）。

两条都只改配置或只删一个可再生文件，可逆、不写固件。但按 §3o 的分段证据，黑屏发生在
ExitBootServices 之后；而这两条处方针对的都是**boot.efi 及更早**的行为，与 §3o 的死点层级不符。
即：**能试，但机制上对不齐**，期望值应压低。

## 3s 执行最后一条社区处方：UEFI/ReservedMemory（2026-10-29 14:50）

§3r 列出两条未验项，本轮只做其中真正构成变量的那一条。

### 为什么"重建 sleepimage"不算变量

休眠镜像在每次 hibernate 时**原地重写**，所以现在删掉它，下次休眠写出来的内容与不删没有区别。
而 `pmset restoredefaults` 重置的那些值（`hibernatemode`/`standby`/`hfile`）`s4-arm.sh arm` 立刻又会写回去。
⇒ 该条对失败链路没有任何输入，若一起改只会造成混淆归因（§3l 的教训：一次动 4 键导致无法归因）。
**本轮只改一个变量：`ReservedMemory`。**

### 配置落地，以及三处与社区配方的差异

条目写在 **`UEFI/ReservedMemory`**，不是社区资料常写的 `Booter/ReservedMemory`。

```xml
<key>ReservedMemory</key>
<array>
    <dict>
        <key>Address</key><integer>569344</integer>   <!-- 0x8B000 -->
        <key>Comment</key><string>Fix hibernate mode 25 black screen on wake (low S3/S4 area)</string>
        <key>Enabled</key><true/>
        <key>Size</key><integer>4096</integer>         <!-- 0x1000 -->
        <key>Type</key><string>RuntimeCode</string>
    </dict>
</array>
```

三处差异（每一处都有源码或原文依据）：

| # | 社区配方 | 实际正确写法 | 依据 |
|---|---|---|---|
| ① | `Booter/ReservedMemory` | **`UEFI/ReservedMemory`** | `OcConfigurationLib.c:874` 只有一条：`OC_SCHEMA_ARRAY_IN ("ReservedMemory", OC_GLOBAL_CONFIG, Uefi.ReservedMemory, ...)`；表结构体名就叫 `mUefiReservedMemorySchema`。全文再无第二处。官方 `Docs/Configuration.tex` 的 `\subsection{ReservedMemory Properties}\label{uefirsvdprops}` 也位于 **UEFI 节**（6528 行起）内。`Booter` 节只有 `MmioWhitelist` / `Patch` / `Quirks` 三项（`Sample.plist` 同） |
| ② | 社区帖子只给 Address/Size/Type/Comment | 必须补 **`Enabled`**（failsafe `false`） | 源码 `OcReserveMemory()` 第一句就是 `if (!...->Enabled) continue;` ⇒ **不写 Enabled 等于没加** |
| ③ | — | `Address`/`Size` 必须 4 KB 对齐 | 源码对非对齐直接 `Status = EFI_INVALID_PARAMETER` 并跳过 |

地址核对（用本机实测 memmap，不靠猜）：`0x8B000` 落在 `Available 0x88000-0x9EFFF`，
**冷启动与 S4 两份完全一致**；`0x8B000`/`0x1000` 均 4 KB 对齐；该区段属 `EfiConventionalMemory`
⇒ 满足文档「必须属于内存映射、类型为 EfiConventionalMemory、4 KB 对齐」三项前提。

### 机制上这次是能对上的（与 §3r 的判断不同）

`Docs/Configuration.tex` 对 `UEFI/ReservedMemory` 的原文说明正是一条 S4 处方：

> *Note: Some types of firmware may not allocate memory areas used by S3 (sleep) and S4 (hibernation)
> code unless CSM is enabled causing wake failures. After comparing the memory maps with CSM disabled
> and enabled, these areas can be found in the lower memory and can be fixed up by doing the reservation.*

即「UEFI-only 固件可能根本不分配 S3/S4 代码所需的内存区，导致唤醒失败；用保留区把它钉住」。
本机恰好是 UEFI-only 无 CSM，与这段话描述的前提完全吻合。

### 生效时机：在 picker 之前，因此可以当场验证

`OcReserveMemory()` 被 `OcLoadUefiSupport()` 调用（`OpenCoreUefi.c:994`），位于
**驱动连接之前、picker 显示之前**；它用的是 `gBS->AllocatePages(AllocateAddress, Type, ...)`
实打实占位，不会被释放 ⇒ 冷启动与休眠唤醒两条路径都会生效，保留区也一定进到 boot.efi 看到的映射里。

副作用是**可验证**：既然在 picker 之前就完成，那么在 picker 里进 OpenShell 采 memmap，
应当能直接看到 `0x8B000` 从 `Available` 变成 `RT_Code`。

而 OC 本机是 **RELEASE** 版，`OC: Reserving region %Lx of %Lx size - %r` 是 `DEBUG_INFO`
级（仅 DEBUG/NOOPT 构建输出）⇒ **日志里查不到**，只能靠 memmap 看。
为此给 `s4-memmap.py` 加了 `probe <addr>` 子命令。

### 本轮同时做的两件事

| 项 | 改动 | 理由 |
|---|---|---|
| `Misc/Boot/HibernateSkipsPicker` | `false` → `true` | 采恢复态时临时关掉，现在回到 §3o 验证过的基线：`true` 下"不弹 picker"才是 OC 认出休眠的表现 |
| `s4-memmap.py` | 新增 `probe 0x8B000`；`save` 放开自定义 tag | 验证保留区是否生效；便于把验证采样单独归档 |

`Misc/Tools` 的 OpenShell 条目保留（验证要用）。`Timeout` 保持 `5`。

### 判读

| 现象 | 含义 | 下一步 |
|---|---|---|
| picker 里 `probe 0x8B000` 报 `RT_Code` | 保留区生效，配置被 OC 接受 | 继续睡，看能否恢复 |
| 仍报 `Available` | `OcReserveMemory` 分配失败（该地址在 OC 运行前已被占用） | 换地址（在低端 Available 里另选），或判定该手段对本机无效 |
| 配置读错（比如 Key 拼错） | OC 会整段忽略 | 见上：必然报 `Available` |

无论哪一种，本轮之后 `ReservedMemory` 这条线都可以收敛，不再有"也许没配对"的余地。

### 3t. ReservedMemory 实测已生效（2026-10-29 15:00）

`probe 0x8B000` 结果：

```
源文件 = /Volumes/ESP/memmap.txt   段数 = 43
查询地址 = 0x000000000008B000 (569344)
落在  RT_Code       0x000000000008B000 - 0x000000000008BFFF  (4 KiB)
```

原始行（归档于 `docs/s4-memmap/memmap-cold-reservedmem.txt`）：

```
RT_Code    000000000008B000-000000000008BFFF 0000000000000001 800000000000000F
```

判读三件，缺一不可：

| 观察点 | 值 | 含义 |
|---|---|---|
| 类型 | `Available` → `RT_Code` | `AllocatePages(AllocateAddress)` 确实占到了这个地址 |
| 属性 | `0x800000000000000F` | bit63 = `EFI_MEMORY_RUNTIME` ⇒ ESRT 之后仍映射，`SetVirtualAddressMap` 后 boot.efi 可寻址 |
| 大小 | 1 页 = 4 KiB | 与 config 的 `Size 4096` 一致，无越界吞邻段 |

⇒ 配置被 OC 正确解析（`Enabled`/`Address`/`Size`/`Type` 四项全部吃到），
§3s 判读表的第二、三行（"分配失败""配置读错"）均已排除。**这是本轮唯一的变量，已确认在位。**

顺带记一条：本次冷启动 43 段，`memmap-cold.txt`（3h 基线）55 段，两者除保留区外无其他
固定区差异——**自由池碎片数每次开机都在变**（`RebuildAppleMemoryMap=true` 每次重建映射），
故"段数"本身不能当判据，只能看固定区（Reserved/ACPI/MMIO/RT*）是否逐元素相等。

### 3t-补. 下一步实验：直接睡

`ReservedMemory` 已生效在 `AllocatePages` 占位层面，但**它是否救得了唤醒是另一件事**，
只能靠一次真睡（`hibernatemode 25` + AC）来判：

| 步骤 | 命令 / 动作 | 判据 |
|---|---|---|
| 1 | `sudo bash EFI/scripts/s4-arm.sh arm` | 最后一行 `hibernatemode=25` 且内核态同步为 25 |
| 2 | 苹果菜单 → 睡眠 | 电源灯灭、风扇停 ⇒ 写完镜像真断电；`HibernateSkipsPicker=true` 下**不弹 picker** 才是正常 |
| 3A | 若上述成立 | 按电源键唤醒，看是否恢复桌面 = 成功收敛 |
| 3B | 若灯重新亮 + 黑屏（老症状） | 长按电源键 10s 断电重启，进系统跑 `bash EFI/scripts/s4-log-collect.sh` |
| 3C | 若仍弹 picker | OC 没读到 `IOHibernateRTCVariables` ⇒ NVRAM 路线本身失效，与保留区无关 |

3B 与 §3o 那次（13:00，`REAN:END` 534ms、`HB|DT 3 0`、无 `HB|! <- BS.Exit`、`EXITBS:START`）
对齐比较；若日志形态完全一致，则说明"钉住低内存"不是缺口，缺口仍在
`hibernate_kernel_entrypoint()` 之后的 wired pages 还原。

⚠️ 测完必须 `sudo bash EFI/scripts/s4-arm.sh disarm` 回滚，否则 AC 侧长期停在
`sleep 0 / hibernatemode 25`，任何一次手动睡眠都会走 S4 黑屏。

---

### 3u. ReservedMemory 实测**未能救回唤醒**，并推翻一条判据（2026-10-29 15:15）

现场（用户口述 + 事后取证）：

```
15:04:43  Entering Sleep（AC 100%，hibernatemode 25）
15:05:28  boot.efi 启动，H:IS 1 → 认出休眠
15:05:29  REAN:END 686ms / HB|DT 3 0 / EXITBS:START（无 HB|! <- BS.Exit）
          → 黑屏
15:06:2x  机器**自动复位**（非人工长按），POST 阶段报 **005**
15:06:32  新内核 boottime
```

⇒ 与 §3o（13:00）**同形态**，死点不变：仍在 `hibernate_kernel_entrypoint()` 之后。
唯一可观测的差别是**失败表现**：那次是卡死不动，这次是自动复位。

### 判据更正（重要，写下来防止再犯）

| 我曾用的判据 | 为什么错 |
|---|---|
| "ESP 上没有第二份 `opencore-*.txt` ⇒ 没有重启" | **不成立**。硬件复位/自动复位后那次引导不保证落到 AppleDebug 文件（本次就没有）。同理也不能反推"有日志=正常"。 |
| "powerd 报 `since boot at 14:58:34` ⇒ 内核是 14:58 那个实例" | 不可靠，powerd 的 boot 标识可跨复位沿用。 |
| `kern.hibernatemode` 25→1 | 本次实测**会**回 1，不能当"内核被重建"的证据，也不能当反证。 |

**唯一可靠的两条**：
- `kern.boottime` + `uptime`（新内核就是新的 boottime，且与上一 boot 的时间戳不连续）
- 用户侧现象（是否黑屏、是否手动复位、App 是否原样）

### 005 是什么：设计内副作用，不是新问题

`005` = HP BIOS 的 **RTC Power Loss / CMOS 校验和错误**。根因就是本路线的武装项本身：

- `Kernel/Quirks/DisableRtcChecksum=false` ⇒ 允许 AppleRTC 更新 `0x58/0x59` 主校验和
- `rtcfx_exclude=0E-57,5A-7F` ⇒ 放开该区，不被 RTCMemoryFixup 挡

macOS 睡下时改了 CMOS 内容，BIOS 侧的校验和对不上 ⇒ 冷启动 POST 报 005。
这是"让密钥活过断电"必须付的代价，与 ReservedMemory 无关，也与 S4 失败无因果。

### 结论与下一步（候选，未执行）

`ReservedMemory` 这条线可以判定为**无效**——它精确生效了（§3t），但没有改变死点。

剩下三条未验证方向，按风险从低到高：

| 方向 | 改动 | 理由 | 风险 |
|---|---|---|---|
| A | `Booter/Quirks/RebuildAppleMemoryMap` true → **false** | 恢复要求 boot.efi 交出的映射与写镜像时一致；OC 每次重建映射与"绝对物理地址装回"直接冲突 | 中：老系统需要 Apple 映射，可能起不来 |
| B | `Booter/Quirks/DiscardHibernateMap` false → **true** | 反过来：丢弃镜像里的映射、改用当前映射。语义与 A 相反，只能二选一 | 中：改错方向等于放弃镜像里的正确映射 |
| C | 接受现状：不改 config，把 AC 侧 `hibernatemode` 退回 3（S3 standby） | S3 在本机可用且不掉电风险低 | 低，但等于放弃 S4 |

A 与 B 是互斥的两条路，必须先用一次对照实验判定"当前映射与镜像映射谁是对的"，
**不能同时改**。§3q 的 memmap 对照只证明了固定区一致，未证明 boot.efi 交出的映射
与镜像内保存的映射逐字节相同——这才是缺口所在，也是下一步该先取证的点：
需要一份**休眠镜像头部保存的映射**与**当前 boot 映射**的对比。


### 3v. 复位性质判定 + kext 能力清单（2026-10-29 15:20）

用户确认：**复位是机器自己触发的，非人工长按**。

配套取证（三条同时为空）= 硬复位，无软件 panic：

| 取证点 | 结果 |
|---|---|
| `/Library/Logs/DiagnosticReports/*.panic` | **0 份**（含 Retired） |
| `/cores/` | 空 |
| `nvram -p` 里的 panic 痕迹 | 无（只有 `prev-lang:kbd`） |

⇒ 内核在恢复早期就触发了复位（triple fault / machine check 一类），**来不及写 panic**。
这与"死在 `hibernate_kernel_entrypoint()` 之后的 wired pages 还原"完全吻合，
且比 13:00 的"卡死"更早失败——`ReservedMemory` 改变了内存布局，只是换了失败形态。

### 本机 HibernationFixup 1.5.4 实际支持的开关（`strings` 实测）

```
-hbfxoff  -hbfxdbg  -hbfxbeta  -hbfxforce
-hbfx-dump-nvram  -hbfx-disable-patch-pci
hbfx-patch-pci  hbfx-ahbm
```

上游 README 关键三条（lvs1974/HibernationFixup，已核实原文）：

1. **`-hbfx-disable-patch-pci`** — 禁用 IOPCIFamily patch。而该 patch 的官方定位正是
   *"to avoid hang & black screen after resume"*，且 *"automatically enabled in macOS Sierra 10.12.1 or later"*
   ⇒ **本机（macOS 26）本就自动开着**，症状与它要解决的问题同型，说明 patch 在跑但没兜住。
2. `hbfx-patch-pci=XHC,IMEI,IGPU` — 指定"**不**调用 `restoreMachineState`"的设备白名单，支持 `none|false|off`。
3. `hbfx-ahbm=N` — 只控制**何时**自动休眠，与恢复失败无因果关系。

⇒ 参数层面上**没有**针对"恢复入口崩"的开关可用。`-hbfx-disable-patch-pci` 属反向验证，
README 明写它会放弃一个正是用来防黑屏的补丁，预期更差。


### 3w. 原理层面的结论：不是缺 quirk，是缺固件契约（2026-10-29 15:22）

#### 为什么恢复对内存布局的容忍度是零

`hibernate_kernel_entrypoint()` 执行时 **translation off**（分页还没开）。它做的第一件事是从
`__HIB` 段取镜像里保存的页表模板、按**物理地址**直填重建页表，然后才开分页、跳到恢复后的内核。

⇒ 镜像里每个页的目标地址是**写死**的；页表本身也在镜像里。
⇒ 只要有任意一个目标页的内容在恢复前被覆盖，重建出的页表就指向垃圾，下一秒取指即 fault。

**这解释了"零 panic"**：此刻 IDT 还没恢复，异常无法处理 ⇒ 直接三重故障 ⇒ CPU 复位。
硬复位、无 panic、无 core，三条特征全部吻合，不是巧合。

#### 真机 vs 黑苹果：S4 期间固件做了什么

| | 真机（Apple 固件） | 本机（HP UEFI + OC） |
|---|---|---|
| S4 断电期间 | 固件保留 resume 上下文 | 无，固件不知道发生过什么 |
| 上电 | 走 **S4 resume 路径**，内存控制器 / PCI 恢复到休眠前状态 | 走**完整冷启动 POST**：内存重新训练、PCI 重新枚举、ME/固件保留区被重写 |
| 交给 boot.efi 的 | 与休眠时一致的布局 | 冷启动后的新布局 |

boot.efi 会按镜像里的绝对地址写回，这点它做对了（日志实证 `H:IS 1` / `REAN:END` / `HB|DT 3 0`）。
但**写回的目标区在 POST 之后可能已经被固件或 OC 自己用过**，而这一层 OC 无从控制。

#### 为什么 ReservedMemory 精确生效却毫无效果（原理自洽）

OpenCore 文档那段原文的完整主语是 *"memory areas used by **S3 (sleep) and S4 (hibernation) code**"*
—— 指的是**固件自己的** S3/S4 处理代码所需的内存（CSM 关闭时固件不分配它）。

而 macOS 的 hibernation 恢复路径里，**固件的 S4 代码一次都没执行**：它只是冷启动，然后由
boot.efi 从磁盘读镜像。钉住固件 S4 代码的内存，对一条根本不经过固件的恢复路径自然毫无意义。

⇒ 这就是"钉 4 KiB 能精准验证生效、结果却一模一样"的唯一自洽解释。这条社区处方张冠李戴，
从原理上就不该指望它。

#### 三个必须同时成立的条件（本机逐条不成立）

1. 冷启动后的物理布局与休眠瞬间逐页相同 —— `RebuildAppleMemoryMap=true` 每次重建，天然违反
2. boot.efi / OC 运行期不占用镜像里的任何目标页 —— 无法从 OC 侧控制
3. 硬件状态可由软件完整回放 —— PCI 设备（尤其 P620）有只写或需特定时序的寄存器，回放不全

`DiscardHibernateMap=true` 只影响 macOS 侧的**映射描述符**，不改 boot.efi 的**物理写回**行为，
所以原理上也救不了——不建议再试。


### 3x. 机制层：恢复期的三条硬约束（xnu 源码实证，2026-10-29 15:25）

来源：`apple-oss-distributions/xnu @ xnu-8792.61.2`
- `osfmk/i386/hibernate_restore.c`
- `osfmk/i386/hibernate_i386.c`

#### 约束一：恢复早期只有前 4 GB 是恒等映射

`pal_hib_map()` 原文：

```c
if (phys < WKDM_AREA) {
    // first 4Gb is all mapped,
    // and do not expect source areas to cross 4Gb
    return phys;
}
index = (virt >> I386_LPGSHIFT);
...
BootPTD[index] = phys;
invlpg(virt);
```

配合 `extern pd_entry_t BootPTD[2048]`：2048 × 2 MB = **4 GB**。
前 4 GB 直通，超过 4 GB 的物理页必须靠动态改写 `BootPTD[index]` 来临时映射。
注释里那句 *"do not expect source areas to cross 4Gb"* 是 Apple 自己写死的假设：
源缓冲区不得跨 4 GB 边界。本机 16 GiB，镜像页绝大部分在 4 GB 以上。

#### 约束二：镜像存什么，由 EFI MemoryMap 的**类型**决定，不是"整块内存"

`hibernate_page_list_allocate()` 按 `args->MemoryMap` 逐条分类：

| EFI 类型 | 是否进镜像 |
|---|---|
| `ConventionalMemory` / `LoaderCode` / `LoaderData` / `BootServicesCode` / `BootServicesData` | **保存** |
| `ACPIMemoryNVS` / `PalCode` | 保存（计入 non_os_pagecount） |
| `RuntimeServicesCode` / `RuntimeServicesData` | **不保存** — 注释 `runtime services will be restarted, so no save` |
| `ACPIReclaimMemory` | **不保存** — 注释 `contents are volatile once the platform expert starts` |
| `Reserved` / `Unusable` / `MMIO` / `MMIOPortSpace` | 不保存 |

⇒ 镜像内容的正确性，**完全取决于 boot.efi 拿到的那张 MemoryMap 是否与内核休眠时所见的真实占用一致**。

#### 约束三：这张表在黑苹果上不是固件给的

`args->MemoryMap` 来自 `PE_state.bootArgs`，而 boot_args 由 boot.efi 填写，boot.efi 从 UEFI 拿表——
本机上那就是 **OpenCore 重建后**的表（`RebuildAppleMemoryMap=true` 每次开机重排）。

真机的闭环是：Apple 固件产表 → 内核按表存页 → S4 → 固件 resume 后**重建 runtime services** → boot.efi 按同一语义还原。
黑苹果的闭环缺最后一环：`OpenRuntime.efi` 驻留在 `kEfiRuntimeServicesCode` 里，
按约束二**不进镜像**，于是恢复期那片区域被视为 scratch 可随意使用，
而 OC 的 runtime 代码恰恰常驻其中。

#### 这套机制能一次性解释全部三个反常

| 反常现象 | 机制解释 |
|---|---|
| boot.efi 全流程绿灯（`H:IS 1` → `REAN:END` → `HB\|DT 3 0` → `EXITBS`） | 它只负责"按表还原"，表错了它也照样报告成功 |
| 零 panic / 零 core / 硬复位 | 页表模板指向垃圾 ⇒ 取指 fault ⇒ IDT 尚未恢复 ⇒ 三重故障 |
| 改 ReservedMemory 后从"卡死"变成"自动复位" | 约束一：改的是 4 GB 内的映射与占用，扰动 `BootPTD` 的真实映射关系，换了个崩法 |

⚠️ 依据强度：约束一、二、三是**源码原文**（可直接核对）。
"OC runtime 区被当 scratch 覆盖"是**由约束二推出的机制假设**，尚无本机实证——
验证需要镜像内的 page bitmap 与本次 boot 的 MemoryMap 逐段比对，而镜像在恢复后被 truncate，
除非在睡眠后、唤醒前抓到 sleepimage，否则无法取证。


### 3y. "还有解吗"——把问题拆成三问（2026-10-29 15:30）

#### 先拆诉求

| 诉求 | 是否依赖固件契约 | 结论 |
|---|---|---|
| ① S4 深休眠能唤醒（0 掉电） | **是** | 本机缺口在内存映射层，无观测通道，盲改 |
| ② 长时间不用时不掉电 | 否 | 有解，但不是 S4（关机 / S3） |
| ③ 不再黑屏卡死 | 否 | **有解且应立即做**：AC 侧 `hibernatemode 0` |

②③ 一开始就有解，只是之前被"S4"这个目标盖住了。

#### 已排除（均有实测或源码依据，不再讨论）

| 项 | 依据 |
|---|---|
| 固件不支持 S4 | DSDT `_S4` 已导出（§3r） |
| OC 读不到休眠密钥 | 日志 `H:IS 1`，picker 已跳过（§3o） |
| boot.efi 流程有问题 | `CHK BM 0x0` / `REAN:END` / `HB\|DT 3 0` / `EXITBS` 全绿 |
| `UEFI/ReservedMemory` 0x8B000 方案 | 精确生效（§3t）但失败形态不变（§3u） |
| HibernationFixup 参数层 | 本机 1.5.4 全部开关已列，无针对恢复入口的（§3v） |
| `DiscardHibernateMap` | 只改映射描述符，不改 boot.efi 物理写回（§3w） |

#### 还能动的三条（按性价比排序，全部属盲改）

| 实验 | 改动 | 命中的机制约束 | 我评估的成功率 | 代价 |
|---|---|---|---|---|
| **D1** | AC 侧 `hibernatemode 0`（彻底不写镜像） | 不适用（放弃 S4） | 诉求③ 100% | 5 分钟，可逆 |
| **D2** | `Booter/Quirks/RebuildAppleMemoryMap` true → false | 约束三：让 OC 不再每次重排 map | **<15%** | 一个布尔；可能起不来，回滚走 `/Volumes/ESP/config.plist.safe` |
| **D3** | `UEFI/ReservedMemory` 补两条，钉住整块 RT 区（`0x764BB000-0x769BAFFF` 5.0 MiB + `0x769BB000-0x76C9EFFF` 2.9 MiB） | 约束二：RT 区不进镜像却住着 OpenRuntime | **<10%** | 需先核 OC 对 `Type` 的语义；每次实验 = 一次睡眠 + 可能一次硬复位 + 一次 POST 005 |

D2 与 D3 都是"改一次、睡一次、看黑不黑"的二分法，**没有任何中间观测量**——
`EXITBS` 是 apple debug 的物理上限，之后只能靠现象。这正是"性价比极低"的来源，
不是"没想法"，而是"每次想法都要用一次硬复位去换一个 bit"。

#### 为什么不能断言"绝对不可能"

`HibernationFixup` 主补丁的官方定位就是 *"avoid hang & black screen after resume"*，
说明**社区确实有机器把 S4 恢复跑通了**。本机的问题不是原理上禁止，而是缺口恰好落在
管不到的那一层（恢复期的物理页布局）。所以准确说法是：**在现有可观测手段下，投入产出比已经为负**，
不是"物理上不可能"。


---

### 3z. 恢复链的完整硬约束 + 全部剩余干预点（2026-10-29 15:35，源码级）

来源（均逐字核对原文）：
- `osfmk/i386/hibernate_restore.c` — `pal_hib_map` / `hibernate_restore_phys_page`
- `osfmk/i386/hibernate_i386.c` — `hibernate_page_list_allocate` / `hibernate_page_list_set_volatile` / `hibernate_processor_setup`
- `osfmk/i386/pal_hibernate.h` — AREA 常量与 `HIB_ENTRYPOINT`
- `HibernationFixup/kern_hbfx.cpp` — PCI 补丁真实行为

#### 3z.1 AREA 布局（`pal_hibernate.h` 原文，这解释了之前所有"4GB"的说法）

```c
#define HIB_MAP_SIZE    (2*I386_LPGBYTES)      /* 4 MB */
#define DEST_COPY_AREA  (4*GB - HIB_MAP_SIZE)  /* 4GB - 4MB  = 0xFFC00000 */
#define SRC_COPY_AREA   (DEST_COPY_AREA - HIB_MAP_SIZE)
#define COPY_PAGE_AREA  (SRC_COPY_AREA  - HIB_MAP_SIZE)
#define BITMAP_AREA     (COPY_PAGE_AREA - HIB_MAP_SIZE)
#define IMAGE_AREA      (BITMAP_AREA    - HIB_MAP_SIZE)
#define IMAGE2_AREA     (IMAGE_AREA     - HIB_MAP_SIZE)
#define SCRATCH_AREA    (IMAGE2_AREA    - HIB_MAP_SIZE)
#define WKDM_AREA       (SCRATCH_AREA   - HIB_MAP_SIZE)  /* 4GB - 32MB = 0xFFE00000 */
#define HIB_ENTRYPOINT  acpi_wake_prot_entry
```

⇒ 八个 AREA 全部挤在 `4GB-32MB` ~ `4GB-4MB`，各占 4 MB。映射靠 `BootPTD[2040..2047]` 这 8 项。
⇒ 入口是 `acpi_wake_prot_entry`，不是泛指的"hibernate_kernel_entrypoint"。

#### 3z.2 `hibernate_restore_phys_page` 的两个致命细节（原文）

```c
if (src == 0) return (uintptr_t)dst;          /* ① 零页直接跳过，不写！ */
d = (uint64_t *)pal_hib_map(DEST_COPY_AREA, dst);
__nosan_memcpy(d, s, len);
```

```c
if (phys < WKDM_AREA) return phys;            /* ② < 4GB-32MB 直接当虚拟地址用 */
...
BootPTD[index] = phys; invlpg(virt);          /* ③ ≥ 该值才动态改页表 */
```

```c
default: asm("cli;hlt;"); break;              /* ④ 非法 AREA 直接停机，不是复位 */
```

④ 是"卡死不动"这个失败形态在源码里的唯一对应物（13:00 那次）。

#### 3z.3 新增关键事实：EFI runtime 区被显式标成 scratch（原文）

```c
void hibernate_page_list_set_volatile(hibernate_page_list_t *page_list, ...)
{
	boot_args *args = (boot_args *)PE_state.bootArgs;
	if (args->efiRuntimeServicesPageStart) {
		hibernate_set_page_state(page_list, page_list_wired,
		    args->efiRuntimeServicesPageStart, args->efiRuntimeServicesPageCount,
		    kIOHibernatePageStateFree);
		*pagesOut -= args->efiRuntimeServicesPageCount;
	}
}
```

配合 `hibernate_processor_setup()` 把同一组值写进镜像头：

```c
header->runtimePages        = args->efiRuntimeServicesPageStart;
header->runtimePageCount    = args->efiRuntimeServicesPageCount;
header->runtimeVirtualPages = args->efiRuntimeServicesVirtualPageStart;
```

⇒ 恢复期内核会把 **`efiRuntimeServicesPageStart` 起的全部 RT 页当作可自由使用的 scratch**。
本机该范围 = `RT_Code` 1280 页 + `RT_Data` 740 页 = **2020 页 ≈ 7.9 MiB**，物理落在
`0x764BB000-0x76C9EFFF`（约 1.85 GB 处）——**而 OpenRuntime.efi / OpenVariableRuntimeDxe.efi 的代码此刻正躺在这里。**

#### 3z.4 实测推翻上一轮的"地址漂移"假设

三次独立采样，RT/ACPI_Recl 段地址**逐字节相同**：

| 采样 | RT_Code | RT_Data | ACPI_Recl |
|---|---|---|---|
| `memmap-cold.txt`（3h 基线） | `0x764BB000` | `0x769BB000` | `0x77B9F000` |
| `memmap-cold-reservedmem.txt` | `0x764BB000` | `0x769BB000` | `0x77B9F000` |
| `memmap-s4.txt`（唤醒前） | `0x764BB000` | `0x769BB000` | `0x77B9F000` |

⇒ §3x 里"OC runtime 每次开机落点不同、与 header 记录不符"的说法**作废**。
地址是稳定的，`header->runtimePages` 在恢复时仍然指向同一批物理页。

⇒ 但**另一个问题反而被这条坐实**：地址既然稳定，那么"恢复期把这块当 scratch 写"就
**必然覆盖 OpenRuntime 的代码**（而不是"可能覆盖到别处去"）。

#### 3z.5 HibernationFixup 的 PCI 补丁真相（与 §3v 的记录不同，特此更正）

hook 的是 `IOPCIBridge::restoreMachineState` 与 `IOPCIDevice::extendedConfigWrite16`，
**不保存也不还原任何配置数据**，只在 `kMachineRestoreDehibernate` 期间把标志置位，
然后给 PCI **Command 寄存器**强制补 `kIOPCICommandMemorySpace` 位：

```cpp
if (callbackHBFX->correct_pci_config_command && offset == WIOKit::PCIRegister::kIOPCIConfigCommand) {
	if (!(data & kIOPCICommandMemorySpace)) data |= kIOPCICommandMemorySpace;
}
```

⇒ 这说明 **Apple 自己承认 de-hibernate 路径下 PCI Command 寄存器的 Memory Space Enable
可能丢失**，需要软件补。补丁生效范围仅此一位，MSI/MSI-X enable、BAR、PCIe ASPM 均未回放。

#### 3z.6 从未验证过的一项：镜像容量

| 项 | 值 |
|---|---|
| 物理内存 | 16 GiB |
| `Pages wired down` | 940,251 页 = **3.59 GiB** |
| `/var/vm/sleepimage` | **1.00 GiB** |
| `IOPMrootDomain: Hibernate File Min` | 1,073,741,824（= 1 GiB，即当前文件正好等于系统下限） |

⇒ 1 GiB 要装下 3.59 GiB wired 的压缩结果，压缩比必须 ≥ 3.6:1（WKDM 典型 2–3:1）。
若写镜像阶段空间见底，`pagesOut` 与实际写入量不匹配，恢复时序号错位 ⇒ 必崩。
**这条从来没被检查过**，而且完全在软件侧可控（扩文件 + 重启）。


#### 3z.7 实验 E1：扩容 sleepimage（已就绪，2026-10-29 15:40）

按"实验三件事"先写清楚，再动手：

| 项 | 内容 |
|---|---|
| **假设** | 镜像容量 1 GiB < wired 3.7 GiB 的压缩需求 ⇒ 写镜像阶段截断/页序错位 ⇒ 恢复时 `hibernate_restore_phys_page` 把 A 页内容写进 B 页地址 |
| **改动** | 仅 `/var/vm/sleepimage`：1 GiB → 8 GiB（`mkfile -n`，稀疏）。**不动 config.plist、不动 kext、不动 boot-args** |
| **预期形态** | 成功 = 唤醒后进入桌面、App 原样；失败 = 与 §3u 完全一致（灯灭 → 自复位 → POST 005） |
| **判据** | ① 重启后 `size` 是否仍为 8 GiB（若被系统缩回 1 GiB ⇒ 系统强制按 `Hibernate File Min` 裁剪，本假设作废）；② `pmset -g log` 有无 `insufficient` / `HibernateError`；③ 唤醒后 `kern.boottime` 是否连续 |
| **回滚点** | `sudo bash EFI/scripts/s4-expand-image.sh restore`（删文件，下次启动系统按 Min 重建 1 GiB） |
| **不可逆风险** | 无。只占 8 GiB 磁盘（卷余 192 GiB）；sleepimage 内容无价值（写时被整体覆盖） |
| **为何必须先重启** | `IOHibernateIO` 在启动时把文件大小读进内核对象，运行中改文件不更新已缓存值 |

脚本：`EFI/scripts/s4-expand-image.sh`（`status` / 默认扩 8 GiB / `restore`）。

#### 3z.8 E1 判定：**扩容无效，系统强制重建**（2026-10-29 15:45，铁证）

| 时间 | 事件 |
|---|---|
| 15:41:11 | 脚本执行，日志记录 `before: size=1073741824` / `target: 8 GiB` |
| 15:41:1x | `mkfile -n 8g` 把文件扩到 8 GiB |
| 15:42:00 | 重启（`kern.boottime`） |
| **15:42:18** | **文件 `birth`（全新 inode）—— 系统删掉 8 GiB 文件、新建 1 GiB** |
| 15:42:24 | `mtime` / `ctime` |

`stat` 三时间戳同时落在 boottime 之后 18–24 秒 ⇒ 这是**系统主动重建**，不是残留。

⇒ **E1 作废**。但要说清作废的准确含义：
不是"1 GiB 证明够用"，而是"macOS 在启动时校验 sleepimage header，不合格就按
`Hibernate File Min` 重建；`mkfile` 造出来的空文件没有合法 header，必然被重建"。
**这次实验根本没跑到"8 GiB 能否工作"那一步。**

⇒ 推论：想让大镜像生效，必须**保留合法 header 只扩大小**，即先让系统写一次真镜像，
再在保留 header 的前提下扩展。而"写一次真镜像"可以用 `hibernatemode 3` 做到（见 E2）。


#### 3z.9 E2：不再盲改——用 `hibernatemode 3` 取一份真镜像做观测（2026-10-29 15:50）

**这一轮不是改配置，是举证。** 前面的困境是 `acpi_wake_prot_entry` 之后没有任何观测通道，
所以每条假设都要烧一次硬复位。但有一条绕过去的办法：**镜像本身就是恢复的全部输入**，
把镜像拿出来分析，等于在恢复发生之前看到"内核准备还原什么"。

| 为什么 mode 25 拿不到，mode 3 可以 | |
|---|---|
| mode 25 | 写完镜像立刻断电 → 恢复后内核 truncate 镜像 ⇒ 内容没了 |
| mode 3 | 写**同一份**镜像，但保持 RAM 供电走 S3 → 唤醒不经过 `boot.efi` → **镜像原样保留** |

**等价性依据**：两者都走 `IOHibernateSystemSleep` → `hibernate_page_list_allocate` →
`hibernate_page_list_setall` → 写 header + bitmap + 页数据，**唯一的差别是写完之后的动作**
（mode 25 断电 / mode 3 留 RAM）。所以 mode 3 拿到的镜像，就是 mode 25 会拿去恢复的那一份。

| 项 | 内容 |
|---|---|
| **改动** | `sudo pmset -a hibernatemode 3` + `sudo pmset -a standby 0`（防 5 分钟后自动转 S4）。**不动 config、不动 kext** |
| **预期** | 电源灯不灭、风扇停、1–2 分钟后按电源键直接回桌面（S3 路径，不经过 boot.efi，不会黑屏） |
| **判据** | 醒后 `/var/vm/sleepimage` 仍是完整镜像；`hib-header.py` 输出 signature 有效、`imageSize ≤` 文件大小、三项校验和 `actual == 计划` |
| **意外收获** | 若 1 GiB 真装不下 3.7 GiB wired，写镜像阶段就会失败，`imageSize` 字段或日志会直接露馅——**这就是 E1 想验而没验成的那件事** |
| **回滚** | `sudo pmset -a hibernatemode 25`（或直接 `s4-arm.sh arm`） |
| **不可逆风险** | 无。不写 disk 结构、不碰 NVRAM 布局 |

解析器：`EFI/scripts/hib-header.py`（按 `IOHibernateImageHeader` 固定偏移解析前 232 字节，
`--memmap` 可与归档的 RT 段对照）。

#### 3z.10 更正：**不能"退回 S3"**，S3 在本机实测是坏的（2026-10-29 15:50）

前面 §3y / §3z 里我反复写"建议收摊退回 S3"，这是**错的**，两处都错：

**错一：S3 用不了。** 2026-09-17 已强制实测过一次（撤 `\_SB.LPS0` 让 `IOPMDeepIdleSupported` Yes→No）：

| 项 | 数值 | 来源 |
|---|---|---|
| 唤醒耗时 | **159.336 s**（正常 2.430–2.617 s，65×） | `docs/sleep-status-summary-2026-10-09.md:145` |
| PS2 恢复 | **157,735 ms**（正常 457–466 ms，342×） | 同上 |
| panic | **1**（NMIPI TLB flush timeout） | 同上；本机唯一 panic |
| 机理 | `AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ USB 栈 panic | `docs/firmware-facts-ledger.md:395` |

外加 OC-Little 原文：「SSDT-DeepIdle 和 S3 睡眠可能有严重冲突，使用 SSDT-DeepIdle 应避免 S3 睡眠」。
⇒ **强制 S3 = 把能用的睡眠换成会 panic 的睡眠。**

**错二：根本不需要"退回"。** 日常睡眠本来就不是 S3，是 **Deep Idle（S0ix）**：

- `pmset -g log`（10-27～10-28 共 6 次）：唤醒**全部** `Wake from Deep Idle [CDNVA]`，
  无一条 `Wake from S3` / `Wake from Hibernate`；即时 10-28 17:45 那条也是 `DarkWake to FullWake from Standby`。
- 成因：`SSDT-DeepIdle` 的 `\_SB.LPS0` ⇒ `IOPMDeepIdleSupported` ⇒ 平台有更优选择就不选 `_S3`。

⇒ 所以"兜底"不是 S3，**就是现状**：不作任何改动，继续走 Deep Idle，代价是 5.5–5.6 %/h / ≈3.7 W。
"收摊"= 保持现状 + AC 侧 `hibernatemode 0`（不写镜像、永不进 S4 恢复路径），而不是切 S3。

**对 E2 的影响：无。** E2 用的是 `hibernatemode 3`（写镜像 + 保 RAM），不是 S3。
物理睡眠态仍由平台选 Deep Idle，不经过 `_S3`，所以 09-17 那条 EC/PS2 死等链路不会被触发。

#### 3z.11 E2（mode 3 取样）判定：**失败——Deep Idle 平台下 mode 3 不写镜像**（2026-10-29 15:56）

实测（一次完整 mode 3 睡眠）：

| 项 | 睡前 | 醒后 | 判读 |
|---|---|---|---|
| `pmset` AC `hibernatemode` | 3 | 3 | 配置生效 |
| `IOPMrootDomain "Hibernate Mode"` | 3 | 3 | 内核对象生效 |
| `kern.hibernatecount` | 0 | **0** | `IOHibernateSystemSleep` 根本没跑 |
| sleepimage `mtime` | 15:51:51 | **15:51:51（未变）** | 一个字节都没写 |
| 睡眠区间 | 15:54:09 → 15:56:13（**124 s**） | `Wake from Deep Idle [CDNVA] : due to PWRB/User` | 走的 Deep Idle，不是 S3 |
| `HibernateStats` | hibmode=25 #80 | **hibmode=3 #81** | 模式已切，但仍未写盘 |

⇒ **mode 3 + `standby 0` 在本机不产生镜像。** macOS 早已把 safe sleep 的写盘动作
从"入睡瞬间"推迟到"**转 standby 时**"；`standby 0` 关掉了那个转换 ⇒ 永远不写。

⚠️ 顺带记一条观测陷阱：`sysctl kern.hibernatemode` 醒来后读 **0**、睡前读 **25**，
而 `pmset`/`IOPMrootDomain` 一直是 **3**。**这个 legacy sysctl 不可用作判据**，
唯一权威是 `ioreg -n IOPMrootDomain` 的 `"Hibernate Mode"`。

#### 取镜像的两条剩余通道（未执行）

| 路 | 做法 | 得到什么 | 代价 |
|---|---|---|---|
| **P1** | `s4-arm.sh arm`（mode 25）→ 睡眠 → 写盘断电 → 恢复失败 → 冷启动后立刻拷 sleepimage | 镜像样本 + **顺带第一次真正测到 E1**（现在文件 8 GiB、`Hibernate File Min` 也是 8 GiB，之前 1 GiB 那轮等于没测） | 一次黑屏 + 自复位 + POST 005 |
| **P2** | 先把 `Misc/Boot/HibernateMode` 改 `None` 再 arm+睡：OC 不把 NVRAM 里的 hibernate key 交给 boot.efi ⇒ 冷启动、**镜像不被消费** | 干净的镜像，不触发失败恢复 | 要改 config + 重启；本轮多一次引导 |

P1 优先：它同时是一次**功能性实验**（8 GiB 若够，S4 可能直接成功）与一次取样。
只有 P1 之后镜像被启动流程清掉，才退到 P2。

#### 3z.12 P1 结果：**E1 排除（8 GiB 同样失败）+ 镜像在下次启动被销毁**（2026-10-29 16:05）

**时间线**（本次为 8 GiB sleepimage 下的第一次有效 S4 测试）：

```
15:51:51  文件被扩到 8 GiB（原地扩展，birth 仍是 15:42:18）
15:59:51  Entering Sleep（hibernatemode 25 已武装）
16:00:38  OC 日志：H:IS 1 → CHK BM 0x0 → H:BI → REAN:START
16:00:39  REAN:END（939 ms）→ HB|DT 3 0 → EXITBS:START
          → 黑屏 → 硬复位
16:01:43  新内核 boottime（冷启动，无第二份 OC 日志）
```

**日志形态与 1 GiB 那次逐项同构**（070528 vs 080038）：

| 行 | 15:05（1 GiB） | 16:00（8 GiB） |
|---|---|---|
| `H:IS` | 1 | 1 |
| `EB.H.CHK\|BM` | `0x0` | `0x0` |
| `EB.H.HB\|!` | `Err(0x84) <- …R MSWr` | `Err(0x84) <- …R MSWr`（同一条） |
| `REAN:START→END` | 686 ms | **939 ms**（唯一差别） |
| `HB\|DT` | `3 0` | `3 0` |
| `EXITBS:START` | 有 | 有 |
| `HB\|! <- BS.Exit` | 无 | 无 |

⇒ **E1（1 GiB 装不下 3.5 GiB wired）正式排除**：8 GiB 下镜像写得更长（939 vs 686 ms）、
header 校验通过、boot.efi 照样全绿，死点一模一样。容量不是原因。

**镜像拿不到（关键新事实）**：冷启动后 `dd` 出来的前 4 MiB **全零**：

| 观测 | 值 |
|---|---|
| `sleepimage-p1-head.bin` 非零字节 | **0 / 4,194,304** |
| 文件 size | 8,589,934,592 → **1,073,741,824**（被截回） |
| mtime | **2019-01-01 08:01:00**（hibernate writer 写的哨兵时间戳，非真实时间） |
| birth | 15:42:18（inode 未变 ⇒ 原地截断+清零，不是重建） |

⇒ 恢复失败后**下一次 macOS 启动会把镜像截断并清零**。所以"冷启动后拷 sleepimage"这条
取样路走不通——必须在镜像被清理**之前**读它，或者让 macOS 这次启动**根本不去清理**。

#### P2′：用 `Misc/Boot/HibernateMode=None` 让启动不碰镜像（已落盘，2026-10-29 16:12）

| 项 | 内容 |
|---|---|
| **改动** | `Misc/Boot/HibernateMode`：`NVRAM` → **`None`**（ESP sha `ae94f155`，仓库/ESP 一致；深递归 diff 仅此一处） |
| **语义** | OC 不再把 macOS 写的 hibernation 数据交给 boot.efi ⇒ boot.efi 冷启动（`H:IS 0`）、**不会走恢复路径、不会黑屏** |
| **待验假设** | 镜像的截断/清零是"恢复失败后的启动清理"还是"每次启动都清理"。若只是前者，`None` 下镜像应留在盘上 |
| **判据** | 开机后立刻 `stat`：size 仍 8 GiB、mtime 仍 `2019-01-01`、前 4 字节 = `73 69 6D 65`（ASCII `sime`，magic `0x73696D65`） |
| **回滚** | `cp docs/backups/config-2026-10-29-1612-pre-capture.plist EFI/OC/config.plist` + 同步 ESP |
| **不可逆风险** | 无。只影响 OC 引导阶段是否转发休眠信息 |

#### 3z.13 "取镜像是否必要"——不必要，改走 `DiscardHibernateMap`（2026-10-29 16:20）

用户提问：`HibernateMode=None` 取样那套是不是必要动作？答案：**不是**。取镜像属**取证**，
本身不改变任何结果；它只把下一轮从"盲改"变成"有据"。而同样一次重启 + 一次睡眠的成本，
可以直接投给一条有文档依据的修复候选。

**先看不用动机器就能查到的现状**（`EFI/OC/config.plist`）：

| Booter/Quirks | 当前值 | 与本问题的关系 |
|---|---|---|
| `RebuildAppleMemoryMap` | **True** | 每次开机重建 map ⇒ 唤醒时的 map 与休眠时不同源 |
| `DiscardHibernateMap` | **False** | 正是"让内核忽略唤醒时新 map"的开关 |
| `ProtectMemoryRegions` | False | 修正 CSM/MMIO 类型误标；OC 称"仅极老固件需要" |
| `ProtectUefiServices` | False | 防固件改写服务指针；针对 VMware / GRUB 链式加载 |
| `AllowRelocationBlock` | False | OC 明写"使用重定位块时 hibernation 不受支持" |

**`DiscardHibernateMap` 的 OC 官方原文**（`Booter → Quirks`）：

> "This option forces the XNU kernel to ignore a newly supplied memory map and assume that it
> did not change after waking from hibernation. This behaviour is required by Windows to work.
> Windows mandates preserving runtime memory size and location after S4 wake."
>
> Note: "…workaround defective memory map implementations on older, rare legacy hardware…
> Do not use this option without a full understanding of the implications."

**为什么把 §3w 的排除改判**：我当时写"只改映射描述符，不改 boot.efi 的物理写回"就把它排除了——
那是**我的推断**，不是文档。文档说的是"**让内核假定 map 未变**"，而本机的客观事实恰恰是
冷启动 POST 之后 map 与休眠瞬间不同源。语义贴合度高于我此前给它的评价，应降级为"未验证"。

⚠️ 未取证的一点：我在 OpenCorePkg 的 `OcMainLib/OpenCoreKernel.c`、`OpenCorePlatform.c`、
`OcAppleKernelLib/CommonPatches.c` 三处均未找到该 quirk 的实现（`OcAfterBootLib` 路径 404），
**它到底是内核补丁还是引导期改 boot_args，未坐实**。风险按"未知但仅作用于休眠语义"处理。

#### 实验 D4（已落盘，2026-10-29 16:20）

| 项 | 内容 |
|---|---|
| **假设** | 内核恢复期用的是"唤醒时新给的 map"，与本机冷启动后的真实布局不一致 ⇒ 页表重建指向错误内容 |
| **改动** | ① `Booter/Quirks/DiscardHibernateMap`：false → **true**；② `Misc/Boot/HibernateMode`：None → **NVRAM**（回基线，否则根本不会尝试恢复） |
| **不变量** | `RebuildAppleMemoryMap` 仍 true、`ReservedMemory` 仍 1 条 0x8B000/4 KiB、boot-args 不动 |
| **预期形态** | 成功 = 按电源键后进桌面、App 原样；失败 = 与 §3z.12 完全一致（黑屏 → 自复位 → POST 005） |
| **判据** | **只有现象**。若该 quirk 是内核侧补丁，OC/boot.efi 日志**不会有任何变化**，别拿日志不变当"没生效" |
| **回滚** | `cp docs/backups/config-2026-10-29-1620-pre-discard.plist EFI/OC/config.plist` + 同步 ESP；ESP 上另留 `config.plist.bak-none`（HibernateMode=None 态）与 `config.plist.safe`（10:05 态） |
| **不可逆风险** | 低。该 quirk 只作用于休眠语义；若误伤正常启动，从 Windows 侧改 ESP 上的 config 即可恢复 |

---

### §3z.14 日志全解析：4 次真 S4 全部死在 EXITBS 之后；下午测试被判无效（2026-10-29 16:23）

#### 一、此前的检索错误（先记下来，别再犯）

ESP 根共有 **23 份** opencore 日志：20 份 `opencore-2026-10-29-*` + **3 份 `opencore-2019-01-01-*`**。
此前找文件用 `opencore-2026-10-29-*.txt`，**把 3 份 2019 命名的整个排除在外**——而它们正是下午失败那段的记录。
教训：**取日志必须 `opencore-*.txt` 全匹配**，因为 RTC 会把文件名打到 2019-01-01。

#### 二、23 份日志的形态分类（全部解析完毕）

| 形态 | 行数 | 份数 | 关键特征 |
|---|---|---|---|
| 冷启动 | 107 | 12 | `H:IS 0` → `H:NOT`，正常进系统 |
| 冷启动（RTC 已坏） | 107 | 3 | 同上，内部时间 `2019-01-01T00:00:3X` |
| **休眠恢复** | **65** | **4** | `H:IS 1` → `H:BI` → `REAN:START/END` |
| OC 走完、boot.efi 零输出 | 575 / 582 / 837 | 3 | 尾行为 `ReleaseUsbOwnership`（575/582）或 `Restoring FW NVRAM`（837） |
| **建了文件但零字节** | 0 | 1 | `051613.txt`，262144 B 全零 |

**4 次休眠恢复的时刻**：`05:00:33`、`06:32:26`、`07:05:29`、`08:00:39`。

#### 三、坐实：死点 100% 在内核侧

用户确认"**S4 就没亮起过**"。⇒ 这 4 次 `H:IS 1` + `REAN` 走完 + `EXITBS:START` 的引导，**全部黑屏**。

| 阶段 | 结果 |
|---|---|
| OC 建日志、加载 boot.efi | 4/4 正常 |
| boot.efi 读出休眠镜像设备路径（`H:BI`） | 4/4 |
| REAN（镜像重定位） | 4/4，耗时 0–1 s |
| 交出控制权（`EXITBS:START`） | 4/4 |
| 内核 `hibernate_kernel_entrypoint` | **4/4 死** |

**4 次独立复现、零次侥幸通过** ⇒ 不是偶发，是确定性故障。`EXITBS` 之前的链路已完全排除，
不再有排查价值。

#### 四、新证据：`EB.H.HB|! Err(0x84)` 是休眠路径专属

4 份 `H:IS 1` 日志里各有一条，位置固定在 `H:BI` 之后、`REAN:START` 之前：

```
#[EB.H.HB|!] Err(0x84) <- 17407E5A-AF6C-4EE8-98A8-00210453CDD9.R MSWr
```

**19 份冷启动日志里一次都没出现**。GUID `17407E5A-AF6C-4EE8-98A8-00210453CDD9` 为 Apple 厂商变量域，
`.R MSWr` 疑为某种 memory-saving write，`0x84` 未解析。**但它是被容忍的**——后面 REAN 照样走完，
所以不是失败原因，只是休眠路径的固定伴生事件。留作指纹用。

#### 五、新证据：RTC 在 08:00:38 那次恢复过程中被打回 2019-01-01

三处记录互相咬合：

| 证据 | 值 |
|---|---|
| 日志文件名 | `opencore-2019-01-01-000032/33/34.txt` |
| boot.efi 内部 `LOG:INIT` | `2019-01-01T00:00:35 / 36 / 37` |
| `/var/vm/sleepimage` 的 mtime | `2019-01-01 08:01:00` |

而 `080038.txt` 内部 `LOG:INIT` 仍是**正确的** `2026-10-29T08:00:38`。
⇒ **同一次事件之内：boot.efi 读到的 RTC 正确，22 秒后内核写盘时 RTC 已是 2019-01-01 00:01 UTC。**

`2019-01-01` 是 HP 机器 CMOS 清空后的出厂默认值。这说明:
1. 恢复路径在内核侧**确实开始执行了**（它动到了 RTC），死点不在入口之前；
2. 08:00:39 之后 RTC 一直是错的，**所有 08:00 之后的日志文件名都不可用于定时**；
3. `rtcfx_exclude=0E-57,5A-7F` 与这现象的关系未查证（该 boot-arg 本意是排除 RTC 写修正）。

#### 六、下午的测试全部作废——机器压根没进 S4

**判据 1：sleepimage 是个空壳**

```
-rw------T 1 root wheel 1073741824 2019-01-01 08:01 /var/vm/sleepimage
size=1073741824  mtime=Jan 1 08:01:00 2019  birth=Oct 29 15:42:18 2026

$ sudo xxd -l 232 /var/vm/sleepimage
00000000: 0000 0000 0000 0000 0000 0000 0000 0000   ← 前 232 字节全零
```

`IOHibernateImageHeader` 的 magic 应为 `0x73696D65`（ASCII `sime`），**实测前 232 字节全零**。
⇒ 这是个没有合法 header 的 1 GiB 空文件，系统不会拿它做 S4。

`birth=15:42:18` 但 `mtime` 比 birth 还早 8 年 ⇒ 文件在 15:42:18 被重建后，**再没被写过一次**。
`mtime=2019-01-01 08:01` 是**上午 08:00 那次写盘**留下的（当时 RTC 已坏）。

**判据 2：两次睡眠都活不到 standby 阈值**

`pmset -g custom`（AC）：`hibernatemode 25`、`standby 1`、`standbydelayhigh 300`、`standbydelaylow 300`。
E2 设的 `mode 3 / standby 0` 已不在配置里。

| 睡眠时刻 | 结束 | 时长 | 判定 |
|---|---|---|---|
| 15:54:09 | 15:56:13 `Wake from Deep Idle` | 124 s | < 300 s，**没到 standby** |
| 15:59:51 | 16:01:43 新内核 boottime | 112 s | < 300 s，**没到 standby** |
| 15:04:43 | 15:42:18 新内核 | 38 min | 够阈值，但见判据 3 |

**判据 3：15:04 那次按电源键后，日志里是 `H:IS 0`**

3 份 `2019-01-01` 日志全是 `H:IS 0` + `H:NOT`，**一次 `H:IS 1` 都没有**。
⇒ 那次机器也没认到可恢复镜像（与判据 1 一致：镜像早已是空壳）。

**⚠️ 以上"下午没进 S4"的判断已被用户实测推翻（16:25 当场证伪）**

用户观察到**睡眠后电源灯熄灭**——断电是 S4 的物理特征，S0ix 不断电。
而"镜像前 232 字节全零"**根本不能**推出"没写镜像"：§3z.12 的 P1 取样早就证明
**恢复失败后、下次 macOS 启动会把镜像原地清零**（birth 不变、内容归零）。

⇒ 正确的读法恰好相反：**镜像全零恰恰是"上次休眠恢复失败、系统因此清零重建"的痕迹**。
`mtime=2019-01-01 08:01` 对应的是 16:01:43 那次启动（RTC 读成 2019-01-01 00:00）时的清零动作，
不是"最后写镜像的时刻"。

**我的推理错误**：拿一个和 §3z.12 已知现象直接冲突的判据去下结论，等于自己推翻自己。
判据必须换成物理观察，见 §3z.15。

#### 七、判据修正（替换此前所有相关表述）

| 旧判据 | 新判据 |
|---|---|
| "没有第二份日志 ⇒ 没有重启" | **废**。每次启动都落一份日志；要看 `Start powerd process is started` 的时间序列 |
| "`kern.hibernatecount` 不 +1 ⇒ 没写镜像" | 保留，但需配合 sleepimage mtime |
| "日志文件名可用于定时" | **08:00:39 之后废**。RTC 已坏成 2019-01-01 |
| "下午失败 = S4 恢复失败" | **废**。需先证明 sleepimage header 合法 + 睡眠时长 > standbydelay |

#### 八、下一步（按顺序）

1. **删掉空壳镜像让系统重建**：`sudo rm -f /var/vm/sleepimage && sudo pmset -a hibernatefile /var/vm/sleepimage`
2. **重启**，让 D4（`DiscardHibernateMap=true` + `HibernateMode=NVRAM`，16:20 落盘）真正加载
3. **重新测**：AC 供电、`pmset -g assertions` 确认无阻止、睡眠后**至少等 8 分钟**（> 300 s 阈值）
4. **进场判据**：机器必须真断电（电源灯灭）+ `sleepimage` mtime 前移 + 前 232 字节出现 `sime`
5. 只有满足 4，才谈"唤醒失败"；否则仍是 Deep Idle 那条线

---

### §3z.15 更正：下午确实进了 S4；`HibernateMode=None` 才是"H:IS 0"的原因（2026-10-29 16:26）

#### 一、错在哪

§3z.14 第六节用"sleepimage 前 232 字节全零"推出"下午没进 S4"，**这与 §3z.12 的 P1 取样直接冲突**：
P1 早就记录过——**恢复失败之后，下次 macOS 启动会把镜像原地清零**（`birth` 不变、内容归零、size 8 GiB→1 GiB）。

所以"镜像全零"不是"没写过"，而是"**写过、恢复失败了、被清零了**"。证据方向完全反了。

**正确读法**：
- `mtime = 2019-01-01 08:01`（= 00:01 UTC）是 **16:01:43 那次启动**（RTC 读成 2019-01-01 00:00）清零镜像留下的；
- `birth = 15:42:18`（2026，正常时间）是文件重建的时刻；
- 前 232 字节全零 = header 已被清掉 = **上一次恢复没有走完**。

#### 二、物理判据（用户可肉眼确认，优先级高于任何文件时间戳）

| 现象 | 含义 |
|---|---|
| 睡眠后**电源灯熄灭** | 机器断电 → **S4**（S0ix 不断电，灯会呼吸/常亮） |
| 按电源键后有 **POST**（HP logo 一闪、风扇转、005 报码） | 说明经历过断电 → 确认 S4 |
| 按电源键后**无 POST、直接亮屏** | 是 S0ix / Deep Idle，不是 S4 |

用户实测：**灯灭了，且有 POST + 005** ⇒ 下午那几次是真的 S4，也是真的失败。

#### 三、那为什么下午一次 `H:IS 1` 都没有？——不是 `HibernateMode`，是镜像哑火

**先排除 `HibernateMode=None` 这个假设**（我一度这么认为，被备份时间线否掉）：

| 备份 | 时刻 | HibernateMode |
|---|---|---|
| `1258-s4-baseline` | 12:58 | **NVRAM** |
| `1313-memmap-probe` | 13:13 | NVRAM |
| `1450-pre-reservedmem` | 14:50 | NVRAM |
| `1612-pre-capture` | 16:12 | NVRAM |
| `1620-pre-discard` | 16:20 | **None** |

⇒ **12:58 到 16:12 全程是 `NVRAM`**，15:04 那次测试就落在这个窗口内。
所以"OC 不转发 boot-image"解释不了它。

**真正的因果链**：

```
E1 实验（mkfile -n 造 8 GiB 空文件 / restore）
   → sleepimage header 被破坏，成了无 magic 的空壳
   → 内核 preflight 认为镜像不可用，不写新镜像
   → NVRAM 里不产生 boot-image / boot-signature
   → boot.efi 读不到 ⇒ H:IS 0 ⇒ H:NOT ⇒ 冷启动
   → 用户看到的仍是黑屏+复位+005（断电确实发生了，但恢复流程根本没启动）
```

**⇒ 下午不是"恢复失败"，是"恢复压根没发生"。判据是 `H:IS 0`，不是黑屏。**

真正有效的 S4 样本**只有早上那 4 次**（05:00:33 / 06:32:26 / 07:05:29 / 08:00:39），
那时镜像合法、`H:IS 1` 走完 REAN、全部黑屏。**这 4 次才是要攻的对象。**

#### 四、D4 两个改动的权重

| 键 | 改动 | 评价 |
|---|---|---|
| `Misc/Boot/HibernateMode` | None → **NVRAM** | 必要但不充分。它只是把 16:12–16:20 那段（为 P1 取样故意设的 None）改回正常态 |
| `Booter/Quirks/DiscardHibernateMap` | false → **true** | 真正待验证的机制假设 |

**⇒ 光改 config 不够，必须先让 sleepimage 重新变成合法镜像**（删掉重建），
否则重启后 `H:IS` 仍然是 0，D4 照样测不到。**进场条件：日志里必须出现 `H:IS 1`。**

#### 五、由此暴露的、与 S4 无关的第二条故障线

`pmset -g log` 里 15:54:09 睡眠 → 15:56:13 `Wake from Deep Idle`（成功，218 s，WakeTime 2.449 s）；
15:59:51 睡眠 → 16:01:43 新内核（失败）。两次都是短睡，结果一成一败 ⇒ S0ix 唤醒本身也不稳定。
**它和 S4 是两条线，判读时必须先按时长分开，否则每次"黑屏"都分不清是谁。**

---

### §3z.16 根本性更正：OpenCore / boot.efi 日志一律用 UTC，本地时间要 +8h（2026-10-29 16:38）

#### 一、错在哪（这一条推翻了 §3z.14 六、§3z.15 三/四的全部结论）

刚重启后新日志 `opencore-2026-10-29-083424.txt`，内部 `#[EB|LOG:INIT] 2026-10-29T08:34:30`。
同一时刻：

```
$ date -u   →  2026-10-29T08:37:34 UTC
$ date      →  2026-10-29T16:37:34 CST
$ kern.boottime → Thu Oct 29 16:34:36 2026
```

**⇒ 日志文件名与 boot.efi 内部时间戳都是 UTC，本地 CST = UTC + 8h。**
（`ls` 显示 mtime 也是同一套 UTC 值，因为 ESP 是 FAT，无时区信息。）

我此前把 `024742` 读成"凌晨 2 点"、把 `080038` 读成"早上 8 点"，**全部错 8 小时**。

#### 二、重写今日时间线（UTC → 本地）

| 日志 | UTC | **本地 CST** | H:IS | 对应事件 |
|---|---|---|---|---|
| 024742 | 02:47 | 10:47 | 0 | 冷启动 |
| 025037 | 02:50 | 10:50 | 0 | 冷启动 |
| 030129 | 03:01 | 11:01 | 0 | 冷启动 |
| 034347 | 03:43 | 11:43 | 0 | 冷启动 |
| 042738 | 04:27 | 12:27 | 0 | 冷启动 |
| 045700 | 04:57 | 12:57 | 0 | 冷启动 |
| **050032** | **05:00** | **13:00** | **1** | **13:00 卡死那次** |
| 051613 | 05:16 | 13:16 | — | 空文件（OC 建文件后死） |
| 055846 | 05:59 | 13:59 | 0 | 冷启动 |
| 060354 / 061145 / 062002 | 06:03–06:20 | 14:03–14:20 | 0 | 冷启动（memmap 采集期） |
| **063008** | **06:30** | **14:30** | **1** | 失败 |
| 065726 | 06:57 | 14:57 | 0 | 冷启动 |
| **070528** | **07:05** | **15:05** | **1** | **15:04 黑屏自动复位 + POST 005** |
| 074152 | 07:41 | 15:41 | 0 | 冷启动 |
| **080038** | **08:00** | **16:00** | **1** | **16:00 失败** |
| 2019-01-01-00003X | — | 16:0X–16:3X | 0 | RTC 被打成 2019 后的复位重启 |
| **083424** | **08:34** | **16:34** | **0** | **本次重启（删镜像后）** |

**⇒ 4 次 `H:IS 1` 不是"早上四次"，就是用户今天下午做的那 4 次失败测试。**
时间点与用户描述逐一对上：13:00 卡死、14:30、15:04 复位 005、16:00 失败。

#### 三、三个错误结论，作废

| 错误结论 | 出处 | 为什么错 |
|---|---|---|
| "下午没进 S4" | §3z.14 六 | 电源灯灭 = 断电 = S4，用户实测直接证伪 |
| "下午一次 `H:IS 1` 都没有" | §3z.14 六 / §3z.15 三 | **UTC 当本地**，把 13:00–16:00 的日志误读成早上 05:00–08:00 |
| "sleepimage 空壳 ⇒ 内核不写镜像 ⇒ 哑火" | §3z.15 三 | 内核 preflight 会自行扩展/覆盖，header 空不影响它写；15:04 那次 `H:IS 1` 就是证据 |

#### 四、站得住的结论（与 §3z 一致，未变）

**今天 4 次真 S4，全部走完 `H:IS 1` → `H:BI` → `REAN` → `EXITBS:START`，全部黑屏。
死点 100% 在内核侧 `hibernate_kernel_entrypoint`，4/4 确定性复现。**

`EXITBS` 之前链路已完全排除；下午折腾的 E1/E2/P1 取样与 ReservedMemory 实验，
**没有一次改变了这个形态**。

#### 五、附带坐实的两件事

1. **S4 恢复失败会把 RTC 打成 2019-01-01**（3 份 `2019-01-01-00003X` 日志即 16:0X–16:3X 那几次复位重启）。
2. **16:34 那次重启 RTC 已恢复正常**（`083424` 内部 UTC 08:34:30 对得上 `date -u`），
   说明该损坏是"一次性的、重启后自行恢复"，不是永久性 CMOS 失效。

#### 六、教训（写进流程）

**取 OC/boot.efi 日志时间必须先 `date -u` 对齐，不能按本地时区读。**
判据代码一律用 UTC；文档里标注时间时写明 `UTC` 或 `CST`。

---

### §3z.17 突破：首次捕获 S4 恢复期 panic，死点从"未知"收敛到"读镜像失败"（2026-10-29 16:56）

#### 一、现象对比：性质变了

| | 前 4 次（050032 / 063008 / 070528 / 080038） | 本次（084752，D4 生效后） |
|---|---|---|
| boot.efi 链路 | `H:IS 1` → `H:BI` → `REAN` → `EXITBS` | **完全相同** |
| `EXITBS` 之后 | 黑屏 → 硬复位 → POST 005，**零 panic 痕迹** | **内核 panic 并成功落盘** |
| 判定 | triple fault，IDT 未恢复，来不及 panic | **`hibernate_kernel_entrypoint` 已过，进入 IOKit 恢复** |

⇒ **D4（`DiscardHibernateMap=true` + `HibernateMode=NVRAM`）确实改变了行为**：
恢复链路从"死在三重故障"推进到"死在读镜像 I/O"。

#### 二、panic 原文

```
panic(cpu 0 caller 0xffffff800dc866ab): Hibernate restore error e00002bc @IOHibernateIO.cpp:2921
  _hibernate_machine_init + 0x12db
  _ml_hibernate_active_post + 0x27
  _IOCPURunPlatformActiveActions + 0x6b
  _acpi_sleep_kernel + 0x2be
  AppleACPIPlatformExpert::sleepPlatform + 0x1f9
  AppleACPICPU::haltCPU + 0x85
  _IOCPUSleepKernel + 0x21c
  IOPMrootDomain::powerChangeDone + 0xa4a
Hibernation exit count: 0
Last Sleep: Uptime 0xb799f3c320 (788.6 s) / Sleep 0xb282112f5d (766.6 s) / Wake 0x0
```

文件：`/Library/Logs/DiagnosticReports/Kernel-2019-01-01-080117.panic`
（文件名时间戳是 2019，因为 S4 断电把 RTC 打回出厂值；`timestamp` 字段同样是错的）

`-hbfxdbg -hbfxforce hfile=/var/vm/sleepimage` 在 boot-args 中，HibernationFixup 1.5.4 已加载。

#### 三、源码定位（xnu `iokit/Kernel/IOHibernateIO.cpp`，`hibernate_machine_init()`）

该函数内共有 **6 处** `panic("Hibernate restore error %x", err)`，全部是 I/O 失败：

```c
/* ① readahead（第一次读盘） */
IOPolledFileSeek(vars->fileVars, gIOHibernateCurrentHeader->image1Size);
vars->fileVars->readEnd = gIOHibernateCurrentHeader->imageSize;
err = IOPolledFileRead(vars->fileVars, NULL, 0, cryptvars);
if (kIOReturnSuccess != err) panic("Hibernate restore error %x", err);

/* ② 读 8 字节 page-range 头 */
err = IOPolledFileRead(vars->fileVars, src, 8, cryptvars);
if (kIOReturnSuccess != err) panic("Hibernate restore error %x", err);

/* ③ 读 4 字节 tag */
err = IOPolledFileRead(vars->fileVars, (uint8_t *) &tag, 4, cryptvars);
if (kIOReturnSuccess != err) panic("Hibernate restore error %x", err);

/* ④ tag 签名不匹配 —— 唯一用固定码的一处 */
compressedSize = kIOHibernateTagLength & tag;
if (kIOHibernateTagSignature != (tag & kIOHibernateTagSigMask)) {
    err = kIOReturnIPCError;
    panic("Hibernate restore error %x", err);
}

/* ⑤ 读压缩页数据 */
err = IOPolledFileRead(vars->fileVars, src, (compressedSize + 3) & ~3, cryptvars);

/* ⑥ 落到目标物理页 */
err = IOMemoryDescriptorReadToPhysical(vars->srcBuffer, decoOffset, ptoa_64(ppnum), page_size);

/* ⑦ 循环结束总校验 */
if ((kIOReturnSuccess == err) && (pagesDone == header->actualUncompressedPages))
    err = kIOReturnLockedRead;
if (kIOReturnSuccess != err) panic("Hibernate restore error %x", err);
```

#### 四、错误码判定

| 值 | 名称 | 出处 |
|---|---|---|
| **`0xe00002bc`（实测）** | **`kIOReturnError`** | `iokit_common_err(0x2bc)`，IOKit 通用错误 |
| `0xe00002c4` | `kIOReturnIPCError` | 仅用于 **④ tag 签名不匹配** |
| `0xe00002c1` | `kIOReturnLockedRead` | 仅用于 **⑦ 页数不符** |

⇒ **实测值不等于 ④ 也不等于 ⑦** ⇒ **排除"镜像内容/签名损坏"与"页数不符"**，
失败发生在 **`IOPolledFileRead` / `IOMemoryDescriptorReadToPhysical` 的读盘动作本身**。

#### 五、最可能的机制：`header->imageSize` 与文件实际大小不符

第一步 readahead 直接拿镜像头的 `imageSize` 当 `readEnd`。若 `imageSize` > 文件真实长度，
`IOPolledFileRead` 会读到 EOF 之外 ⇒ 返回通用错误 `kIOReturnError`。

**当前实测**：

```
/var/vm/sleepimage  size=1073741824 (1 GiB)  birth=Oct 29 16:33:43 2026  mtime=2019-01-01 08:01:24
```

`birth` 是 16:33:43（16:34:36 那次启动前 53 秒创建），说明**文件未被重建**。
若头里 `imageSize` 是数 GiB 而文件只有 1 GiB，本条即为根因。

**待验证（需 root）**：`sudo python3 EFI/scripts/hib-header.py /var/vm/sleepimage`
读 magic（应为 `sime`）、`imageSize`、`image1Size`、`pageCount`、`conflictCount`。

#### 六、判据修正

| 旧表述 | 更正 |
|---|---|
| "死点 100% 在 `EXITBS` 之后，triple fault，无 panic 痕迹" | **仅在 D3（`DiscardHibernateMap=false`）下成立**。D4 下内核能 panic |
| "boot.efi 侧已完全排除" | 保留。`REAN` 0.7 s 正常，问题在交棒之后 |
| "镜像内容坏了" | **本次可排除**（错误码不是 `kIOReturnIPCError`） |

#### 七、顺带坐实

1. `#[EB.H.CHK|BM] 0x0000000000000000` —— boot manifest 值为 0。
2. `#[EB.H.CHK|!] Err(0xE) <- BS.LocDP 5B27263B-…` —— `LocateDevicePath` 返回 `EFI_NOT_FOUND`，**被容忍**，`REAN` 照常完成。
3. `#[EB.H.HB|DT] 3 0` —— 恢复路径固定伴生输出。
4. `Last Sleep: Wake absolute = 0` —— 唤醒时刻未写回（panic 打断），不可作"未唤醒"判据。

---

### §3z.18 二进制取证：panic 行 2921 = **第一处 readahead**，一页都没恢复（2026-10-29 17:20）

#### 一、方法（可复现，不依赖任何在线源码版本）

退 10 帧源码猜测的低效做法：**直接在本机 `mach_kernel` 二进制上定位 panic 调用点**。

```bash
nm -n /System/Library/Kernels/kernel | grep _hibernate_machine_init
# ffffff800099d3d0 T _hibernate_machine_init

# backtrace: 0xffffff800dc866ab，Kernel slide = 0x000000000d2e8000
# unslid = 0xffffff800dc866ab - 0xd2e8000 = 0xffffff800099e6ab
# 0xffffff800099e6ab - 0xffffff800099d3d0 = 0x12db  ← 与 backtrace 的 "+0x12db" 逐位吻合
```

panic 是 `call _panic`，所以调用点 = `0xffffff800099e6ab - 5 = 0xffffff800099e6a6`。
其前面 6 字节是 `b9 69 0b 00 00` = `mov ecx, 0xB69` = **2921** —— panic 消息里的 `@IOHibernateIO.cpp:2921`
就是从这里来的（`panic(fmt, err, __FILE__, __LINE__)` 的第三个参数）。

以同样办法把 `_hibernate_machine_init`（0x1360 字节）内 **所有** "Hibernate restore error" 站点扫了一遍：

| lea 位置 | 源码行 | 固定错误码 |
|---|---|---|
| `…e68f` | **2921** | —（透传 err） |
| `…e625` | 2940 | — |
| `…e5a5` | 2955 | — |
| `…e5c1` | **2961** | `0xe00002bf` = `kIOReturnIPCError` |
| `…e589` | 2966 | — |
| `…e56a` | 2998 | 扫描到 `0xe00002e7`（= `kIOReturnUnderrun`），疑为相邻块的立即数，未确认 |
| `…e6ab` | **3030** | `0xe00002c3` = `kIOReturnLockedRead` |

（地址为 `lea rdi, [fmt]` 指令位置；实际 `call _panic` 在其后约 0x22 字节。）

**行号 ↔ 源码站点的锚定**：xnu `xnu-12377.121.6` 的 `IOHibernateIO.cpp` 里这 7 处按源码顺序是
①readahead ②读 8 字节块头 ③读 4 字节 tag ④**tag 签名（唯一用 `kIOReturnIPCError`）**
⑤读页数据 ⑥`IOMemoryDescriptorReadToPhysical` ⑦**页数总校验（唯一用 `kIOReturnLockedRead`）**。

本机二进制里带固定码的是**第 4 个（2961）和第 7 个（3030）**，与源码顺序 1:1 对上。
⇒ 第 1 个 = **2921** = readahead。

#### 二、结论：死点在第 1 处 readahead

```c
IOPolledFileSeek(vars->fileVars, gIOHibernateCurrentHeader->image1Size);
vars->fileVars->readEnd = gIOHibernateCurrentHeader->imageSize;
...
err = IOPolledFileRead(vars->fileVars, NULL, 0, cryptvars);   // ← 2921
if (kIOReturnSuccess != err) panic("Hibernate restore error %x", err);
```

`IOPolledFileRead(vars, NULL, 0, …)`：长度 0，只做"启动预读"。它内部（`IOPolledInterface.cpp`）：

```c
if ((vars->bufferOffset == vars->bufferLimit) && (vars->position < vars->readEnd)) {
    if (!vars->pollers->io) cryptvars = NULL;
    err = IOPolledFilePollersIODone(vars->pollers, true);   // io==false ⇒ 立即返回 success
    if (err) break;
    ...
    err = IOStartPolledIO(vars->pollers, kIOPolledRead, vars->bufferHalf, offset, length);
    if (err) break;                                        // ← 就是这里返回 0xe00002bc
}
```
而 `IOStartPolledIO`：
```c
err = vars->ioStatus;            // open 时被置 0 ⇒ 通过
if (err) return err;
vars->ioStatus = -1;
poller = vars->pollers->getObject(0);
err = poller->startIO(operation, bufferOffset, deviceOffset, length, completion);  // ← 真正失败点
```

⇒ **失败发生在 poller 的 `startIO`，不是数据校验、不是解密、不是页表、不是内存映射。**

**本机的 poller 是谁，有直接证据**（`ioreg -rc IONVMeController`）：

```
"IOPolledInterface" = "IONVMeControllerPolledAdapter is not serializable"
```

即 Apple 闭源的 `IONVMeControllerPolledAdapter`（WD Blue SN570 1TB，PCIe x4，APFS 根卷 `disk1s1s1`）。

#### 三、勘误（此前两条错误码给错了）

| 码 | 正确名称 | 此前误写 |
|---|---|---|
| `0xe00002bc` | `kIOReturnError`（通用） | ✔ 正确 |
| `0xe00002bf` | `kIOReturnIPCError` | ✘ 曾误写为 `0xe00002c4` |
| `0xe00002c3` | `kIOReturnLockedRead` | ✘ 曾误写为 `0xe00002c1` |

依据：`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/…/IOReturn.h:96-104`。
**结论不变**：实测 `0x2bc` 既不等于 `0x2bf` 也不等于 `0x2c3` ⇒ 排除"签名不匹配"与"页数不符"。

#### 四、被这一条一次性排除的旧假设

| 旧假设 | 状态 |
|---|---|
| 镜像内容/加密/签名损坏 | ✘ 根本没读到数据 |
| `imageSize` 与实际文件大小不符导致越界 | ✘ 越界也要先走到第 ②③⑤ 站；这里是第 ① 站 |
| RT 区被当 scratch 覆写（OpenRuntime 代码被盖） | ✘ 一页都没写回，物理地址还没动过 |
| `ReservedMemory` 0x8B000 位置不对 | ✘ 同上 |
| 页表 / `BootPTD[2040..2047]` / AREA 映射 | ✘ 内存恢复阶段还没开始 |
| 页数校验 `pagesDone` | ✘ 第 ⑦ 站，没走到 |

#### 五、当前唯一站得住的描述

> S4 唤醒后，内核在**读取镜像的第一个块之前**就失败了；失败点是 NVMe 控制器的轮询接口
> `IONVMeControllerPolledAdapter::startIO(kIOPolledRead, …)` 返回 `kIOReturnError`。
> 此时镜像内容未被触碰、内存未被写回。

`IOPolledFilePollersOpen(kIOPolledAfterSleepState)` 的返回值在源码里**只 HIBLOG、不 panic**，
所以"poller 的 open 失败"与"startIO 失败"两种情形都可能落到这条 panic 上，需要 HIBLOG 才能分开——
而 release 内核的 HIBLOG 不落盘（本机 OC 日志文件里 100% 是 boot.efi 的 `AAPL:` 行，0 条 `OCB:/OCABC:`）。

#### 六、剩余可动变量盘点（全部有 OC 官方文本背书，逐条评估）

| 变量 | 现值 | OC 文档原文 | 对本次失败的作用 |
|---|---|---|---|
| `Booter/Quirks/DiscardHibernateMap` | true | "forces XNU to ignore a newly supplied memory map … Do not use without a full understanding" | 已测：false→三重故障，true→推进到 I/O 错误。**保留 true** |
| `Booter/Quirks/DevirtualiseMmio` | true（`MmioWhitelist=[]`） | "On certain firmware, a list of addresses that need virtual addresses for proper NVRAM **and hibernation** functionality may be required. Use the MmioWhitelist section" | 唯一有"hibernation"字样的未处理项；但 whitelist 需要 OC 自己打印的 devirt 列表，**当前拿不到**（OC 日志未落盘） |
| `ACPI/Quirks/ResetHwSig` | **true** | "works around firmware that fail to maintain hardware signature across reboots and cause issues with waking from hibernation" | 已开 |
| `ACPI/Quirks/RebaseRegions` | **true** | "Not recommended … Do not use unless absolutely required" | 与本故障无关，但是配置卫生问题 |
| `Booter/Quirks/ForceBooterSignature` | false | "let OpenCore shim hibernation wake on **Mac EFI firmware**" | 非 Mac EFI，不适用 |
| `Booter/Quirks/AllowRelocationBlock` | false | "Hibernation is not supported when booting with a relocation block" | ✔ 已是关闭状态 |

#### 七、现实判断

剩下这一层是 **Apple 闭源 NVMe 轮询适配器 + 固件在 S4 后未保留的控制器状态**，
XNU 与 OpenCore 都**没有**能改到这条代码路径的开关。要继续只能靠：
1. 拿到 HIBLOG（需要串口或 debug 内核）区分 open 失败 / startIO 失败；
2. 换非 NVMe 的启动盘（AHCI 轮询路径是另一套代码）做对照实验。

#### 八、运维建议（与实验解耦）

当前 AC 侧 `hibernatemode 25`，意味着**每次睡眠都走写盘+断电**。在 S4 恢复修好之前，
日常使用应退回不写镜像的睡眠：

```bash
sudo pmset -a hibernatemode 0 standby 0 autopoweroff 0
```

需要做 S4 实验时再单独 `sudo pmset -a hibernatemode 25` 并 `s4-arm.sh arm`，两者不要混。

---

### §3z.19 D5 实验：禁用 NVMeFix + hibernatemode 29（2026-10-29 17:30）

#### 改动
- `Kernel/Add[11]`（NVMeFix.kext）`Enabled: true → false`，深递归 diff 确认**仅此一处**。
- 备份 `docs/backups/config-2026-10-29-1727-pre-nvmefix.plist`，ESP 上留 `config.plist.bak-nvmefix`。
- 同步 ESP，两侧 sha `f5dbfdc7…27ea5b7` 一致。
- 运行时电源设置**保持 25 不变**（见下方勘误，29 不合法）。

#### 依据
**NVMeFix 会重写控制器 APST 表**（二进制里 `APST unsupported` / `Failed to enable APST` / `-nvmefaspm`），
而本机盘 WD Blue SN570 1TB (FW 234100WD) 是 DRAM-less + HMB，上游 issue `kvic-z/SsdPmEnabler#24` 记录
真 Mac 换 SN570 后合盖数小时必 panic、去掉 SsdPmEnabler 即恢复 ⇒ 该盘与 macOS 低功耗态的配合有实证问题。

#### ★ 勘误：`hibernatemode 29` 的说法作废（源码实证）

`xnu-12377.121.6` 的 `iokit/IOKit/IOHibernatePrivate.h:740-748`：

```c
kIOHibernateModeOn                   = 0x00000001,
kIOHibernateModeSleep                = 0x00000002,
kIOHibernateModeEncrypt              = 0x00000004,
kIOHibernateModeDiscardCleanInactive = 0x00000008,
kIOHibernateModeDiscardCleanActive   = 0x00000010,
```

⇒ **`25 = 0x19 = On | DiscardCleanInactive | DiscardCleanActive`，本身不含 `Encrypt` 位。**
⇒ **`29 = 0x1D = 25 | Encrypt`，是"25 加上加密"，与"跳过加密"完全相反。**
（此前表述"29 跳过镜像加密"方向反了，作废。）

而 `man pmset` 第 113 行原文：**`hibernatemode supports values of 0, 3, or 25.`**
⇒ **29 未文档化，不是可用的调参入口**。同理 `hibernatemode 1` 也不在官方支持列表内。

**结论：hibernatemode 这条路上没有可动的变量，保持 25。**
"改变断电前时序"这个想法作废——25 是唯一能真正走 S4 恢复的值（3 会保持内存供电、从内存唤醒，根本不进恢复路径）。

#### 为什么 HibernationFixup 在这条链上无效（已确认，别再指望它）
panic backtrace：
```
_hibernate_machine_init ← _ml_hibernate_active_post ← _IOCPURunPlatformActiveActions ← _acpi_sleep_kernel
```
这是**唤醒后第一个 CPU 起来时**执行，IOService 树尚未恢复。HibernationFixup 的 PCI Command 补位挂在
`IOMachineRestore`（`kMachineRestoreDehibernate`），**比 panic 点晚一个阶段**，来不及执行。
⇒ `-hbfxforce` / `hbfx-patch-pci` 对本故障无效，无需再调。

#### 判据（不变）
1. 新日志必须出现 `[EB|H:IS] 1`，否则这轮无效；
2. 现象：黑屏+复位+005 = 仍失败；panic 但有新错误码 = 推进了；正常亮屏 = 成了。

#### 注意
**不要用 `s4-arm.sh arm`** —— 它会把 `hibernatemode` 强制改回 25，冲掉本实验的 29。

---

### §3z.20 D5 结果：禁用 NVMeFix 完全无效，错误位点逐字节一致（2026-10-29 18:15）

#### 一、实验失败，且失败点一字未变

| 项 | D4（NVMeFix **on**） | D5（NVMeFix **off**） |
|---|---|---|
| 日志 | `084752`（UTC 08:47:52） | `100602`（UTC 10:06:02） |
| `H:IS` | 1 | **1** |
| `H:SIG` | — | **`0x73696D65` = `sime`（镜像头签名有效）** |
| `H:BI` → `REAN` → `EXITBS` | 全走完 | **全走完** |
| panic 文件 | `Kernel-2019-01-01-080117.panic` | `Kernel-2019-01-01-080103.panic` |
| **panic 内容** | `Hibernate restore error e00002bc @IOHibernateIO.cpp:2921`<br>`_hibernate_machine_init + 0x12db` | **完全相同** |
| `Hibernation exit count` | 0 | 0 |
| `Last Sleep: Wake` | 0 | 0 |

⇒ **NVMeFix 与本故障零相关，已排除。** 这是干净的单变量对照：只改了 `Kernel/Add[11].Enabled`，
panic 的调用者地址、函数偏移（`+0x12db`）、源码行号（2921）、错误码（`e00002bc`）四项**全部一致**。

#### 二、本次坐实的两条新事实

1. **`#[EB|H:SIG] 0x73696D65`** —— boot.efi 从镜像头读到的签名就是 `sime`。
   **镜像本身有效、header 完好**，与"header 全零"那次的结论区分开：全零是**恢复失败后被清零**的结果。
2. 本次日志新增可见字段 `H:WCK` / `H:BOOT.1` / `H:DLW 0` / `H:HBOPT 0 1 1 0` / `H:RDST` / `H:RDEND`，
   均为 boot.efi 恢复路径的标准输出，无异常。

#### 三、时间线核对（第 N 次自我校验，全部吻合）

```
18:06:02  boot.efi LOG:INIT（UTC 10:06:02）
18:06:03  REAN:END + EXITBS:START
          → 内核 hibernate_machine_init → panic e00002bc
          → 硬复位，RTC 丢失归零到 2019-01-01 00:00
18:06:03  sleepimage 被清零（mtime 记为 RTC 08:01:07 = UTC 00:01:07）
18:06:06  生成 Kernel-2019-01-01-080103.panic
18:07:10  新内核起来（kern.boottime）
```
panic 里 `Uptime = 0x1e05a9dc478` ≈ 2064 s ≈ 34.4 min，与 17:31:30 → 18:06:02 的 34.5 min 吻合；
`sleepimage` mtime 与 panic 文件 mtime **同为 08:01:07**，是同一次事件写下的。

#### 四、已回滚

`Kernel/Add[11].Enabled` 恢复 `true`，与实验前备份 `config-2026-10-29-1727-pre-nvmefix.plist`
**深递归 diff 差异 0 条**；ESP 同步，两侧 sha `d2f02935…a4668c`（= D4 基线值）。

#### 五、排除清单（累计，全部有实测或源码依据）

| 变量 | 结论 | 依据类型 |
|---|---|---|
| 镜像内容 / header / 加密 / 签名 | 排除 | `H:SIG=sime` + 一页未读即失败 |
| `imageSize` 越界 | 排除 | 失败在 2921（第 1 站 readahead），非 2940/2955 |
| RT 区 scratch / `ReservedMemory` | 排除 | 内存恢复未开始 |
| 页表 / `BootPTD` / AREA / `pagesDone` | 排除 | 同上 + 非 3030 站 |
| `HibernationFixup` 全部参数 | 排除 | 阶段错位（panic 早于 `IOMachineRestore`） |
| `hibernatemode 29` / `1` | 不存在 | `man pmset`：只支持 0/3/25；位定义 29=25\|Encrypt |
| `hibernatefile` 移到非根卷 | 排除 | `man pmset`：Image may only be located on the root volume |
| **NVMeFix** | **排除** | **本次单变量对照，panic 位点逐项一致** |

#### 六、剩下的只有一层

`IONVMeControllerPolledAdapter::startIO(kIOPolledRead, …)` 返回 `kIOReturnError`。这是 Apple 闭源实现，
XNU 无开关、OpenCore 无开关。唯一还没碰过的是**固件层**：

- BIOS 里的 **PCIe ASPM**（L1 / L1.2）。SN570 与 ASPM 是已知问题组合；若 S4 后链路停在 L1.2 且无唤醒事件，
  控制器不响应命令。**HP 商务本 BIOS 通常不暴露该选项**，需进 F10 确认是否可见。
- 否则只剩**换盘**：换带 DRAM 缓存的 NVMe（SN750 / 铠侠 RC20），或换 SATA 盘走另一套 poller 代码。

---

### §3z.21 关键新事实：断电后机器**自己上电**，用户从未按过电源键（2026-10-29 18:20）

#### 一、用户观察（一手实测，多次一致）

> "每次电源指示灯黑了之后我都没做操作，它自己就亮了。"

这条推翻了此前所有测试中隐含的模型：

| | 我们一直假设的 | **实际发生的** |
|---|---|---|
| 流程 | 合盖 → 写盘 → 断电（灯灭）→ **保持断电** → 用户按电源键 → S4 resume | 合盖 → 写盘 → 断电（灯灭）→ **自己上电** → POST 005 → OC → `H:IS 1` → REAN → EXITBS → panic |
| "按电源键" | 关键动作 | **从未发生** |
| 机器是否停在 S4 | 是 | **否，断电后几秒内自动恢复上电** |

⇒ **过去每一轮"唤醒失败"，其实都不是"从 S4 唤醒"，而是"固件自己上电后偶然走了恢复流程"。**

#### 二、与 005 的闭环

`005` = HP `Real-Time Clock Power Loss`。实测每次 S4 后必报，且 RTC 被打回 `2019-01-01`。

今天 4 份 `opencore-2019-*` 日志，`LOG:INIT` 分别是 `00:00:35 / 00:00:35 / 00:00:37 / 00:00:49`
——**每次断电后 RTC 都从 00:00:00 重新计时** ⇒ 断电确实把 CMOS/RTC 内容一起带走了。

`005` 与"自己上电"因此极可能是**同一根因的两面**：S4 断电 → RTC 丢失 → 固件检测到 CMOS 无效 → 上电重建并报 005。

#### 三、这条链为什么可能解释 panic（**推断，未验证**）

固件在两种情况下行为不同：

| | 正常 S4 resume（用户按电源键） | 实际路径（CMOS 异常后自动上电） |
|---|---|---|
| 固件判定 | 有 S4 resume 上下文 → 走 resume | POST 判定 CMOS 异常 → 走完整冷启动 |
| 内存控制器 | 保留/恢复 | 完整重新初始化 |
| PCIe / NVMe 链路 | 保留 | 完整重新协商 |
| 交给 boot.efi 的状态 | resume 上下文 | 仅靠 NVRAM 里的 `boot-image` 变量 |

而内核恢复的第一步（`IOHibernateIO.cpp:2921`）就用 **polled I/O 直接读 NVMe**，
它期望的是"S4 resume 之后控制器已在可用状态"。若固件走的是 cold boot，
控制器状态与内核期望不一致 ⇒ `IONVMeControllerPolledAdapter::startIO` 返回 `kIOReturnError`。

**⚠ 这条是推断，不是结论。** 依据强度：源码级（panic 位点）+ 实测（`005`、RTC 归零、自动上电）
+ 机制推理（固件 resume vs cold boot 差异），**中间那一环（固件如何判定 resume）没有直接证据**。

#### 四、验证实验（5 分钟，一刀切开三种可能）

**实验 A：完全关机 + 拔 AC**

```bash
sudo shutdown -h now          # 不是睡眠，是关机
# 关机后拔掉电源适配器，等 2–3 分钟，再插回
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| **自动开机** + 报 005 | BIOS 有 "AC 恢复自动开机" + CMOS 电池失效 | 换 CR2032，可能一并解决 S4 |
| 不自动开机，但开机**报 005** | CMOS 电池失效（不止 S4，完全断电也丢） | 换 CR2032 |
| 不自动开机，也**不报 005** | CMOS 电池正常，`005` 是 S4 特有 | 转查 BIOS/ACPI 的 S4 处理 |

**实验 B（辅助）：拔掉 AC，只用电池睡一次**
若只在 AC 下出现"自己上电"，则为适配器/EC 相关；若电池下同样发生，则为固件 S4 处理问题。

#### 五、顺带记录的两条环境事实

- 电源适配器为 **HP 原厂 60W 圆口**（`AdapterDetails`：`Watts=60, FamilyCode=186, Manufacturer=Hewlett-Packard`），
  **不是 USB-C PD** ⇒ 排除 PD 重新协商导致上电。
- 无雷电设备（`No drivers are loaded`），USB 仅内建摄像头 ⇒ 排除外设 PME 唤醒。
- 电池：`Cycle Count=132`、`Condition=Normal`、`100%`、AC 已连接。

#### 六、干扰源

`pmset -g sched` 有一条 `wake at 10/29/2026 18:06:46 by 'com.apple.alarm.user-invisible-GaugingMitigationActions'`
——时间比 18:06:02 那次恢复晚 44 秒，**不是那次的起因**，但属于干扰项，实验前应清掉：

```bash
sudo pmset schedule cancelall && pmset -g sched
```

#### 七、日志形态补充

18:07:10 那次（panic 之后）的启动日志是 `opencore-2019-01-01-000047.txt`
（`LOG:INIT 2019-01-01T00:00:49`，`H:IS 0`）。
⇒ **RTC 归零后所有日志都落到 `opencore-2019-*`，用 `ls -t` 会排到最后**，取日志必须 `ls -t opencore-*.txt` 全匹配。

---

### §3z.22 突破：找到"断电后自己上电"的机制候选 —— `GaugingMitigationActions` 的 RTC 闹钟（2026-10-29 19:00）

#### 一、用户提供的关键判据

> "平时肯定不报 005 啊。"

⇒ **完全关机（S5）再开机不报 005**，只有 S4 后才报。

| 场景 | 报 005 | RTC 归零 | 结论 |
|---|---|---|---|
| S5 关机 → 开机 | ✘ | ✘ | CMOS 电池正常，RTC 靠电池维持 |
| **S4 断电 → 上电** | **✔** | **✔**（日志 INIT 全在 `2019-01-01T00:00:3X`） | **S4 路径特有** |

⇒ **CMOS 电池这条线彻底排除**（此前建议换 CR2032 的方案作废）。
⇒ 005 与 RTC 归零是 S4 断电时机序异常的**结果**，不是电池没电。

#### 二、决定性证据：每次睡眠后都有 1–4 分钟的 RTC 唤醒闹钟

`pmset -g log | grep "Wake Requests"` 逐条实测（本地时间）：

| 睡眠时刻 | `UserWake` 间隔 | 唤醒时刻 | 排定者 |
|---|---|---|---|
| 09:55:29 | 59 s | 09:56:29 | `GaugingMitigationActions,104` |
| 12:59:49 | 155 s | 13:02:24 | 同上 |
| 14:29:24 | 153 s | 14:31:57 | 同上 |
| 15:04:45 | 229 s | 15:08:34 | 同上 |
| 15:54:10 | 187 s | 15:57:18 | 同上 |
| 15:59:52 | 145 s | 16:02:18 | 同上 |
| 16:47:07 | 163 s | 16:49:51 | 同上 |
| **18:05:17** | **89 s** | **18:06:46** | 同上 |

日志格式原文：
```
[*process=powerd request=UserWake deltaSecs=89 wakeAt=2026-10-29 18:06:46
  info="com.apple.alarm.user-invisible-GaugingMitigationActions,104"]
```

**关键性质**（三条，缺一不可）：

1. **类型是 `UserWake`，不是 `DarkWake`** —— `UserWake` 是"用户可见唤醒"，会真正把系统拉起来，不只是维护性 DarkWake。
2. **用 RTC 硬件闹钟实现** —— 写在 RTC 的 alarm 寄存器里，**独立于 OS 是否运行，S4 断电后依然有效**（RTC 由 CMOS 电池供电）。
3. **每次睡眠都被重新排定，间隔 89–229 秒** —— 正好落在"灯灭后马上又亮"的观察窗口内。

`GaugingMitigationActions` = Apple 内部的**电池电量计校准**子系统（`powerd` 的未文档化 alarm），无任何用户可见开关。
社区记录（AlDente issue #1760）确认：它以 `com.apple.alarm.user-invisible-GaugingMitigationActions,<n>` 形式反复出现在 Wake Requests 中，
且 `pmset schedule cancelall` 清掉后**睡眠时会被重新排上**。

#### 三、这条链如何解释全部现象

```
合盖 → hibernatemode 25 写盘 → 断电（灯灭）          ← S4 成立
     → RTC alarm 到点（89–229 s 后）                  ← 硬件层，断电也有效
     → EC/固件被 RTC alarm 拉起 → 上电（灯亮）         ← 用户看到"自己亮"
     → 但 RTC 已在本轮断电中丢失 → 报 005，时间归 2019
     → 固件走的不是"用户按电源键的 S4 resume"，而是"RTC 闹钟唤醒"
     → boot.efi 凭 NVRAM 里的 boot-image 判 H:IS 1 → REAN → EXITBS
     → 内核 hibernate_machine_init → polled NVMe startIO 失败 → e00002bc
```

**这一条同时解释了此前所有孤立事实**：

| 观察 | 由本条解释 |
|---|---|
| 灯灭后自己亮，用户没碰 | RTC alarm |
| 每次必报 005、RTC 归 2019 | 断电时 RTC 域被带走 |
| S5 关机不报 005 | S5 不设 RTC alarm，且 RTC 供电正常 |
| `H:IS 1` 但 NVMe `startIO` 失败 | 固件走 alarm-wake 而非 resume，控制器未按 resume 初始化 |
| 4 次都是确定性失败 | alarm 每次都排、每次都触发 |

**⚠ 强度声明**：机制链条中的"RTC alarm 触发上电"这一段，有实测数据（alarm 存在 + 间隔吻合 + 类型为 UserWake + RTC 硬件闹钟性质），
但"18:06:02 那次上电就是这个 alarm 触发"**没有直接日志**（当时 clock 已被清零，alarm 记录失效）。
属于**强推断**，需用下面的一次性实验确认。

#### 四、一次性验证（1 分钟，不涉及 S4，零风险）

```bash
sudo pmset schedule cancelall      # 清掉当前 alarm
pmset -g sched                     # 确认已空
# 然后立刻合盖/睡眠，计时观察
```

| 观察（睡下后 5 分钟内） | 结论 |
|---|---|
| **不再自己亮** | 确认元凶是 RTC alarm ⇒ 转入"抑制 alarm"路线 |
| **仍然自己亮** | 不是（或不只是）alarm ⇒ 转 EC/固件层，需 Windows 对照 |

注意：`cancelall` 只能清**当前**已排的；`powerd` 会在睡眠过程中重新排定。
因此若结果仍是"自己亮"，还需做第二步（见下）。

#### 五、若确认是 alarm：抑制路线

`GaugingMitigationActions` 是电池 gauging 触发，可能的抑制点：

| 手段 | 依据 | 风险 |
|---|---|---|
| `hibernatemode 3` + `standby 1` + `standbydelayhigh 300` | alarm 每 89–229 s 来一次，**每次唤醒都重置 standby 计时器** ⇒ 永远到不了 300 s ⇒ 永不进入 S4 断电 | 等于不用 S4，但合盖唤醒全部走内存，快速且不 panic |
| 关闭"优化电池充电"/电池健康 | 未验证能否停止 gauging | 低 |
| 电池校准一次（完整充放） | gauging 的目的是校准；电量计一旦认为已校准，可能停止 | 低，耗时 |

**其中最实际的是第一条**：它不是在"修 S4"，而是把系统固定在"永不进入 S4 断电"的状态，
从而彻底避免 panic + 005 + RTC 归零。日常使用等价于把 `hibernatemode 0` 的效果做扎实。

#### 六、附带查清：`SSDT-PCI0.LPCB-Wake-AOAC` 是坏的，且内容与文件名不符

反编译 `EFI/OC/ACPI/SSDT-PCI0.LPCB-Wake-AOAC.aml`（OEM Table ID `CLWAKE`）实际内容是：

```asl
Method (_DSW, 3, NotSerialized)
{
    If (!_OSI ("Darwin")) { Return (Zero) }
    If ((Arg0 == 0x03))              // ← 致命错误
    {
        OperationRegion (AOWR, SystemIO, 0x1800, 0x02)
        Field (AOWR, ByteAcc, NoLock, Preserve) { AOAC, 8, AOEN, 1 }
        AOEN = Arg2                   // ← 参数也错位
    }
}
Method (_PRW, 0) { ... Darwin 返回 {0x6D, Zero} ... }
```

**按 ACPI 6.4 §7.3.1 原文**：
```
Arguments (3):
  Arg0 — device wake capability control: 0 = Disable, 1 = Enable
  Arg1 — target system state (0-4)
  Arg2 — target device state (0-3)
```
⇒ `Arg0` **只能是 0 或 1，永远不等于 3** ⇒ `If (Arg0 == 0x03)` **恒假** ⇒ 这段在 Darwin 下**从未执行过**
⇒ 这个"防唤醒"补丁**自部署起就是空操作**，等于从未测试过"压制 AOAC 唤醒"这条方向。

**而 OC-Little 官方 `SSDT-PCI0.LPCB-Wake-AOAC` 的内容根本不同**（原文实引）：
```asl
Scope (_SB.PCI0.LPCB) {
    If (_OSI ("Darwin")) {
        Method (_PS0, 0, Serialized) { \_WAK(0x03) }
        Method (_PS3, 0, Serialized) { }
    }
}
```
用途是修"唤醒后**不能点亮屏幕**/电源数据不更新"——不是 `_PRW`/`_DSW`。
⇒ **本机这份文件被换成了自定义内容，且写错了参数语义。**

**但要说清**：即使改成官方 `_PS0`/`\_WAK(0x03)`，也**解决不了当前 panic** ——
`_PS0` 在 LPCB 上电到 D0 时执行，而 panic 发生在 `ml_hibernate_active_post`（IOKit 恢复之前），阶段更早。

#### 七、本轮排除清单新增

| 变量 | 结论 | 依据 |
|---|---|---|
| CMOS 电池 | **排除** | 用户实测 S5 关机开机不报 005 |
| macOS 软件唤醒源（womp/powernap/tcpkeepalive/proximitywake/networkoversleep/ttyskeepawake） | **全部已 0** | `pmset -g custom` 实测 |
| `SSDT-PCI0.LPCB-Wake-AOAC` 的防唤醒作用 | **从未生效** | ACPI 规范 + 反编译，`If` 恒假 |
| `SSDT-LID-G7` 新增的 `_GPE._L00` | **高风险待查** | 原生 DSDT 无 `_L00`（只有 `_L66/_L69/_L61/_L62/_L6F/_L72`），新增其为 GPE 0x00 注册 handler，内含 `Sleep(0x03E8)` |
| ACPI 中声明可从 S4 唤醒的 `_PRW` | **53 处** | DSDT 全表扫描（GPE 0x69 最多，0x6D 为 GLAN/XDCI，0x72 一处） |

---

### §3z.23 对照组实测：Deep Idle 从不自发唤醒 —— §3z.22 的 RTC 闹钟假设被推翻（2026-10-29 18:55）

#### 一、用户提供的对照事实

> **"deepidle不会自己亮"**

这是一条**对照实验结论**：内存睡眠（Deep Idle）状态下，机器不会自己上电/亮起；只有 S4 断电路径会出现"自己亮"。

#### 二、日志实证：6 次 Deep Idle 唤醒，6 次都是用户按电源键

`pmset -g log` 全量（跨 boot 保留，最早 10-27）：

| 时间（本地） | 唤醒记录 | 唤醒原因 |
|---|---|---|
| 10-27 13:59:30 | `Wake from Deep Idle [CDNVA]` | `PWRB/UserActivity Assertion` |
| 10-27 19:01:06 | `Wake from Deep Idle [CDNVA]` | `PWRB/UserActivity Assertion` |
| 10-27 20:25:56 | `Wake from Deep Idle [CDNVA]` | `PWRB/UserActivity Assertion` |
| 10-28 10:20:37 | `Wake from Deep Idle [CDNVA]` | `PWRB/Notification` |
| 10-28 17:08:35 | `Wake from Deep Idle [CDNVA]` | `PWRB/User` |
| 10-29 15:56:13 | `Wake from Deep Idle [CDNVA]` | `PWRB/User` |

**`PWRB` = Power Button，电源键。6/6 全是人为按键，自发唤醒 0 次。**
⇒ 用户的观察在日志上完全成立。

#### 三、关键否证：7 次 `*UserWake` 闹钟，实际触发 0 次

10-29 当天，powerd 每次睡眠后都排了 `GaugingMitigationActions` 的 1–4 分钟闹钟，且都带 `*` 前缀
（`*` = powerd 当前选中的生效排程，即已写入 RTC）：

| 入睡时刻 | 排程延迟 | 应醒时刻 | 实际是否唤醒 |
|---|---|---|---|
| 12:59:49 | 155 s | 13:02:24 | **否** |
| 14:29:24 | 153 s | 14:31:57 | **否** |
| 15:04:45 | 229 s | 15:08:34 | **否** |
| 15:54:10 | 187 s | 15:57:18 | 15:56:13 是 `PWRB/User`（用户按的），**非闹钟** |
| 15:59:52 | 145 s | 16:02:18 | **否** |
| 16:47:07 | 163 s | 16:49:51 | **否** |
| 18:05:17 | 89 s | 18:06:46 | **否**（见下条，18:38 才 boot） |

**7 排 0 触发。** 说明 `com.apple.alarm.user-invisible-*` 这类闹钟在本机**排得上但不会真的拉起系统**——
这与它的命名语义一致（user-invisible = 不打扰用户，只在系统本就醒来时顺带处理）。

⇒ **§3z.22 提出的"RTC 闹钟把机器从 S4 拉起"假设，作废。**
（§3z.22 当时已自我标注为"强推断、缺直接日志"，现由对照实验证伪。原文保留不改，以此节为准。）

#### 四、顺带核出的四条硬事实

**(1) 10-29 全天 14 次重启，SMC 一律记录 `shutdown cause: 5`（Software initiated shutdown）。**
原文样例：`2026-10-29 18:39:11 +0800 ShutdownCause  SMC shutdown cause: 5: Software initiated shutdown`
⇒ 固件侧看到的都是"软件请求的关机/断电"，**不是掉电（power loss）**。这与 hibernatemode 25 的语义吻合，
也说明"断电"这一步是软件正常下发的，不是供电意外中断。

**(2) 真实的 S4 恢复失败只有 2 次，不是 4 次。**
`/Library/Logs/DiagnosticReports/` 下 panic 文件**仅 2 个**：
`Kernel-2019-01-01-080117.panic`、`Kernel-2019-01-01-080103.panic`。
文件名时间戳是 **2019-01-01 08:01** —— 即 **RTC 已归零后约 1 分钟**写下的（RTC 丢失是 S4 断电的直接后果）。
⇒ 其余十几次重启都是用户手动开关机，没有产生 panic。

**(3) 18:38 那次 boot 没有对应的 shutdown 记录。**
`last reboot` 序列：`17:30 shutdown` → `17:31 reboot` → **`18:38 reboot`（前无 shutdown）**。
而 18:05:16 刚睡着。⇒ **这是一次非正常断电重启**，与用户描述的"自己亮 → 黑屏 → 复位"吻合。
时间跨度 32 分钟说明：上电后引导未完成、卡在恢复阶段，最后由外部手段断开。

**(4) 10-29 15:56:13 的 `HibernateStats` 显示 `hibmode=3`。**
原文：`2026-10-29 15:56:13 HibernateStats  hibmode=3 standbydelaylow=300 standbydelayhigh=300  81`
⇒ **当时 AC 侧 hibernatemode 是 3，不是 25**（现在 `pmset -g custom` 已变 25，由 `s4-arm.sh` 强设）。
这条解释了"为什么 10-29 一次 `/HibernateError` 都没有"：hibernate 模式不同，路径不同。

**(5) 10-28 有 2 次 hibernate 写盘失败，10-29 一次没有。**
- `2026-10-28 17:23:50 DarkWake from Standby [CDN] : due to /HibernateError`（45 s）
- `2026-10-28 17:44:56 DarkWake from Standby [CDN] : due to /HibernateError`（18 s）
`/HibernateError` 是内核内部原因标记，含义是"standby 到期要写盘，但写盘失败，退回内存睡眠"。
⇒ **10-28 那两次 S4 尝试根本没走到断电**，卡在写盘；**10-29 走的是另一条路（断电成功）**。

#### 五、排除矩阵（deepidle 对照法）

用户这条对照实验的价值：**凡是"内存睡眠时也会生效"的唤醒源，全部一次性排除。**

| 唤醒源 | 内存睡眠是否生效 | deepidle 实测 | 结论 |
|---|---|---|---|
| 键盘/触控板（含合盖压键） | 是 | 6 次全 PWRB，无一例 | **排除** |
| USB 设备热插拔 | 是 | 同上 | **排除** |
| EC SCI / `_L00` / GPE 0x69 | 是 | 同上 | **排除**（`SSDT-LID-G7` 风险降级） |
| 网络 / `womp` / `powernap` / `proximitywake` | 是 | 全为 0，且无网络唤醒 | **排除** |
| `GaugingMitigationActions` RTC 闹钟 | 排了但**不触发** | 7 排 0 触发 | **排除** |
| `calaccessd.travelEngine` 闹钟 | 同上 | 当前 sched 有 2 条（00:48/01:45），同类 | **同类待观** |
| 电源键 | 是 | —— | 用户未操作，**排除** |

**剩下的机制必须满足：仅在"主电源轨被切断后重新建立"时才能发生。**
⇒ 候选收敛到 **固件/EC 层的断电-上电路径**，与操作系统、OpenCore、ACPI 全部无关。

#### 六、新的最强候选：S4 断电被固件当成"供电恢复"处理

假设链：`hibernatemode 25` 写盘完成 → 内核下发断电 → **EC 执行时切断了主电源轨（等效 S5 级）** →
某个环节（适配器检测抖动 / EC 状态机超时 / 电容放电曲线）让供电轨在数十秒内重新建立 →
固件检测到"AC 插入/恢复" → 按 BIOS 的 **`AC Power Recovery` / `Power On When AC Detected`** 策略**自动开机** →
POST 时 RTC 已随断轨丢失 → 报 **005** → OC 引导 → 读到残留镜像头 → 尝试恢复 → `startIO` 失败 → panic/黑屏。

该假设能同时解释全部五条现象：005 只在 S4 报、S5 不报、deepidle 不触发、断电后必然上电、上电后必然走恢复失败路径。

**标注：这是推断，尚无直接证据。** 判据在下面第五节。

#### 七、判别实验（按性价比排序，均不涉及修 S4）

**F3（首选，5 分钟，零风险，一刀切开)**
```
1) sudo shutdown -h now            # 走 S5
2) 等电源灯完全熄灭、风扇停转
3) 拔掉电源适配器，等 10 秒，插回
4) 观察：机器是否自己开机
```
- **自己开机** ⇒ BIOS 的 `AC Power Recovery` 处于 `Power On` ⇒ **§六假设成立**，根因找到，去 BIOS 关掉即可。
- **保持关机** ⇒ AC 恢复自动开机被排除，转 F1。

**F1（电池路径对照，需要临改配置）**
```
sudo pmset -b hibernatemode 25
# 拔适配器，用电池跑一次 S4
```
- 电池供电下**仍自己上电** ⇒ 与 AC 无关，指向 EC 对 S4 断电的处理（下一步需 Windows 对照）。
- 电池供电下**不上电** ⇒ 问题锁定在 AC 供电路径。

**F2（BIOS 核对，与 F3 同时做）**
HP 的 `Advanced → Power Management Options`（或 `Built-In Device Options` 附近）逐项核对：
`AC Power Recovery`（或 `Power On When AC Detected`）、`Scheduled Power-On`、`Power On from Keyboard Ports`、
`S5 Maximum Power Savings`、`PCI Express Power Management (ASPM)`。
**注意 BIOS 里任何名字带 `S4`/`Hibernate` 的项也要看**，HP 消费/商务线的 S4 支持常被固件裁剪。

#### 八、止血状态（未执行，`sudo` 在本会话不可用）

`pmset -g custom` 现状：**AC = `hibernatemode 25` + `standby 1` + `standbydelayhigh 300`**。
⇒ 合盖 5 分钟必然走一遍"写盘→断电→005→恢复失败"，与是否在做实验无关。

建议止血（需用户手动执行）：
```
sudo pmset -c hibernatemode 3 standby 0 autopoweroff 0
```
- `hibernatemode 3` = 内存+磁盘双写（safe sleep），`standby 0` = **永不进入断电阶段**。
- 合盖变成普通内存睡眠，**不会丢 RTC、不会报 005、不会 panic**。
- 要再测 S4 时，由 `s4-arm.sh` 显式把 `hibernatemode 25 / standby 1 / standbydelayhigh 60` 设回去。
- 电池分支当前已是 `hibernatemode 0 / standby 0`，无需改动。

---

### §3z.24 D6 实测（standbydelay 1）：仍失败，但首次抓到完整恢复日志 —— 内核对镜像的判断与 boot.efi 分裂（2026-10-29 19:45）

#### 一、D6 执行时间线（全部本地时间）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 19:33:08 | 屏幕关闭，`darkwakelinger` 建 15 s | `pmset -g log` |
| **19:33:38** | `Entering Sleep state due to 'Software Sleep pid=31107'`（`pmset sleepnow`） | `pmset -g log` |
| 19:33:40 | 排 `*UserWake deltaSecs=159 wakeAt=19:36:19 GaugingMitigationActions` | `pmset -g log` |
| 19:34 前后 | 写盘 → 断电（`standbydelayhigh 1` 已生效） | 推断 |
| 上电后 | RTC 归零为 **2019-01-01 00:00 UTC**，固件自动上电引导 | 见下 |
| 00:05:58 UTC | OC 写日志 `opencore-2019-01-01-000558.txt` | ESP |
| **00:06:31 UTC** | **panic 写入** `Kernel-2019-01-01-080631.panic` | DiagnosticReports |
| 19:41:01 | 复位后正常 boot（`kern.boottime`），**无 wtmp 记录** = 非正常重启 | `sysctl` / `last` |

`pmset -g` 确认八连全部生效：`hibernatemode 25 / standby 1 / standbydelaylow 1 / standbydelayhigh 1 / powernap 1 / sleep 1 / womp 0 / proximitywake 0`。

#### 二、panic 与 D4/D5 逐项一致（第三次同源）

`Kernel-2019-01-01-080631.panic` 原文：

```
panic(cpu 0 caller 0xffffff801e8866ab): Hibernate restore error e00002bc @IOHibernateIO.cpp:2921
_hibernate_machine_init + 0x12db
_ml_hibernate_active_post + 0x27
Kernel version: Darwin 25.6.0 ... root:xnu-12377.161.15.701.48~2/RELEASE_X86_64
System model name: MacBookPro16,4
Hibernation exit count: 0
```

与 08:01:03 / 08:01:17 两份**同一个 panic string、同一个偏移、同一个错误码**。文件大小亦同为 9490 B。

**附带更正**：当前内核已是 `xnu-12377.161.15.701.48~2`，不是先前取证用的 `xnu-12377.121.6`。
源码行号 2921 由 panic string 自带，不受影响；但若再引用行号对应的源码段落，须重新对 `161.15` 分支核对。

#### 三、★ 首次拿到完整恢复日志，发现全新事实

`/Volumes/ESP/opencore-2019-01-01-000558.txt`（9629 字节非零内容，其余补零）。关键段落原文：

```
00:000 00:000 AAPL: #[EB.H.IS|!] Err(0xE) <- RT.GV boot-signature 7C436110-AB2A-4BBB-A880-FE41995C9F82
00:003 00:003 AAPL: #[EB.H.IS|!] Err(0xE) <- RT.GV boot-image-key 7C436110-AB2A-4BBB-A880-FE41995C9F82
00:007 00:003 AAPL: #[EB|H:IS] 0
00:010 00:003 AAPL: #[EB|LOG:INIT] 2019-01-01T00:06:03
...
00:108 00:003 AAPL: #[EB.H.LV|!] Err(0xE) <- RT.GV boot-signature ...
00:114 00:003 AAPL: #[EB.H.LV|!] Err(0xE) <- RT.GV boot-image-key ...
00:121 00:003 AAPL: #[EB.H.LV|!] Err(0xE) <- RT.GV boot-image ...
00:125 00:004 AAPL: #[EB.H.LV|!] Err(0xE) <- RT.SV- boot-signature ...   ← 尝试删除，也不存在
00:135 00:002 AAPL: #[EB|H:NOT]
```

两条硬结论：

**(1) `#[EB|H:IS] 0`** —— Hibernate Image Status = **0 = 没有休眠镜像**。
之前用户贴的 `084752.txt` 是 `H:IS 1`（有镜像）。**这次是 0。**

**(2) `#[EB|H:NOT]`** —— boot.efi 明确判定 **"这不是休眠唤醒"**。

**(3) 三个元数据变量全部 `Err(0xE) = EFI_NOT_FOUND`**：
`boot-signature`、`boot-image-key`、`boot-image`（GUID `7C436110-AB2A-4BBB-A880-FE41995C9F82`）—— **NVRAM 里根本不存在**。

⇒ **boot.efi 认为这是普通冷启动，可内核照样进了 `hibernate_machine_init` 并 panic。**

#### 四、矛盾的解释：`-hbfxforce` 与 `hfile=` 让两侧判断分裂

这是本轮最重要的推断，但有直接依据：

| 参数 | 作用 | 依据 |
|---|---|---|
| `hfile=/var/vm/sleepimage` | 让内核**直接使用指定路径**的 hibernation 文件，绕过标准 NVRAM 元数据变量 | HibernationFixup 参数语义；与 `562f881`「真正根因是内核没有写镜像路径 —— boot-args 补 hfile」的自诊断一致 |
| `-hbfxforce` | **强制**内核按 hibernate 恢复路径执行，不看 boot.efi 的判定 | HibernationFixup 参数语义 |

于是形成死局：
- 内核侧：被 `hfile=` 告知路径、被 `-hbfxforce` 强制进恢复 → 调 `_hibernate_machine_init`
- 固件侧：NVRAM 无 `boot-signature`/`boot-image-key`/`boot-image` → boot.efi `H:IS 0`、`H:NOT`
- 内核去 `IOPolledFileRead` 读一个**未经 boot.efi 认可**的镜像 → `IOStartPolledIO` → NVMe polled `startIO` → `kIOReturnError`
- **一页都没恢复，全部对得上。**

⇒ 之前锁定在 NVMe 的那个死点，**可能不是 NVMe 的问题，而是"读的入口本就不该被打开"**。

#### 五、D6 顺带排除的变量

| 变量 | 结论 | 依据 |
|---|---|---|
| `standbydelayhigh 300` 的「S3 窗口期」 | **排除** | D6 改成 1 秒后失败方式完全不变 |
| `powernap 0` | **排除**（本轮已改 1，仍失败） | 同上 |
| `sleep 0` | **排除**（本轮已改 1） | 同上 |
| 「Dell 成功案例的 pmset 八连」 | **不是充分条件** | 八连全生效仍 panic |

#### 六、D7 方案（下一步，单变量）

移除 `-hbfxforce` 与 `hfile=`，让**内核与 boot.efi 用同一套原生元数据**：

```
-hbfxdbg -hbfxforce hfile=/var/vm/sleepimage   ← 删掉这三个
rtcfx_exclude=0E-57,5A-7F                      ← 保留（hibernation 变量区 0x80-0xAB 本就未排除）
```

**预期形态（必须先写清）**：
- **成功** → 日志出现 `H:IS 1`，且 NVRAM 三变量可读，恢复段走通
- **失败形态 A（最可能）** → `H:IS 0` + 正常冷启动，**不再 panic**，等于"休眠静默失败、当普通开机"
- **失败形态 B** → 若移除 `hfile=` 后内核报"没有写镜像路径"（回到 `562f881` 之前的状态），说明原生 NVRAM 元数据写入确实被阻断，问题定位到 NVRAM 写入侧

**回滚点**：三个 boot-arg 原样加回即可；备份 `config-2026-10-29-1945-pre-d7.plist`。
**不可逆风险**：无（只改 boot-args，不写固件、不写系统卷）。

#### 七、仍需并行的硬件侧事实

RTC 每次断电归零（`POST 005`）这件事本身没变。而 `boot-*` 三变量在 **NVRAM（SPI Flash）不掉电**，
理论上断电不该丢 —— 所以"为什么不在 NVRAM"要么是内核没写（`hfile=` 绕过），要么是写入被阻断。
D7 正是用来分辨这两者的。

---

### 3z.24. D7 已实施 + 三项新证据（2026-10-29 19:50）

#### 一、D7 改动（已落盘并镜像到 ESP）

```
删：-hbfxdbg -hbfxforce hfile=/var/vm/sleepimage
留：-v -igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall
    revpatch=sbvmm rtcfx_exclude=0E-57,5A-7F keepsyms=1 -vi2c-force-polling
```

- 备份：`EFI/OC/config-2026-10-29-1948-pre-d7.plist`
- 新 sha256：`8d101db5…2d0da1`，仓库与 `/Volumes/ESP/EFI/OC/config.plist` **两侧一致**
- 需**重启**生效（boot-args 属启动参数，非 `pmset` 类可即时生效项）

#### 二、★ 证据一：`nvram -p` 证明三个休眠元数据变量压根不存在，且 NVRAM 本身健在

本机开机态 `nvram -p` **只有 13 个变量**，其中 9 个是 OC `NVRAM/Add` 硬注入
（`boot-args`、`csr-active-config`、`prev-lang:kbd`、`SystemAudioVolume(DB)`、
`bluetoothExternalDongleFailed`、`bluetoothInternalControllerInfo`、
`ForceDisplayRotationInEFI`、`run-efi-updater`），

**真正由 macOS 自己写下并存活至今的只有 4 个**：
`aapl,panic-info`、`AAPL,PanicInfo000K`、`backlight-level`、`LocationServicesEnabled`。

⇒ **NVRAM 持久化是好的**（这 4 个变量经历了多次 S4 断电与 RTC 归零仍在）。
⇒ 所以 `boot-signature` / `boot-image-key` / `boot-image` 的 `Err(0xE)`
**不是「断电后 NVRAM 失忆」，而是「内核/kext 从来没把它们写进去」**。
这把 §3z.23 里「要么没写、要么被阻断」的二选一，收敛到「没写」。

#### 三、★ 证据二：sleepimage 只有 1 GiB，而物理内存 16 GB（严重的尺寸不匹配）

| 项 | 值 | 来源 |
|---|---|---|
| 物理内存 | 16.0 GB | `sysctl hw.memsize` |
| `sleepimage` 逻辑大小 | 1 073 741 824 = **1 GiB** | `ls -l` |
| `sleepimage` 实际占用块 | blocks=2 097 152 × 512 = **1 GiB**（非稀疏） | `stat` |
| `Hibernate File Min` | **1 073 741 824** | `ioreg -rc IOPMrootDomain` |
| `Hibernate File` | `/var/vm/sleepimage` | 同上 |
| `Hibernate Mode` | 25 | 同上 |
| `sleepimage` mtime | 2019-01-01 08:06（= RTC 归零期那次 panic 时刻） | `ls -l` |

**公开文档口径**（osxdaily / CNET / `man pmset` 引用一致）：
> sleepimage 的大小「一般与物理内存完全一致；2 GB 内存则 sleepimage 也是 2 GB」。

⇒ 16 GB 内存应有 ~16 GB 镜像，实测仅 **6.25%**。
⇒ 这给出一条比 NVMe 更靠前的因果：**镜像目标文件只有 1 GiB，16 GB 内存的内容写不进去
⇒ 写镜像阶段失败 ⇒ 不写元数据（证据一）⇒ boot.efi `H:IS 0` ⇒ 恢复无镜像 ⇒ panic**。
⇒ 之前把死点锁在 `IONVMeControllerPolledAdapter::startIO`，可能是**在追一个下游症状**。

#### 四、★ 证据三（对 §3z.23 的更正）：`-hbfxforce` 与 `hfile=` 都不是 HibernationFixup 的参数

HibernationFixup 官方 README 的 boot-args 完整列表只有：

```
-hbfxoff  -hbfxdbg  -hbfxbeta  -hbfx-dump-nvram
hbfx-patch-pci=<devs>  -hbfx-disable-patch-pci  hbfx-ahbm=<bits>
```

**列表里没有 `-hbfxforce`，也没有 `hfile=`。**

- `-hbfxforce`：**不是该 kext 的参数**，§3z.23 四把它归因为「强制内核走恢复路径」缺乏依据。
  （它可能来自某个教程的臆造，或早期分支，但当前主线 README 无此项。）
- `hfile=`：**是 XNU 内核自己的 boot-arg**（`strings /System/Library/Kernels/kernel` 里确有 `hfile` 与
  `hibernatefile` 两个独立字符串），语义为覆盖休眠文件路径，**与 HibernationFixup 无关**。

顺带更正 §3z.23 的因果：`-hbfxforce` 未必在"强拉内核恢复"，**D7 的真实价值是删掉两个无效/越权参数，
让镜像尺寸与元数据都回到内核原生计算路径**。

#### 五、README 给出的另一条关键机制（解释元数据为何必须由 kext 代写）

> By design the mach kernel encrypts hibernate sleepimage and writes the encryption key to variable
> `IOHibernateRTCVariables` in the system registry (PMRootDomain). Somehow this value has to be written
> into RTC (or SMC) in order the boot.efi could read it. ... Fortunately, boot.efi can read key
> `IOHibernateRTCVariables` from NVRAM! **This kext detects entering into "hibernate" power state, reads
> variable IOHibernateRTCVariables from the system registry and writes it to NVRAM.**

⇒ 黑苹果上「元数据进 NVRAM」这一步**本来就要靠 HibernationFixup 代劳**，前提是
① 内核真正进入 `kIOHibernateStateHibernating`，② 它能拿到 `IOHibernateRTCVariables`。
若①因写镜像失败而不成立，kext 无物可同步 —— **与证据二完全自洽**。

#### 六、新发现的配置矛盾（待判，暂不动）

| 来源 | hibernatemode |
|---|---|
| `pmset -g` | **25** |
| `ioreg` `Hibernate Mode` | **25** |
| `sysctl kern.hibernatemode` | **1** |
| `ioreg` `SystemPowerProfileOverrideDict` → AC Power | **3** |

`sysctl` 与 `pmset` 不一致时以 `pmset`/`ioreg` 的行动值（25）为准；`kern.hibernatemode=1` 疑为
boot 期初值或旧式取值残留，`SystemPowerProfileOverrideDict` 是备用 profile，均**未证实有实际作用**，
本节仅登记，不作为判据。

#### 七、D8（下一步，需重启 + 一次 sudo）

```
# 1) 删除尺寸异常的镜像（系统会在下次睡眠时按内存重建）
sudo rm -f /var/vm/sleepimage

# 2) 重启，让 D7 的 boot-args 生效
sudo reboot

# 3) 醒来后先核 D7 是否生效
nvram boot-args          # 应不含 -hbfxforce / hfile=
ls -l /var/vm/sleepimage # 不存在属正常
```

随后睡一次（`sudo pmset sleepnow`），**三个判据**：

1. 新 `sleepimage` 大小 —— **≈16 GB ⇒ 病根确认在尺寸；仍是 1 GiB ⇒ 有东西在限死尺寸，继续追**
2. 是否还 panic（`ls -t /Library/Logs/DiagnosticReports/*.panic`）
3. 新 OC 日志的 `H:IS` 是 0 还是 1

**回滚点**：`cp EFI/OC/config-2026-10-29-1948-pre-d7.plist EFI/OC/config.plist`（并回写 ESP）。
**不可逆风险**：无。删 sleepimage 是 Apple 官方认可的安全操作（会自动重建）。

---

### 3z.25. D7 已生效，但镜像重建后仍是 1 GiB（2026-10-29 20:10）

#### 一、D7 生效确认

`nvram boot-args` 实测：

```
-v -igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall
revpatch=sbvmm rtcfx_exclude=0E-57,5A-7F keepsyms=1 -vi2c-force-polling
```

`-hbfxforce` / `hfile=` **均已消失**，boot 时间 20:06:44。D7 达成。

#### 二、★ 关键事实：删掉后系统立刻重建，仍是 1 GiB

```
-rw------T 1 root wheel 1073741824 2026-10-29 20:07 sleepimage
```

mtime 20:07 = 开机后约 1 分钟内生成。⇒ **不是文件残留，是内核主动按 1 GiB 创建**。
`ioreg` 同步复核：`Hibernate File Min = 1073741824`，`Hibernate File = /var/vm/sleepimage`。

#### 三、1 GiB 是不是 macOS 26 的新策略？——不是

三份独立公开资料（CleanWithCrumb、IsItSafeToDelete、Digitash）与 osxdaily/CNET 口径一致：
**sleepimage 大小应等于物理内存**（16 GB 机器 → 约 16 GB）；均未提及 Tahoe 改了此策略。
Digitash 另提到 Apple Silicon 上可能接近 0 字节，但**本机是 Intel**，不适用。

⇒ 1 GiB / 16 GB = 6.25%，判定为异常。

#### 四、内核里也没有 `hfilesize` 参数可以解释它

`strings /System/Library/Kernels/kernel | grep -E '^(hfile|hibernatefile|hibernatemode)$'`
只有这三条，**没有 `hfilesize`**。⇒ 1 GiB 不是 boot-arg 设的，是内核自身计算/硬编码行为。

#### 五、下一步 D9：用 `hibernatemode 3` 做"NVRAM 是否写入"的直接观测（不重启、不断电）

设计理由：`hibernatemode 25` 写完就断电，无法在睡眠后检查 NVRAM；
换成 `hibernatemode 3`（写镜像但保持内存供电）+ `standby 0`（禁止转 S4 断电），
睡一次再唤醒，就能**直接看 `boot-image-key` 三个变量有没有被写进 NVRAM**，同时看 `sleepimage` 是否增长。

```
sudo pmset -c hibernatemode 3 standby 0 autopoweroff 0
sudo pmset sleepnow
```

**判据矩阵**：

| 唤醒后看到 | 结论 |
|---|---|
| NVRAM 有三变量 **且** sleepimage ≈16 GB | 写镜像与写元数据在 mode 3 下都成功 ⇒ mode 25 的断电才是断点 |
| NVRAM 有三变量 **但** sleepimage 仍 1 GiB | 元数据写入正常，尺寸不阻碍 ⇒ 死点在恢复侧 |
| NVRAM **无**三变量 | 写镜像阶段根本没走完 ⇒ 1 GiB 尺寸限制是首要嫌疑 |
| 唤醒后直接 panic | mode 3 也坏 ⇒ 与休眠模式无关，是 restore 路径本身 |

**风险**：`hibernatemode 3` + `standby 0` 不会断电，最坏情况是唤醒黑屏但机器还在（不 panic、不丢数据）。
**回滚**：`sudo pmset -c hibernatemode 25`（若要继续测 S4）。

---

### 3z.26. 反汇编 `IOHibernateSystemSleep`：1 GiB 的位置找到了，但"尺寸限死写入"假说被削弱（20:15）

#### 一、先更正 3z.25 的 D9 设计错误（用户当场指出）

`hibernatemode 3` 是 deepidle：内存持续供电，**正常睡眠不写镜像**，只有电池告急或转 standby 才写。
用它测"写镜像是否成功"根本不会触发写盘。用户指出"之前不是试过吗？deepidle 不会写 sleepimage"——**成立**。
10-29 15:56 那次 `hibmode=3` 全程零 `HibernateError`，即为此机制。

#### 二、定位过程（本机内核二进制，非推测）

```
nm -a /System/Library/Kernels/kernel | grep -i ibernate
→ __Z22IOHibernateSystemSleepv @ 0xffffff8000998790
→ __Z21IOHibernateSystemInitP14IOPMrootDomain @ 0xffffff800099ab80
```

`IOPMrootDomain::getHibernateSettings(p1,p2,p3)` 只读三个属性键（实测字符串）：
`Hibernate Mode`、`Hibernate Free Ratio`、`Hibernate Free Time` —— **不含尺寸**。

`IOHibernateSystemSleep` 内命中三处关键指令：

| 地址 | 指令 | 含义 |
|---|---|---|
| `0xffffff8000998af5` | `lea "Hibernate File Min"` → 存 `rbx+0x28` | 读最小尺寸属性 |
| `0xffffff8000998d2d` | `lea "Hibernate File Max"` → 存 `rbx+0x50` | 读最大尺寸属性（**本机该属性不存在**） |
| `0xffffff8000999006` | **`movl $0x40000000, %r8d`** | **硬编码 1 GiB 常量，作为第 5 参数传给 `IOPolledFileOpen`** |

#### 三、★ 但真正的文件长度不是这个 1 GiB

紧邻调用前的计算（`0xffffff8000998f0d`~`0xffffff8000998f18`）：

```
leaq  (%rax,%rdx,8), %r15      ; r15 = 页数 × 页大小 类算式
andq  $-0x100000, %r15         ; 向下对齐到 1 MiB
addq  $0x100000, %r15          ; 再加 1 MiB
```

然后：

```
movq %r14, %rdx   ; arg3 = file_offset = max(FileMax, r15)
movq %r15, %rcx   ; arg4 = file_length = r15   ← 真实大小走这里
movl $0x40000000, %r8d   ; arg5 = 1 GiB（常量）
call IOPolledFileOpen    ; mangled: (PKc j y y y Pv m ...)
```

⇒ **内核确实按内存页数算出了真实文件长度（`r15`）并作为 `file_length` 传入**；
那个 1 GiB 是**另一个独立参数**（第 5 个），不是文件长度。

**因此 3z.24 §三 的「1 GiB 太小导致写不进去 ⇒ 不写元数据」这条因果链证据不足，暂降级为「未成立的假说」。**
「sleepimage 开机即 1 GiB」更可能是内核预分配/占位的固定下限值，未必是病因。

#### 四、这一轮真正站得住的结论

1. `Hibernate File Max` 属性在本机**不存在**（ioreg 查不到），所以 `file_offset` 会退化为 `r15`。
2. 1 GiB 常量位置已精确定位到 `0xffffff8000999006`，若后续要动它需改内核，不可行。
3. 尺寸假说被削弱后，**最有效的下一步不再是查尺寸，而是拿一次 D7 条件下的真实睡眠数据**。

#### 五、下一步 D10：D7 条件下睡一次（唯一会写镜像的模式是 25）

```
# 睡之前先记基线
ls -l /var/vm/sleepimage

sudo pmset sleepnow
```

**三个判据（醒来后）**：

| 观测 | 含义 |
|---|---|
| `sleepimage` 涨到 ≈16 GB | 写镜像真的执行了 ⇒ 病根在恢复侧，不在写入 |
| `sleepimage` 仍是 1 GiB 且 mtime 更新 | 打开文件后没写入任何有效数据 ⇒ 写入阶段失败 |
| `sleepimage` 仍是 1 GiB 且 mtime 不变 | 内核压根没走到写文件这步 |
| 新增 panic / `H:IS` 值 | 与历史三次对照是否同源 |

---

### 3z.27. D10 实测：D7 下首次睡满一轮 —— 无 panic、boot.efi 认镜像、但仍冷启动（2026-10-29 20:25）

#### 一、时间线（本地时间，全部实测）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 20:06:44 | 上一轮重启完成（boot-args 已是 D7 版） | `sysctl kern.boottime` |
| 20:06:59 | `sleepimage` **被创建**（birth time） | `stat %SB` |
| 20:15:11 | `Entering Sleep state due to 'Software Sleep pid=10232'` Using AC 100% | `pmset -g log` |
| 20:15:12 | 排 `*UserWake 107s → 20:16:59`（GaugingMitigationActions） | 同上 |
| ~20:15:1x | **断电**（见下「四、RTC 再次归零」） | USB assertion `creat=2019/1/1 08:03` |
| **20:17:34** | boot.efi 启动，日志 `opencore-2026-10-29-121734.txt`（UTC 12:17:34） | ESP |
| 20:17:36 | `EXITBS:START` 交给内核 | 同上 |
| 20:18:44 | 内核 uptime 起点（`uptime` 反推） | — |
| 20:19:07 | `sleepimage` mtime 被更新 | `stat %Sm` |
| 20:19:29 | **新 console 登录** | `last` |

#### 二、★ OC 日志：H:IS 1，完整休眠引导路径（无 `H:NOT`）

```
00:000  #[EB|H:IS] 1
00:170  #[EB.H.CHK|BM] 0x0000000000000000
00:176  #[EB|H:BI] <02010c00d041...39 0030 0066 0035 0038 0032 0065 0030 0030 0030 00...>
00:191  #[EB.H.CHK|!] Err(0xE) <- BS.LocDP 5B27263B-9083-415E-889E-6432CAA9B813
00:197  #[EB|H:WCK]
00:201  #[EB|H:BOOT.1]
00:207  #[EB|H:DLW] 0
00:220  #[EB|H:SIG] 0x73696D65          ← "sime"，镜像头有效
00:235  #[EB.H.HB|!] Err(0x84) <- 17407E5A-AF6C-4EE8-98A8-00210453CDD9.R MSWr
00:258  #[EB|H:HBOPT] 0 1 1 0
00:272  #[EB|H:RDST]
00:277  #[EB|LOG:REAN:START] 2026-10-29T12:17:35
00:915  #[EB|LOG:REAN:END]   2026-10-29T12:17:36
00:920  #[EB|H:RDEND]
00:925  #[EB.H.HB|DT] 3 0
00:939  #[EB|LOG:EXITBS:START] 2026-10-29T12:17:36
```

**`H:NOT` 没有出现**，说明 boot.efi 判定这是休眠唤醒并完整走了 REAN + EXITBS。

#### 三、★ 但这**不是新现象**：今天 16:47 那次逐字段完全相同

`opencore-2026-10-29-084752.txt`（UTC 08:47 = 本地 16:47，D7 之前）同样：

```
H:IS 1 → H:BI → H:WCK → H:BOOT.1 → H:DLW 0 → H:SIG 0x73696D65
→ H:HBOPT 0 1 1 0 → REAN:START/END → H:RDEND → EXITBS:START
```

两份日志**有效文本长度同为 4596 字节**，字段集合一致。
⇒ **「boot.efi 认镜像」在 D7 之前就已成立**，不能算 D7 的成果。
（真正的 D7 变化在 19:33 那次：带 `hfile=`/`-hbfxforce` 时反而是 `H:IS 0` + `H:NOT`。）

#### 四、★ D7 带来的唯一实质变化：**不再 panic**

| 轮次 | OC 判定 | 内核结果 | 新 panic |
|---|---|---|---|
| 16:47 | H:IS 1 | panic `e00002bc @2921` | 有 |
| 19:33 | H:IS 0 + H:NOT | panic（`-hbfxforce` 强拉） | 有 |
| **20:15（D7）** | H:IS 1 | **无 panic** | **无**（仍 4 份旧 panic） |

`DiagnosticReports` 计数未变，`Kernel-2019-01-01-080631.panic` 仍是最新一份。

#### 五、★ 结论层面：仍是**冷启动**，不是恢复

三条独立判据，互相印证：

1. `last`：`console 20:07 - 20:19 (00:12)` 旧会话**在 20:19 结束**，随后 `console 20:19 still logged in` 新会话。
   成功的休眠唤醒不会产生新的 console 登录记录。
2. `ioreg -rc IOPMrootDomain` → `"IOHibernateState" = <00000000>`（0 = 未处于休眠态）。
3. 用户侧终端输出 `[恢复于 2026-10-29 20:19:45]` + `Last login: 20:19:29 on console` = Terminal 被状态恢复重新拉起，不是原会话延续。

#### 六、★★ 自我更正：`sleepimage` 开机后的尺寸**不能**作为写镜像成败的判据

```
birth  = Oct 29 20:06:59     ← 上一轮开机时创建
modify = Oct 29 20:19:07     ← 本轮开机后 ~23 秒被改写
size   = 1073741824（1 GiB），blocks=2097152（真实分配）
```

- 文件 **在 20:06:59 开机时创建**，而不是 20:15 睡眠时；20:19:07 又被内核动了一次。
- 结合 3z.26 反汇编：`IOHibernateSystemSleep` 打开文件时按内存页算出真实长度 `r15`；
  若 20:15 真的写成过大文件，**开机后 20:19:07 这次触碰会把长度重置回 `Hibernate File Min`=1 GiB**。
- ⇒ **「睡完回来还是 1 GiB」既可能是没写，也可能是写了被开机重置**，二者不可区分。

**因此 3z.25 §五 与 3z.26 §五 里以「文件大小是否涨到 16 GB」作判据的设计（D9/D10 判据矩阵）全部作废。**

#### 七、★ 新发现的疑点：EXITBS 到内核起点之间有 68 秒空档

| 时刻 | 事件 |
|---|---|
| 20:17:36 | `EXITBS:START`（boot.efi 交棒） |
| 20:18:44 | 内核 uptime 起点（`uptime` 在 20:22:44 报 up 4 mins） |

正常冷启动从 EXITBS 到内核跑起来是**秒级**；68 秒是异常量级。
最自然的解释（**推断，未证**）：内核进入 `hibernate_machine_init` 后反复尝试 polled 读盘，
每次超时后重试，耗尽后放弃恢复、**回退到冷启动**而不是 panic。
这与「无 panic + 冷启动 + 68 秒延迟」三者自洽，但**缺内核日志直接证据**。

#### 八、待办：唯一能定性的证据是内核日志（`sudo` 在本环境被禁）

```
# 1) 内核启动日志里的休眠相关行
sudo dmesg | grep -iE "hiber|sleepimage|polled|restore"

# 2) 当前镜像头（前 64 字节）
sudo xxd -l 64 /var/vm/sleepimage
```

判读：

| 观测 | 结论 |
|---|---|
| 有 `hibernate_machine_init` / polled IO 相关报错 | 内核确实尝试恢复并失败 ⇒ 死点仍在 NVMe polled 读 |
| 完全没有任何 hibernate 行 | 内核**没尝试**恢复（boot.efi 的 H:IS 1 没传到内核）⇒ 死点在 OC 与内核的传参，`HibernateMode=NVRAM` 是首要嫌疑 |
| 镜像头仍有 `sime` + 合理 imageSize | 镜像完整写出过，病在恢复 |
| 镜像头全零 | 开机即被清零，无法判读（与前几轮一致） |

---

### 3z.28. 内核日志与镜像头取证 —— 两条都不足以定性，但挖出 107 秒闹钟时间线（2026-10-29 20:30）

#### 一、`sudo dmesg | grep -iE "hiber|sleepimage|polled|restore"` → **零输出**

不能直接读成「内核没尝试恢复」，先验证日志是否被编译进发行版内核：

```
strings -a /System/Library/Kernels/kernel | grep -ic hibernate   → 96
```

抽样命中（说明日志代码与格式串都在）：

```
hibernate image path: %s
hibernate handoff @%s:%d
hibernate file open timed out
hibernate file busy
hibernate file close due timeout
hibernate_alloc_pages act %d, inact %d, anon %d, throt %d, spec %d, wire %d, wireinit %d
Hibernate restore error %x @%s:%d      ← 三次 panic 用的就是它
```

⇒ 内核里**有** 96 条休眠日志串，dmesg 却一条都没有。
最合理的解释（**推断**）：内核确实进了 `hibernate_kernel_entrypoint`，恢复失败后
**回退成完整冷启动，冷启动会重建内核日志缓冲区（msgbuf）**，把休眠阶段的记录冲掉。
这与 3z.27 §七 的 68 秒空档互相印证——所以「无 panic + 无日志 + 冷启动 + 68 s 延迟」是同一件事的四个面。

#### 二、`sudo xxd -l 64 /var/vm/sleepimage` → **64 字节全零**

结合 `birth=20:06:59 / mtime=20:19:07`：镜像在**开机后 23 秒被清零**。
⇒ 任何「事后看镜像头 / 看镜像大小」的判据在本机**结构性失效**，不是这次写没写的问题。
（3z.27 §六 的结论再次成立，且现在是直接观测到的。）

#### 三、★★ 新证据：这次 RTC **没有**归零，OC 日志文件名是真实日期

| 日志文件名 | 含义 |
|---|---|
| `opencore-2019-01-01-000032/33/34/47/000558.txt`（5 份） | RTC 归零，POST 报 005 的那几次 |
| **`opencore-2026-10-29-121734.txt`（本次）** | **RTC 正常，时间正确（UTC 12:17:34 = 本地 20:17:34）** |

其余 27 份也是 2026 日期，属正常开关机。⇒ **本次 S4 断电期间 RTC 一直有电、没丢时间**，
说明断电时间很短，与「没报 005」一致。

#### 四、★★ 由此得到一个精确到秒的上电时间线（这是本轮最硬的推断）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 20:15:11 | 入睡 | pmset log |
| 20:15:12 | 排 `*UserWake 107s → 20:16:59`（GaugingMitigationActions） | pmset log |
| ~20:15:4x | 写盘完成、断电（灯灭） | 推断 |
| **20:16:59** | **RTC 闹钟到点** | 排程值 |
| 20:17:34 | boot.efi 起来（闹钟后 +35 s，正好是一次 POST + OC 的耗时） | OC 日志 |
| 20:18:44 | 内核起来（+68 s） | uptime 反推 |

⇒ 机器**不是**「你按电源键从 S4 唤醒」，而是**被 RTC 闹钟从断电状态硬拉起来做了一次完整 POST**。

这能同时解释两件事：
1. RTC 没丢 → 断电只有 ~75 秒，电容/电池撑得住，不会报 005；
2. **完整 POST 会重新初始化 NVMe 控制器**（HP 固件要为引导枚举硬盘），
   于是 `IONVMeControllerPolledAdapter::startIO` 拿到的是一个被固件重置过的控制器状态，
   返回 `kIOReturnError` —— 与三次 panic 的落点完全一致。

#### 五、唯一还没做过、且有判别力的观测：灯灭到灯亮的**实际间隔**

判据：

| 观察 | 结论 |
|---|---|
| 间隔 ≈ 90–230 s（与闹钟 deltaSecs 区间吻合） | 确认是 RTC 闹钟拉起 ⇒ 固件走冷上电而非 S4 resume ⇒ 本机 S4 结构性无解 |
| 间隔 < 30 s 或每次都在固定值附近（与闹钟无关） | 不是闹钟 ⇒ 固件 AC/EC 自动上电，也是冷上电 |
| 灯一直不亮，直到手动按电源键 | **首次真正的 S4 唤醒，可能直接成功** |

配套动作：灯亮起来、登录之后立刻跑
`pmset -g log | grep "Wake Requests" | tail -2`，把这一次排的闹钟 deltaSecs 和实测间隔对账。

---

### 3z.29. ★ RTC 闹钟假设正式证伪 —— 内核早就把它禁掉了（2026-10-29 20:34）

#### 一、`Kernel/Patch` 里唯一一条就是它，且一直启用

`EFI/OC/config.plist` → `Kernel/Patch` 共 **1 条**：

```
Enabled    = true
Comment    = Disable RTC wake scheduling
Identifier = com.apple.driver.AppleRTC
Base       = __ZN8AppleRTC18setupDateTimeAlarmEPK11RTCDateTime
Find       = (空)
Replace    = C3            ← x86 的 ret
Count      = 1  Limit = 0  Skip = 0
MinKernel  = 19.0.0   MaxKernel = (空)   Arch = Any
```

- `Find` 为空 ⇒ OpenCore 直接在 `Base` 符号地址写入 `Replace`。
- `C3` = `ret`，即 `AppleRTC::setupDateTimeAlarm(RTCDateTime const*)` **函数入口立刻返回**。
- ⇒ **内核永远不会把任何唤醒时间写进 RTC 硬件**。`pmset -g sched` 里那些
  `com.apple.alarm.user-invisible-*` 只是 `powerd` 的账面记录，落到硬件那一步被直接跳过。

#### 二、补丁不是死配置：符号存在、kext 已加载

`strings` 在 `.kc` 上取不到（容器格式），改用二进制 grep：

| 文件 | `setupDateTimeAlarm` | `AppleRTC` |
|---|---|---|
| `BootKernelExtensions.kc` | **3 处** | 13 处 |
| `SystemKernelExtensions.kc` | 0 | 0 |

```
kmutil showloaded --list-only | grep AppleRTC
→ 83  0 0xffffff8001c25000 0x5324 0x5324 com.apple.driver.AppleRTC (2.0.1)
```

⇒ 符号在 BootKC 中存在、kext 已加载 ⇒ OC 能解析到 `Base`，补丁会实际写入 `C3`。

#### 三、它从第一版 EFI 就在，从未关闭

```
6cb1b20 2024-10-10 init          ← 首次引入
9ebfa57 2024-11-17 update
496fe15 2025-06-22 修复深度空闲
```

后续若干提交（`f27dc63`/`42895ac`/`25fd013` 等）对该条只有**缩进/序列化差异**，`Enabled` 从未改成 false。

#### 四、⇒ 3z.28 §四 的「107 秒闹钟上电」时间线**作废**

既然从 2024-10 起闹钟就没有被写进硬件，那么**每一次"灯灭后自己亮"都发生在闹钟被禁的条件下**。
RTC 闹钟这条线彻底排除，连同 3z.28 §四 的拟合一起撤回。

#### 五、时间线需要重算：断电视作「瞬间」

若 16 GB 镜像的同步 polled 写入耗时约 2 分钟（DRAM-less SN570，写入速率未知），
则真正的断电时刻在 **20:17:3x**，而 boot.efi 是 20:17:34 ⇒ **断电后几秒就自亮**。

这个版本同时解释了另外两件事：
1. 与你最早的描述「电源指示灯黑了之后马上又亮」一致；
2. 本次 RTC 没有归零、没报 005 —— 因为只断了十几秒，电容/电池撑得住。

#### 六、剩余唯一可能：固件 / EC 层

软件侧（macOS 排程、OpenCore、ACPI `_PRW`、USB/键盘/网络唤醒）已全部排除，
剩下的只能发生在「主电源轨被切断再重建」的那一瞬间，属 HP 固件/EC 行为。

**待查（BIOS F10 → Advanced → Power Management Options）**：

| 选项 | 为什么要看 |
|---|---|
| `Power On When AC Detected` / `AC Recovery` | AC 瞬间跌落再恢复会被当成"插电"而自动开机 |
| `Wake On LAN`（含 S4/S5 WOL） | 固件级 WOL 独立于 macOS 的 `womp` |
| `Power On from Keyboard Ports` | 合盖压键可触发 |
| `Scheduled Power-On` / `BIOS Power-On` | 固件自带定时开机 |

#### 七、唯一还缺的观测：灯灭 → 灯亮的**实际间隔**

| 实测间隔 | 结论 |
|---|---|
| **几秒（< 10 s）** | 断电动作本身触发回电 ⇒ 固件/EC，对应上表第一项 |
| **约 90–230 s 且每次不同** | 存在非 macOS 的定时唤醒源 ⇒ 固件定时开机 / 外设 |
| 基本固定值（如整分钟） | 固件 `Scheduled Power-On` |

配套：灯亮登录后立刻 `pmset -g log | grep "Wake Requests" | tail -2`，
但注意——由于本补丁，这些账面排程**不代表硬件真的被写过**，只能作为参考。

---

### 3z.30. S4 攻关暂停，回退 deepidle（2026-10-29 20:47）

#### 一、决策

用户决定：「算了，先 deepidle 吧」。S4 深休眠这条线暂停，运行环境回到**内存睡眠（deepidle）**。
理由汇总（前 29 节的收敛结果）：

| 层 | 状态 | 依据 |
|---|---|---|
| macOS 排程唤醒（RTC 闹钟） | **已禁用** | `Kernel/Patch` 把 `AppleRTC::setupDateTimeAlarm` 打成 `C3`(ret)，自 2024-10-10 起从未关闭（§3z.29） |
| 电源键 / USB / 键盘 / 网络唤醒 | **全部排除** | deepidle 对照 6/6 全为 `PWRB`，自发唤醒 0 次 |
| ACPI `_PRW`（53 处可 S4 唤醒） | **不触发** | 同上 |
| OC 配置 | **无相关开关** | `HibernateMode` 已试 Auto/NVRAM，boot-args 已清理（D7） |
| 恢复路径 | **NVMe polled 读失败** | `IONVMeControllerPolledAdapter::startIO` → `kIOReturnError`，三次 panic 同源 |
| 剩余可能 | **固件 / EC 断电-上电** | 需 BIOS F10 与 Windows 对照，非用户侧软件可改 |

⇒ 继续投入的边际收益已很低，先把日常使用恢复到稳定状态。

#### 二、改动前后对照（AC 与 Battery 两侧同步）

| 项 | 改前 | 改后 | 作用 |
|---|---|---|---|
| `hibernatemode` | **25** | **0** | 25 = 写盘后断电（每次重跑失败循环）；0 = 纯内存睡眠，不写镜像、不断电 |
| `standby` | **1** | **0** | 禁止转入 standby（standby 才会切断内存供电） |
| `standbydelayhigh` / `low` | **1 / 1** | **86400 / 3600** | 双保险：即使 `standby` 被系统改回 1，也不会 1 秒就断电 |
| `powernap` | **1** | **0** | Power Nap 会排小时级维护唤醒，一并关掉 |
| `autopoweroff` | 0（未列出） | **0** | 保持一致，未变 |
| `womp` / `proximitywake` | 0 / 0 | 0 / 0 | 未变 |
| 已排程唤醒 | 5 条 | **0 条** | `pmset schedule cancelall` |

执行命令（`shell` 层 `sudo` 被禁，改用系统授权弹窗执行，rc=0）：

```bash
pmset -a hibernatemode 0 standby 0 autopoweroff 0 powernap 0 \
        standbydelayhigh 86400 standbydelaylow 3600
pmset schedule cancelall
```

#### 三、执行后实测（`pmset -g`，20:47）

```
standby              0
womp                 0
powernap             0
hibernatemode        0
standbydelayhigh     86400
standbydelaylow      3600
sleep                1 (sleep prevented by Electron)
displaysleep         15
```

`pmset -g sched` → **空**（5 条 `UserWake` 全部清除）。
`pmset -g custom` 的 AC 与 Battery 两段均为上述值。

#### 四、未做的事项（有意保留）

| 项 | 为什么不回滚 |
|---|---|
| D7 删掉的 `-hbfxdbg -hbfxforce hfile=` | 三者对 deepidle 无影响；`-hbfxforce` 本身不是 HibernationFixup 参数（§3z.24 §四），留着才是隐患 |
| `Misc/Boot/HibernateMode=NVRAM` | `hibernatemode 0` 下内核不写镜像，NVRAM 里也没有 `boot-image*` 变量 ⇒ 不会误判为休眠恢复 |
| `rtcfx_exclude=0E-57,5A-7F` | 排除区已避开 0x80–0xAB 的 `IOHibernateRTCVariables`，deepidle 下不参与 |
| `EFI/scripts/s4-arm.sh` | 脚本内**不含任何 `pmset` 调用**，只做体检与 config 改写；且无 LaunchAgent/Daemon 自动执行 |
| `/var/vm/sleepimage`（1 GiB） | `hibernatemode 0` 下永不写入；保留不占额外 I/O。若要回收这 1 GiB，`sudo rm -f /var/vm/sleepimage` 安全，系统会按需重建 |

#### 五、deepidle 模式的已知特性与代价

| 项 | 说明 |
|---|---|
| 掉电率基线 | 5.5–5.6 %/h ≈ 3.7–3.8 W（未用功率计校准，±30%）；常态 DarkWake 0、WakeTime ≈2.4 s |
| 唤醒方式 | 只能靠电源键 / 开盖（`womp`、`proximitywake`、`powernap` 均 0） |
| **数据风险** | `hibernatemode 0` **没有磁盘镜像兜底**：电池耗尽时未保存的内容会丢失。长时间不用应关机或接电源 |
| 与原默认的差异 | macOS 笔记本出厂默认 `hibernatemode 3`（safe sleep，写盘 + 保电）。本机因 S4 恢复路径损坏，写盘只会白耗 I/O，故选 0 |

#### 六、若日后要继续攻 S4，恢复武装的完整步骤

```bash
# 1) 恢复 S4 电源策略
pmset -a hibernatemode 25 standby 1 standbydelayhigh 1 standbydelaylow 1

# 2) 重启后确认 OC 侧状态
nvram boot-args
# 3) 触发一次
pmset sleepnow
```

判据仍为：OC 日志 `H:IS`、是否新增 panic、`last` 是否有新 console 登录。
**当前 S4 的死点已定位到「固件断电-上电后 NVMe 控制器被重置」，属固件/EC 行为，用户侧软件不可改。**

---

### 3z.31. ★ 关键前提补录：Windows 侧休眠（S4）正常 —— 定性修正（2026-10-30 11:00）

#### 一、事实

用户指出「**Windows 休眠正常**」这条信息此前已经说过多次。
**核查结果：`grep -rn "Windows.*休眠" .workbuddy/memory/ docs/` 全库零命中** ⇒ 确实是漏记，
只在对话里出现过，未被落盘。此为记录缺陷，本节补录并据此修正 §3z.30 的定性。

#### 二、它与 macOS 侧失败并不矛盾（两者恢复机制不同）

| 环节 | Windows（S4 正常） | macOS（本机失败） |
|---|---|---|
| 镜像位置 | `C:\hiberfil.sys`（NTFS） | `/var/vm/sleepimage`（APFS 根卷，`man pmset` 强制） |
| 上电后 | 完整固件 POST → `bootmgr` 读 hiberfil | 完整固件 POST → `boot.efi` 读镜像头 → 跳入内核 |
| 谁读镜像 | **完整存储驱动栈**（`stornvme.sys` 重新 probe 控制器） | **`IONVMeControllerPolledAdapter`**，在加载任何 kext **之前**裸操作 BAR |
| 对控制器状态的假设 | 无假设，任何状态都能重新初始化 | 假设控制器可被 polled 路径直接接管 |
| 结果 | 成功 | `startIO` → `kIOReturnError`（`IOHibernateIO.cpp:2921`） |

⇒ **Windows 正常证明的是「硬件与固件能完成 S4 断电-上电-恢复循环」，不能推出「macOS 也该成功」**，
因为 macOS 走的是**驱动加载之前的 polled 裸读**那条路，Windows 完全不经过它。

#### 三、对 §3z.30「固件/EC 行为，用户侧软件不可改」的措辞修正

原表述过强。更准确的说法：

> 硬件层面 S4 可用（Windows 已验证）；macOS 的失败源于**其 polled NVMe 恢复路径与本机固件在
> `EXITBS` 交接时留下的控制器状态不兼容**。这是 macOS 侧实现与本机固件的组合问题，
> 不是硬件缺陷，也不是 EC 策略问题。

责任归属变了（从「固件坏」改为「组合不兼容」），但**可动的旋钮没有增加**，见下节。

#### 四、剩余变量复核：已无可用项

| 候选 | 结论 |
|---|---|
| 加载 OC 的 `NvmExpressDxe.efi` 接管控制器 | **排除**。本机 `UEFI/Drivers` 只有 8 个非 NVMe 驱动（HfsPlus/OpenRuntime/OpenCanopy/ToggleSipEntry/FirmwareSettingsEntry/ResetNvramEntry/ext4_x64/OpenLinuxBoot），**完全没有 NVMe 驱动**，全程用固件原生驱动。社区共识：已在固件原生支持 NVMe 的平台上强行加载 `NvmExpressDxe` 会导致启动延迟、内存分配冲突，甚至卡在选单。**风险 > 收益** |
| `MemoryAllocation.efi` | 不适用（官方明确「要用 hibernation 就不要用它」），本机也未加载 |
| `hbfx-patch-pci=` / `-hbfx-disable-patch-pci` | **排除**。README 原文：该 patch 的作用是「resume 后不调用 `restoreMachineState` 以避免 hang & black screen」，属 `IOPCIFamily` 阶段；本机死点在更早的 `hibernate_machine_init` readahead，**不在其作用域内** |
| `HibernateMode` | 当前 `NVRAM`（`git log -S` 显示自 2024-10-10 init 起从未改过值）。它只决定密钥存放位置，不影响 polled 读盘 |
| 换 NVMe / 换 SATA | 唯一剩下能改物理变量的路。但 Dell 两个成功案例用的都是 **DRAM-less + HMB** 的盘（Crucial P3 / WD SN770），与本机 SN570 同类 ⇒ **盘型不是决定因素**，换盘更像买彩票 |
| 等 macOS 更新 | 被动，无法预期 |

#### 五、结论（本节定稿）

**S4 在本机维持「暂停」判定。** 与 3z.30 的差别只在措辞：不是「固件坏了」，而是
「macOS 的 polled 恢复路径与本机固件的交接状态不兼容」，两者都不存在用户侧可调开关。
「Windows 休眠正常」是一条**有价值的前提事实**（它砍掉了「硬件不支持」这个分支），
但**不构成「再试一次就会成功」的依据**。

---

### 3z.32. 遗漏审查：查出 1 条未验证配置、1 处理解错误、2 条未解释观测（2026-10-30 11:05）

本节是对 §3z.31 结论的自查——「还有没有漏掉的考虑」。结论：**没有新的可用旋钮，但有几处此前未交代清楚，其中一处是我的理解错误。**

#### 一、★ 排除两项此前从未查过的前提（本轮新增）

| 前提 | 实测 | 结论 |
|---|---|---|
| **磁盘加密**（FileVault 若开，polled 裸读读到密文必失败） | `fdesetup status` → **FileVault is Off**；`diskutil info` 对 disk1s1/s4/s6 全部 `Encrypted: No` / `FileVault: No` | **排除** |
| **根卷空间不足**（8 GiB 镜像无法分配） | `df -h /var/vm` → 190 GiB 可用；APFS 容器 `Capacity Not Allocated: 204.2 GB` | **排除** |

顺带确认：`vm.swapusage: total = 0.00M`（swap 未启用），`/System/Volumes/VM/kernelcore` 仅 1 MiB
（mtime `2019-01-01 08:01`，即上次 panic 时留下的 core，太小、无回溯价值）。
macOS 26 新增独立 `disk1s6 (VM)` 卷且已挂载在 `/System/Volumes/VM`，但 `sleepimage` 仍在
`/var/vm`（Data 卷 firmlink）——**与 `man pmset` 的「镜像只能在根卷」不冲突，且 boot.efi 已能读到
`H:SIG=sime`，说明路径与卷映射都不是障碍**。

#### 二、★ 我的理解错误：`hbfx-ahbm` 不是 Host Memory Buffer

上一轮我曾把 `hbfx-ahbm` 联想成本机 SN570 的 HMB（DRAM-less 主控用主机内存做缓存），**这是错的**。
HibernationFixup README 原文：`hbfx-ahbm` 是 **Auto Hibernate 的位掩码**，与 HBM 无关：

```
1=EnableAutoHibernation   2=WhenLidIsClosed   4=WhenExternalPowerIsDisconnected
8=WhenBatteryIsNotCharging   16=WarnLevel   32=CriticalLevel
64=DoNotOverrideWakeUpTime   128=DisableStimulusDarkWakeActivityTickle
256/512/1024/2048=剩余电量百分比位
```

其中只有两位与本问题沾边：
- `64 = DoNotOverrideWakeUpTime`：不修改下次唤醒时间。若 kext 默认**会**改，可能引入额外唤醒。
- `128 = DisableStimulusDarkWakeActivityTickle`：禁止 dark wake→full wake 的刺激事件。

但 deepidle 对照已实测 6/6 唤醒全为 `PWRB`、自发唤醒 0 次（§3z.22/§3z.30），
**没有任何需要靠这两位去抑制的唤醒**，故不采用。**HMB 这条线本来就该忽略**——Dell 两个成功案例
（Crucial P3 / WD SN770）同为 DRAM-less + HMB，已证明盘型不是决定因素（§3z.31 §四）。

#### 三、★ 未解释观测之一：`Hibernate File Min` 从 1 GiB 变成 8 GiB

| 时刻 | `Hibernate File Min` | `Hibernate Mode` | `sleepimage` 实际大小 |
|---|---|---|---|
| 2026-10-29 19:5x（§3z.24 记录） | **1 073 741 824（1 GiB）** | 25 | 1 GiB |
| 2026-10-30 11:05（本轮实测） | **8 589 934 592（8 GiB = 内存 50%）** | **0** | 1 GiB |

中间唯一改动是 `pmset -a hibernatemode 0`。
⇒ `Hibernate File Min` **依赖 `hibernatemode` 而非常量**：mode 25 报 1 GiB、mode 0 报 8 GiB。
这与 §3z.26 反汇编里那个 `movl $0x40000000`(1 GiB) 常量能够对上——它只在 mode 25 路径上作为参数出现。

**这条观测的含义（谨慎表述，未证）**：昨天「1 GiB 太小写不下 16 GB」的假说（§3z.24 §三）
虽被 §3z.26 削弱，但现在有了第三种可能——**1 GiB 这个值本身就只存在于 mode 25 路径**，
它到底是「文件分配上限」还是「别的参数」，反汇编尚未给出完整符号名。
⇒ 若要再查，方向应是 `IOPolledFileOpen` 的参数序号与 `imageSize` 的关系，而非看文件长度。

#### 四、★ 未解释观测之二：EXITBS→内核的 68 秒，两种解释从未区分

§3z.27 §七 只给了「polled 读反复超时」一种解释，但另有同样自洽的一种：

```
16 GiB ÷ 68 s ≈ 240 MB/s
```

**这个速率正好落在 DRAM-less SN570 的 polled 单队列恢复区间**。
⇒ 68 秒也可能是「真的在读盘、且读完了」，失败发生在读盘之后的页表重建/校验和比对。

两种解释的修法完全不同（前者修 NVMe 交接，后者修内存映射），**而本轮没有任何新证据能区分**。
唯一的区分手段是内核日志里的 `PMStats: Hibernate read took %qd ms`（字符串已确认存在于内核），
但冷启动会重建 msgbuf 把它冲掉（§3z.28 §一）。
⇒ **本条维持「未知」，不再作为推理依据。**

#### 五、★ 唯一一条还没做过单变量验证的配置

`UEFI/ReservedMemory` 只有 1 条，且**注释与病灶不对症**：

```
Address = 569344 (0x8B000)   Size = 4096   Type = RuntimeCode   Enabled = true
Comment = "Fix hibernate mode 25 black screen on wake (low S3/S4 area)"
```

三个问题：
1. 它是为解决**唤醒黑屏**抄来的偏方，而本机症状是 `polled read → kIOReturnError`，不是黑屏；
2. 它在 **0x8B000 低内存区**把 4 KiB 标成 `RuntimeCode`，而 `hibernate_machine_init` 的 RT scratch
   正在这一带——**理论上可能改变 polled 路径的内存布局**；
3. 自加入以来**从未关闭过做对照**（`git log -S` 可查）。

⇒ 若还要再试一次，**这是唯一一个「配置层、可回滚、单变量」的候选**，优先级高于电池对照。

#### 六、其余散点（价值低，登记备查）

| 项 | 状态 |
|---|---|
| OC 日志字段 `#[EB\|H:HBOPT] 0 1 1 0` / `#[EB\|H:DLW] 0` | 语义**从未查证**，未作为判据使用 |
| OC 在 `ExitBootServices` 时是否 `DisconnectController` 停掉固件 NVMe 驱动 | 未查。此前把「控制器被重置」全归给固件 POST，**未排除 OC 自身参与** |
| 电池供电下试 S4 | 从未做过（此前全在 AC 下），上轮估计成功率 15% |
| `hbfx-patch-pci` | 作用域在 `IOPCIFamily` 的 `restoreMachineState`，晚于本机死点（§3z.31 §四），确认无效 |

#### 七、本节结论

- **没有新的可用旋钮**，§3z.31 的「暂停」判定不变。
- 但有三处此前没交代：① 文件系统侧两个前提（加密/空间）本轮才第一次排除；
  ② `hbfx-ahbm` 我曾误解为 HBM，已更正；③ `Hibernate File Min` 随 `hibernatemode` 变化这条观测此前完全没提。
- 若将来还要动手，**唯一值得做的单变量是关掉 `UEFI/ReservedMemory` 那条 0x8B000**
  （配置层、可回滚、从未验证），而不是电池对照——后者的判别力被「Windows 休眠正常」这条事实削弱了。

#### 八、★★ 追加：我的一处推理漏洞（§3z.31 §四 表格最后一行）

§3z.31 里我写「`setup_var PchSetup 0x16` 是 Dell 三家共同点，但那是解 RTC Memory Lock（保密钥）；
你这边 `H:SIG=sime` 说明密钥早就通了，不相干」——**这句话推理不成立**。

- `H:SIG = 0x73696D65`(`sime`) 是 **镜像文件头里的签名**，boot.efi 从 `sleepimage` 文件本身读出；
- `IOHibernateRTCVariables` 是 **RTC 变量**（内核写注册表 → HibernationFixup 同步到 NVRAM）；
- 两者**完全无关**。用 `H:SIG` 有效去论证「RTC 通道正常」，是偷换概念。

⇒ **「RTC Memory Lock / `setup_var PchSetup 0x16`」这条不能凭上述理由排除，应维持「未验证」。**
本机 PchSetup 中该位的偏移与 Dell 的 `0x16` 不同，需从 HP BIOS IFR 提取，且需 UEFI Shell，
非零成本、有变砖风险（写错变量），故**不作为首选**。

#### 九、★★ 追加：一个从未试过的官方取证参数 `-hbfx-dump-nvram`

HibernationFixup README 原文：
> `-hbfx-dump-nvram` saves NVRAM to a file nvram.plist **before hibernation** and after kernel panic.

它的价值在当前所有手段里是**唯一**的：

| 特性 | 意义 |
|---|---|
| 在**休眠前**写盘 | 文件的 mtime 就是入睡时刻，能证明"写镜像/写元数据"走到了哪一步 |
| 写到**磁盘文件** `/nvram.plist` | S4 断电后仍在，不像 dmesg 会被冷启动冲掉（§3z.28 §一） |
| 内容是**完整 NVRAM** | 可直接回答「`boot-image-key` / `boot-signature` / `boot-image` 到底有没有被写进去」这个悬了两天的核心问题 |

⇒ 此前一直靠「开机后 `nvram -p` 反推」，而开机后这些变量可能已被清理。
**`-hbfx-dump-nvram` 是唯一能拿到「睡前快照」的手段，却从未试过——这是本次自查中最实质的遗漏。**

#### 十、修正后的「若再试一次」优先级

| 优先级 | 动作 | 层 | 成本 | 判别力 |
|---|---|---|---|---|
| **1** | 加 `-hbfx-dump-nvram`，睡一次，读 `/nvram.plist` | kext 取证 | 一条 boot-arg + 重启 | **最高**：直接看睡前 NVRAM 有没有三个休眠变量 |
| 2 | 掐表：`pmset sleepnow` 后记录灯灭→灯亮秒数 | 观测 | 零 | 高：区分「真 S4 断电」与「瞬断回电」 |
| 3 | 关掉 `UEFI/ReservedMemory` 0x8B000 | 配置单变量 | 改 config + 重启 | 中低 |
| 4 | 电池供电下试 S4 | 供电方式 | 一次失败重启 | 低（Windows 正常已削弱判别力） |
| 5 | UEFI Shell 查 `PchSetup` RTC Memory Lock 偏移 | 固件变量 | 需 IFR 提取，有写错风险 | 未知 |

---

### 3z.33. 「模棱两可」专项清算：坐实 3 处、仍存 6 处、更正 1 处说过头的话（2026-10-30 11:10）

用户追问「没有模棱两可的点了？」。本节把全部结论按证据强度重排，不自留余地。

#### 一、★ 本轮新坐实的三件事（均为本机二进制实测）

**① `IOPolledFileOpen` 的完整签名 —— 第 5 参数确定是 `unsigned long long` 类型的大小**

mangled：`__Z16IOPolledFileOpenPKcjyyyPvmPP18IOPolledFileIOVarsPP6OSDataPhPm`
解出：

```
IOPolledFileOpen(char const*, unsigned int, unsigned long long, unsigned long long,
                 unsigned long long, void*, unsigned long,
                 IOPolledFileIOVars**, OSData**, unsigned char*, unsigned long*)
```

按 SysV ABI：`rdi`=path / `rsi`=uint / `rdx`=`u64` / `rcx`=`u64` / **`r8`=`u64`（就是那个 `0x40000000`）**。
⇒ 它是**尺寸类参数**，不是标志位、不是指针。**但名字仍未知**（见 §二.1）。

**② 2921 确认是「第一处」`IOPolledFileRead` 的错误分支**

全函数只有 4 处 `IOPolledFileRead`（`094dcab` / `094dd59` / `094dde3` / `094de26`），
panic 块被编译器集中在函数尾部。用跳转目标反查：

```
ffffff800099dca6:  xorl %edx, %edx          ← len = 0
ffffff800099dca8:  movq %r15, %rcx
ffffff800099dcab:  callq _IOPolledFileRead
ffffff800099dcb0:  testl %eax, %eax
ffffff800099dcb2:  jne   0xffffff800099e68f  ← 只此一处跳到 2921 的 panic 块
```

`0xffffff800099e68f` 正是 `movl $0xb69(2921), %ecx` 那条 panic 的入口。
⇒ **「死在第一处 readahead」这个定位成立，无误。**

**③ `IOPolledFileRead` 没有 `len == 0` 的早退 ⇒ 那次调用真的碰了硬件**

入口处 `movq %rdx,%rbx` 存下 len 后 **`jmp` 直接进主循环**（`0xffffff80009e23b3`），
主循环用 `0x30(%r15)`(readEnd) 与 `0x44(%r15)`(readOffset) 算读取量，全程不看 `%rbx`。
⇒ 「`Read(NULL, 0)` 是空操作、失败只是参数检查」这个替代解释**被排除**。
`hibernate_machine_init` 里那两行 `movl 0x30(%rax),%ecx; movl %ecx,0x44(%rax)` 是把 readOffset 复位到 readEnd，
所以这次调用实际读的是 `imageSize - image1Size` 那一段。**I/O 是真的发生了。**

#### 二、★ 仍然模棱两可的六处（如实列出）

| # | 模糊点 | 为什么模糊 | 影响 |
|---|---|---|---|
| **1** | 那个 **1 GiB 参数的名字/语义** | 只解到类型 `u64`，名字未知。XNU 源码三通道全被墙（`gh-proxy`/`ghfast`/直连 raw 一律返回 **14 字节**错误页） | **决定「尺寸假说」生死** |
| **2** | panic 里 `Uptime 788.6s / Sleep 766.6s` 差 **22 s** 的含义 | 我按「入睡时刻→写入 uptime」解释成「写镜像耗时 22 s」，但这是推断。22 s 对应 1 GiB(46 MB/s) 或 8 GiB(372 MB/s) **都算合理** | 同上，定量 |
| **3** | `Hibernate File Min` 随模式变（mode25→1 GiB，mode0→8 GiB）**公式不明** | 今天首次发现，无解释 | 与 #1 同源 |
| **4** | EXITBS→内核的 **68 s** | 「polled 超时」与「真在读盘 240 MB/s」两种解释未区分 | 决定修 NVMe 还是修内存映射 |
| **5** | OC 在 `ExitBootServices` 时是否 `DisconnectController` 停掉固件 NVMe 驱动 | **从未查**。此前把「控制器被重置」全归给固件 POST | 可能整条归因错 |
| **6** | OC 日志 `H:HBOPT 0 1 1 0` / `H:DLW 0` 的字段语义 | 从未查证 | 低 |

#### 三、★ 更正：§3z.26 说「尺寸假说降级为未成立」—— 说过头了

§3z.26 的原文推理是：反汇编看到 `r15`（按内存页算出）作为 `file_length` 传入 ⇒
「1 GiB 只是另一个参数」⇒ 尺寸假说不成立。

**这个推断有漏洞**：我只证明了 `r15` 落在第 4 个参数位，**没有证明第 5 个参数（1 GiB）不是上限类约束**。
若它的语义是 `maxLength` / `minSize` 一类，那么「`file_length` 按内存算出、而 `maxLength` 只有 1 GiB」
**本身就是矛盾参数**，写镜像照样会失败。

⇒ 正确表述应为：**§3z.24 的「1 GiB 太小 ⇒ 写不下 ⇒ 不写元数据」假说，状态从「未成立」回退为「未定」。**
它既未被证实，也**未被证伪**——证伪需要知道第 5 参数的名字。

#### 四、★ 这六个模糊点收敛到同一个盲区

#1 / #2 / #3 全都指向同一件事：**「写镜像阶段实际发生了什么」，至今没有任何直接观测。**
现有全部证据（H:IS / H:SIG / panic 栈 / dmesg）都发生在**写完之后**。

⇒ 唯一的直接观测手段仍是 `-hbfx-dump-nvram`（§3z.32 §九），它在**睡前**落盘完整 NVRAM。
若 dump 出的 `nvram.plist` 里带镜像尺寸/密钥变量，则 #1~#3 可一次性收敛。

#### 五、本节结论

- **模棱两可的点有 6 处，不是 0 处。** 其中 #1（1 GiB 参数语义）最关键，直接决定尺寸假说的生死。
- 本轮坐实 3 处，其中第 3 处（`IOPolledFileRead` 无 len==0 早退）**把「零长度调用自己报错」这条退路堵死了**，
  等于确认「I/O 真的执行并失败了」。
- **更正 §3z.26**：尺寸假说从「未成立」回退为「未定」，因为第 5 参数的名字没解开，不能凭参数位置就排除它。
