#!/bin/bash
# 系统进入睡眠前执行：关蓝牙/Wi-Fi，外接显示器时立即息屏。
# 由 install-sleep-hooks.sh 安装，勿直接手动调用。

set -euo pipefail

STATE_DIR="${HOME}/.local/state"
BT_STATE="${STATE_DIR}/oc-sleep-bt.state"
WIFI_STATE="${STATE_DIR}/oc-sleep-wifi.state"
WIFI_SSID_STATE="${STATE_DIR}/oc-sleep-wifi-ssid.state"
DISPLAY_STATE="${STATE_DIR}/oc-sleep-display.state"
LOG_FILE="${HOME}/Library/Logs/oc-sleep-hooks.log"

mkdir -p "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [sleep] $*" >>"$LOG_FILE"
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

wifi_is_on() {
  local dev="$1"
  networksetup -getairportpower "$dev" 2>/dev/null | grep -qi ': on$'
}

external_display_connected() {
  system_profiler SPDisplaysDataType 2>/dev/null | grep -q 'Display Type: External'
}

# --- 蓝牙 ---
BLUEUTIL="$(find_blueutil || true)"
if [[ -n "$BLUEUTIL" ]]; then
  if "$BLUEUTIL" -p | grep -q '^1$'; then
    echo 1 >"$BT_STATE"
    "$BLUEUTIL" -p 0
    log "bluetooth off (was on)"
  else
    echo 0 >"$BT_STATE"
    log "bluetooth already off"
  fi
else
  log "blueutil not found, skip bluetooth"
fi

# --- Wi-Fi ---
WIFI_DEV="$(wifi_device || true)"
if [[ -n "$WIFI_DEV" ]]; then
  if wifi_is_on "$WIFI_DEV"; then
    echo 1 >"$WIFI_STATE"
    CURRENT_SSID="$(networksetup -getairportnetwork "$WIFI_DEV" 2>/dev/null | sed 's/^Current Wi-Fi Network: //')"
    if [[ -n "$CURRENT_SSID" ]] && [[ "$CURRENT_SSID" != "You are not associated with an AirPort network." ]]; then
      printf '%s' "$CURRENT_SSID" >"$WIFI_SSID_STATE"
    else
      rm -f "$WIFI_SSID_STATE"
    fi
    networksetup -setairportpower "$WIFI_DEV" off
    log "wifi off on ${WIFI_DEV} (was on${CURRENT_SSID:+, ssid=${CURRENT_SSID}})"
  else
    echo 0 >"$WIFI_STATE"
    log "wifi already off on ${WIFI_DEV}"
  fi
else
  log "wifi device not found, skip"
fi

# --- HDMI / 外接显示器 ---
# macOS 无法像蓝牙一样彻底断电 HDMI 口；插入线缆时端口可能仍有微量待机功耗。
# 检测到外接屏时立即息屏，让显示器尽快进入待机（停止 HDMI 信号）。
if external_display_connected; then
  echo 1 >"$DISPLAY_STATE"
  if pmset displaysleepnow 2>/dev/null; then
    log "external display: displaysleepnow ok"
  else
    log "external display: displaysleepnow failed (displays may still sleep with system)"
  fi
else
  echo 0 >"$DISPLAY_STATE"
fi
