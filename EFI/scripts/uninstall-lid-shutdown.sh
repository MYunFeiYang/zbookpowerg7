#!/bin/bash
#
# 一键卸载：合盖关机 LaunchDaemon（可选恢复 pmset 睡眠）
# 用法：
#   ./uninstall-lid-shutdown.sh              # 只卸 plist + 脚本
#   ./uninstall-lid-shutdown.sh --restore-sleep   # 同时 pmset disablesleep 0
#

set -euo pipefail

DEST_SH="/Library/Scripts/lid-close-shutdown.sh"
DEST_PLIST="/Library/LaunchDaemons/com.oc.lidshutdown.plist"
LABEL="com.oc.lidshutdown"

RESTORE_PMSET=0
for a in "$@"; do
  case "$a" in
    --restore-sleep) RESTORE_PMSET=1 ;;
    -h|--help)
      echo "Usage: $0 [--restore-sleep]"
      exit 0
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

echo "==> Unloading ${LABEL}"
launchctl bootout system "$DEST_PLIST" 2>/dev/null || true
launchctl unload "$DEST_PLIST" 2>/dev/null || true

if [[ -f "$DEST_PLIST" ]]; then
  echo "==> Removing ${DEST_PLIST}"
  rm -f "$DEST_PLIST"
fi

if [[ -f "$DEST_SH" ]]; then
  echo "==> Removing ${DEST_SH}"
  rm -f "$DEST_SH"
fi

if [[ "$RESTORE_PMSET" -eq 1 ]]; then
  echo "==> pmset: disablesleep 0 (restore default sleep behavior)"
  pmset -a disablesleep 0
else
  echo "==> pmset unchanged. To allow sleep again: sudo pmset -a disablesleep 0"
fi

echo "==> Uninstall complete."
