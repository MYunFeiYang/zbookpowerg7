#!/bin/bash
#
# 卸载睡眠 hook（SleepWatcher LaunchAgent + 本地脚本）
# 用法: ./uninstall-sleep-hooks.sh
# 不卸载 brew 的 sleepwatcher / blueutil（其他用途可能仍需要）

set -euo pipefail

HOOK_DIR="${HOME}/.local/lib/oc-sleep"
AGENT_DIR="${HOME}/Library/LaunchAgents"
AGENT_PLIST="${AGENT_DIR}/com.oc.sleephooks.plist"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/${UID_NUM}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    exit 0
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

echo "==> Stopping com.oc.sleephooks..."
if [[ -f "$AGENT_PLIST" ]]; then
  launchctl bootout "$GUI_DOMAIN" "$AGENT_PLIST" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
fi

echo "==> Removing hook scripts..."
rm -f "${HOOK_DIR}/sleep-pre.sh" "${HOOK_DIR}/sleep-wake.sh"
rmdir "$HOOK_DIR" 2>/dev/null || true

echo "==> Uninstall complete."
echo "    brew 的 sleepwatcher / blueutil 未卸载。"
