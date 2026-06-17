#!/bin/bash
#
# 一键安装：耳麦输入自动切换（MicFix + MicInputSwitch）
# 推荐入口: ./oc-setup.sh mic install
# 卸载:
#   ./uninstall-mic-auto-switch.sh
#
# 前提: EFI 已配置 layout-id 55、boot-args 含 alcverbs=1 alctcsel=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MICFIX_URL="https://github.com/WingLim/MicFix/releases/download/v1.2.0/MicFix-Release-v1.2.0.zip"
MICFIX_VERSION="v1.2.0"

BIN_DIR="${HOME}/.local/bin"
AGENT_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs"
MICFIX_BIN="${BIN_DIR}/MicFix"
MICINPUT_BIN="${BIN_DIR}/MicInputSwitch"
MICFIX_PLIST="${AGENT_DIR}/com.WingLim.MicFix.plist"
MICINPUT_PLIST="${AGENT_DIR}/com.oc.micinputswitch.plist"
MICINPUT_LOG="${LOG_DIR}/MicInputSwitch.log"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/${UID_NUM}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo "  安装 MicFix + MicInputSwitch（用户级，无需 sudo）。"
    echo "  卸载: ${SCRIPT_DIR}/uninstall-mic-auto-switch.sh"
    exit 0
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if ! echo "$(sysctl -n kern.bootargs 2>/dev/null)" | grep -q 'alcverbs=1'; then
  echo "WARN: boot-args 未含 alcverbs=1，MicFix 可能无效。请确认 OpenCore 配置后重启。" >&2
fi

echo "==> Checking SwitchAudioSource..."
if ! command -v SwitchAudioSource >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Install Homebrew first, or: brew install switchaudio-osx" >&2
    exit 1
  fi
  echo "    Installing switchaudio-osx via Homebrew..."
  brew install switchaudio-osx
fi
echo "    $(command -v SwitchAudioSource)"

echo "==> Installing MicFix ${MICFIX_VERSION}..."
mkdir -p "$BIN_DIR" "$AGENT_DIR" "$LOG_DIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
curl -fsSL -o "${TMPDIR}/MicFix.zip" "$MICFIX_URL"
unzip -q "${TMPDIR}/MicFix.zip" -d "$TMPDIR"
install -m 755 "${TMPDIR}/MicFix-Release-v1.2.0/MicFix" "$MICFIX_BIN"

cat > "$MICFIX_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.WingLim.MicFix</string>
	<key>ProgramArguments</key>
	<array>
		<string>${MICFIX_BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ServiceIPC</key>
	<false/>
</dict>
</plist>
EOF

echo "==> Installing MicInputSwitch..."
install -m 755 "${SCRIPT_DIR}/mic-input-switch.sh" "$MICINPUT_BIN"

cat > "$MICINPUT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.oc.micinputswitch</string>
	<key>ProgramArguments</key>
	<array>
		<string>${MICINPUT_BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${MICINPUT_LOG}</string>
	<key>StandardErrorPath</key>
	<string>${MICINPUT_LOG}</string>
</dict>
</plist>
EOF

load_agent() {
  local plist="$1"
  launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true
  launchctl bootstrap "$GUI_DOMAIN" "$plist"
}

echo "==> Loading LaunchAgents..."
# 迁移旧版 plist 名称（com.zbook.MicInputSwitch）
launchctl bootout "$GUI_DOMAIN" "${AGENT_DIR}/com.zbook.MicInputSwitch.plist" 2>/dev/null || true
rm -f "${AGENT_DIR}/com.zbook.MicInputSwitch.plist"
load_agent "$MICFIX_PLIST"
load_agent "$MICINPUT_PLIST"

sleep 3
echo "==> Done."
echo "    MicFix:          $MICFIX_BIN"
echo "    MicInputSwitch:  $MICINPUT_BIN"
echo "    Log:             $MICINPUT_LOG"
echo "    Current input:   $(SwitchAudioSource -c -t input 2>/dev/null || echo '?')"
echo ""
echo "验证: 插 TRRS 耳麦后，系统设置 → 声音 → 输入应自动变为「线路输入」。"
