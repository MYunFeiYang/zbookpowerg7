#!/bin/bash
#
# 睡眠功耗：Deep Idle -> 断电（hibernate/standby）
#
# 背景：本机 FADT 声明 LOW_POWER_S0_IDLE_CAPABLE，macOS 走 Deep Idle（S0ix）而非 S3。
#   Deep Idle 下 CPU 停在 C10 但 SoC 部分带电 —— 用户功率计实测睡眠恒约 5W。
#   pmset-reduce-wake.sh 的"减少唤醒"路线已到顶（DarkWake 早就 0 次），
#   唯一能把 5W 打到 ~0.2W 的杠杆是"延迟断电"（standby）。
#
# 前置（仅 test/on 需要，一次即可）：
#   EFI/OC/config.plist -> Misc/Boot/HibernateMode: None -> Auto
#   否则断电后 OpenCore 不会去恢复镜像，开盖只会冷启动（丢会话）。
#
# 用法：
#   ./pmset-hibernate.sh status   # 打印当前状态
#   ./pmset-hibernate.sh test     # 受控试验：合盖 5 分钟后断电（先跑这个！）
#   ./pmset-hibernate.sh on       # 正式启用：30 分钟 / 60 分钟后断电
#   ./pmset-hibernate.sh off      # 回滚到现状（纯 Deep Idle，不写镜像）
#
# 试验判据：
#   成功   = 功率计 5W -> ~0.2W，开盖能回到原会话
#   半成功 = 断电了但开盖是冷启动（省电达成，丢会话）-> 需要 HibernateMode=Auto
#   失败   = 断电后起不来 -> 长按电源，开机后跑 ./pmset-hibernate.sh off
#            （若 macOS 也起不来：OpenCore 界面 Reset NVRAM）
#

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

show_status() {
  echo "==> 当前 pmset 关键项"
  pmset -g custom | grep -E 'hibernatemode|standby|standbydelay|powernap|womp|tcpkeepalive' || true
  echo
  echo "==> 历史 standby/hibernate 事件"
  if pmset -g log 2>/dev/null | grep -qE "Entering Standby state|Entering Hibernate"; then
    pmset -g log 2>/dev/null | grep -E "Entering Standby state|Entering Hibernate" | tail -5
  else
    echo "  (无 —— 从未真正进入过 standby/hibernate)"
  fi
  echo
  echo "==> /var/vm (休眠镜像)"
  ls -la /var/vm/ 2>/dev/null || true
}

case "${1:-}" in
  status)
    show_status
    ;;

  test)
    echo "==> 受控试验：合盖/休眠 5 分钟后写镜像并断电"
    echo "    先确认 config.plist 的 Misc/Boot/HibernateMode = Auto"
    pmset -a hibernatemode 3 standby 1 standbydelaylow 300 standbydelayhigh 300
    echo "    已应用。现在合盖，等 8~10 分钟，看电源灯是否熄灭 / 功率计是否掉到 ~0.2W。"
    echo "    回滚：$0 off"
    show_status
    ;;

  on)
    echo "==> 正式启用：30 分钟（低电） / 60 分钟（高电）后断电"
    pmset -a hibernatemode 3 standby 1 standbydelaylow 1800 standbydelayhigh 3600
    show_status
    ;;

  off)
    echo "==> 回滚到纯 Deep Idle（当前基线）"
    pmset -a hibernatemode 0 standby 0 autopoweroff 0
    show_status
    ;;

  *)
    sed -n '3,30p' "$0"
    exit 1
    ;;
esac
