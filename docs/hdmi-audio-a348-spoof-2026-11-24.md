# HDMI/DP 音频：HDAS device-id 伪装 A348（2026-11-24）

> 本机 HP ZBook Power G7 / i7-10750H / macOS 26.7.3 (25G342) / ALC236 / layout-id 55 / SimpleHDA 1.0.0
> 状态：**已改配置，待重启验证**

---

## 1. 现象与判断依据（均为实测，>90%）

| 观察 | 命令 | 结果 |
|---|---|---|
| 系统无 HDMI 音频输出 | `system_profiler SPAudioDataType` | 只有「内建输出」+ Oray 虚拟声卡，无显示器音频 |
| 显示音频 codec 空挂 | `ioreg -c IOHDACodecDevice` | `IOHDACodecDevice@1F,3,2` 属性为**空字典**、`!registered !matched`；codec 0（`0x10EC0236` ALC236）正常 |
| 视频通路正常 | `system_profiler SPDisplaysDataType` | 外接屏 `Connection Type: DVI or HDMI`、`Online: Yes` |
| 显示音频驱动未加载 | `kmutil showloaded \| grep -i gfxhda` | 无输出 |

补充：`AppleGFXHDA.kext` 的 `IOPCIMatch` 只有
`0x9DC88086 / 0xA3488086 / 0x9D718086 / 0x34C88086 / 0x38C88086`；
本机 HDA 控制器是 **`pci8086,6c8`（HDAS，ACPI 名为 `HDAS` 非 `HDEF`）**，一个都不匹配。

## 2. 根因（推断，~75%）

1. AppleALC 1.9.9 对 `06C8` 的 controller patch 把策略返回 **9D70**（Sunrise Point-LP）。
   本机 AppleALC 二进制内同时存在两套常量：
   - `0e0000b8709d0000eb0690`（→ 9D70）
   - `0e0000b848a30000eb0690`（→ A348）
2. `CodecAddressFilterArray` 只放行掩码 `0x01` / `0x09`，**没有 `0x04`（地址 2）**；
   本机 display audio codec 恰在地址 2 ⇒ 被过滤，vendor id 都不读。
3. `AppleGFXHDA` 不匹配 `06C8` ⇒ 即使 codec 被读到，也没有驱动建 HDMI 音频引擎。

外部佐证：AppleALC 核心开发者 lvs1974 在 `tctien342/Dell-Inspiron-7591-Hackintosh` issue #28 明确
`8086:06C8/A348` 的数字音频需要把策略改到 A348；社区（Deskmini 等）注入 `device-id = 0xA348` 是常规做法。

## 3. 本次改动（唯一变量）

`EFI/OC/config.plist` → `DeviceProperties/Add/PciRoot(0x0)/Pci(0x1F,0x3)`：

```xml
<key>device-id</key>
<data>SKMAAA==</data>   <!-- 0x0000A348 little-endian = 48 A3 00 00 -->
```

| 项 | 值 |
|---|---|
| 改动前 sha256 | `dca0ed0d…f07538`（工作区，含未提交的 PMCDump v1.6.3 注释） |
| 改动后 sha256 | `fed59305…e0c2e2`（工作区与 ESP 一致，间隔 6s 两次复验稳定） |
| 备份 | `docs/backups/config.plist.before-hdmi-a348-20261124-110829`、`docs/backups/config.plist.ESP-before-hdmi-a348-*` |
| 校验 | `plutil -lint` OK；`device-id` 解析为 `{length = 4, bytes = 0x48a30000}` |
| 未改 | `hda-gfx`、`layout-id 55`、framebuffer 全部保持原样 |

## 4. 重启后验证（4 条）

```bash
kmutil showloaded | grep -i gfxhda                  # 期望：AppleGFXHDA 出现
ioreg -lw0 -p IOService -c IOHDACodecDevice | grep -A2 "1F,3,2"   # 期望：出现 IOHDACodecVendorID = 8086xxxx
system_profiler SPAudioDataType | grep -iE "HDMI|PHL|Display"     # 期望：多出显示器音频输出
ioreg -c AppleHDAController -r | grep -i "device-id"               # 期望：0xa3480000
```

## 5. 失败判据与回退

| 现象 | 含义 | 动作 |
|---|---|---|
| codec 2 仍空、GFXHDA 仍不加载 | A348 策略未走通 | 回退，改试 9DC8 |
| codec 2 有 vendor id 但无音频输出 | EDID 未声明音频（本屏 EDID 仅 128B、无 CEA 块） | 保留改动，换带 CEA Audio Data Block 的屏 |
| 内建音频（ALC236）也消失 | A348 策略与 layout 55 不兼容 | 立即回退 |

回退（删键，两处同改）：

```bash
cd /Volumes/Common/workplace/zbookpowerg7
cp EFI/OC/config.plist /tmp/cfg.bak
plutil -remove 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x1F,0x3).device-id' EFI/OC/config.plist
plutil -lint EFI/OC/config.plist
cp EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
```

## 6. 与换屏的关系

- `device-id` 与 `AppleGFXHDA` 匹配是**设备级**配置，换屏不会失效（>90%）。
- 但「某块屏有没有音频输出」由该屏 EDID 决定：本机 PHL 241B8Q 的 `IODisplayEDID` 仅 128 B、
  `extension count = 0`、无 CEA 块 ⇒ 在 macOS 眼里不声明音频能力。
- 修好驱动栈后，换一块 EDID 带 CEA Audio Data Block 的屏（电视/原生 HDMI 带喇叭）成功率更高；
  只换屏不做本改动，成功率 <20%。

---

## 7. 实测结果（2026-11-24 11:16，重启后）—— 失败，已回退

### 7.1 观察

| 项 | 结果 |
|---|---|
| `AppleGFXHDA` 加载 | **成功**（550.1）—— 说明 A348 匹配确实把它拉起来了 |
| `HDEF@1F,3` 的 `device-id` | `48a30000`（伪装生效） |
| `AppleHDAController` 实例 | **0 个** |
| `IOHDACodecDevice` 数量 | **0 个**（ALC236 与显示音频 codec 全部消失） |
| `SPAudioDataType` | 仅剩 `OrayVirtualAudioDevice`，**内建音频消失** |
| HDEF 子节点 | 只有 `TGLDmic`，无控制器 |

### 7.2 根因（~90%）

`cn.laobamac.SimpleHDA` 不是自研音频栈，而是**把 Apple 原版 AppleHDA 通过 OpenCore 注入回来**
（二进制里的构建路径 `/AppleInternal/.../Binaries/AppleHDA/...` 可证）。该原版 AppleHDA 只包含
**一个**控制器类：

```
AppleHDA8086_9D70Controller   ← 全二进制仅此一个
pinConfigurations_80862807
```

AppleALC 1.9.9 的做法是**改写 AppleHDA 里的 device-id 比对常量**（二进制里同时存在
`0e0000b8 709d0000 eb06 90` → 0x9D70 与 `0e0000b8 48a30000 eb06 90` → 0xA348 两种补丁）。
- `device-id = 06C8` 时被改写成 **9D70** ⇒ 命中 `AppleHDA8086_9D70Controller` ⇒ 正常。
- `device-id = A348` 时被改写成 **A348** ⇒ 原版 AppleHDA 里**没有 A348 的控制器类** ⇒ 无实例 ⇒
  整条控制器/codec 链不建立 ⇒ 模拟音频与显示音频一起消失。

同时 `AppleGFXHDA` 虽然加载，但它是"显示音频控制器"，接管不到 codec（HDEF 下零 codec），
所以也发不出声。

### 7.3 结论与取舍

1. **A348 伪装路线关闭（~90%）**：与 AppleHDA 只剩 9D70 控制器这一事实硬冲突。
2. 变体 `9D71`（同属 9D70 家族，AppleGFXHDA 也匹配）理论上两侧都能过，但：
   - 成功率估 **25~35%**（未知 AppleGFXHDA 是否会抢占 HDEF）；
   - **当前这块 PHL 241B8Q 的 EDID 只有 128B、无 CEA Audio Data Block** ⇒ 即便驱动通了，
     这块屏在 macOS 眼里也不声明音频能力，**收益为零**。
3. 因此停止投入：等真的接上「EDID 带 CEA 音频块」的屏（电视等）时再评估，届时才值得试 9D71。

### 7.4 回退记录

- 工作区与 ESP 两处 `device-id` 已删除，`plutil -lint` OK。
- `diff` 与 `docs/backups/config.plist.before-hdmi-a348-20261124-110829` **逐字段一致**。
- sha256（两处同值）：`dca0ed0db3b8fdcb49694022e8f84b5048935c7f8a0b574bbd4f87c1e6f07538`
- ESP 间隔 6s 两次复验一致，未被回写。

---

## 8. 重大更正（2026-11-24 11:28，删除 EDID 注入键后重启）

### 8.1 实测：真实 EDID 与注入的 EDID **不一样**

移除 `AAPL01,override-no-connect` 后，`AppleIntelFramebuffer@1` 的 `IODisplayEDID` 变成 **256 字节**，
而原先注入的是 **128 字节**。逐项对比：

| 项 | 注入版（128B） | 真实版（256B） |
|---|---|---|
| 扩展块数 | 0 | **1（CEA-861 rev3）** |
| Video Data Block | 无 | 有（len=11） |
| **Audio Data Block** | **无** | **有：1 个 SAD = LPCM 2ch @32/44.1/48kHz** |
| Speaker Allocation | 无 | 有 |
| **HDMI VSDB** | **无** | **有（OUI 000C03，PHY 4096）** |
| 另一 VSDB | 无 | 有（OUI 00001a） |
| DTD1 | 1920×1080@60，148.50MHz | **完全相同** |
| 范围限制 | 48–76Hz / 30–85kHz / 180MHz | 完全相同 |

⇒ 注入的那份是**被截断的基础块**（丢了整个 CEA 扩展）。视频时序不受影响，
但**音频能力声明与 HDMI 厂商能力被一起抹掉了**。

### 8.2 由此作废的旧结论

- §7.3 与 §6 中「本屏 EDID 未声明音频能力 / 只有 128B base block」**作废（>90%）**：
  显示器本身**明确声明 2 声道 LPCM**，是注入的截断版把它隐藏了。
- 「换屏才可能出声」的推理前提不成立：**当前这块屏就具备音频能力声明**。

### 8.3 HDMI 音频的真实卡点（更正后）

删键重启后实测：

- `IOHDACodecDevice` **总数 = 1**，只有 `@1F,3,0`（ALC236，`vendor=0x10EC0236`）；
  **`@1F,3,2`（显示音频 codec）根本不存在**（此前是"存在但 !registered"，现在是"压根没建"）。
- `AppleGFXHDA` **仍未加载**（它只匹配 `9DC8/A348/9D71/34C8/38C8`，本机 `06C8`）。
- `SPAudioDataType`：`内建麦克风 / 内建线路输入 / 内建输出`（默认输出）+ Oray 虚拟卡，**无显示音频**。

⇒ 卡点不在 EDID，而在**控制器只探测 codec 地址 0**：AppleHDA（由 SimpleHDA 注入的原版）
仅含 `AppleHDA8086_9D70Controller` 一个控制器类，其 codec 地址过滤不覆盖地址 2；
而唯一能处理显示音频的 `AppleGFXHDA` 又因 `06C8` 不在匹配表而无法加载。与 §7.2 结论一致。

### 8.4 删键的收益与风险（实测结论）

- **纯收益、零回退**：视频侧 DTD1 完全一致（1920×1080@60 / 148.5MHz / `IOFBCurrentPixelClock=148500000`），
  `Framebuffer Depth` 仍 30-Bit ARGB2101010，`AppleDisplay` 实例 = 1，`Connection Type: DVI or HDMI`，
  内建音频三设备齐全（`内建输出` 为默认）。
- LSPCON 开机不透传 EDID 的担忧**未发生**：真实 EDID 正常读到 256B。
- 备份：`docs/backups/config.plist.before-remove-edid-override-20261124-112457`。

---

## 9. 后遗症：热插拔后整屏泛红，已回退 EDID 注入键（2026-11-24 11:41）

### 9.1 现象（用户三条观察，均为决定性分叉）

1. **重启后正常，热插拔 HDMI 后整屏泛红**
2. **这个现象在 11:24 删 EDID 注入键之前不存在（"这次才有"）**
3. 形态是**整体泛红**（白色发粉），不是暗部或局部

### 9.2 判别：偏色不在软件色彩管理

- `screencapture` 分别截内建屏与外接屏，统计高亮像素（近纯白）：
  - 外接 PHL 241B8Q：R=243.1 G=244.4 B=242.5（R−G=−1.3，B−R=−0.6）
  - 内建：R=235.1 G=236.7 B=237.4（R−G=−1.6，B−R=+2.3）
- ⇒ **framebuffer 输出完全中性**，偏色发生在 framebuffer 之后（GPU 色彩处理 / DP 链路 / LSPCON / 面板）。
- 两个 ICC 的 `rXYZ/gXYZ/bXYZ` 矩阵**完全相同**（都是标准 sRGB），差异仅在 `wtpt` 编码（v4 用 D50 PCS / v2 用显示器实际白点），属正常。
- `IODisplayParameters` 的 `rgsc/ggsc/bgsc` 全为 65536（=1.0），macOS 未做通道增益校正。
- 泛红状态与正常状态的软件读数**完全一致**：30-Bit ARGB2101010 / 148.5MHz / 2475000 / EDID 256B。⇒ 软件侧查不出差异。

### 9.3 机制（~80%）

两个独立缺陷叠加，删键把它们暴露出来：

1. **`igfxonln=1`（boot-args）** 启用 WEG 的 `ForceOnlineDisplay`，挂钩
   `AppleIntelFramebuffer::getDisplayStatus`，把 `0=offline / 1=online / 2=empty dongle`
   一律改写为 **1**。⇒ 拔线时上层看不到"离线"，插回时也看不到"离线→在线"，
   **热插拔不走完整的"重读 EDID → 重协商色域/量化"流程**，只做局部重初始化。
2. **EDID 身份从 DVI 变成 HDMI**：注入版是 128B 纯基础块（无 CEA、无 HDMI VSDB，
   特征字节 `0x22` = display-type 0 非 RGB color）；真实版 256B 含 CEA-861 rev3 +
   HDMI VSDB（OUI 000C03，PHY 1.0.0.0），特征字节 `0x2a` = display-type 1 **RGB color**。
   ⇒ macOS 把这块屏判成 **HDMI sink**，热插拔时需要协商色域；偏偏那一步被 (1) 跳过 ⇒ 残留错误 ⇒ 泛红。

⇒ 删键前走 DVI 路径**不需要协商**，所以即使 `igfxonln=1` 一直挡着也不出错。
这解释了"重启正常（走 full modeset）、一拔一插就红（走 hotplug 分支）"。

### 9.4 源码依据与备选方案

- WEG `ForceOnlineDisplay`：`if (ret != 1) { customised ? (inList(fb) ? 1 : ret) : (ret = 1); }`
- 基类 `FramebufferModifer`：`uint8_t fbs[sizeof(uint64_t)] {};`（8 槽，默认全 0）；
  `inList()` 读属性 **`IOFBDependentIndex`** 并判断 `idx` 是否在 `fbs[]` 中
- 本机实测索引：`AppleIntelFramebuffer@0` = **0**（内建，有 `built-in`，port 0）、
  `@1` = **1**（外接 HDMI，port 7）、`@2` = 2（未用，port 6）
- ⇒ 备选方案 B：`igfxonln=1 igfxonlnfbs=0`，只对内建屏强制 online，外接屏恢复真实检测 → 热插拔自动协商
- **但 `igfxonln=1` 是 commit `04bcd26`「修复核显睡眠唤醒 panic（避免 IGPU SafeForceWake MEDIA 域超时导致硬冻/内核崩溃）」引入的**，
  放开外接屏后有 panic 复发风险 ⇒ B 仅标 **~65%**，本次未采用。

### 9.5 处置：回退 EDID 注入键（方案 A）

- 在 `DeviceProperties.Add["PciRoot(0x0)/Pci(0x2,0x0)"]` 重新加入
  `AAPL01,override-no-connect` = 原 128B EDID（base64 已逐字节校验：长度 128、
  扩展块 0、校验和 OK、厂商 PHL、DTD1 1920×1080、特征字节 `0x22`）。
- IGPU 属性数 18 → 19；`plutil -lint` 两处 OK；`grep` 计数两处均为 1。
- **sha256（两处同值）= `dca0ed0db3b8fdcb49694022e8f84b5048935c7f8a0b574bbd4f87c1e6f07538`**，
  与 §7.4「删 A348 device-id 回退后」的记录**完全相同** ⇒ 字节级回到"已证明热插拔不红"的状态，
  中途未混入任何其他改动。ESP 间隔 6s 复验未回写。
- 备份：`docs/backups/config.plist.before-restore-edid-override-20261124-114112`（含删键状态）。
- 代价：EDID 回到截断的 128B（丢 CEA ⇒ 无音频声明 / 无 HDR / 无 YCbCr）。本机 HDMI 音频已确认修不了（§7.2/§8.3），
  HDR 与 YCbCr 也用不上 ⇒ **实际零损失**。
- 待验证：重启后热插拔一次 HDMI，确认不再泛红。

---

## 10. 最终处置：按用户决定撤回 EDID 注入（2026-11-24 11:44）

### 10.1 决策

用户明确两点指令：

1. **"不要注入 edid"** —— 拒绝方案 A（写回 128B 截断版 EDID）。
2. **"内屏就算了，外屏这样太麻烦了"** —— 不为外接屏再动内屏相关或睡眠相关配置。

⇒ 最终状态：**不注入 EDID、不改 boot-args、不改 connector 配置**，仅接受热插拔后需要手动触发一次 full modeset。

### 10.2 已执行

- 删除 `DeviceProperties.Add["PciRoot(0x0)/Pci(0x2,0x0)"]` 中的 `AAPL01,override-no-connect`（§9.5 刚加回的那一份）。
- IGPU 属性数 19 → **18**，其余键全部原样：
  `AAPL,ig-platform-id` / `AAPL,backlight-control` / `complete-modeset` / `device-id` /
  `disable-agdc` / `enable-hdmi20` / `enable-lspcon-support` / `force-online` /
  `framebuffer-con1-enable` / `-con1-has-lspcon` / `-con1-index` / `framebuffer-con3-flags` /
  `-con3-type` / `framebuffer-fbmem` / `-patch-enable` / `-stolenmem` / `-unifiedmem` / `hda-gfx`
- boot-args **一字未动**（确认不含 `igfxonlnfbs`，`igfxonln=1` 保持原样）。
- `plutil -lint` 工作区与 ESP 均 OK；`grep override-no-connect` 两处均为 **0**。
- **sha256（两处同值）= `f01eafb9df535d11abe7d046fcd5b352668a2b01538ec659b4bf12fc681738af`**，
  与 §11 记录「首次删键后」的状态**完全相同**；ESP 间隔 6s 复验未回写。
- 备份：`docs/backups/config.plist.before-drop-edid-again-20261124-114414`（含 §9.5 的注入版）。

### 10.3 当前行为与已知代价

| 项 | 状态 |
|---|---|
| 开机后显示 | 正常（full modeset，色域一次设对） |
| 热插拔 HDMI 后 | **整屏泛红**（`igfxonln=1` 令 hotplug 跳过色域协商） |
| 内建音频 | 正常（本次改动不涉及 HDA） |
| 睡眠唤醒 | **不受影响**（未动 boot-args） |
| EDID | 真实 256B，含 CEA / HDMI VSDB / 音频声明 |

### 10.4 泛红时的即时缓解（零配置）

任一操作都会强制走一次完整 modeset，颜色复位：

1. 系统设置 → 显示器 → 把分辨率切到别的再切回（或改一次刷新率）；
2. 或合盖睡眠再唤醒；
3. 或直接重插 + 上述其一。

长期做法：**开机前就插好 HDMI 线**，避免热插拔这一动作。

### 10.5 遗留可选路径（本次不做）

`igfxonln=1 igfxonlnfbs=0`：只对内建（`IOFBDependentIndex=0`）强制 online，外接（=1）恢复真实检测
⇒ 热插拔走完整协商。但 `igfxonln=1` 来自 commit `04bcd26`（修 IGPU SafeForceWake 睡眠唤醒 panic），
改动后可能 panic 复发，且需再评估一次睡眠 ⇒ 估 ~65%，**仅在用户主动要求时才动**。

---

## 11. 修热插拔泛红：`igfxonlnfbs=0` 只强制内屏（2026-11-24 11:48，待重启验证）

用户指令演进：`不要注入edid` → `内屏就算了，外屏这样太麻烦了` → **`泛红肯定要修啊`**。
⇒ 约束：**不得注入 EDID、不得改内屏行为、必须修泛红**。方案 A（写回 128B EDID）因此彻底排除。

### 11.1 源码依据（WhateverGreen master + Lilu，本地拉取逐行核对）

```cpp
// ForceOnlineDisplay::processKernel —— 只有 boot-arg 存在时才读取 fbs 掩码
uint64_t fbs;
if (PE_parse_boot_argn("igfxonlnfbs", &fbs, sizeof(fbs)) ||
    WIOKit::getOSDataValue(info->videoBuiltin, "force-online-framebuffers", fbs)) {
    for (size_t i = 0; i < arrsize(this->fbs); i++)
        this->fbs[i] = (fbs >> (8 * i)) & 0xffU;
    customised = true;
}

// wrapGetDisplayStatus —— 0=offline 1=online 2=empty dongle
uint32_t ret = orgGetDisplayStatus(framebuffer, displayPath);
if (ret != 1) {
    if (customised) ret = inList(framebuffer) ? 1 : ret;   // ← 掩码生效时，不在名单内则保留真实值
    else            ret = 1;                               // ← 未定制时一律强制 online（当前行为）
}

// FramebufferModifer::inList —— 读 IOFBDependentIndex，与 fbs[8] 任一相等即命中
bool inList(IORegistryEntry* fb) {
    uint32_t idx;
    if (AppleIntelFramebufferExplorer::getIndex(fb, idx))
        for (auto i : fbs) if (i == idx) return true;
    return false;
}
```

`fbs[sizeof(uint64_t)]` 是**8 个字节**（不是 64 位掩码），零初始化。

### 11.2 为什么 `igfxonlnfbs=0` 恰好等于"只强制内屏"

`PE_parse_boot_argn` 的取值语义在两种实现解释下都收敛到同一结果：

| 解释 | `"0"` 落到 fbs[8] | idx 0（内建）命中 | idx 1（外接）命中 |
|---|---|---|---|
| XNU 字符串拷贝语义 | `{0x30, 0,0,0,0,0,0,0}` | **命中**（fbs[1..7]=0） | 不命中 |
| 数值语义 | `{0,0,0,0,0,0,0,0}` | **命中**（全 0） | 不命中 |

⇒ 内建（`IOFBDependentIndex=0`）**继续被强制 online，行为与现在完全一致**；
外接（`=1`）拿到**真实的 0/1/2**，热插拔时的 offline→online 事件因此首次可见。
ASCII 数字为 0x30–0x39，不可能等于 idx 1 ⇒ 外接必然不会被强制。

### 11.3 为什么"看见事件"就能修好泛红

`complete-modeset` 已在配置中启用（`complete-modeset=1`，且 CometLake `supported=true`），
且未配置 `complete-modeset-framebuffers` ⇒ `customised=false`，走这条分支：

```cpp
// wrapHwRegsNeedUpdate
return !framebuffer->getProperty("built-in") || orgHwRegsNeedUpdate(...);
```

⇒ **任何非内建 framebuffer 每次 hwRegsNeedUpdate 都强制 complete modeset**。
此前因为 `getDisplayStatus` 恒返 1，`hwRegsNeedUpdate` 根本不被触发；现在事件可见 ⇒ 触发 complete
modeset ⇒ 重读 EDID（真实 256B）+ 重协商色域/量化 ⇒ 泛红消失。

### 11.4 改动（仅一个 boot-arg 令牌）

```
boot-args: ... igfxonln=1  →  igfxonln=1 igfxonlnfbs=0 ...
```

- 逐项 diff：新增 `['igfxonlnfbs=0']`，丢失 `[]`，参数 31 → 32。
- `plutil -lint` 工作区 / ESP 均 OK。
- sha256（两处同值）= `c1d12c775050d245528707818fc6819bbea41a9ad7a1ab17f3b9334528bf0669`，ESP 间隔 6s 未回写。
- 备份：`docs/backups/config.plist.before-onlnfbs-20261124-114824`。
- **EDID 注入键保持删除状态**（本文件 §10 的最终态未被破坏）。

### 11.5 风险与判读

| 结果 | 概率 | 处置 |
|---|---|---|
| 热插拔不再泛红 | ~65%（推断；机制链完整但未实测） | 收工 |
| 无变化（掩码未生效） | ~20% | 说明 `igfxonlnfbs` 未被解析或 external 未触发 hwRegsNeedUpdate，下一刀：临时完全去掉 `igfxonln=1` 做对照 |
| 热插拔后外屏点不亮 | ~10% | 删掉 `igfxonlnfbs=0` 即回到现状 |
| 睡眠唤醒 panic 复发 | ~5~10% | 内建仍被强制 online，理论上唤醒主路径未变；若复发立即回退 |

回退：`cp docs/backups/config.plist.before-onlnfbs-20261124-114824 EFI/OC/config.plist` 后双写 ESP。

### 11.6 重启后验证清单

1. 内建屏 / 外接屏 / 内建音频 三项正常（sanity，确认没被连带影响）
2. `nvram boot-args` 含 `igfxonlnfbs=0`
3. **拔 HDMI 线 5 秒再插回 → 看是否仍泛红**
4. 若正常：再做一次睡眠 + 唤醒，确认不 panic

---

## 12. `igfxonlnfbs=0` 实测失败 → 真因在 LSPCON 内部 → 自动化收口（11-24 12:28–12:46）

### 12.1 §11 假说被推翻
加 `igfxonlnfbs=0` 重启后基线正常，但**一次热插拔后仍泛红**。原"跳过色域协商导致泛红"（~65%）**作废**。

客观证据（说明软件层根本没坏）：
- 插拔瞬间（12:27）系统重建 `PHL 241B8Q-8993B388….icc`，读到**完整序列号**、白点 D65、带 Bradford `chad` 矩阵 ⇒ 协商按规范跑通了
- 截屏解析：外接屏最亮 0.3% `R=G=B=251.8`（比值 1.000），内建屏 `R=G=B=255` ⇒ 帧缓冲数据中性
- 红态（12:30 `/tmp/fb.txt`）与正常态（12:37 `/tmp/fb_ok.txt`）外接 framebuffer 属性**逐项完全相同**：`connector-type=<00040000>`、`av-signal-type`、像素时钟 148.5MHz、`IOFBGammaWidth=10`、`CLUTDefer`、`colr=11010000`

⇒ 差异不在 macOS 侧任何可见属性里，**只在 LSPCON（固件 8.41）芯片内部状态**。

### 12.2 决定性实验
`CGDisplaySetDisplayMode` 把外接屏切 `1920x1080@50Hz` 停 4s 再切回 `@60Hz`（两步 `err=0`），ICC 于 12:36:40 再次重建 ⇒ 泛红**消失**（用户确认）。

### 12.3 机制（~85%）
WEG `LSPCONDriverSupport::setupLSPCON()` 挂在 `AppleIntelFramebufferController::GetDPCDInfo()`；若 `hasLSPCONInitialized(index)` 为真，只做 `setModeIfNecessary()`+`wakeUpNativeAUX()`，**不重新 probe/init**；而 `setModeIfNecessary` 只按 I2C 0x41 判 LS/PCON 模式，**完全不看色彩空间/位深** ⇒ hotplug 后的错误状态无人纠正。
旁证：Linux i915 有 `[PATCH v3] drm/i915: Re-init lspcon after HPD`（Kai-Heng Feng, 2019-12-24）在 long HPD 时重新 `lspcon_init()`。
`complete-modeset=1` 不够：它只让 `wrapHwRegsNeedUpdate` 恒返 true（重算寄存器），**不重训链路、不重配 LSPCON**。

### 12.4 已排除（勿重查）
- `framebuffer-conX-type=00080000`：针对**桌面机原生 HDMI**；本机物理上就是 DP，WEG 官方 LSPCON 文档从不要求改 connector-type
- `framebuffer-con3-type` 是**死配置**：缺 `con3-enable`，`kern_igfx.cpp:1486-1495` 直接 `continue`，从未生效
- 被当 TV 按 YCbCr 编码：`kCGDisplayModeIsTelevisionOutput=false`
- CLUT/gamma 不一致：内外屏参数完全相同
- WEG 全局无 YCbCr/RGB/量化范围处理代码

### 12.5 自动化落地（交付物）
| 文件 | 作用 |
|---|---|
| `~/automation-workspace/hdmi-recolor.c` / 二进制 | 手动修复一次；`--status` 只看状态 |
| `~/automation-workspace/修复外接屏泛红.command` | 双击版手动修复 |
| `~/automation-workspace/hdmi-recolor-watch.c` / 二进制 | **常驻**：1 秒轮询检测外接屏出现 → 等 2.5s → 切 50Hz→切回 |
| `~/automation-workspace/install-hdmi-agent.sh` | 安装/重装 LaunchAgent（**改配置只跑它**） |
| `~/Library/LaunchAgents/com.thinkway.hdmi-recolor.plist` | `RunAtLoad`+`KeepAlive`+`ThrottleInterval=5`+`Aqua`+`Interactive` |
| `~/automation-workspace/hdmi-recolor.log` | 运行日志（>512KB 自动清空） |

关键设计：
- **轮询而非回调**：`CGDisplayRegisterReconfigurationCallback` 在某些 hotplug 时序下不带 add 标志；1 秒轮询 `CGGetActiveDisplayList` 更稳
- **启动只记基线**：开机/登录时已插着线，画面本来正常，不做动作
- **睡眠唤醒不误伤**：墙钟跳跃 >6s 判为睡眠（`mach_absolute_time`/`CLOCK_MONOTONIC` 睡眠期间不走），本轮只重建基线。计时基准必须放在 `usleep` 之前，否则 `doFix` 自身 5~6s 耗时会造成假报警
- **自身抖动抑制**：`g_fixing` + 修复后 8 秒窗口
- **备选模式三层回退**：同分辨率异刷新 → 同宽高比近像素 → 任意模式；只有单一模式的显示器记日志放弃
- **自检**：`HDMI_RECOLOR_SELFTEST=1 ./hdmi-recolor-watch` 把基线置空，不拔线即可跑通 检测→等待→修复（12:45 实测 `err=0/0 成功`）

### 12.6 launchd 注册的正确姿势（纠错）
`launchctl bootstrap gui/501 <plist>` 在本 agent 的 shell 里报 `Bootstrap failed: 5: Input/output error`，**不是**域不可用——同进程 `launchctl print gui/501` 正常（`active count=453`）⇒ 是本进程**不在 GUI bootstrap 命名空间**、无权写入。
绕法：`osacompile -o x.app -e 'do shell script "launchctl bootstrap gui/501 <plist>"'` 然后 `open x.app` ⇒ LaunchServices 把进程放进真实 Aqua 会话 ⇒ 注册成功。`osascript -e 'do shell script ...'` 无效（仍 EIO），必须经 `open` 换会话。

### 12.7 端到端验证通过（12:47，泛红结案）
用户拔插一次后报"正常了"，日志证明是服务自动完成的：

```
[12:47:02] 外接屏 display 1124229553 已断开
[12:47:04] 检测到热插拔：外接屏 display 1124229553 出现
[12:47:07] fix 开始（hotplug）：1920x1080@60Hz -> @50Hz -> 切回
[12:47:09] fix 结束：err=0/0 成功
```

时序：断开被 1s 轮询即时捕获；出现后 3s 触发修复（2.5s settle + 轮询周期）；**全程 7 秒，零人工**。修复后仍为 `1920x1080 @60Hz / 30-Bit Color (ARGB2101010)`，与修复前一致（位深未被改动）。

失效时的排查顺序（换屏后可能遇到）：
1. 显示器只有单一模式 → 三层备选回退全都为空，日志有 `该显示器只有一个可用模式`
2. settle 2.5s 太短（插入判定早于色域定稿）→ 把 `SETTLE_MS` 加到 4000，或改成"连续两次确认再修"
3. 服务没起来 → `launchctl print gui/501/com.thinkway.hdmi-recolor`

改完源码后：`clang -O2 -o hdmi-recolor-watch hdmi-recolor-watch.c -framework ApplicationServices && ./install-hdmi-agent.sh`

遗留未验：`igfxonlnfbs=0` 那轮改动之后，还没做过一次「睡眠 + 唤醒」确认不 panic。

### 12.8 检测机制返工：为什么最终是「事件优先 + 1s 兜底」（12:52）

用户质疑"检测是轮询？"后，把两种机制都实测了一遍，结论不是推测：

| 实验 | 做法 | 结果 |
|---|---|---|
| 回调能否收到**别的进程**的改动 | 最小探针注册 `CGDisplayRegisterReconfigurationCallback`，另起进程做一次 50→60 切换 | **0 个事件** |
| 回调能否收到**自己发起**的改动 | 同一探针自己切模式再切回 | **8 个事件**，flags `0x1`(BeginConfiguration) / `0x8`(SetModeFlag) / `0x0` |
| 轮询代价 | 单独程序跑 30 次 `CGGetActiveDisplayList` | **单次 183µs，30s 累计 CPU 0.0055s = 0.018%**，无 I/O |

⇒ 回调在这台机器上**只对自身改动可靠**，跨进程不投递；而**热插拔（硬件/系统发起）是否投递仍未知**，不能拿它当唯一判据。反过来，轮询便宜到可忽略（0.018% CPU），"轮询=浪费"不成立。

同时自曝一个 bug：v1 版本用 `dispatch_main()` 当主循环，**CFRunLoop 根本没有运行**，所以那版的回调物理上不可能触发——等于从未验证过。

现役 v4 结构：
1. `CFRunLoopRun()` 主循环（CG 回调与 IOKit 电源通知都是 runloop source，必须跑）
2. CG 显示变更回调 → 去抖 0.6s → 评估（快速通道，能收到就省一次等待）
3. **1s 兜底轮询**，`CFRunLoopTimerSetTolerance(0.2)` 允许内核合并唤醒
4. `IORegisterForSystemPower` 处理 `CanSystemSleep/WillSleep/HasPoweredOn`，唤醒后抑制 30s
5. 墙钟跳跃 >6s 作为第二道睡眠判据（兜底电源通知失效的情况）
6. 判定逻辑统一看"外接屏集合差异"，**不看事件 flags**

踩坑：`CFRunLoopTimerCreate` 的第 4 个参数是 `CFOptionFlags` 不是 leeway，leeway 要另调 `CFRunLoopTimerSetTolerance`（编译器 `-Wliteral-conversion` 警告暴露了这点）。

自检记录：`12:51:58 出现(自检) → 12:52:01 fix → 12:52:04 err=0/0 成功`，无假睡眠报警、无重复触发。服务重装后 pid 39625 running。

另注：agent 沙箱里 `ps`(exit 127) 与 `top`(operation not permitted) 都不可执行，量进程开销要自写 getrusage 小程序。

### 12.9 检测通道返工（14:45–14:52）：集合式轮询漏掉快速拔插

用户连续拔插两次：**第一次正常，第二次仍红**。日志里只有一条完整记录，第二次零记录。

系统侧却证明第二次确实发生过：`/Library/ColorSync/Profiles/Displays` 于 **14:40:23** 新建了 `PHL 241B8Q-FFFFFFFF-FFFF-F….icc`（序列号全 `F` = 读 EDID 时未取到），**14:40:25** 原 profile 被重写。

**根因**：旧判据是"外接屏集合差异"。快速拔插或 HDMI 接触不良的瞬时断连，1 秒轮询抓到的前后快照都是同一块屏 ⇒ 判定"什么都没发生" ⇒ 流程被静默跳过。

| 机制 | 跨进程（别的进程改模式） | 空闲 95 秒 | 结论 |
|---|---|---|---|
| `CGDisplayRegisterReconfigurationCallback` | **0 事件** | — | 只能看自己 |
| `IOServiceAddInterestNotification` on `IOFramebuffer` / `AppleIntelFramebuffer` | **2 事件** | **0 事件** | 驱动层推送，与发起者无关 |

事件类型实测为 `0xe0016007`（IOGraphics 显示模式变更）。据此把主通道换成 IOKit 通知，**收到事件即便集合未变也判为 hotplug**；1 秒轮询降为兜底。

**新踩的坑**：一次自身深度 fix 会产生**两批**尾随事件——切回瞬间一批（t≈+7s），**其后整 10 秒再来一批（t≈+17s）**。抑制窗口必须 >10 秒，否则每 10 秒闪一次。现设 `SUPPRESS_AFTER_FIX=15.0`。另加一条：检测到真实断开就把 `g_lastFixEnd` 归零解除抑制（自身修复不会让集合变空，断开必是用户拔线）。

## 12.10 最终形态：只换刷新率、不改分辨率（15:00–15:22）

用户明确要求「不要改分辨率，改刷新率」，据此重做选档逻辑，并修掉一次真实事故。

### 12.10.1 选档判据（不写死具体数字）

消红的物理前提是 **DP 链路重训**，即**像素时钟必须真的变化**。判据：

- 像素时钟变化 ≥ **10%**；
- 刷新率相对差 ≥ **20%**；
- 两条都满足时优先 30Hz（标准 CEA 半频，本机 148.5→74.25MHz 正好减半），否则取像素时钟变化最大的一档；
- 一个候选都没有 ⇒ **明确放弃，绝不改分辨率**。

**那道 20% 的门槛是专为 1080p50 加的**：`1080p50` 与 `1080p60` 的真实像素时钟**同为 148.5MHz**（只是消隐不同），
只按像素时钟估算会误判成"有变化"。这正是早期"切 50Hz 时好时坏"的根因（2 成 2 败）。

### 12.10.2 修掉的事故：切走回不来，屏被留在 1024x768

日志 14:58:52 与 14:59:25 两次出现 `err=0/-1` —— 切到低分辨率**成功**、切回**失败**。
根因：切回时只按 `IODisplayModeID` 去模式表里查，而模式表重建期间查不到就直接放弃。

现改为四重兜底：`IODisplayModeID` → 分辨率+刷新率 → 分辨率最近刷新率 → 原模式对象存档。
另外**默认动作压根不再换分辨率**，该类事故失去触发条件。

### 12.10.3 交付物与持久化

整套东西（源码即全部资产，无二进制依赖）落在仓库顶层 `hdmi-recolor/`：
`hdmi-recolor.c`（手动工具）、`hdmi-recolor-watch.c`（常驻监视器）、`install-hdmi-agent.sh`、
`bootstrap.sh`（重装系统后一条命令重建）、`修复外接屏泛红.command`、`README.md`。

> 位置选择：`tools/` 在 `.gitignore` 里是**刻意**忽略本地一次性脚本的；为放代码而改忽略规则是本末倒置。
> 仓库对源码类产物的既有做法是顶层独立目录（先例 `drivers/RtcRamRedirectPkg/`）。

### 12.10.4 实测记录

| 时间 | 事件 | 结果 |
|---|---|---|
| 15:02:52 | 手动触发 | `1920x1080@60 → @30 → 切回`，`err=0/0`，分辨率未动 |
| 15:21:28 | **真实拔插**（用户确认） | 检测到断开 → 15:21:40 开始修 → 15:21:43 `err=0/0` |

尾随事件（+7s / +17s 两批）全部落在 15 秒抑制窗口内被吸收，未形成循环。
`bootstrap.sh` 在搬迁后的新路径重跑通过：编译 OK、agent 正常拉起、`--plan` 仍选 1080p30。
