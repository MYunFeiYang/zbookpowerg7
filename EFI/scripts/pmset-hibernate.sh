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
#   - hibernatemode 25 不依赖 standby，必定断电（唤醒要读镜像，较慢）。
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
# 前置（test/on/instant 都需要）—— ✅ 均已于 commit 2f5c047 完成：
#   1) Misc/Boot/HibernateMode: None -> NVRAM
#      OC 手册取值仅 None/Auto/RTC/NVRAM，Failsafe 默认即 None。
#      旧值 None = 忽略休眠状态，断电后 OpenCore 不去恢复镜像，开盖只会冷启动。
#   2) Misc/Security/AllowNvramReset = true
#      此前该键缺失 = 取 Failsafe false，即本机**没有** Reset NVRAM 逃生口。
#
# 用法：
#   ./pmset-hibernate.sh status    # 打印本机能力 + 当前状态
#   ./pmset-hibernate.sh test      # 受控试验：合盖 5 分钟后断电（先跑这个）
#   ./pmset-hibernate.sh on        # 延迟断电：电量>50% 走 60 分钟，<50% 走 30 分钟
#   ./pmset-hibernate.sh instant   # 合盖即断电（hibernatemode 25，同 Win 侧做法）
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
  test|on|instant|off)
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "Re-running with sudo..."
      exec sudo "$0" "$@"
    fi
    ;;
esac

val() { $PMSET -g custom 2>/dev/null | awk -v K="$1" '$1==K{print $2; exit}'; }
supported() { [[ -n "$(val "$1")" ]]; }

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
    show_status
    ;;

  *)
    awk 'NR>=3 && /^set -euo/{exit} NR>=3' "$0"
    exit 1
    ;;
esac
