# hdmi-recolor — 外接屏热插拔后泛红自动修复

适用：HP ZBook Power G7（i7-10750H / UHD630）+ macOS 26 + 本机 OpenCore 配置。

## 症状

HDMI 外接屏插上或热插拔后，画面整体**偏红**（像少了绿/蓝通道）。重新开机后正常，
在 系统设置里重选一次同一分辨率也能好。

## 根因（把握 ~85%）

本机 HDMI 不是原生输出，而是 **DP → HDMI 的 LSPCON 转换芯片**（固件 8.41）。
热插拔后 macOS 侧读到的属性与正常态**逐项完全相同**（`connector-type`、
`av-signal-type`、`IOFBCLUTDefer`、gamma 位深、ICC 序列号都不变），
所以不是系统设置错了，是 **LSPCON 芯片内部状态坏了**。

结论性事实：**只有让 DP 链路真正重新训练**（像素时钟变化 → 重新握手）才能消红。
单纯改刷新率里"像素时钟相同"的档（1080p50 与 1080p60 都是 148.5MHz）不重训，实测时好时坏。

## 方案

**改刷新率，不改分辨率。** 切到像素时钟明显不同的另一档（本机选 1080p30，148.5→74.25MHz，正好减半），
停 700ms 再切回原档。分辨率全程不动，桌面窗口不会重排，屏幕短促闪一下。

筛选判据（不写死具体数字）：

1. **像素时钟变化 ≥10%** —— 链路重训的物理前提；
2. **刷新率相对差 ≥20%** —— 专门排除 1080p50 这种"像素时钟相同"的假候选；
3. 上面两条都满足时，优先 30Hz（标准 CEA 半频），否则选像素时钟变化最大的一档；
4. 一个候选都找不到 → **明确放弃，绝不改分辨率**。

换一块屏也一样：每次修复都现场枚举新屏自己的模式表，不存在"30Hz 不存在就失效"。
换屏后先跑 `--plan` 预演：它只会告诉你挑哪档，不会真切。

## 安装

```bash
bash tools/hdmi-recolor/bootstrap.sh      # 编译 + 装 LaunchAgent + 自检
```

前置：`xcode-select --install`（首次需要）。装完无需重启，登录后自动常驻。

抹盘重装后要恢复的**只有这个目录**（源码全在里面，无二进制依赖）：

- `hdmi-recolor.c` 手动修复工具
- `hdmi-recolor-watch.c` 常驻监视器（检测热插拔 → 自动修复）
- `install-hdmi-agent.sh` 写 LaunchAgent
- `修复外接屏泛红.command` 双击兜底
- `bootstrap.sh` 一条命令重建

## 使用

常驻服务装好后不用管：插上屏 → 约 8 秒等系统收尾 → 自动切一次 → 修好。
日志在 `~/automation-workspace/hdmi-recolor.log`（超过 512KB 自动清空）。

手动工具：

```bash
~/automation-workspace/hdmi-recolor            # 直接修一次（等系统稳定后执行）
~/automation-workspace/hdmi-recolor --now      # 立即修，不等待
~/automation-workspace/hdmi-recolor --status   # 看当前模式 / 像素时钟（只读）
~/automation-workspace/hdmi-recolor --plan     # 预演会挑哪档（只读，不真切）
~/automation-workspace/hdmi-recolor --mode 1920x1080@60   # 手动指定一档
```

## 为什么是用户态常驻程序而不是 kext

修复动作是"换显示模式"，等价物只有 `CGDisplaySetDisplayMode`（用户态 API）。
内核里能用的只有 `IOFramebuffer::setDisplayMode`，绕过 WindowServer 改模式会出现
"硬件已切、CG/ColorSync 还按旧配置跑"的状态错配（黑屏/花屏），且改动需要每次重启、出错黑屏。

另外实测确认：本机 `IOI2CTransactionTypes = 19`（不含 native AUX 的 4），**用户态读不到 LSPCON 的 DPCD**，
所以也没有"直接写寄存器治本"这条路。当前方案是唯一低风险可用路径。

## 已知边界

- **只能事后修，做不到无感**：约 8 秒延迟 + 闪一下。这 8 秒是刻意等 WindowServer/ColorSync 收尾，
  太早动手会被系统覆盖（实测过）。
- **红不红只能靠眼睛判断**：已实测封死的客观判红手段——`CGGetDisplayTransferByTable`
  （外接屏返回 1001）、`vcgt`（当前 profile 无此 tag）、截屏（帧缓冲中性）。
  所以是"每次插拔都无条件修一次"，而不是"检测到红了才修"。
- **抑制窗口 15 秒**：自身修复会尾随出两批 framebuffer 事件（+7s / +17s），
  窗口短于 10 秒会形成每 10 秒闪一次的循环。真实断开连接会立即解除抑制。
- **不碰内屏**：只对非内建显示器动作。
- 与睡眠/唤醒相关的 boot-args `igfxonln=1 igfxonlnfbs=0` 是另一件事（修 IGPU 唤醒 panic + 外接泛红的诱因），
  不归本目录管，改它前先看 `docs/`。

## 已验证记录

- `15:02:52` 端到端：`1920x1080@60 → @30 → 切回`，`err=0/0`，分辨率未动。
- `14:39`、`12:47` 两次插拔后自动消红成功。
- 检测通道：IOKit framebuffer interest 通知跨进程有效（2 事件），空闲 0 事件；
  1 秒兜底轮询单次 183µs（约 0.018% CPU）。
