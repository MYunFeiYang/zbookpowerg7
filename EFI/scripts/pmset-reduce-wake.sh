#!/bin/bash
#
# 睡眠功耗优化：收紧 pmset，减少 Deep Idle 期间被网络/维护任务唤醒。
# 用法: ./pmset-reduce-wake.sh        （非 root 时自动 sudo）
# 系统大版本更新后可能被还原，可重跑。
# 脚本外：长期睡眠可拔 USB 外设、关 Handoff/蓝牙，进一步省电。
#

set -euo pipefail

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo "  配置 pmset，降低睡眠平均功耗（需 macOS）。"
    exit 0
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

echo "==> Applying sleep power settings..."

# 全电源：关网络唤醒；hibernatemode=0 时 standby/autopoweroff 无意义
pmset -a \
  womp 0 \
  powernap 0 \
  tcpkeepalive 0 \
  proximitywake 0 \
  standby 0 \
  autopoweroff 0 \
  hibernatemode 0 \
  disablesleep 0 \
  networkoversleep 0

# 电池：低电量模式 + 关 Power Nap（AC 侧 lowpowermode 保持系统默认）
pmset -b lowpowermode 1 powernap 0

echo "==> Done. Key settings:"
pmset -g custom | grep -E 'womp|powernap|tcpkeepalive|standby|autopoweroff|hibernatemode|disablesleep|networkoversleep|lowpowermode' || true
