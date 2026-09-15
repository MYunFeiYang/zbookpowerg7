#!/bin/bash
#
# 睡眠功耗：Deep Idle（~5W） -> 断电档（~0.2W）
#
# 背景：本机 FADT 声明 LOW_POWER_S0_IDLE_CAPABLE，macOS 走 Deep Idle（S0ix）而非 S3。
#   Deep Idle 下 CPU 停在 C10 但 SoC 部分带电 —— 用户功率计实测睡眠恒约 5W。
#
# 三档与开关（依据本机 man pmset + pmset -g custom 实测，非推断）：
#   Deep Idle    当前唯一可达档                                       ~5 W
#   Standby      hibernatemode 3 + standby 1，到 standbydelay 落盘断电  ~0.2 W
#   Hibernate    hibernatemode 25，合盖即落盘断电                      ~0.2 W
#   - hibernatemode 3 会写镜像，但**仍给内存供电**（wake from memory），
#     所以只设 3 而不设 standby 不省电 —— standby 才是"摘内存电"那个动作。
#   - hibernatemode 25 不依赖 standby，必定断电（唤醒要读镜像，较慢）。
#   - 本机 `standby` **受支持**（pmset -g 中可见，值 0）；`autopoweroff`
#     **不受支持**（pmset -g 里根本不出现，脚本设了也无效，故不再设）。
#   - standbydelayhigh/low 取哪个由**剩余电量** vs highstandbythreshold(50%)
#     决定，与 AC/电池无关；电量 100% 走 high —— 故 high 必须显式设短，
#     否则用默认 86400（24 小时）等于永不触发。
#
# 前置（test/on/instant 都需要，一次即可）：
#   EFI/OC/config.plist -> Misc/Boot/HibernateMode: None -> Auto
#   否则断电后 OpenCore 不会去恢复镜像，开盖只会冷启动（丢会话）。
#   建议同时把 Misc/Security/AllowNvramReset 设为 true：该键缺失时 OpenCore
#   取 Failsafe=false（本机现状），即当前没有 Reset NVRAM 逃生口。
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
#   半成功 = 断电了但开盖是冷启动 -> 需要 HibernateMode=Auto
#   失败   = 断电后起不来 -> 长按电源，开机后跑 ./pmset-hibernate.sh off
#            （若 macOS 也起不来：OpenCore 界面 Reset NVRAM）
#   ⚠️ 未验证风险：OCLP 注入的 Wi-Fi 在休眠恢复后可能起不来。
#

set -euo pipefail

PMSET=/usr/bin/pmset
SYSCTL=/usr/sbin/sysctl

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

val() { $PMSET -g custom 2>/dev/null | awk -v K="$1" '$1==K{print $2; exit}'; }
supported() { [[ -n "$(val "$1")" ]]; }

show_status() {
  echo "==> 本机能力（pmset -g 里能看到的才受支持）"
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
  echo "==> /var/vm (休眠镜像，目标 RAM 大小的文件)"
  ls -la /var/vm/ 2>/dev/null || true
}

case "${1:-}" in
  status)
    show_status
    ;;

  test)
    echo "==> 受控试验：合盖 5 分钟后写镜像并断电"
    echo "    先确认 config.plist 的 Misc/Boot/HibernateMode = Auto"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 300 standbydelayhigh 300
    echo "    已应用。现在合盖，等 8~10 分钟，看电源灯是否熄灭 / 功率计是否掉到 ~0.2W。"
    echo "    回滚：$0 off"
    show_status
    ;;

  on)
    echo "==> 延迟断电：>50% 电量 60 分钟，<50% 电量 30 分钟"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 1800 standbydelayhigh 3600
    show_status
    ;;

  instant)
    echo "==> 合盖即断电（hibernatemode 25）"
    $PMSET -a hibernatemode 25
    echo "    注意：每次睡眠都要读镜像，唤醒明显变慢（等同 Win 侧 LIDACTION=2）。"
    show_status
    ;;

  off)
    echo "==> 回滚到纯 Deep Idle（当前基线）"
    $PMSET -a hibernatemode 0 standby 0
    show_status
    ;;

  *)
    sed -n '3,42p' "$0"
    exit 1
    ;;
esac
