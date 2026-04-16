#!/bin/bash
#
# 合盖后延迟关机（适用于睡眠/休眠不可靠、希望合盖=关机时）
#
# 使用前请先（一次性，需管理员）：
#   sudo pmset -a disablesleep 1
# 避免系统先进入失效的睡眠，与脚本抢状态。若需恢复睡眠： sudo pmset -a disablesleep 0
#
# 一键安装 / 卸载（在 scripts 目录执行）：
#   ./install-lid-shutdown.sh
#   ./uninstall-lid-shutdown.sh
#   ./uninstall-lid-shutdown.sh --restore-sleep   # 同时恢复 pmset 睡眠

set -u

# 合盖确认后、执行关机前的等待秒数（期间打开盖子可取消）
DELAY_SECONDS="${LID_SHUTDOWN_DELAY:-5}"

# 轮询间隔（秒）
POLL_INTERVAL="${LID_POLL_INTERVAL:-2}"

is_lid_closed() {
  ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -Fq '"AppleClamshellState" = Yes'
}

last="unknown"
while sleep "${POLL_INTERVAL}"; do
  if is_lid_closed; then
    if [ "$last" = "open" ]; then
      i=0
      while [ "$i" -lt "$DELAY_SECONDS" ]; do
        sleep 1
        i=$((i + 1))
        if ! is_lid_closed; then
          logger -t oc-lidshutdown "Lid opened during grace period; cancel shutdown."
          last="open"
          continue 2
        fi
      done
      logger -t oc-lidshutdown "Lid stayed closed for ${DELAY_SECONDS}s; halting."
      /sbin/shutdown -h now
    fi
    last="closed"
  else
    last="open"
  fi
done
