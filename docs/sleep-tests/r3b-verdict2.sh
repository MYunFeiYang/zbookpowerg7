#!/bin/bash
# wb-r3b-verdict2.sh —— R3b 事后取证 v2（聚焦三处：日志缺口 / 2019 时钟那次 boot / 看门狗冷启动）
set -u

BASE=""
for d in "/Volumes/Common 1/workplace/zbookpowerg7" "/Volumes/Common/workplace/zbookpowerg7"; do
  [ -d "$d/docs/sleep-tests" ] && BASE="$d" && break
done
[ -z "$BASE" ] && BASE="/Volumes/Common 1/workplace/zbookpowerg7"
OUT="$BASE/docs/sleep-tests/r3b-artifacts"
mkdir -p "$OUT"
R="$OUT/verdict2-$(date '+%m%d-%H%M%S').txt"
exec > "$R" 2>&1

echo "=== R3b 取证 v2 $(date '+%F %T') uid=$(id -u) ==="

echo; echo "--- [A] 看门狗冷启动回退路径的落点 ---"
for f in /var/log/watch.log /var/log/MARKER /var/log/wb-r3b-watch.out /var/log/wb-r3b-watch.err; do
  printf "%s : " "$f"; [ -e "$f" ] && stat -f "存在 size=%z mtime=%Sm" -t "%F %T" "$f" || echo "不存在"
done
echo "--- /var/log 下 r3b/watch 相关 ---"
ls -la /var/log/ 2>/dev/null | grep -aiE "r3b|watch|MARKER" || echo "(无)"
echo "--- LaunchDaemons 现状 ---"
ls -la /Library/LaunchDaemons/ 2>/dev/null | head -20

echo; echo "--- [B] 19:01:00~19:08:30 内核日志【不加关键词过滤】行数 ---"
log show --start "2026-09-20 19:01:00" --end "2026-09-20 19:08:30" --info --debug --predicate 'process == "kernel"' 2>/dev/null | wc -l
echo "--- 上面窗口的原始前 25 行 ---"
log show --start "2026-09-20 19:01:00" --end "2026-09-20 19:08:30" --info --debug --predicate 'process == "kernel"' 2>/dev/null | sed -n '1,25p'

echo; echo "--- [B2] 19:01:00~19:08:30 是否存在 Sleep 流程标志串 ---"
log show --start "2026-09-20 19:01:00" --end "2026-09-20 19:08:30" --info --debug 2>/dev/null \
  | grep -aiE "sleepWake UUID|sleep reason|askChangeDown|tellChangeDown|WillSleep|hibernateMode|sleep params|SLEEP_STATE" | head -30
echo "(空 ⇒ 该窗口无睡眠流程记录)"

echo; echo "--- [C] 2019-01-01 08:00:00~08:03:00 那次 boot 的身份 ---"
log show --start "2019-01-01 08:00:00" --end "2019-01-01 08:03:00" --info --debug --predicate 'process == "kernel"' 2>/dev/null | sed -n '1,30p'
echo "--- 该窗口行数 ---"
log show --start "2019-01-01 08:00:00" --end "2019-01-01 08:03:00" --info --debug --predicate 'process == "kernel"' 2>/dev/null | wc -l

echo; echo "--- [D] 时钟证据：2019-01-01 前后内核挂钟记 ------------------------------------------------------------------"
log show --start "2019-01-01 07:59:00" --end "2019-01-01 08:02:30" --info --debug --predicate 'process == "kernel"' 2>/dev/null \
  | grep -aE "PMRD: |boot|Darwin|sleep" | head -40

echo; echo "--- [E] 系统日志里的时钟回退/校正 ---"
log show --start "2026-09-20 19:00:00" --end "2026-09-21 09:00:00" --info 2>/dev/null \
  | grep -aiE "timed? is (now|not)|clock|settimeofday|ntp|rtc" | head -30

echo; echo "--- [F] sleep/wake 失败报告 ---"
ls -la /Library/Logs/DiagnosticReports/ 2>/dev/null | grep -aiE "sleep|wake|panic|stackshot|spindump" || echo "(无)"
echo "--- /var/db/PowerManagement ---"
ls -la /var/db/PowerManagement/ 2>/dev/null | head
echo "--- 当前 sleep-wake failure 计数 ---"
pmset -g log 2>/dev/null | grep -aiE "sleep wake fail|failure|SMC shutdown" | tail -12

echo; echo "=== 结束 ==="
echo "结果: $R"
