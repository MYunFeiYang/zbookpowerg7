#!/bin/bash
#
# 安装：开机（系统启动时）自动挂载本机启动盘上的 ESP 到 /Volumes/<卷名>。
# 需要管理员权限；会安装 LaunchDaemon + /Library/Scripts/mount-esp.sh
#
# 用法：
#   ./install-mount-esp.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SH="${SCRIPT_DIR}/mount-esp.sh"
SRC_PLIST="${SCRIPT_DIR}/com.oc.mountesp.plist"
DEST_SH="/Library/Scripts/mount-esp.sh"
DEST_PLIST="/Library/LaunchDaemons/com.oc.mountesp.plist"
LABEL="com.oc.mountesp"

if [[ ! -f "$SRC_SH" || ! -f "$SRC_PLIST" ]]; then
  echo "Missing mount-esp.sh or com.oc.mountesp.plist next to this script." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

echo "==> Installing ${DEST_SH}"
mkdir -p /Library/Scripts
install -m 755 "$SRC_SH" "$DEST_SH"
chown root:wheel "$DEST_SH"

echo "==> Installing ${DEST_PLIST}"
install -m 644 "$SRC_PLIST" "$DEST_PLIST"
chown root:wheel "$DEST_PLIST"

unload_daemon() {
  launchctl bootout system "$DEST_PLIST" 2>/dev/null || true
  launchctl unload "$DEST_PLIST" 2>/dev/null || true
}

echo "==> (Re)loading LaunchDaemon ${LABEL}"
unload_daemon
if launchctl bootstrap system "$DEST_PLIST" 2>/dev/null; then
  echo "    loaded via launchctl bootstrap"
elif launchctl load -w "$DEST_PLIST" 2>/dev/null; then
  echo "    loaded via launchctl load"
else
  echo "Failed to load LaunchDaemon." >&2
  exit 1
fi

echo "==> Running mount once now"
/bin/bash "$DEST_SH" || true

echo "==> Install complete."
echo "    Logs: /var/log/oc-mountesp.log , /var/log/oc-mountesp.err"
echo "    Uninstall: sudo ${SCRIPT_DIR}/uninstall-mount-esp.sh"
