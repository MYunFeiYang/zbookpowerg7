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
| `Misc/Boot/HibernateMode` | `Auto` | RTC 优先、NVRAM 兜底 |
| `Misc/Boot/HibernateSkipsPicker` | `true` | 恢复时跳过选择器 |
| `boot-args` | `rtcfx_exclude=0E-FF … -hbfxdbg -hbfxforce` | 全封 RTC + 强制 NVRAM + 日志 |
| `rtc-blacklist` | `242 B`（`0x0E–0xFF`） | 全封，含 `0x80–0xAB` |
| `Kernel/Quirks/PowerTimeoutKernelPanic` | `false` | 超时不 panic，免污染判读 |
| `Misc/Security/AllowNvramReset` | `true` | Reset NVRAM 逃生口 |

相对上一版（RTC 路线）的实质变化：`rtcfx_exclude` 与 `rtc-blacklist` **从「留出 80–AB」改回「全封」**。

## 五、验证与判读

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

一次睡眠后三选一：

| 结果 | 含义 | 下一步 |
|---|---|---|
| **v1** `nvram` 出现 `IOHibernateRTCVariables` 且能恢复 | NVRAM 路线成立 | 转日常配置，`-hbfxdbg` 可移除 |
| **v2** 变量出现但醒不来 | 卡在 boot.efi 恢复 | 查镜像完整性 / 是否走了加密（`hibernatemode 25` 带加密） |
| **v3** 变量始终不出现 | macOS 26 没往 PMRootDomain 放密钥 | 看 HBFX 日志是否打 `PMRootDomain key MISSING`；是则需改 kext 取数方式 |

v3 的日志判据（`-hbfxdbg` 开着）：

```
HBFX: NVStorage path entered (forceNvram=1), PMRootDomain key present
HBFX: kIOHibernateRTCVariables is 44 bytes
```

若第二行字节数不是 44，说明结构变了；若是 `MISSING`，说明前提不成立。

## 六、回滚

| 层级 | 动作 |
|---|---|
| 只关 fork 逻辑 | boot-args 去掉 `-hbfxforce`（kext 留着无害，此时行为等于上游） |
| 回上游 kext | `cp -R docs/backups/hbfx-fork-20261028-1630/HibernationFixup.kext.upstream EFI/OC/Kexts/` |
| 回整个配置 | `cp docs/backups/hbfx-fork-20261028-1630/config.plist.before EFI/OC/config.plist` |

不改固件、不写 RTC ⇒ 无不可逆风险。最坏情况是「睡下去醒不来，需长按电源键」，
NVRAM 里的 `IOHibernateRTCVariables` 可用 OpenCore 的 Reset NVRAM 清掉。
