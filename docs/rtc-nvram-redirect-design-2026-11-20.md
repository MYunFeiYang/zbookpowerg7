# 自研补丁方案：RTC 休眠变量 → NVRAM 重定向（2026-11-20）

> 起因：用户「不找成功案例呢？从源码层面自己写补丁呢？」
> 目标：拆掉"三道墙"里的墙②（写 CMOS 0x80–0xAB ⇒ HP 005），使 S4 在不碰 CMOS 的前提下仍能恢复。
> 本文只做设计与定价，未实施。

## 一、原理（为什么这条路在理论上是通的）

真 Mac 的 S4 恢复凭据，是 boot.efi 经 **`AppleRtcRam` 协议**从 CMOS 0x80–0xAB 读出的
`AppleRTCHibernateVars`（44 B：`signature='AAPL'` + `revision` + `booterSignature[20]` + `wiredCryptKey[16]`，见 xnu `IOHibernateIO.cpp`）。

**关键事实（决定可行性）**：boot.efi 访问 RTC 走的是 UEFI 协议，不是直接 `in/out 0x71`。
证据：OC 的 `UEFI/ProtocolOverrides/AppleRtcRam=true` + `rtc-blacklist` 确实能拦住 boot.efi 的写
（社区用它防 BIOS 报错是有效的）。**既然能拦，就能改**。

协议结构（OC `Include/Apple/Protocol/AppleRtcRam.h`，全文已核对）：

```c
#define APPLE_RTC_RAM_PROTOCOL_GUID \
  { 0xE121EC07, 0x9C42, 0x45EE, { 0xB0,0xB6,0xFF,0xF8,0xEF,0x03,0xC5,0x21 } }

struct APPLE_RTC_RAM_PROTOCOL_ {
  UINTN  (EFIAPI *GetAvailableMemory)(APPLE_RTC_RAM_PROTOCOL *This);            // 通常 256
  EFI_STATUS (EFIAPI *ReadMemory) (This, OUT UINT8 *Buffer, UINTN Size, UINTN Address);
  EFI_STATUS (EFIAPI *WriteMemory)(This, IN CONST UINT8 *Buffer, UINTN Size, UINTN Address);
  EFI_STATUS (EFIAPI *ResetMemory)(This);
};
```

⇒ 只要装一个自己的实例：**0x80–0xAB 段走 NVRAM，其余透传真实 CMOS**，boot.efi 就永远看不到 CMOS 被动过。

## 二、三层改造（每层现状不同）

| 层 | 作用 | 现状 | 要做什么 |
|---|---|---|---|
| ① 内核（写） | 阻止 macOS 写 CMOS 0x80–0xAB | **已有**：`rtcfx_exclude=0E-FF`（RTCMemoryFixup） | 不动 |
| ② 内核（搬运） | 把被拦下的 vars 存进 NVRAM | **有代码但被门控**：HBFX `kern_hbfx.cpp:96-101` 已有 `nvstorage.write(kIOHibernateRTCVariablesKey, rtc, OptRaw)`，但外面套着 `if (!checkRTCExtendedMemory())`（2-bank 机器返回 true ⇒ 整段跳过） | 改 HBFX 门控重编译，或新写 ~150 行小 kext |
| ③ UEFI（回放） | boot.efi 读时从 NVRAM 返回 | **不存在** | 新写 ~250 行 DXE 驱动，安装上述协议 |

③ 的实现要点：
- `ReadMemory`：若 `[Address, Address+Size)` 与 `[0x80,0xAC)` 相交 → 从 NVRAM 变量拷出，越界部分补 0xFF；否则 `OcRtcRead` 透传。
- `WriteMemory`：同样分流；NVRAM 段写变量并 `gRT->SetVariable(... NV|BS|RT)`，其余写 CMOS。
- `ResetMemory`：清 NVRAM 段。
- 配套：`UEFI/ProtocolOverrides/AppleRtcRam=` **改为 false**（关掉 OC 那份，避免两份协议打架），驱动放 `EFI/OC/Drivers/` 并在 `UEFI/Drivers` 加条目。

## 三、能解决什么、不能解决什么

| 目标 | 判断 | 把握 |
|---|---|---|
| HP 005 不再出现 | CMOS 0x80–0xAB 从头到尾没人写（内核被 ① 拦、boot.efi 被 ③ 截）⇒ BIOS 无从发现异常 | **~85%** |
| S4 能真正恢复 | boot.efi 经协议拿到完整的 'AAPL' 签名套装 ⇒ 应触发恢复 | **~70%**（boot.efi 是否还校验别的未知） |
| **恢复后 iGPU 花屏** | **不解决**。显示管线重编程是另一个问题 | — |

⇒ **这套补丁最多把"恢复不了"换成"能恢复但花屏"**。花屏需另写补丁（或接受"再睡一次唤醒"的规避）。

## 四、工程量与风险

| 项 | 估计 |
|---|---|
| EDK2 环境 | 本机 `iasl`/`clang`/`python3` 齐；缺 `nasm`/`mtoc`，OC 的 `build_oc.tool` 会自动下载 |
| DXE 驱动 | ~250 行 C，参照 `Library/OcMainLib/OpenCoreUefi.c` 里现成的 AppleRtcRam 实现 |
| kext 侧 | 改 HBFX 门控重编译（HBFX 1.5.4 未适配 macOS 26，需自行处理加载） |
| 测试轮次 | 每轮 = 重启 + 睡眠 + 拔电 + 唤醒；至少 3-5 轮 |
| 最大风险 | 驱动 bug 导致无法启动（有 ESP 回滚 + 备用 U 盘可救，不碰固件） |

## 五、开始前必须坐实的三件事

1. **NVRAM 变量名与 GUID**：Lilu `NVStorage` 在 native NVRAM 机器上把 `IOHibernateRTCVariables` 写成哪个 GUID 的变量（需读 Lilu `NVStorage` 源码确认；若是文件后端则 ③ 读不到，需换方案）。
2. **boot.efi 是否只依赖 RTC 签名**：若它还交叉校验 `boot-signature` NVRAM 变量等，需一并满足。
3. **花屏是否可解**：若不可解，本方案的价值只剩"005 消失"，体验仍是恢复后花屏。

## 六、结论

- 技术路径成立、协议接口清晰、不需要改 Apple 二进制、不需要刷 BIOS、不需要拆机。
- 但它只拆墙②，不拆墙③；且需要写 UEFI 驱动 + 改 kext + 多轮实测。
- **是否实施，取决于用户是否接受"即使全成功，恢复后仍可能花屏"这一终点。**
