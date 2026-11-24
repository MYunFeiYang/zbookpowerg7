#!/bin/bash
# install-hdmi-agent.sh — 安装/重装 外接屏泛红自动修复服务（LaunchAgent）
#
# 为什么要绕一圈 applet：
#   我们的 shell 进程不在 GUI 会话的 bootstrap 命名空间里，直接 launchctl bootstrap
#   gui/501 会报 "Bootstrap failed: 5: Input/output error"。
#   而通过 LaunchServices(open) 启动的进程处于真实 Aqua 会话，可以正常写入 gui 域。
set -u

LABEL=com.thinkway.hdmi-recolor
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/automation-workspace/hdmi-recolor-watch"
LOG="$HOME/automation-workspace/hdmi-recolor.log"
RESULT=/tmp/hdmi-agent-install.log

[ -x "$BIN" ] || { echo "缺少可执行文件：$BIN"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null || { echo "plist 校验失败"; exit 1; }

# 用 applet 在 GUI 会话里注册（无需管理员权限，不弹密码框）
rm -f "$RESULT"
osacompile -o /tmp/hdmi-agent-installer.app -e \
"do shell script \"launchctl bootout gui/$(id -u)/$LABEL >/dev/null 2>&1; launchctl bootstrap gui/$(id -u) '$PLIST' > '$RESULT' 2>&1; sleep 2; launchctl print gui/$(id -u)/$LABEL >> '$RESULT' 2>&1; echo DONE >> '$RESULT'\""

open /tmp/hdmi-agent-installer.app
sleep 6
rm -rf /tmp/hdmi-agent-installer.app

echo "--- 安装输出 ---"
cat "$RESULT" 2>/dev/null | tail -20
echo "--- 服务状态 ---"
launchctl print "gui/$(id -u)/$LABEL" 2>&1 | grep -E "state =|pid =|last exit" | head -5
echo "--- 运行日志 ---"
tail -6 "$LOG" 2>/dev/null
