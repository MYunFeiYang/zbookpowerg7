# RtcRamRedirect 部署与回滚方案（2026-11-20，22:00 修订）

> 驱动源码：仓库内 `drivers/RtcRamRedirectPkg/`（构建产物 `dist/RtcRamRedirect.efi`）
> 设计依据：`docs/rtc-nvram-redirect-design-2026-11-20.md`
> 状态：**已编译、已静态验证**；未上机实测。**本文件每一步都可逆，不写固件、不刷 BIOS。**

## 〇、关键前提修正（本次最重要的一条）

原先设计假设"需要自己造内核侧组件把休眠变量搬进 NVRAM"。**这个假设已被推翻。**
把 macOS 26 的 `com.apple.driver.AppleRTC` 从 `BootKernelExtensions.kc` 里切出来反汇编后确认：

```
AppleRTC::setHibernateState(this, mode):
    if (this->rtcSize <= 0xff)              // 只有单 bank（128B）
        return 0xe00002db;                  // 直接报错 "RTC: setHibernateState() error"
                                            //   ← HBFX 在单 bank 机器上自己写 NVRAM 就是替这一步
    data = OSDynamicCast(OSData,
             PMRootDomain->getProperty("IOHibernateRTCVariables"));
    if (!data || mode != 0 || data->getLength() > 0x2c) -> 跳过写入
    this->shadow = IOMalloc(this->rtcSize);         // 整块 RTC RAM 的影子拷贝
    memcpy(this->shadow, this->ramMap, this->rtcSize);
    helper(this, data->bytes, 0x80, data->length);  // ① 写进 RTC 偏移 0x80
    nvramEntry = IODeviceTree("/options");          // ② 同一个 blob 再写进 NVRAM
    nvramEntry->setProperty(OSSymbol("IOHibernateRTCVariables"), data);
```

结论：**在双 bank（256B）机器上，AppleRTC 自己就会把同一份 44 字节 blob 同时写 CMOS 0x80 和
NVRAM 的 `/options`（GUID `7C436110-AB2A-4BBB-A880-FE41995C9F82`）。** 我们不需要写任何内核代码，
驱动直接复用 macOS 亲手写下的那份 NVRAM 副本即可。

把握度：>90%（反汇编逐条读过，分支条件与字符串一一对上）。

## 一、部署前置检查

| 检查项 | 命令 / 位置 | 期望 |
|---|---|---|
| 基线 config sha | `shasum -a 256 EFI/OC/config.plist` | 记录当前值，作回滚锚点 |
| ESP 双侧一致 | repo 与 `/Volumes/ESP/EFI/OC/config.plist` | 同 sha |
| 现有 Drivers | `ls EFI/OC/Drivers` | 无 `RtcRamRedirect.efi` |
| `AppleRtcRam` | `UEFI/ProtocolOverrides` | 当前 `<true/>` → 将改为 `false` |

## 二、驱动的安全语义（为什么可以放心装）

改成"**按需武装**"之后：

| NVRAM 里有没有 `IOHibernateRTCVariables` | 驱动行为 |
|---|---|
| **没有**（从未真正休眠过） | 0x80–0xAB 全部透传真实硬件 —— 与没装这个驱动**完全等价** |
| **有**（发生过一次 hibernation） | 该窗口的读走 NVRAM 副本，写回 NVRAM，不碰 CMOS |

所以首次安装的失败面只有"驱动本身能不能加载"，不涉及行为变化。
真正开始起作用，是在下一次真正写入休眠镜像之后。

## 三、为什么关掉 `AppleRtcRam`

OC 的 `AppleRtcRam=true` 会自己装一份同名协议（只做 blacklist 过滤）。我们的驱动若装在它之后，
用 `ReinstallProtocolInterface` 能接管；但若加载时序反过来，OC 会盖掉我们。
**关掉它，让本驱动成为唯一实例**，时序问题就不存在了。

代价：OC 的 `rtc-blacklist` 随之失效。本驱动对 0x80–0xAB 是整段接管，blacklist 本来就轮不到；
而 0x80 以下的偏移本驱动一律透传，与 blacklist 为空的行为一致。

## 四、部署步骤（严格三写 + 复验）

```bash
# 0) 记录锚点
cd /Volumes/Common/workplace/zbookpowerg7
shasum -a 256 EFI/OC/config.plist            # 记下 A

# 1) 放驱动（repo + ESP 双写）
cp drivers/RtcRamRedirectPkg/dist/RtcRamRedirect.efi EFI/OC/Drivers/
cp drivers/RtcRamRedirectPkg/dist/RtcRamRedirect.efi /Volumes/ESP/EFI/OC/Drivers/

# 2) 改 config（PlistBuddy，勿手写整文件）
/usr/libexec/PlistBuddy -c "Set :UEFI:ProtocolOverrides:AppleRtcRam false" EFI/OC/config.plist
plutil -lint EFI/OC/config.plist

# 3) 部署 config（repo → ESP），三次 sync
cp -f EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
sync; sync; sleep 3; sync

# 4) 复验（必须全部相等）
shasum -a 256 EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist \
              EFI/OC/Drivers/RtcRamRedirect.efi /Volumes/ESP/EFI/OC/Drivers/RtcRamRedirect.efi
```

`UEFI/Drivers` 新增条目模板：

```
Dict {
  Arguments =
  Comment = RTC hibernate vars -> NVRAM
  Enabled = true
  LoadEarly = false          # 必须 false
  Path = RtcRamRedirect.efi
}
```

当前产物：`RtcRamRedirect.efi`，14944 B，
sha256 `79365e6a2d4424c7878f0a42af370787d6186c7452a8d9deb6a5b98a2766acc5`，
PE32+ / subsystem 11（EFI boot service driver）/ x86-64 / 3 段 / 1 条基址重定位。

## 五、判定标准（实测时看什么）

| 观察点 | 成功 | 失败 |
|---|---|---|
| 开机进系统 | 正常启动、无卡顿 | 卡在 OC 选择器之前 → 驱动加载崩 |
| 休眠前 NVRAM | 存在 `IOHibernateRTCVariables`（44 B，首 4 字节 `AAPL`） | 变量不存在 → AppleRTC 那条路没走通 |
| 休眠后上电 | 出现苹果 logo + 进度条并恢复到桌面 | 直接冷启动 → boot.efi 没读到签名 |
| 再次重启发 BIOS 画面 | **无 005** | 出现 005 → 见 §七 第 1 条 |
| 恢复后画面 | 大概率**花屏**（已知未解） | 若正常则意外之喜 |

取值命令（休眠前后各跑一次对比）：

```bash
sudo nvram -p | grep -i hibernate          # 或
ioreg -p IODeviceTree -n options -r -d 1 -w0 | grep -i hibernate
# 十六进制看前 4 字节应为 41 50 50 4C ("AAPL")
sudo nvram -x -p | grep -A2 -i hibernate
```

## 六、回滚（三种粒度，任选其一）

**粒度 1 — 只关驱动（保留 config 其他改动）**
```
PlistBuddy: Set :UEFI:Drivers:<index>:Enabled false
```

**粒度 2 — 撤掉全部部署**
```bash
cd /Volumes/Common/workplace/zbookpowerg7
rm -f EFI/OC/Drivers/RtcRamRedirect.efi /Volumes/ESP/EFI/OC/Drivers/RtcRamRedirect.efi
git checkout <锚点commit> -- EFI/OC/config.plist
cp -f EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist
sync; sync; sleep 3; sync
```

**粒度 3 — 系统都进不去**
1. 开机按住 → 进 OC 选择器（`PollAppleHotKeys` 已开，可空格进扩展模式）
2. 选 `Reset NVRAM`（若有），或
3. 用备用 U 盘启动到任意 EFI，把 ESP 里 `RtcRamRedirect.efi` 删掉 / 把 config 换回锚点版本
4. 最坏情况：把 ESP 的 EFI 目录整体替换为仓库里已知可用的备份

> 本方案**不写固件、不刷 BIOS**，最坏结果只是开机不进系统，可从 ESP 层完全恢复。

## 七、已知限制（必须再次明确）

1. **005 不能保证消失。** AppleRTC 在睡眠时**仍然会把 blob 写进 CMOS 0x80–0xAB**（反汇编
   第一段就写着 `helper(this, bytes, 0x80, len)`）。本驱动只接管 boot.efi 的读写，
   管不到内核在睡眠那一刻的直写。005 是否还会出现，取决于 HP 固件到底对哪段 CMOS 做校验——
   这一条目前 **<80%，属未知**。可能的杠杆是 `rtcfx_exclude=0E-FF`（当前 boot-args 里带着，
   把 0x80–0xAB 排除在 OC 的 RTC 保留/恢复之外），但 OC 这段语义尚未查证，暂不动。
2. **不解决恢复后 iGPU 花屏。** 这是独立问题，社区无解（>90%）。
3. 驱动按需武装：变量不存在时完全透传，因此"装上但没效果"是预期中的安全状态，不是故障。
