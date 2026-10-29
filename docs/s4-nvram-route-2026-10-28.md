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
