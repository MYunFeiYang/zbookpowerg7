# S4 真休眠：机制与配置依据（2026-10-28）

> 本文只回答一个问题：**macOS 休眠在这台机器上依赖哪几个环节，每个环节由哪个配置项负责，依据出处是什么。**
> 结论均标注来源等级：**源码** > **官方文档** > **社区实践**。社区实践只用来提示"有哪些变量"，不用来定结论。

## 一、休眠的完整机制

### 1.1 数据流

```
入睡                                    唤醒
────────────────────────────────────────────────────────────
kernel 把整份内存镜像加密写入 sleepimage
        │
        ├─ 生成 16 B AES 密钥 + 20 B 签名
        └─ 打包成 AppleRTCHibernateVars（44 B，含 "AAPL" 标记）
                │
                ├─→ RTC 0x80–0xAB（44 字节，原生路径）
                └─→ NVRAM IOHibernateRTCVariables（HibernationFixup 补充路径）
                                    │
                                    ↓
                        boot.efi 需要拿回这 44 字节
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
              拿得到 → 解密 sleepimage          拿不到 → 按冷启动处理
              还原内存、回到原会话                 会话丢失
```

### 1.2 44 字节结构（源码）

`OpenCorePkg/Include/Apple/IndustryStandard/AppleHibernate.h`：

```c
typedef struct {
  UINT8  signature[4];       // "AAPL"
  UINT32 revision;
  UINT8  booterSignature[20];
  UINT8  wiredCryptKey[16];  // AES-128
} AppleRTCHibernateVars;     // sizeof = 44
```

44 字节 = `0xAB - 0x80 + 1`，与 RTCMemoryFixup README 的描述
"Offsets from 0x80 to 0xAB are used to store some hibernation information (`IOHibernateRTCVariables`)"
完全对应。

### 1.3 黑苹果的落点只有两个

| 落点 | 谁写 | 谁读 |
|---|---|---|
| RTC `0x80–0xAB` | macOS 的 AppleRTC（原生） | OpenCore 的 RTC 分支 |
| NVRAM `IOHibernateRTCVariables` | HibernationFixup（有条件，见 §2.2） | OpenCore 的 NVRAM 分支 |

真 Mac 还有 SMC 这条路，黑苹果的 SMC 是 VirtualSMC 模拟的，不承担这个职责。

NVRAM 变量的 GUID = `gAppleBootVariableGuid` = `7C436110-AB2A-4BBB-A880-FE41995C9F82`，
即配置里 `SystemAudioVolume` / `boot-args` 所在的同一个域。HibernationFixup 通过
`IODeviceTree:/options` 的裸变量名读写，与 OC 侧按 GUID 读取**指向同一存储**。

## 二、OpenCore 侧如何取回（源码）

`OpenCorePkg/Library/OcBootManagementLib/AppleHibernate.c` 的 `OcActivateHibernateWake`。
模式位定义在 `Include/Acidanthera/Library/OcBootManagementLib.h:1168`：

```c
#define HIBERNATE_MODE_NONE   0U
#define HIBERNATE_MODE_RTC    1U
#define HIBERNATE_MODE_NVRAM  2U      // Auto = RTC | NVRAM = 3
```

关键分支：

```c
if (HibernateMask & HIBERNATE_MODE_RTC) {
    for (Index = 0; Index < sizeof (AppleRTCHibernateVars); Index++)
        RtcRawVars[Index] = OcRtcRead (Index + 128);          // 偏移 128 = 0x80
    HasHibernateInfoInRTC = RtcVars.signature == "AAPL";
    HasHibernateInfo      = HasHibernateInfoInRTC;
}

if (HibernateMask & HIBERNATE_MODE_NVRAM) {
    GetVariable2 (L"IOHibernateRTCVariables", &gAppleBootVariableGuid, ...);
    if (!HasHibernateInfo && !EFI_ERROR (Status) && Size == sizeof (RtcVars)) {
        CopyMem (RtcRawVars, Value, sizeof (RtcVars));         // 仅在 RTC 没拿到时使用
    }
    ... SetVariable (..., 0, NULL);                            // 取完立即擦除（一次性）
}

if (HasHibernateInfo) {
    SetVariable (L"boot-image-key", ... RtcVars.wiredCryptKey);
    SetVariable (L"boot-signature", ... RtcVars.booterSignature);
}
```

三条要点：

1. **RTC 优先，NVRAM 只是兜底**（`if (!HasHibernateInfo && ...)`）。
2. 只有 `HibernateMask` 含 RTC（`1`）时才会去读 RTC；配成 `NVRAM`（`2`）就完全跳过 RTC。
3. 真正交给 boot.efi 的是 `boot-image-key` 与 `boot-signature` 两条变量；
   `OcIsAppleHibernateWake` 也只以它们是否可读作为"这是休眠唤醒"的判据。

## 三、HibernationFixup 在本机不工作的原因（源码）

`HibernationFixup-1.5.4/HibernationFixup/kern_hbfx.cpp:91`：

```cpp
if (result == KERN_SUCCESS || ioHibernateState == kIOHibernateStateHibernating) {
    if (!callbackHBFX->checkRTCExtendedMemory()) {     // ← 关键门控
        ... 把 IOHibernateRTCVariables 写入 NVRAM ...
    }
}
```

`checkRTCExtendedMemory()` 最终落到 `Lilu/Sources/kern_rtc.cpp:44`：

```cpp
bool RTCStorage::checkExtendedMemory() {
    uint8_t off = 0xB4;   /* APPLERTC_POWER_BYTE_PM_ADDR */
    uint8_t dst = 0;
    return read(off, 1, &dst);      // 只要能把 RTC 0xB4 读出来，就认为 RTC 有扩展内存
}
```

**判定逻辑是"RTC 够用就不写 NVRAM"。**

本机 RTC 是完整 256 字节（`0x00–0xFF`）：09-16 把那一段封死确实生效，且能把 CMOS 写坏 ⇒ `0x80–0xFF` 真实存在。
因此 `checkRTCExtendedMemory()` 返回 `true`，**HibernationFixup 整段跳过，一个字节都不写**。

这解释了 09-16 失败后 `nvram -p` 里查无任何休眠变量：**不是"来不及生效"，是主动不写。**

## 四、本机可行的链路：三个环节，缺一不可

| 环节 | 要求 | 负责的配置 | 违反的后果 |
|---|---|---|---|
| ① 44 B 落进 RTC | `0x80–0xAB` 可写 | `rtcfx_exclude` / `rtc-blacklist` 不得覆盖该区间 | macOS 写了也进不去，OC 读不到 `AAPL` |
| ② OC 去查 RTC | mask 含 RTC | `Misc/Boot/HibernateMode` = `Auto` 或 `RTC` | 配 `NVRAM` 时 RTC 分支根本不执行 |
| ③ 交给 boot.efi | `boot-image-key` / `boot-signature` | OC 自动完成，无需配置 | — |

### 09-16 / 09-21 两轮的失败原因

当时 `HibernateMode=NVRAM`（09:03，`2f5c047`）与 HibernationFixup 1.5.4（10:42，`85888f6`）都已就位，
但：

- ② 违反：`NVRAM` 模式不读 RTC；
- ① 违反：`rtcfx_exclude=80-FF` / `0E-FF` 把 RTC 休眠区封死。

两个来源同时为空 ⇒ OC 判定"非休眠唤醒" ⇒ 冷启动。

**结论：不是平台不支持，也不是 HibernationFixup 没用，而是配置把两条路一起堵了。**

## 五、本次配置与依据

| 项 | 值 | 依据 |
|---|---|---|
| `Misc/Boot/HibernateMode` | `NVRAM` → **`Auto`** | 源码：`NVRAM` 模式跳过 RTC 分支；本机 NVRAM 里永远没有变量（§三） |
| `rtcfx_exclude` | 保持 `0E-7F,AC-FF`（**不含 80–AB**） | 源码：OC 读 RTC 偏移 128 起 44 字节；RTCMemoryFixup README：该区间即休眠数据 |
| `NVRAM/Add/…/rtc-blacklist` | 保持 198 B（`0E-7F` + `AC-FF`） | 与 boot-arg 同口径；`0x58–0x59` 仍在保护范围内 |
| `Kernel/Add` | + `HibernationFixup.kext` 1.5.4（idx 1） | 本机不写 NVRAM，保留它是为 README 第二项功能：patch IOPCIFamily 防恢复黑屏；且 `pluginStart` 的 max = `KernelVersion::Tahoe`，原生支持 macOS 26 |
| `Kernel/Quirks/PowerTimeoutKernelPanic` | `true` → `false` | 电源转换超时时不 panic；否则失败与崩溃无法区分，污染判读 |
| `Misc/Security/AllowNvramReset` | 新增 `true` | 此前缺失 = Failsafe `false`，本机没有 Reset NVRAM 逃生口 |
| `boot-args` | + `-hbfxdbg` | 取证：确认 kext 是否触发、RTC 是否读到 `AAPL` |
| `Misc/Boot/HibernateSkipsPicker` | 保持 `true` | 恢复时跳过选择器 |

## 六、明确不加的项及理由

| 项 | 社区做法 | 为什么不加 |
|---|---|---|
| `RebuildAppleMemoryMap` = false | T530、X250 都用 false | 官方文档只说它修**启动期**三类问题（映射 > 4096 B / MAT 权限 / 低内存描述符合并 UAF），**未**建立与休眠的因果。本机当前 true 且启动正常，改为 false 属引入无依据变量 |
| `DiscardHibernateMap` = true | T530 在"第二次休眠又黑屏"时开 | 官方定义是"让 XNU 忽略新内存映射、假设 S4 醒来后没变"，并标注"仅老旧罕见硬件（Ivy Bridge + Insyde）的 workaround，不理解后果不要用"。本机 Comet Lake + HP，无依据 |
| `ReservedMemory` 0x8B000/0x1000/RuntimeCode | T530 用它修"休眠黑屏" | **机制有官方支撑**：`Configuration.tex` 的 ReservedMemory Note 原文——「Some types of firmware may not allocate memory areas used by S3 (sleep) and S4 (hibernation) code unless CSM is enabled causing wake failures ... these areas can be found in the lower memory」。但**地址必须是本机的**，T530 的 `0x8B000` 是它自己对比 CSM 开/关得到的；本机 `ioreg -n memory-map` 返回空、boot-log 计数 0，拿不到映射。盲填 4 KB 保留区没有依据，位置错还会挤掉固件真用的内存 |
| NVRAM `E09B9297-7928-4440-9AAB-D1F8536FBF0A` | X250 在 Add/Delete 各加一次 | 这是 HibernationFixup 的 NVRAM options 域；本机不用任何 `hbfx-*` NVRAM 选项（全走 boot-args），且 `DisableVariableWrite=false` 不拦写入 ⇒ 空占位无语义 |
| `Kernel/Patch`「Disable RTC wake scheduling」 | T530 称它会阻止 RTC 定时唤醒 | 该说法针对 ahbm 自动转休眠场景；本机是手动触发。与休眠的交互**未证实** ⇒ 视为待观测变量，保持现状 `true`（用于压 DarkWake） |

## 七、若首测失败：按症状定位，不要批量试

| 症状 | 指向 | 下一步 |
|---|---|---|
| 睡下后电源灯**不灭**、功率不掉 | 没进 S4（还在 Deep Idle） | 查 `pmset -g log` 有无 `Entering Hibernate`；查 `standby` / `standbydelay` 是否生效 |
| 断电气味但开机是**冷启动**（丢会话） | ③ 环节：OC 没拿到密钥 | 查 `log show` 的 HBFX 日志；查 NVRAM `boot-image-key` / `boot-signature` 是否被写入 |
| **恢复黑屏 / 半途重启** | 内存映射或低内存区 | 先取本机 memory map（临时开 `Misc/Debug/Target` 0x40）再定 `ReservedMemory`；`DiscardHibernateMap` 作为第二候选 |
| 重启报 **HP 005 RTC Power Loss** + 时钟回 2019 | RTC 被写坏 | 已发生 3 次。`pmset -g log` 取证后立即 `s4-arm.sh disarm`；逃生口 = OpenCore 选择器 → Reset NVRAM |

## 八、取证命令

```bash
pmset -g log | grep -E 'Entering Sleep|Entering Hibernate|Wake from' | tail -20
nvram -p | grep -i hiber                                  # 有输出 = NVRAM 腿生效
nvram -p | grep -E 'boot-image-key|boot-signature'         # 有输出 = OC 已认定休眠唤醒
ls -l /System/Volumes/VM/sleepimage                        # 存在且尺寸变化 = 真写了镜像
sysctl kern.hibernatecount                                 # 历史成功休眠次数
log show --last 30m --predicate 'eventMessage CONTAINS "HBFX"' | tail -30
```

## 九、回滚

```bash
sudo EFI/scripts/s4-arm.sh disarm          # pmset 回 Deep Idle 基线
git checkout HEAD -- EFI/OC/config.plist  # EFI 侧回滚（或恢复 docs/backups/s4-ready-20261028-1603/config.plist.before）
```

> 注：本次 EFI 侧改动全部在"检测方式"与"开关"层，未触碰 RTC 保护范围（`0E-7F,AC-FF` / 198 B 与改动前一致），
> 因此回滚 pmset 后即恢复原状，无需额外的 RTC 处理。
