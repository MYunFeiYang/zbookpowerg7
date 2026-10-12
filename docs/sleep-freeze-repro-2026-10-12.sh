#!/bin/zsh
# 长睡 freeze 复现 + 取证脚本（在黑苹果真机运行）
# 背景：sleep 约30分钟后 freeze、长按电源强制重启（非崩溃、无 panic）。
#       社区（dortania）对"无声卡死"的标准诊断：用 swd_panic=1/keepsyms=1
#       把静默 hang 逼成可查的 panic 日志；配合 log stream 实时抓电源/IGPU/XHCI/蓝牙事件。
# 用法：把本文件拷到 Mac，chmod +x，sudo zsh sleep-freeze-repro.sh
# 前置：config.plist 已含 swd_panic=1 keepsyms=1（见 commit 修正方案）

echo "=== 0. 关闭后台唤醒干扰（dortania 标配，仅本次会话生效）==="
sudo pmset -a powernap 0
sudo pmset -a tcpkeepalive 0
sudo pmset -a proximitywake 0
sudo pmset -a autorestart 0
echo "当前关键电源设置:"
pmset -g | grep -iE "powernap|tcpkeepalive|proximitywake|hibernatemode|standby|autopoweroff|displaysleep|sleep "

LOGDIR=~/sleep_forensics_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOGDIR"
echo "日志目录: $LOGDIR"

echo "=== 1. 启动 log stream（电源/IGPU/AGPM/XHCI/蓝牙 事件）==="
nohup /usr/bin/log stream --predicate 'process == "powerd" OR process == "kernel" OR subsystem CONTAINS "com.apple.power" OR senderImagePath CONTAINS "AppleGraphics" OR senderImagePath CONTAINS "AppleIntel" OR senderImagePath CONTAINS "IOUSB" OR senderImagePath CONTAINS "Blue" OR eventMessage CONTAINS[c] "IGPU" OR eventMessage CONTAINS[c] "AGPM" OR eventMessage CONTAINS[c] "XHCI" OR eventMessage CONTAINS[c] "sleep" OR eventMessage CONTAINS[c] "wake" OR eventMessage CONTAINS[c] "Entering" OR eventMessage CONTAINS[c] "panic"' --style syslog > "$LOGDIR/sleep_trace.log" 2>&1 &
LOGPID=$!

echo "=== 2. 每 30s dump IGPU 电源态 ==="
( while true; do
    echo "=== $(date) ==="
    echo "--- IGPU ---"
    ioreg -n IGPU -r 2>/dev/null | grep -A5 IOPowerManagement
    echo "--- XHCI/USB 控制器 ---"
    ioreg -l -w0 2>/dev/null | grep -iE '"(XHCI|XHC|AppleUSBXHCI|RHUB)"' | head -3
    sleep 30
  done ) >> "$LOGDIR/igpu_state.log" 2>&1 &
DUMPPID=$!

echo ""
echo "[OK] 取证已启动"
echo "   log stream pid = $LOGPID  -> $LOGDIR/sleep_trace.log"
echo "   dump pid      = $DUMPPID  -> $LOGDIR/igpu_state.log"
echo ""
echo "[复现步骤]"
echo "  A. 短睡对照: 合盖 或 'sudo pmset sleepnow'，等 ~2 分钟，唤醒，看 trace 里 IGPU 是否平滑 sleep->wake"
echo "  B. 长睡复现: 再合盖/sleepnow，睡 >=40 分钟（覆盖上次 ~30min 失败阈值）"
echo "  C. 尝试唤醒；若屏幕不亮/无响应 -> 长按电源强制重启"
echo "  D. 重启后【别清日志】，把 $LOGDIR 目录给我（或说'跑完了'）"
echo ""
echo "[中断取证] kill $LOGPID $DUMPPID"
