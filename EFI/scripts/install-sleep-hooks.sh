#!/bin/bash
#
# 一键安装：睡眠前关蓝牙/Wi-Fi，外接屏息屏（SleepWatcher + blueutil）
# 推荐入口: ./oc-setup.sh sleep install
# 卸载: ./oc-setup.sh sleep uninstall
#
# 说明: 睡眠前关蓝牙/Wi-Fi；外接 HDMI 显示器时立即息屏（无法彻底断电 HDMI 口）。
#       USB 鼠标等仍可能唤醒，睡眠前建议拔掉。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="${HOME}/.local/lib/oc-sleep"
AGENT_DIR="${HOME}/Library/LaunchAgents"
AGENT_PLIST="${AGENT_DIR}/com.oc.sleephooks.plist"
LOG_FILE="${HOME}/Library/Logs/oc-sleep-hooks.log"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/${UID_NUM}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo "  安装睡眠 hook：入睡关蓝牙/Wi-Fi，外接屏息屏；唤醒按原状态恢复。"
    echo "  卸载: ${SCRIPT_DIR}/uninstall-sleep-hooks.sh"
    exit 0
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: 不要用 sudo 运行此脚本（LaunchAgent 需装到登录用户）。" >&2
  echo "  请用: ${SCRIPT_DIR}/oc-setup.sh sleep install" >&2
  exit 1
fi

echo "==> Checking Homebrew dependencies..."
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install from https://brew.sh" >&2
  exit 1
fi

for pkg in sleepwatcher blueutil; do
  if ! brew list "$pkg" &>/dev/null; then
    echo "    Installing $pkg..."
    brew install "$pkg"
  else
    echo "    $pkg already installed"
  fi
done

SLEEPWATCHER="$(brew --prefix sleepwatcher)/sbin/sleepwatcher"
if [[ ! -x "$SLEEPWATCHER" ]]; then
  echo "sleepwatcher binary not found at $SLEEPWATCHER" >&2
  exit 1
fi

echo "==> Installing hook scripts to ${HOOK_DIR}"
mkdir -p "$HOOK_DIR" "$(dirname "$LOG_FILE")"
install -m 755 "${SCRIPT_DIR}/sleep-pre.sh" "${HOOK_DIR}/sleep-pre.sh"
install -m 755 "${SCRIPT_DIR}/sleep-wake.sh" "${HOOK_DIR}/sleep-wake.sh"

cat >"$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.oc.sleephooks</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SLEEPWATCHER}</string>
		<string>-V</string>
		<string>-s</string>
		<string>${HOOK_DIR}/sleep-pre.sh</string>
		<string>-w</string>
		<string>${HOOK_DIR}/sleep-wake.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

launchctl bootout "$GUI_DOMAIN" "$AGENT_PLIST" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PLIST"

echo "==> Done."
echo "    Hooks:  ${HOOK_DIR}/sleep-{pre,wake}.sh"
echo "    Agent:  com.oc.sleephooks"
echo "    Log:    ${LOG_FILE}"
echo ""
echo "测试: 睡眠后日志应有 bluetooth/wifi off；唤醒后 restored。"
echo "HDMI: 外接屏会 displaysleepnow，但插线时端口仍可能有微量待机功耗。"
echo "USB 鼠标睡眠前仍建议拔掉。"
