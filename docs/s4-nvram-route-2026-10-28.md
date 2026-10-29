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
