# S4 休眠密钥的 SMC(HBKP) 通路 —— 2026-11-20 新发现

> 本文记录一条此前所有排查都漏掉的路径：macOS 在**真 Mac 上并不把休眠密钥写进 RTC**，而是写进 SMC 的 `HBKP` key。VirtualSMC 从内核层实现了这个 key，OpenCore 从 EFI 层实现了配套的读取与解密。两侧在本机都是**关闭**状态，这才是 11-18「进 S4 成功但恢复从未尝试」的真正原因。

## 一、为什么之前的结论是"RTC 无解"

历史结论（§95）建立在两个上游文档判决上，二者都正确、但都只针对 RTC 通路：

1. `RTCMemoryFixup`（lvs1974）README：
   > "Offsets from 0x80 to 0xAB are used to store some hibernation information (IOHibernateRTCVariables). **If any offset in this range causes a conflict, you can exclude it, but hibernation won't work.**"

2. InsanelyMac #359189（ThinkPad X250）：`rtc-blacklist` 09–FF 全封仍报 CMOS checksum，唯一解法是 UEFITool 删 `DxeCmosInit` + 编程器硬刷。

这两条说的是：**走 RTC 存密钥，就必然与 BIOS 的 CMOS 校验冲突**。本机 4/4 出现 005 也印证了。结论"RTC 通路无解"成立。

**但没有人问过：macOS 为什么一定要走 RTC？** 真 Mac 走的是 SMC。

## 二、SMC 通路的完整机制（源码级，四段）

### 段 1：内核侧写入 —— VirtualSMC 拦截 HBKP

`VirtualSMC/kern_keys.cpp`：

```cpp
SMC_RESULT VirtualSMCValueHBKP::update(const SMC_DATA *src) {
    DBGLOG("hbkp", "updating hbkp with key %d", findNotEquals(src, SMC_HBKP_SIZE, 0));
    // Do not try to write real value to HBKP key for security reasons.
    if (dumpToNVRAM) {
        if (EfiBackend::submitEncryptionKey(src, dumpEncrypted))
            DBGLOG("hbkp", "writing hbkp success");
        else
            SYSLOG("hbkp", "failed to write hbkp");
    }
    return SmcSuccess;
}
```

开关（`kern_keys.cpp`，`withDump`）：

```cpp
uint32_t val = DumpNormal;                 // DumpNormal = 1
lilu_get_boot_args("vsmchbkp", &val, sizeof(val));
hbkp->dumpToNVRAM  = dump && val >= DumpNormal;
hbkp->dumpEncrypted = val == DumpNormal;   // val==2 → 明文
```

- `dump` 来自 `VirtualSMCProvider::init()` 里的 `firmwareStatus = EfiBackend::detectFirmwareBackend()`，即**EFI backend 是否可用**。
- 默认 `vsmchbkp=0` ⇒ `dumpToNVRAM=false` ⇒ **HBKP 只存在内存里，断电即失**。

### 段 2：落盘方式（两种，区别巨大）

`VirtualSMC/kern_efiend.cpp`，`submitEncryptionKey(key, allowEncryption)`：

```cpp
if (allowEncryption) {                       // vsmchbkp=1
    auto privkey = Crypto::genUniqueKey(RtcKeySize);
    value = Crypto::encrypt(privkey, key, valueSize);
    if (RTCStorage::writeDirect(RtcKeyOffset, RtcKeySize, privkey, false, true))  // ← 写 RTC 0xD0
        DBGLOG("efend", "successfully written privkey to rtc");
    ...
}
...
if (value) totalSize = outInfo->write(value, valueSize, true);      // VSEN 密文
else       totalSize = outInfo->write(key, SMC_HBKP_SIZE, false);   // VSPT 明文
storage.write(EncryptionKey, ..., NVStorage::OptRaw|NVStorage::OptSensitive);
```

- `vsmchbkp=1`：AES-CBC 加密，**私钥写 CMOS 0xD0（16 字节）** ⇒ 仍碰 RTC。
- `vsmchbkp=2`：`value == nullptr` 分支 ⇒ 明文 `VSPT` 直接进 NVRAM，**零 RTC 写入**。

常量：`kern_efiend.hpp` → `RtcKeyOffset = 0xD0`，`RtcKeySize = 16`。

### 段 3：EFI 侧读回 —— OpenCore 内置 OcSmcLib

`OpenCorePkg/Library/OcSmcLib/OcSmcLib.c`：

```c
APPLE_SMC_IO_PROTOCOL * OcSmcIoInstallProtocol (IN BOOLEAN Reinstall, IN BOOLEAN AuthRestart) {
  if (AuthRestart) {
    LoadAuthenticationKey ();   // ← 从 NVRAM 读 vsmc-key 并解密/拷贝到 HBKP 槽
    ExportStatusKey ();         // ← 写 vsmc-status（"VSMC" magic），告诉 kext backend 可用
  }
  ...
  gBS->InstallMultipleProtocolInterfaces (&NewHandle, &gAppleSmcIoProtocolGuid, &mSmcIoProtocol, NULL);
}
```

`ExtractAuthentificationKey()` 的两个分支：

```c
if (Buffer[0]=='V'&&Buffer[1]=='S'&&Buffer[2]=='P'&&Buffer[3]=='T') {
    CopyMem (mVirtualSmcKeyValue[mAuthenticationKeyIndex].Data, Buffer + sizeof(UINT32), SMC_HBKP_SIZE);
} else if (Buffer[0]=='V'&&Buffer[1]=='S'&&Buffer[2]=='E'&&Buffer[3]=='N') {
    for (Index = 0; Index < sizeof(EncryptKey); Index++) {
        EncryptKey[Index] = OcRtcRead (0xD0 + Index);
        OcRtcWrite (0xD0 + Index, 0);      // ← 读后立即清零
    }
    ...
}
```

- `VSPT`（mode 2）：纯内存拷贝，**连 0xD0 都不读不写**。
- `VSEN`（mode 1）：读 CMOS 0xD0 再清零 —— 只碰 16 字节，不碰 0x80–0xAB。

调用点（`Library/OcMainLib/OpenCoreUefi.c`）：

```c
if (OcSmcIoInstallProtocol (Config->Uefi.ProtocolOverrides.AppleSmcIo,
                            Config->Misc.Security.AuthRestart) == NULL)
```

### 段 4：boot.efi

boot.efi 通过 `gAppleSmcIoProtocolGuid` 读 `HBKP`（`mVirtualSmcKeyValue` 最后一项，32 字节 `SmcKeyTypeCh8s`）⇒ 拿到密钥 ⇒ 去读 `/var/vm/sleepimage` ⇒ 恢复内存镜像。

HBFX README 的旁证也在这里：**"Fortunately, boot.efi can read key `IOHibernateRTCVariables` from NVRAM!"** —— boot.efi 有不止一条取钥路径，SMC 是最原生的一条。

## 三、本机 11-18 失败的真正原因（改写）

| 项 | 11-18 当时的值 | 后果 |
|---|---|---|
| `UEFI/ProtocolOverrides/AppleSmcIo` | `false` | `gAppleSmcIoProtocolGuid` **根本没装** ⇒ boot.efi 无处读 HBKP |
| `Misc/Security/AuthRestart` | `false` | `OcSmcIoInstallProtocol(_, false)` ⇒ `LoadAuthenticationKey()` 从不执行 |
| `vsmchbkp` boot-arg | 未设置 ⇒ 0 | `dumpToNVRAM=false` ⇒ HBKP 断电即失，NVRAM 里什么都没有 |
| `Misc/Boot/HibernateMode` | `None` | OC 不做任何休眠处理 |

三者全关 ⇒ boot.efi 拿到的是**全零 HBKP** ⇒ 认为没有待恢复镜像 ⇒ 冷启动。

**这比"RTC 被 rtcfx 挡了"更贴合观测**：观测是「进 S4 成功（LED 灭）、恢复从未尝试」，说明写阶段成功了、读阶段拿不到东西。全零 HBKP 完美解释这个不对称。

把握度：**>85%**（四段源码 + 三个开关全 false 的实证 + 观测吻合）。

同时这也解释了 HBFX 那个"奇怪的门"：`checkRTCExtendedMemory()` 判 RTC 有第二 bank 就跳过 NVRAM 补丁 —— 那是 **FakeSMC 时代**的补偿逻辑（当时内核只能走 RTC）。VirtualSMC 补齐 HBKP 之后，内核有了 SMC 通路，HBFX 的那个判断就变成了错位判断。所以**这条路不需要 HBFX，也不需要改 HBFX 源码**。

## 四、本次改动（已部署，sha `bd456752`）

| 项 | 原值 | 新值 | 作用 |
|---|---|---|---|
| `Misc/Security/AuthRestart` | false | **true** | 每次 boot 执行 `LoadAuthenticationKey()` |
| `UEFI/ProtocolOverrides/AppleSmcIo` | false | **true** | 安装 `gAppleSmcIoProtocolGuid` 给 boot.efi |
| `Misc/Boot/HibernateMode` | None | **Auto** | OC 自行判定休眠唤醒 |
| `boot-args` | … | 追加 **`vsmchbkp=2`** | 明文 dump、零 RTC 写入 |

保持不动：`rtcfx_exclude=0E-FF`（兜底拦内核写 RTC）、`AppleRtcRam=true`（OC 用内存模拟 RTC RAM，保护物理 CMOS）、未安装 HBFX。

## 五、为什么选 mode 2 而不是 mode 1

| | mode 1（加密） | mode 2（明文） |
|---|---|---|
| CMOS 写入 | 16 字节 @0xD0，重启时清零 | **零** |
| 005 风险 | 仍在（0xD0 虽不在 0x80–0xAB，但仍在 CMOS） | **理论上不存在** |
| NVRAM 内容 | AES 密文（VSEN） | 明文 32 字节（VSPT） |
| 安全性 | 高 | 低（本机 FileVault Off，仅本地暴露） |

选 mode 2 的唯一理由：**把 005 从根上排除**。这是「HP 005 接受不了」这个约束下唯一自洽的选择。

## 六、判读协议

### 步 1（重启后，无需睡眠，零风险）
查本次 boot 日志：`(efend) authenticated restart support is unavailable`
- 该行**消失** ⇒ `vsmc-status` 写入成功、backend 可用 ⇒ SMC 通路已活
- 该行**仍在** ⇒ backend 仍不可用（`AuthRestart`/`AppleSmcIo` 未生效或被别的东西覆盖）

### 步 2（mode 25 实测，判决点）
1. `sudo pmset -a hibernatemode 25`
2. 重启一次（让 pmset 生效并清空内存残留）
3. 拔电合盖睡 **2–3 分钟**（足够写盘 + 断电）
4. 按电源键唤醒
5. 判据：
   - **会话完整回来** ⇒ 成功，3.63W → 0.1–0.2W
   - 冷启动（出现 Apple logo 从头走）⇒ 恢复失败，看 `kern.hibernatecount` 与日志
   - 出现 HP 005 ⇒ mode 2 的"零 RTC 写"假设被推翻，需重新取证

### 回滚
`git checkout ee7755b~1 -- EFI/OC/config.plist` + 拷 ESP + `sudo pmset -a hibernatemode 0` + 重启。

## 七、把握度声明

| 命题 | 把握度 | 依据 |
|---|---|---|
| 11-18 失败=三个开关全关导致零 HBKP | >85% | 四段源码 + 本机三值实证 + 观测吻合 |
| 打开三开关后 SMC 通路可用 | ~85% | OcSmcLib 与 VirtualSMC 是配套设计，非 DIY |
| 端到端恢复成功（macOS 26） | ~55% | 上游 2025-07 后无 macOS 26 适配；本机无先例 |
| mode 2 全程零 CMOS 写入 | ~80% | 代码路径确定；未知的是内核是否另有 RTC 写者 |
| 005 不再出现 | ~70% | mode 2 零写入是必要条件，但"005 的唯一来源是 RTC"尚未坐实 |

## 八、与 HBFX 路线的区别（为什么放弃那条）

HBFX 那条要改源码（`checkRTCExtendedMemory()` 无条件返回 false），属于逆上游设计意图，且它写的是 NVRAM 变量 `IOHibernateRTCVariables`，仍可能被 boot.efi 的 RTC 优先逻辑盖过。
本方案**不改任何源码**、用的是上游两半配套设计、并且有"零 RTC 写入"的额外好处。唯一的"借用"是 `AuthRestart` 这个开关的用途移位：官方文档说它是给 FileVault 认证重启用（"Enable VirtualSMC-compatible authenticated restart... splitting and saving disk encryption keys between NVRAM and RTC"），但机制上与 hibernation 的取钥需求完全同构。这是本方案唯一的"非官方用法"。
