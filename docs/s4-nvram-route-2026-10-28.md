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
