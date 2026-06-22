#!/bin/bash
# 系统唤醒后执行：按睡眠前状态恢复蓝牙/Wi-Fi。
# 由 install-sleep-hooks.sh 安装，勿直接手动调用。

set -euo pipefail

STATE_DIR="${HOME}/.local/state"
BT_STATE="${STATE_DIR}/oc-sleep-bt.state"
WIFI_STATE="${STATE_DIR}/oc-sleep-wifi.state"
WIFI_SSID_STATE="${STATE_DIR}/oc-sleep-wifi-ssid.state"
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

wifi_is_on() {
  local dev="$1"
  networksetup -getairportpower "$dev" 2>/dev/null | grep -qi ': on$'
}

wifi_associated() {
  local dev="$1"
  networksetup -getairportnetwork "$dev" 2>/dev/null | grep -q '^Current Wi-Fi Network: '
}

join_saved_wifi() {
  local dev="$1"
  local ssid="$2"
  networksetup -setairportnetwork "$dev" "$ssid" 2>/dev/null
}

restore_bluetooth() {
  local blueutil="$1"
  if [[ -f "$BT_STATE" ]] && [[ "$(cat "$BT_STATE")" == "1" ]]; then
    "$blueutil" -p 1
    log "bluetooth restored"
  else
    log "bluetooth left off"
  fi
}

restore_wifi() {
  local dev="$1"
  local saved_ssid=""

  networksetup -setairportpower "$dev" on
  sleep 2

  if wifi_associated "$dev"; then
    log "wifi restored on ${dev} (already associated)"
    return 0
  fi

  if [[ -f "$WIFI_SSID_STATE" ]]; then
    saved_ssid="$(cat "$WIFI_SSID_STATE")"
    if [[ -n "$saved_ssid" ]] && join_saved_wifi "$dev" "$saved_ssid"; then
      log "wifi restored on ${dev}, joined ${saved_ssid}"
      return 0
    fi
  fi

  # AirportItlwm on Tahoe may need a radio cycle; only do this after soft restore fails.
  log "wifi soft restore incomplete on ${dev}, cycling radio"
  networksetup -setairportpower "$dev" off
  sleep 1
  networksetup -setairportpower "$dev" on
  sleep 3

  if [[ -n "$saved_ssid" ]] && join_saved_wifi "$dev" "$saved_ssid"; then
    log "wifi restored on ${dev}, joined ${saved_ssid} after cycle"
    return 0
  fi

  if wifi_associated "$dev"; then
    log "wifi restored on ${dev} (associated after cycle)"
    return 0
  fi

  if [[ -n "$saved_ssid" ]]; then
    log "wifi power on ${dev}, join failed for ${saved_ssid}"
  else
    log "wifi restored on ${dev} (no saved ssid)"
  fi
}

# --- Wi-Fi first (lighter wake burst than simultaneous BT + radio cycle) ---
WIFI_DEV="$(wifi_device || true)"
if [[ -n "$WIFI_DEV" ]] && [[ -f "$WIFI_STATE" ]] && [[ "$(cat "$WIFI_STATE")" == "1" ]]; then
  restore_wifi "$WIFI_DEV"
elif [[ -n "$WIFI_DEV" ]]; then
  log "wifi left off on ${WIFI_DEV}"
else
  log "wifi device not found, skip"
fi

# --- Bluetooth after Wi-Fi (or in parallel only if Wi-Fi was left off) ---
BLUEUTIL="$(find_blueutil || true)"
if [[ -n "$BLUEUTIL" ]]; then
  restore_bluetooth "$BLUEUTIL"
else
  log "blueutil not found, skip bluetooth"
fi

# HDMI/外接屏随系统唤醒自动亮屏，无需额外操作
