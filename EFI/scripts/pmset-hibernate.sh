#!/bin/bash
#
# 睡眠功耗：Deep Idle（~5W） -> 断电档（~0.2W）
#
# 背景：本机 FADT Flags=0x002384A5，bit21 LOW_POWER_S0_IDLE_CAPABLE = SET，
#   故 macOS 走 Deep Idle（S0ix）而非 S3。Deep Idle 下 CPU 停在 C10 但 SoC
#   部分带电 —— 实测睡眠恒约 5W（落在 OC-little 记录的 AOAC 5%~10%/h 区间）。
#
# 可用档位（依据本机 man pmset + pmset -g cap 实测，非推断）：
#   Deep Idle    当前档，唯一默认可达                                  ~5 W
#   Standby      hibernatemode 3 + standby 1，到 standbydelay 断内存电   ~0.2 W
#   Hibernate    hibernatemode 25，合盖即落盘断内存电                    ~0.2 W
#   - hibernatemode 3 会写镜像，但**仍给内存供电**（wake from memory），
#     所以只设 3 而不设 standby 不省电 —— standby 才是"摘内存电"那个动作。
#   - hibernatemode 25 不依赖 standby，必定断电 —— ⚠️ **此断言已降级为待复验**。
#     2026-09-16 14:39 实测反例（AC + standby 0 + **外接显示器在线**，显示器为 PHL 241B8Q/HDMI）：
#     mode 25 睡眠走的是 Deep Idle —— `lastSleepType='Deep Idle'`、无 `Entering Hibernate`、
#     `sleepimage` mtime 未变、`PMRD: hibernateMode 0x0`、`Eligible for Standby: 0`。
#   - ★★ **四次睡眠实测（11:16 / 12:04 / 13:11 / 14:39）全部发生在插电状态** ——
#     依据 `pmset -g log`（**跨启动持久**，比 `log show --start/--end` 可靠；后者查旧窗会返回
#     当日最新的行）。四次原话均为 `Entering Sleep state due to 'Software Sleep' … Using AC (Charge:100%)`。
#     ⇒ **电池场景（拔电 + 无外设）从来、一次都没测过**；"mode 25 不行"目前只在 AC 下成立。
#   - ★ 策略结论（本脚本 `auto` 档的依据）：**日常办公（插电 + 外接显示器 + USB）本就不该用档 B** ——
#     插电省电收益 ≈ 0、唤醒还慢 10~30 s，且每次睡眠都会走"想写休眠镜像"那条会碰 RTC 的路
#     （HP POST 005 三次都发生在该配置下）。⇒ 正确做法是**按电源源分档**，见下：
#   - 本机 `standby` **受支持**（pmset -g cap 中出现，当前值 0）；
#     `autopoweroff` **不受支持**（cap 里根本没有，设了也无效，故不再设）。
#   - standbydelayhigh/low 取哪个由**剩余电量** vs highstandbythreshold(50%)
#     决定，与 AC/电池无关；电量 100% 走 high —— 故 high 必须显式设短，
#     否则用默认 86400（24 小时）等于永不触发。
#
# 【第 3 条路：强制 S3 —— 实验级，脚本不代做】
#   本机 DSDT **已经暴露 S3**：根作用域 \SS3 = One（DSDT.dsl L5708），
#   于是 L38257 的 If (SS3) { Name (_S3, Package (0x04) { 0x05, Zero, Zero, Zero }) }
#   成立。真正拦住 S3 的是 FADT bit21，不是 _S3 缺失。
#   要试：ACPI/Patch TableSignature=FACP, Find=<A5842300>, Replace=<A5840300>
#   （已实测该 8 位模式在 FACP 中**唯一**，位置 = offset 112 即 Flags 本身），
#   并同时禁用 SSDT-DeepIdle.aml（LPS0/LXEN 是 S0ix 的 OS 侧接口）。
#   ⚠️ 社区零先例；daliansky/OC-little 立场相反（专门提供**禁用** S3 的 SSDT）。
#   ⚠️ 反例：Surface IceLake 在**完全同构**的 DSDT 上把 SS3 改成 One 后，
#      内核日志确实变为 "ACPI: sleep states S3 S4 S5"，但 S3 睡眠本身仍未修好，
#      他们最终靠 hibernatemode 25 解决。→ 优先级排在 Standby/Hibernate 之后。
#
# ⚠️⚠️ 【2026-09-16 15:0x 应用 auto 档后发现的两件事，务必先读】
#   1) **`/var/vm/sleepimage` 会被删掉**：AC 档改成 `hibernatemode 0` 后，实测 `/var/vm/` 变空
#      （`total 0`）。⇒ **拔电后必须确认它被重建**（`ls -la /var/vm/`），否则电池档要休眠时没有
#      镜像文件可用，可能直接给个 Deep Idle 了事。**未验证：macOS 是否会在拔电/入睡时自动重建。**
#   2) **"拔掉所有外接 USB 设备"在本机做不到**：`pmset -g assertions` 的 kernel `0x4=USB` 断言
#      显示被算作外部设备的是 —— `HP HD Camera`（**内置**摄像头）、`Bluetooth USB Host Controller`
#      （**内置**蓝牙）、`USB Optical Mouse`（外接）。前两个是焊死在机器上的，**拔不掉**。
#      ⇒ **不要走"靠拔外设去满足 standby 前提"这条路**，方向本身就不成立。
#      ❓ 未定论：`UTBMap_tahoe.kext` 只把 3 个端口声明为 Internal（XHC/HS04、XHC/HS06、XHC2/SS01），
#         其余非 Internal；但端口节点上实测到的是 `USBPortType = 0`，与映射表里的 255 对不上
#         —— 可能是 macOS 26 暴露的属性名/取值不同，**证据不足，不下结论**。
#         验证法：拔掉鼠标后睡一次，看 `PMRD: sleep factors` 里 `USBExternalDevice` 是否消失。
#
# 前置（test/on/instant 都需要）—— ✅ 均已于 commit 2f5c047 完成：
#   1) Misc/Boot/HibernateMode: None -> NVRAM
#      OC 手册取值仅 None/Auto/RTC/NVRAM，Failsafe 默认即 None。
#      旧值 None = 忽略休眠状态，断电后 OpenCore 不去恢复镜像，开盖只会冷启动。
#   2) Misc/Security/AllowNvramReset = true
#      此前该键缺失 = 取 Failsafe false，即本机**没有** Reset NVRAM 逃生口。
#
# 用法：
#   ./pmset-hibernate.sh status    # 打印本机能力 + 当前状态
#   ./pmset-hibernate.sh auto      # ★ 推荐：按电源源分档 —— 插电 hibernatemode 0（不写盘/不碰 RTC）
#                                  #            电池 hibernatemode 25（真休眠）。拔插电源自动切，
#                                  #            **不需要改变任何使用习惯**。
#   ./pmset-hibernate.sh test      # 受控试验：合盖 5 分钟后断电（先跑这个）
#   ./pmset-hibernate.sh on        # 延迟断电：电量>50% 走 60 分钟，<50% 走 30 分钟
#   ./pmset-hibernate.sh instant   # 合盖即断电（hibernatemode 25，同 Win 侧做法；**全电源源**，慎用）
#   ./pmset-hibernate.sh off       # 回滚到现状（纯 Deep Idle，不写镜像）
#
# 判据 / 回滚：
#   成功   = 功率计 5W -> ~0.2W，开盖能回到原会话
#   半成功 = 断电了但开盖是冷启动 -> HibernateMode 值不对
#   失败   = 断电后起不来 -> 长按电源；能进系统就跑 ./pmset-hibernate.sh off
#            （若 macOS 也起不来：OpenCore 界面 Enter 进菜单 -> Reset NVRAM，
#              逃生口已由 2f5c047 打开）
#   ⚠️ 未验证风险：OCLP 根补丁注入的 Wi-Fi（IO80211 合并 + AirportItlwm）在
#      休眠恢复后能否起不来 —— 零先例，须实测。
#   ⚠️ 睡前**拔掉外接 USB 鼠标**：pmset -g assertions 里它有 0x4=USB 断言，
#      包里被蹭到就会唤醒整机。
#

set -euo pipefail

PMSET=/usr/bin/pmset
SYSCTL=/usr/sbin/sysctl

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

# status 是纯只读的，不需要 root；只有改系统电源设置的子命令才提权
case "${1:-}" in
  auto|test|on|instant|off)
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "Re-running with sudo..."
      exec sudo "$0" "$@"
    fi
    ;;
esac

val() { $PMSET -g custom 2>/dev/null | awk -v K="$1" '$1==K{print $2; exit}'; }
supported() { [[ -n "$(val "$1")" ]]; }

# 取指定电源源分块里的某个键值（pmset -g custom 里 "AC Power:" / "Battery Power:" 各一块）
# 用法：per_source "AC Power" hibernatemode
per_source() {
  $PMSET -g custom 2>/dev/null | awk -v sec="$1:" -v key="$2" '
    $0==sec {f=1; next}
    /^[A-Za-z].*:$/ {f=0}
    f && $1==key {print $2; exit}'
}

show_status() {
  echo "==> 本机能力（pmset -g cap 里能看到的才受支持）"
  if supported standby; then
    echo "  standby      : 受支持（当前 $(val standby)）"
  else
    echo "  standby      : 不受支持"
  fi
  if supported autopoweroff; then
    echo "  autopoweroff : 受支持（当前 $(val autopoweroff)）"
  else
    echo "  autopoweroff : 不受支持（设了也无效）"
  fi
  echo "  hibernatecount: $($SYSCTL -n kern.hibernatecount 2>/dev/null || echo '?')（历史真实休眠次数）"
  echo
  echo "==> hibernatemode 按电源源（拔插电源自动切换）"
  echo "    插电(AC Power)    : $(per_source 'AC Power' hibernatemode)"
  echo "    电池(Battery Power): $(per_source 'Battery Power' hibernatemode)"
  echo "    （0=不写盘仅内存供电 / 3=safe sleep / 25=真休眠落盘断电）"
  echo
  echo "==> 当前 pmset 关键项"
  $PMSET -g custom | grep -E 'hibernatemode|standby|standbydelay|powernap|womp|tcpkeepalive' || true
  echo
  echo "==> 历史 standby/hibernate 事件"
  if $PMSET -g log 2>/dev/null | grep -qE "Entering Standby state|Entering Hibernate"; then
    $PMSET -g log 2>/dev/null | grep -E "Entering Standby state|Entering Hibernate" | tail -5
  else
    echo "  (无 —— 从未真正进入过 standby/hibernate)"
  fi
  echo
  echo "==> 谁在阻止空闲睡眠"
  $PMSET -g assertions 2>/dev/null | grep -E "PreventUserIdleSystemSleep|NoIdleSleepAssertion|USB$|owner=" | head -8 || true
  echo
  echo "==> /var/vm (休眠镜像，目标 RAM 大小的文件)"
  ls -la /var/vm/ 2>/dev/null || true
}

case "${1:-}" in
  status)
    show_status
    ;;

  auto)
    echo "==> 按电源源分档（推荐档；拔插电源自动切换，**不需要改变使用习惯**）"
    $PMSET -c hibernatemode 0
    $PMSET -b hibernatemode 25
    # 空闲计时器：测试期曾把两档都设成 1 分钟，配上"电池=25"会变成"空闲 1 分钟即休眠"
    #   ⇒ 反复写 RTC（正是 005 的成因）⇒ 必须同时归一化。AC 0 = 插电永不自动睡（≈苹果默认）。
    $PMSET -c sleep 0
    $PMSET -b sleep 15
    echo "    插电(AC) : hibernatemode 0  —— 不写盘、**不碰 RTC**、唤醒最快；空闲不自动睡"
    echo "    电池     : hibernatemode 25 —— 真休眠，落盘并断内存供电；空闲 15 min 后才睡"
    echo
    echo "    依据："
    echo "      · 四次睡眠实测（11:16/12:04/13:11/14:39）**全在插电状态**（pmset -g log 原文"
    echo "        'Entering Sleep … Using AC (Charge:100%)' ×4）⇒ 电池场景从未测过。"
    echo "      · 日常办公（插电 + 外接显示器 + USB）用档 B 本就无收益，且每次睡眠都会走"
    echo "        '想写休眠镜像'那条会碰 RTC 的路 —— 三次 HP POST 005 都发生在该配置下。"
    echo "      · 出差时天然拔掉电源/显示器/USB ⇒ standby 前提自足，才是档 B 的真实场景。"
    echo "    回滚：$0 off"
    show_status
    ;;

  test)
    echo "==> 受控试验：合盖 5 分钟后写镜像并断电"
    echo "    前置已就绪（commit 2f5c047: HibernateMode=NVRAM, AllowNvramReset=true）"
    echo "    ⚠️ 睡前拔掉外接 USB 鼠标 —— 它有 0x4=USB 唤醒断言"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 300 standbydelayhigh 300
    echo "    已应用。现在合盖，等 8~10 分钟，看电源灯是否熄灭 / 功率计是否掉到 ~0.2W。"
    echo "    回滚：$0 off"
    show_status
    ;;

  on)
    echo "==> 延迟断电：>50% 电量 60 分钟，<50% 电量 30 分钟"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 1800 standbydelayhigh 3600
    echo "    短睡(<30min)仍从内存唤醒，快；长睡自动落盘断电。"
    show_status
    ;;

  instant)
    echo "==> 合盖即断电（hibernatemode 25）"
    $PMSET -a hibernatemode 25
    echo "    注意：每次睡眠都要读镜像，唤醒明显变慢（等同 Win 侧 LIDACTION=2）。"
    echo "    参照先例：ThinkPad E480 / Surface Laptop 3 / Fujitsu Q958 均用此档。"
    show_status
    ;;

  off)
    echo "==> 回滚到纯 Deep Idle（当前基线）"
    $PMSET -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400
    $PMSET -c sleep 0
    $PMSET -b sleep 15
    show_status
    ;;

  *)
    awk 'NR>=3 && /^set -euo/{exit} NR>=3' "$0"
    exit 1
    ;;
esac
