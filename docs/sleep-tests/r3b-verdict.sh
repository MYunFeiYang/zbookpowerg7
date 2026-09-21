#!/bin/bash
# wb-r3b-verdict.sh —— R3b 事后取证（必须在回滚之前跑，uid=0）
#   目的：判定 2026-09-20 19:02:41 那次睡眠到底是
#         (a) 软失败 = 与 R3 相同（type5→type7，Deep Idle）
#         (b) 硬失败 = 真休眠/断气（09-16 同档）
#         (c) 从未真正换档、只是看门狗挂了
#   调用：osascript -e 'do shell script "bash \"<此脚本>\"" with administrator privileges'
set -u

BASE=""
for d in "/Volumes/Common 1/workplace/zbookpowerg7" "/Volumes/Common/workplace/zbookpowerg7"; do
  [ -d "$d/docs/sleep-tests" ] && BASE="$d" && break
done
[ -z "$BASE" ] && BASE="/Volumes/Common 1/workplace/zbookpowerg7"
OUT="$BASE/docs/sleep-tests/r3b-artifacts"
mkdir -p "$OUT"
R="$OUT/verdict-$(date '+%m%d-%H%M%S').txt"
exec > "$R" 2>&1

echo "=== R3b 事后取证 $(date '+%F %T')  uid=$(id -u)  BASE=$BASE ==="

echo; echo "--- [1] 当前系统 ---"
sysctl kern.boottime kern.hibernatemode kern.hibernatecount
uptime

echo; echo "--- [2] sleepimage 真实元数据（判据⑤）---"
stat -f "%N size=%z mtime=%Sm" -t "%F %T" /var/vm/sleepimage 2>&1
ls -la@ /var/vm/sleepimage 2>&1

echo; echo "--- [3] 本轮启动是不是「从休眠恢复」？（找 IOHibernateState / Hibernate）---"
log show --start "2026-09-21 08:50:00" --end "2026-09-21 08:58:00" --info --debug --predicate 'process == "kernel"' 2>/dev/null \
  | grep -aiE "hibernate|Wake reason|IOHibernateState|boot-args|Darwin Kernel Version" | head -40
echo "(若上面为空 ⇒ 本段无休眠恢复痕迹)"

echo; echo "--- [4] 09-20 19:01~19:12 内核轨迹（R3b 那次睡眠）---"
log show --start "2026-09-20 19:01:00" --end "2026-09-20 19:12:00" --info --debug --predicate 'process == "kernel"' 2>/dev/null \
  | grep -aE "PMRD:|HBFX|hibernateMode|hibernateDisabled|sleepType|Hibernate|Wake reason|Sleep Type|darkwake" | head -120

echo; echo "--- [5] 09-20 21:03~21:12 内核轨迹（第二次睡眠，standbydelay 仍为 0）---"
log show --start "2026-09-20 21:03:00" --end "2026-09-20 21:12:00" --info --debug --predicate 'process == "kernel"' 2>/dev/null \
  | grep -aE "PMRD:|HBFX|hibernateMode|hibernateDisabled|sleepType|Hibernate|Wake reason|Sleep Type" | head -120

echo; echo "--- [6] 电源事件（09-20 19:00 ~ 09-21 09:00）---"
pmset -g log 2>/dev/null | grep -aE "^2026-09-2[01]" | grep -aE "Entering Sleep|Wake from|Hibernate|Standby|Sleep Type|WakeTime|Assertion.*Prevent" | sed -n '/2026-09-20 19:00/,$p' | head -60

echo; echo "--- [7] 09-20 19:00 之后 PSH/BIOS 侧异常 ---"
pmset -g log 2>/dev/null | grep -aiE "CMOS|rtc|005|shutdown|restart cause|panic" | tail -30

echo; echo "--- [8] sleepimage 里是否有有效镜像（前 16 字节魔数）---"
xxd -l 16 /var/vm/sleepimage 2>&1 | head -2
echo "（Hibernate image 头部通常是 'hibernate image' 或全 0 占位）"

echo; echo "--- [9] NVRAM 休眠变量 ---"
nvram -p 2>/dev/null | grep -aiE "hibernate" || echo "(无)"

echo; echo "--- [10] ioreg IOPMrootDomain ---"
ioreg -rc IOPMrootDomain 2>/dev/null | grep -aiE "SleepType|Hibernate|Standby|IOHibernateState|WakeReason|Last Sleep" | head -30

echo; echo "--- [11] 崩溃报告（09-20 19:00 起）---"
ls -lat /Library/Logs/DiagnosticReports/ 2>/dev/null | head -25

echo; echo "=== 取证结束 ==="
echo "结果文件: $R"
