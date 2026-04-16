#!/bin/sh
# 在 macOS 本机执行（需管理员密码）。收紧「被网络/TCP/接近传感器等唤醒」的策略。
# 说明：USB 设备唤醒没有单一 pmset 总开关，仍靠拔线或 USB 映射/机型对照；
# OpenCore 的 config.plist 里也没有等价于「禁用全部 USB 唤醒」的一项。

set -e
sudo pmset -a womp 0
sudo pmset -a powernap 0
sudo pmset -a tcpkeepalive 0
sudo pmset -a proximitywake 0
echo "Done. Current settings:"
pmset -g

# --- DeepIdle / S0 省电（可选，按需取消注释执行）---
# 目标：关屏后更多停留在 S0 + LPS0，而不是立刻进传统睡眠（与 SSDT-DeepIdle 思路一致）。
# 数值请按习惯改；sleep=0 表示「不设系统睡眠定时」，仅显示器睡眠（耗电仍高于真 S3）。
# sudo pmset -a displaysleep 10
# sudo pmset -a sleep 0
# sudo pmset -a lessbright 1
# sudo pmset -a lowpowermode 1

# --- 合盖关机（睡眠不可靠时可选）---
# 同目录：./install-lid-shutdown.sh  或  ./install-lid-shutdown.sh --skip-pmset
# 卸载：./uninstall-lid-shutdown.sh [--restore-sleep]
