#!/bin/bash
#
# 卸载：移除 ESP 自动挂载 LaunchDaemon（不删除 /Library/Scripts/mount-esp.sh 以外的文件）。
#

set -euo pipefail

DEST_PLIST="/Library/LaunchDaemons/com.oc.mountesp.plist"
LABEL="com.oc.mountesp"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

launchctl bootout system "$DEST_PLIST" 2>/dev/null || launchctl unload "$DEST_PLIST" 2>/dev/null || true
rm -f "$DEST_PLIST"
rm -f /Library/Scripts/mount-esp.sh
echo "Removed ${LABEL} and /Library/Scripts/mount-esp.sh"
