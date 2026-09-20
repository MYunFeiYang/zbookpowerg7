#!/bin/bash
# Round 3 (hbfx-ahbm) 唤醒后核验 —— 只读，不做任何写操作
# 用法：bash docs/sleep-tests/round3-verify.sh
# 目的：判「ahbm 有没有让这次睡眠变成真休眠」以及「平台能不能穿过去」

echo "########## Round 3 唤醒后核验 ##########"
echo "现在时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo

echo "=== [1] ★ 核心判据：本次睡眠的类型（成功 = 出现 Entering Hibernate）==="
pmset -g log 2>/dev/null | grep -E "Entering Sleep|Entering Hibernate|Entering Standby|Wake from|Hibernate|Sleep  " | tail -40
echo

echo "=== [1b] ★ 睡眠流程是否「真的启动过」——比上一条更早的阶段 ==="
echo "  判据：'Display is turned off' = 睡眠流程第一步已执行"
echo "       'darkwakelinger'      = powerd 进入睡眠协商（15s linger）"
echo "       'DarkWake'            = 曾经睡下去又被唤醒"
pmset -g log 2>/dev/null | grep -iE "Display is turned|darkwakelinger|acwakelinger|Entering DarkWake|Wake from" | tail -12
echo "  ⚠️ 若只看到 Display is turned off + darkwakelinger、没有 Entering Sleep"
echo "     ⇒ 睡眠流程启动了但被【打断】（常见原因：有人在 linger 期内操作机器 / 跑命令）"
echo

echo "=== [2] kern.hibernatecount（>0 = 内核侧真发生过休眠）==="
sysctl -n kern.hibernatecount 2>/dev/null
echo

echo "=== [3] sleepimage 是否生成（出现且 >=8GiB = 镜像写成功）==="
ls -la /System/Volumes/VM/ 2>/dev/null
echo

echo "=== [4] NVRAM 休眠变量（HibernationFixup 的 NVRAM 通路是否被用过）==="
nvram -p 2>/dev/null | grep -iE "hibernat" || echo "  (无 —— 与上次失败签名一致)"
echo

echo "=== [5] 启动时间（判断本次唤醒是「冷启动」还是「从镜像恢复」）==="
sysctl -n kern.boottime
echo

echo "=== [6] 现役 pmset（测后要回滚：hibernatemode 0 / standby 0）==="
pmset -g 2>/dev/null | grep -E "hibernatemode|standby|standbydelay"
echo

echo "=== [7] gate 属性（Standby Enabled 是否还在 Yes）==="
ioreg -rn IOPMrootDomain -d 1 2>/dev/null | grep -E "\"Standby Enabled\"|\"Standby Delay\""
echo

echo "=== [8] panic / 断电痕迹 ==="
ls -la /Library/Logs/DiagnosticReports/*.panic 2>/dev/null | tail -5 || echo "  (无 panic 文件)"
echo

echo "=== [9] HibernationFixup 实例计数（确认 kext 仍在跑）==="
echo "  ⚠️ 注意：ioreg 的 Classes 段格式是 \"HibernationFixup\"=1（等号两侧【无空格】）"
ioreg -d 0 -l -w0 2>/dev/null | grep -oE '"HibernationFixup"=[0-9]+' | sort -u
ioreg -d 0 -l -w0 2>/dev/null | grep -oE '"(RTCMemoryFixup|Lilu|X86PlatformPlugin|X86PlatformShim)"=[0-9]+' | sort -u
echo
echo "########## 核验结束 ##########"
