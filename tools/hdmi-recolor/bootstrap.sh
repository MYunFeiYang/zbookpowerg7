#!/bin/bash
# bootstrap.sh — 重装系统 / 换机后，一条命令重建「外接屏热插拔泛红自动修复」
#
# 用法：  bash bootstrap.sh          （可选：先 sudo xcode-select --install 装编译工具）
#
# 做的事：
#   1. 编译两个工具到 ~/automation-workspace（LaunchAgent 指向该目录）
#   2. 装 LaunchAgent（常驻 watcher，登录后自动拉活）
#   3. 放置「修复外接屏泛红.command」双击兜底
#   4. 跑一次 --plan 自检，打印它打算怎么修
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/automation-workspace"
mkdir -p "$BIN_DIR"

echo "== 1/4 检查编译环境 =="
if ! command -v clang >/dev/null 2>&1; then
    echo "   ✗ 没有 clang。先执行： xcode-select --install   装完再重跑本脚本。"
    exit 1
fi
echo "   clang: $(clang --version | head -1)"

echo "== 2/4 编译 =="
clang -O2 -o "$BIN_DIR/hdmi-recolor" "$DIR/hdmi-recolor.c" \
      -framework ApplicationServices || { echo "   ✗ hdmi-recolor 编译失败"; exit 1; }
echo "   hdmi-recolor OK"
clang -O2 -o "$BIN_DIR/hdmi-recolor-watch" "$DIR/hdmi-recolor-watch.c" \
      -framework ApplicationServices -framework IOKit -framework CoreFoundation \
      || { echo "   ✗ hdmi-recolor-watch 编译失败"; exit 1; }
echo "   hdmi-recolor-watch OK"

echo "== 3/4 安装常驻服务 =="
cp "$DIR/install-hdmi-agent.sh" "$BIN_DIR/install-hdmi-agent.sh"
chmod +x "$BIN_DIR/install-hdmi-agent.sh"
bash "$BIN_DIR/install-hdmi-agent.sh" || echo "   ⚠ 安装脚本返回非 0，请检查上面的输出"

cp "$DIR/修复外接屏泛红.command" "$BIN_DIR/修复外接屏泛红.command"
chmod +x "$BIN_DIR/修复外接屏泛红.command"

echo "== 4/4 自检 =="
"$BIN_DIR/hdmi-recolor" --plan
echo
echo "服务状态："
launchctl print "gui/$(id -u)/com.thinkway.hdmi-recolor" 2>&1 | grep -E "state =|pid =" | head -3
echo
echo "完成。日志：$BIN_DIR/hdmi-recolor.log"
