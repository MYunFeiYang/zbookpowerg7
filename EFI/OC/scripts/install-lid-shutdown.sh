#!/bin/bash
#
# 一键安装：合盖延迟关机（LaunchDaemon + 可选禁用系统睡眠）
# 用法：
#   ./install-lid-shutdown.sh           # 安装并执行 pmset disablesleep 1
#   ./install-lid-shutdown.sh --skip-pmset   # 只装守护进程，不改 pmset
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SH="${SCRIPT_DIR}/lid-close-shutdown.sh"
SRC_PLIST="${SCRIPT_DIR}/com.oc.lidshutdown.plist"
DEST_SH="/Library/Scripts/lid-close-shutdown.sh"
DEST_PLIST="/Library/LaunchDaemons/com.oc.lidshutdown.plist"
LABEL="com.oc.lidshutdown"

SKIP_PMSET=0
for a in "$@"; do
  case "$a" in
    --skip-pmset) SKIP_PMSET=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-pmset]"
      exit 0
      ;;
  esac
done

if [[ ! -f "$SRC_SH" || ! -f "$SRC_PLIST" ]]; then
  echo "Missing lid-close-shutdown.sh or com.oc.lidshutdown.plist next to this script." >&2
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

if [[ "$SKIP_PMSET" -eq 0 ]]; then
  echo "==> pmset: disablesleep 1 (avoid broken sleep racing the lid script)"
  pmset -a disablesleep 1
  echo "    Done. To undo later: sudo pmset -a disablesleep 0"
else
  echo "==> Skipped pmset (you can run: sudo pmset -a disablesleep 1)"
fi

echo "==> Install complete. Default: lid closed for 5s -> shutdown (open lid in between to cancel)."
echo "    Logs: /var/log/oc-lidshutdown.log , /var/log/oc-lidshutdown.err"
