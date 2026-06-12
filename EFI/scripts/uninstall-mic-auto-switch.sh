#!/bin/bash
#
# 卸载耳麦输入自动切换（MicFix + MicInputSwitch）
# 用法: ./uninstall-mic-auto-switch.sh

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
AGENT_DIR="${HOME}/Library/LaunchAgents"
MICFIX_BIN="${BIN_DIR}/MicFix"
MICINPUT_BIN="${BIN_DIR}/MicInputSwitch"
MICFIX_PLIST="${AGENT_DIR}/com.WingLim.MicFix.plist"
MICINPUT_PLIST="${AGENT_DIR}/com.oc.micinputswitch.plist"
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

unload_agent() {
  local plist="$1"
  if [[ -f "$plist" ]]; then
    launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true
    rm -f "$plist"
  fi
}

echo "==> Stopping agents..."
unload_agent "$MICFIX_PLIST"
unload_agent "$MICINPUT_PLIST"

echo "==> Removing binaries..."
rm -f "$MICFIX_BIN" "$MICINPUT_BIN"

echo "==> Uninstall complete."
echo "    SwitchAudioSource (brew) 未卸载，其他用途可能仍需要。"
