#!/bin/bash
# 系统唤醒后执行：按睡眠前状态恢复蓝牙/Wi-Fi。
# 由 install-sleep-hooks.sh 安装，勿直接手动调用。

set -euo pipefail

STATE_DIR="${HOME}/.local/state"
BT_STATE="${STATE_DIR}/oc-sleep-bt.state"
WIFI_STATE="${STATE_DIR}/oc-sleep-wifi.state"
LOG_FILE="${HOME}/Library/Logs/oc-sleep-hooks.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wake] $*" >>"$LOG_FILE"
}

find_blueutil() {
  command -v blueutil 2>/dev/null && return 0
  for p in /opt/homebrew/bin/blueutil /usr/local/bin/blueutil; do
    [[ -x "$p" ]] && echo "$p" && return 0
  done
  return 1
}

wifi_device() {
  networksetup -listallhardwareports | awk '
    /Hardware Port: (Wi-Fi|AirPort)/ { getline; if ($1 == "Device:") { print $2; exit } }
  '
}

sleep 2

# --- 蓝牙 ---
BLUEUTIL="$(find_blueutil || true)"
if [[ -n "$BLUEUTIL" ]]; then
  if [[ -f "$BT_STATE" ]] && [[ "$(cat "$BT_STATE")" == "1" ]]; then
    "$BLUEUTIL" -p 1
    log "bluetooth restored"
  else
    log "bluetooth left off"
  fi
else
  log "blueutil not found, skip bluetooth"
fi

# --- Wi-Fi ---
WIFI_DEV="$(wifi_device || true)"
if [[ -n "$WIFI_DEV" ]] && [[ -f "$WIFI_STATE" ]] && [[ "$(cat "$WIFI_STATE")" == "1" ]]; then
  networksetup -setairportpower "$WIFI_DEV" on
  log "wifi restored on ${WIFI_DEV}"
elif [[ -n "$WIFI_DEV" ]]; then
  log "wifi left off on ${WIFI_DEV}"
else
  log "wifi device not found, skip"
fi

# HDMI/外接屏随系统唤醒自动亮屏，无需额外操作
