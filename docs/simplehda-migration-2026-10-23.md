# 音频投递方式迁移：OCLP root patch → SimpleHDA（OC 注入）

> 2026-10-23 实施并实测通过。本机 HP ZBook Power G7 / i7-10750H / macOS 26.7.1 (25G241) / ALC236 / layout-id 55。

---

## 1. 为什么要换

此前音频依赖 OCLP-CustoMac 的 `Modern Audio` root patch：把 AppleHDA 600.2 写进 `/System/Library/Extensions/`，代价是

- 系统卷 seal 从 `Sealed: Yes` 变成 `Sealed: Broken`
- 必须关 SIP（本机 `csr-active-config = 0xFFF`）+ `authenticated-root` 关闭
- 每次 macOS 更新都会抹掉补丁，更新后必须重打，否则全静音

`laobamac/SimpleHDA` 走完全不同的路子：**Lilu 插件，把 AppleHDA 全套静态编进自己二进制（`__DATA_CONST` 4,198,539 B），运行时解压注册**，由 OpenCore 在启动时注入。不改系统卷、不重建 KC、不需要关 SIP。

---

## 2. 落地配置

| 项 | 值 |
|---|---|
| kext | `EFI/OC/Kexts/SimpleHDA.kext`，二进制 sha256 `f74c9dbddf43266c97c5f72cd76498bce1d6b5bd3731a947be62f1378b4c7954`（与官方 `SHA256.json` 逐字节一致） |
| `Kernel/Add[9]` | `BundlePath=SimpleHDA.kext`、`Arch=x86_64`、`MinKernel=25.0.0`、`MaxKernel=25.99.99`、Enabled |
| 加载顺序 | **WhateverGreen[7] → AppleALC[8] → SimpleHDA[9]** |
| boot-args | 追加 `keepsyms=1`（**必需**，否则符号解析失败会 panic） |
| HAL 插件 | **未装**（`SimpleHDA-HAL-1.0.0.pkg`）。参考实现 issue #3 也没装，少一个变量 |
| `SecureBootModel` | `Disabled`（本机已满足；开启时 SimpleHDA 无法启动，见 issue #4） |

**顺序为什么必须在 AppleALC 之后**：issue #3 记录的 panic 矩阵是 `SimpleHDA → AppleALC → 显示驱动` 会触发
`Lilu patcher: previous plugin had short jump type on a multiroute function`。本机无 NootedRed，但 WhateverGreen 同理必须在前面。

---

## 3. 关键机制：OCLP 的 Revert 不是删文件

这是本次最容易误判的一点。**实测 + 源码双重确认**：

`opencore_legacy_patcher/sys_patch/sys_patch.py`（`kgp-macPro/OCLP-CustoMac`）

```python
def _unpatch_root_vol(self):
    """Reverts APFS snapshot and cleans up any changes made to the root and data volume"""
    if APFSSnapshot(...).revert_snapshot() is False: ...
    self._record_revert_pending()          # ← Lifecycle.State 写 REVERT_PENDING
    logging.info("- Unpatching complete")  # ← 日志里那一行
```

文件头注释写明了动作：

```
'sudo bless --mount /System/Volumes/Update/mnt1 --bootefi --last-sealed-snapshot'
```

⇒ **revert = bless 切回上一个 sealed 快照，一个文件都不删。**

所以点完 Revert 后：

| 观察到的现象 | 是不是失败 |
|---|---|
| `Lifecycle.State = REVERT_PENDING` | **不是**，表示「已切好快照，等重启进入」 |
| `/S/L/E/AppleHDA.kext` 还在、mtime 没变 | **不是**，当前系统仍跑在 patch 后的快照里 |
| `/S/L/E` 目录 mtime 没变 | **不是**，同上 |
| 活卷与 `mnt1` 的 `AppleHDA.kext` inode 完全相同 | **不是**，同一 APFS 对象在两个快照视图里 |

有效判据只有两个：OCLP UI 的 `Root patch reversion succeeded; reboot into the restored sealed snapshot` + 日志 `- Unpatching complete`。
**不能用「文件还在不在」判断 revert 成败。**

重启后才有决定性证据：`/` 从快照 `EEC58BF6`（patch 后新建）切到 `DE1A35FD`（`com.apple.os.update-…`，原始），
`/S/L/E` mtime 回到 `Sep 25 10:06`，AppleHDA 计数 0，`Sealed: Yes`。

---

## 4. ★Revert 后必须先摘 auto-patch，否则白干

`/Library/LaunchAgents/com.dortania.opencore-legacy-patcher.auto-patch.plist`
（OCLP 打补丁时自己装的，`RunAtLoad=true` + `--auto_patch`）会在**登录时自动把补丁打回去**。

实测它确实有重打意图（15:39:48 那次日志）：

```
Set Auto patching
Starting Automatic Patching
Detected Snapshot seal intact, detecting patches
Detected applicable patches, determining whether possible to patch
Determined patching is possible, checking for OCLP updates
No new binaries found on Github, proceeding with patching     ← 准备动手
```

这一轮卡在 `SysPatchDisplayFrame` UI 上没写盘，但**不能靠运气**。三个守护项实测触发条件：

| 文件 | 触发 | 是否要删 |
|---|---|---|
| `auto-patch.plist` | `RunAtLoad=true` + `--auto_patch` | **必删** |
| `os-caching.plist` | `WatchPaths` + `--cache_os` | 可留（缓存失效才跑） |
| `macos-update.plist` | `WatchPaths` + `--prepare_for_update` | 可留（系统更新才跑） |

本次处置：**整个 OCLP 应用与三个守护项一并删除**。`/Library/Application Support/Dortania/` 只剩
`OpenCore-Legacy-Patcher-Lifecycle.plist` 作为历史记录。

代价：将来系统更新若需要重打补丁（如 Modern Wireless），必须重新下载 OCLP。
当前不需要——Wi-Fi 走 OC 注入的 `AirportItlwm`，音频走 SimpleHDA。

---

## 5. 实测结果（2026-10-23 15:38 重启后）

| 项 | 结果 | 证据 |
|---|---|---|
| `/S/L/E/AppleHDA.kext` | **已消失** | `ls` 报 No such file；AppleHDA 计数 0 |
| 系统卷 seal | **`Sealed: Yes`** | `diskutil apfs list`（revert 前 `Broken`）← **本次最大收益** |
| 启动快照 | `DE1A35FD` | 从 patch 后的 `EEC58BF6` 切回原始快照 |
| `/S/L/E` mtime | `Sep 25 10:06` | 干净快照时间，佐证真换快照 |
| SimpleHDA | **`cn.laobamac.SimpleHDA (1.0.0)` 已加载**，0x445000 | `kmutil showloaded` 第 63 项 |
| `keepsyms=1` | **已进 NVRAM** | `nvram -p \| grep keepsyms` |
| HDA 控制器 | `AppleHDAController@1F,3` active | `ioreg -r -c AppleHDAController` |
| **类来源** | **`kextstat \| grep -c AppleHDA` = 0** | 类全部由 SimpleHDA 内嵌提供 ⇒ 不存在重名冲突 |
| 音频设备 | 内建输出（默认）/ 内建线路输入（默认输入）/ 内建麦克风 | `system_profiler SPAudioDataType` |
| 出声 | `afplay Glass.aiff` 无报错，音量 19、未静音 | — |
| 音频选择器 | `imic` / `line` / `hdpn` 三值 | `IOAudioSelectorControlAvailableSelections` |

**内建麦仍不可用**（`num-internal-mics=1` 只是 layout 造的空壳，真麦是 Intel AE30 SoundWire 阵列，macOS 无 Intel SST 驱动）。
这项与投递方式无关，换 SimpleHDA 也修不了。详见 `docs/macos-mic-troubleshooting.md`。

---

## 6. 回滚路径

| 场景 | 操作 |
|---|---|
| 启动中 panic | OC picker 加 `-shdaoff` 跳过 SimpleHDA（另有 `-shdahaloff` 停 HAL、`-shdadbg` 需 DEBUG 包） |
| 进不了桌面 | 从 Windows 侧挂 ESP，改 `Kernel/Add[9].Enabled=false`（双系统可用） |
| 彻底回滚 | 关 SimpleHDA → 重新下载 OCLP → 重跑 `Modern Audio` root patch → 重启（`keepsyms=1` 留着无害） |

---

## 7. 尚未处理的遗留

- **SIP 仍全关**（`csr-active-config = 0xFFF`）、`authenticated-root` disabled。SimpleHDA 本身不需要关 SIP，
  但这是 OCLP 时代留下的设置，且 `-amfipassbeta` 等参数与之耦合。恢复需改 `NVRAM/Add` 并重启验证，
  建议单独一轮做，不要和本次改动混在一起。
- `Lifecycle.State` 停在 `REVERT_PENDING`（revert 后没人更新它），不影响功能。
- `/Users/Shared/OCLP*.log` 有 10 个历史日志残留，无功能影响。
