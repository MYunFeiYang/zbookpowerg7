#!/bin/bash
# wb-r3b-watch.sh —— R3b 看守（launchd LaunchDaemon / root）
#
#  作用①「冷启动检测」：若 ARM 标记里的 boottime 与当前 boottime 不同 ⇒ 说明上一轮 R3b
#        没正常收尾（硬断电/重启）⇒ **立刻回滚 pmset**，把危险配置关掉。
#  作用②「唤醒检测」：等"机器真的睡过并被唤醒" ⇒ 先取证（回滚前！）⇒ 立刻回滚 ⇒ 抓内核日志 ⇒ 自清。
#
#  由 wb-r3b-run.sh 安装为 /Library/LaunchDaemons/com.wb.r3b.watch.plist（RunAtLoad）
set -u

REPO=/Volumes/Common/workplace/zbookpowerg7
OUT="$REPO/docs/sleep-tests/r3b-artifacts"
mkdir -p "$OUT" 2>/dev/null || OUT=/var/log          # 冷启动时外置卷可能未挂载 ⇒ 退回内部盘
LOG="$OUT/watch.log"
exec >> "$LOG" 2>&1

SELF_PLIST=/Library/LaunchDaemons/com.wb.r3b.watch.plist
SELF_SCRIPT=/usr/local/bin/wb-r3b-watch.sh
ARMFILE="$OUT/.armed"

ROLLBACK() { pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400; }
CLEANUP()  { rm -f "$SELF_PLIST" "$SELF_SCRIPT" "$ARMFILE"; launchctl bootout system/com.wb.r3b.watch 2>/dev/null; }

echo "================================================================"
echo "WATCH START $(date '+%F %T')  pid=$$  uid=$(id -u)  OUT=$OUT"

# ---------------- 0. 冷启动检测 ----------------
# ★ 必须锚定行首 "{ sec = "：否则 ".*sec = " 会贪婪匹配到 "usec = 152327" ⇒ 拿到错误值（本文件 v1 踩过）
bt_now=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+).*/\1/')
if [ ! -f "$ARMFILE" ]; then
  echo "无 ARM 标记 ⇒ 陈旧实例，自清退出"
  CLEANUP; exit 0
fi
bt_arm=$(awk '{print $1}' "$ARMFILE")
echo "boottime: arm=$bt_arm now=$bt_now"
if [ "$bt_arm" != "$bt_now" ]; then
  echo "!! 冷启动：上一轮未正常收尾 ⇒ 立即回滚 pmset"
  ROLLBACK
  { echo "=== 冷启动回滚 $(date '+%F %T') ==="; pmset -g custom | grep -iE "standbydelay|hibernatemode|standby"; } > "$OUT/boot-rollback.txt" 2>&1
  echo "BOOT-ROLLBACK $(date '+%F %T')" > "$OUT/MARKER"
  CLEANUP; exit 0
fi

# ---------------- 1. 基线计数 ----------------
sleep_before=$(pmset -g log 2>/dev/null | grep -ac "Entering Sleep state")
wake_before=$(pmset -g log 2>/dev/null | grep -ac "Wake from")
echo "基线: Entering Sleep=$sleep_before  Wake from=$wake_before  （等入睡并被唤醒）"

# ---------------- 2. 轮询等"睡过并醒" ----------------
start=$(date +%s); last=$start; n=0
cond=""
while :; do
  sleep 10; n=$((n+1))
  now=$(date +%s); gap=$((now - last))
  slept=$(pmset -g log 2>/dev/null | grep -ac "Entering Sleep state")
  woke=$(pmset -g log 2>/dev/null | grep -ac "Wake from")
  if [ "$woke" -gt "$wake_before" ]; then cond="wake-line+$((woke-wake_before))"; break; fi
  if [ "$slept" -gt "$sleep_before" ] && [ "$gap" -ge 20 ]; then cond="sleep-line+$((slept-sleep_before))/gap${gap}s"; break; fi
  if [ "$gap" -ge 120 ]; then cond="wallgap${gap}s"; break; fi
  last=$now
  if [ $((now - start)) -ge 2400 ]; then cond="TIMEOUT40min"; break; fi
done
echo "*** 检出：cond=$cond  at $(date '+%F %T')  轮次=$n ***"

# ---------------- 3. 唤醒后快照（★ 必须在回滚之前） ----------------
{
  echo "=== 唤醒后快照 $(date '+%F %T')  触发=$cond ==="
  echo "--- sysctl ---";        sysctl kern.hibernatemode kern.hibernatecount kern.boottime
  echo "--- sleepimage ---";    ls -la /var/vm/sleepimage
  echo "--- pmset custom ---";  pmset -g custom | grep -iE "standbydelay|hibernatemode|standby|hibernatefile"
  echo "--- pmset 日志尾部 ---"; pmset -g log 2>/dev/null | grep -aE "Entering Sleep|Wake from|Hibernate|Standby|DarkWake|Sleep state" | tail -45
  echo "--- ioreg ---";         ioreg -rc IOPMrootDomain 2>/dev/null | grep -aiE "SleepType|Hibernate|Standby|IOHibernateState|WakeReason"
  echo "--- nvram ---";         nvram -p 2>/dev/null | grep -aiE "hibernate" || echo "(无休眠变量)"
} > "$OUT/postwake-snapshot.txt" 2>&1
echo "快照已写 postwake-snapshot.txt"

# ---------------- 4. ★ 立刻回滚 ----------------
ROLLBACK
{ echo "--- 回滚后 ---"; pmset -g custom | grep -iE "standbydelay|hibernatemode|standby"; echo "ROLLBACK-DONE $(date '+%F %T')"; } >> "$OUT/postwake-snapshot.txt"
echo "回滚完成 $(date '+%F %T')"

# ---------------- 5. 内核日志（重活放最后） ----------------
log show --last 60m --info --debug --predicate 'process == "kernel"' --style syslog > "$OUT/kernel-postwake.log" 2>&1
grep -aE "PMRD:|HBFX|hibernateMode|sleepType|Wake reason|hibernat" "$OUT/kernel-postwake.log" | tail -400 > "$OUT/pmrd-postwake.txt"
echo "内核日志行数=$(wc -l < "$OUT/kernel-postwake.log")  PMRD/筛选行数=$(wc -l < "$OUT/pmrd-postwake.txt")"

echo "DONE $(date '+%F %T')" > "$OUT/MARKER"
CLEANUP
echo "自清完成，看守退出"
exit 0
