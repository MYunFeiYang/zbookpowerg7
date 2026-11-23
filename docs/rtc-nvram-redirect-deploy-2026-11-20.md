# RtcRamRedirect 部署与回滚方案（2026-11-23 重写）

> 驱动源码：仓库内 `drivers/RtcRamRedirectPkg/`（产物 `dist/RtcRamRedirect.efi`）
> 设计依据：`docs/rtc-nvram-redirect-design-2026-11-20.md`
> 状态：**已编译、已静态验证**；未上机实测。**不写固件、不刷 BIOS、每一步可逆。**

## 〇、本轮修订把三个前提全部推翻了

| 旧说法 | 现状 | 依据 |
|---|---|---|
| 需要自研内核组件把 blob 搬进 NVRAM | **错**。AppleRTC 双 bank 路径自己就同时写 CMOS 和 NVRAM | AppleRTC 反汇编（>90%） |
| 部署时必须把 `AppleRtcRam` 关掉 | **错**。必须保持 `true` 并**链式委托**给它 | OC 源码 + 本次查证（>95%） |
| `rtcfx_exclude` 语义未查证、暂不动 | **已查清**，它正是"CMOS 从未被 macOS 写"的那把锁 | RTCMemoryFixup 1.0.8 源码（>95%） |

## 一、`rtcfx_exclude` 到底是什么（源码级）

它**不是** OpenCore 的配置键，而是 kext **RTCMemoryFixup** 的 boot-arg（本机已加载 1.0.8、Enabled）。

`RTCMemoryFixup.cpp::excludeAddresses()` 把每个偏移标记进 `emulated_flag[256]`；
随后 `hookProvider()` 用 `KernelPatcher::routeVirtual` 挂钩 `AppleRTC` 的
`IOPortAccess::ioRead8 / ioWrite8`：

```c
ioWrite8:  if (emulated_flag[off]) { emulated_rtc_mem[off] = value; write_enabled = false; }
           // 真实硬件一个字节都不写，值只进内核内存影子
ioRead8:   先读硬件；若 emulated_flag[off] 则 result = emulated_rtc_mem[off];
           // 影子初值全 0（memset），所以读到的是"被吸收后的值"
```

关键词：**双向**（写拦、读也拦）、**内核态**、`emulated_rtc_mem` 初始全 0。

本机 `rtcfx_exclude=0E-FF` ⇒ `for (i = 0x0E; i <= 0xFF; ++i) emulated_flag[i] = true`
（range 分支，`soffset < eoffset` 校验通过）⇒ **0x0E–0xFF 全段双向拦截，含 0x80–0xAB**。

## 二、两层拦截，恰好叠成死锁

| 阶段 | 执行体 | 拦截者 | 效果 |
|---|---|---|---|
| kernel（睡眠瞬间） | `AppleRTC.kext` 写 CMOS 0x80 | `rtcfx_exclude=0E-FF` | 写被吸收进内核影子，CMOS 不变 |
| firmware（boot.efi） | boot.efi 读写 RTC | OC `AppleRtcRam` + `rtc-blacklist`（`4D1FDA02-…:rtc-blacklist` = 0x0E..0xFF，242 B） | `SyncRtcWrite` 吸收、`SyncRtcRead` 返回影子 |

⇒ **CMOS 0x80–0xAB 永远不会被 macOS 侧写入**（这同时解释了"近期不再报 005"），
但也 **boot.efi 永远读不到签名** ⇒ S4 只能冷启动。

官方文档把分工写得很直白（`Docs/Configuration.tex`，`Kernel/Quirks/DisableRtcChecksum`）：

> Note 2: This option will not protect areas from being overwritten at firmware stage
> (e.g. macOS bootloader), see `AppleRtcRam` protocol description if this is desired.

即 kernel 阶段归 RTCMemoryFixup，firmware 阶段归 AppleRtcRam。**两条都需要，也两条都被锁死。**

## 三、本驱动的插入点：只解 firmware 那一层

保持 `rtcfx_exclude` 与 `rtc-blacklist` **原样不动**（CMOS 继续零写入，005 源头继续关闭），
把 boot.efi 对 0x80–0xAB 的**读**改由 NVRAM 副本供给：

```
RtcReadMemory(0x80..0xAB)  -> NVRAM IOHibernateRTCVariables
RtcReadMemory(其余偏移)     -> 委托原实例（OC，blacklist 继续生效）
RtcWriteMemory(0x80..0xAB) -> 只更新 NVRAM，不碰 CMOS
RtcWriteMemory(其余偏移)    -> 委托原实例
ResetMemory                -> 只删 NVRAM 变量
```

**为什么必须委托而不是自己实现**：OC 的 blacklist 覆盖 0x0E–0xFF，包含 checksum
（0x58/0x59）、boot status（0x5C）、power bytes（0xB0–0xB4）。自己实现等于把这些保护全撤掉，
平白新开一个 005 面。委托后**净行为差异只有一条**：谁来回答 0x80–0xAB 的读。

链路安全性（源码级，>95%）：
- `Application/OpenCore/OpenCore.c` 主流程：`OcLoadUefiSupport` → 内部先
  `OcReinstallProtocols()`（其中 `OpenCoreUefi.c:490` 装 AppleRtcRam），**之后**才
  `OcLoadDrivers()`（同函数 ~990 行）。
- ⇒ 本驱动作为普通 driver 加载时，OC 实例已存在，`LocateHandleBuffer` 必中，
  `ReinstallProtocolInterface` 必成，**不存在被 OC 反向覆盖的时序风险**（驱动必须 `LoadEarly=false`）。
- OC 自始不卸载自身，`mOrigRtc` 函数指针在 boot.efi 调用期间始终有效；协议本身是
  Boot Services 协议，boot.efi 的休眠判定必然发生在 `ExitBootServices` 之前。

## 四、⚠️ 上机前必须先决的阻断点：`hibernatemode 0`

2026-11-23 实测本机：

```
hibernatemode 0        standby 1    standbydelayhigh/low 60
/var/vm/sleepimage    0 字节
```

`hibernatemode 0` ⇒ 永不写休眠镜像 ⇒ `AppleRTC::setHibernateState()` 不被调用 ⇒
**NVRAM 里永远没有 `IOHibernateRTCVariables`** ⇒ 本驱动每次都走"委托"分支 ⇒ **装上等于没装**。

要让驱动有东西可喂，必须先把 `hibernatemode` 改成 `25`（或 `3`）并真正写一次 sleepimage。
代价：这会改变当前已调好的 S0ix/standby 行为链（`standby 1` + 2×60s），
等于用"现在这套 3.6W 的睡眠形态"去换"S4 路线"。**该不该换由用户决定，不是技术细节。**

## 五、部署步骤（确认要换之后才执行）

```bash
cd /Volumes/Common/workplace/zbookpowerg7
shasum -a 256 EFI/OC/config.plist              # 记锚点 A

# 1) 驱动双写
cp drivers/RtcRamRedirectPkg/dist/RtcRamRedirect.efi EFI/OC/Drivers/
cp drivers/RtcRamRedirectPkg/dist/RtcRamRedirect.efi /Volumes/ESP/EFI/OC/Drivers/

# 2) UEFI/Drivers 追加条目（PlistBuddy）
#    Path=RtcRamRedirect.efi / Enabled=true / LoadEarly=false / Arguments="" / Comment="RTC hib -> NVRAM"
plutil -lint EFI/OC/config.plist

# 3) 部署 config + 三次 sync
cp -f EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
sync; sync; sleep 3; sync

# 4) 复验（四值必须相等）
shasum -a 256 EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist \
              EFI/OC/Drivers/RtcRamRedirect.efi /Volumes/ESP/EFI/OC/Drivers/RtcRamRedirect.efi
```

`AppleRtcRam` **保持 `true`**，`rtc-blacklist` **保持原值**，`rtcfx_exclude` **保持 `0E-FF`**。

当前产物：`RtcRamRedirect.efi`，15456 B，
sha256 `c57316513222157cc44d6329548ff05a509daa585b994e65ae587418dfe29252`，
PE32+ / subsystem 11 / x86-64 / entry RVA 0x2e4d。

## 六、判定标准

| 观察点 | 成功 | 失败 |
|---|---|---|
| 开机 | 正常进系统 | 卡在 OC 之前 → 驱动加载崩（粒度 1 回滚） |
| 休眠前 NVRAM | 存在 `IOHibernateRTCVariables`（44 B，首 4 字节 `AAPL`） | 变量不存在 → hibernatemode 还没生效 |
| 休眠后上电 | 苹果 logo + 进度条 → 回桌面 | 直接冷启动 → boot.efi 仍未读到签名 |
| 再重启发 BIOS | 无 005 | 出现 005 → 见 §八 |
| 恢复后画面 | 大概率花屏（已知未解） | 正常则意外之喜 |

```bash
sudo nvram -x -p | grep -A2 -i hibernate        # 前 4 字节应为 41 50 50 4C
```

## 七、回滚（三粒度）

1. **只关驱动**：`PlistBuddy -c "Set :UEFI:Drivers:<index>:Enabled false"`
2. **撤全部**：删两份 `RtcRamRedirect.efi` + `git checkout <锚点> -- EFI/OC/config.plist` + 拷回 ESP + sync×3
3. **进不去系统**：OC 选择器（`PollAppleHotKeys` 已开）→ `Reset NVRAM`，或备用 U 盘换 ESP 的 EFI 目录

> 不写固件、不刷 BIOS，最坏结果只是开机不进系统，可从 ESP 层完全恢复。

## 八、已知限制

1. **005 与"能不能恢复"仍是一对矛盾**，但矛盾已被推到最窄处：只要 `rtcfx_exclude` 覆盖面
   不小于固件校验的范围，固件就看不到改动。若放开 0x80–0xAB 后仍出 005，说明固件校验的是
   整段 CMOS 一致性（参考 X250 案例 `zamkara` issue #11：全 blacklist + RTCMemoryFixup 仍挡不住，
   最终只能 UEFITool 删 `DxeCmosInit`），本机即为无解。<80%，需实测。
2. **不解决恢复后 iGPU 花屏**（独立问题，社区无解 >90%）。
3. 驱动按需武装：变量不存在时完全委托，所以"装上没效果"是预期安全状态。
