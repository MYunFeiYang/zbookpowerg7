#!/bin/sh
# Round 3 内核日志导出 v3 —— 睡眠瞬间的完整 kernel 轨迹（不截断）
# 用法（WorkBuddy 侧）：osascript -e 'do shell script "<本文件绝对路径>" with administrator privileges'
#   —— 走系统授权助手，进程不在 WorkBuddy 沙箱内（实测 uid=0 可跑 `log`）
# v3 变更：v2 的 [B] 段被 head -80 截断在开机时刻，没看到睡眠瞬间；
#          本次改成【窄时间窗 + process == kernel + 不截断】
OUT=/Volumes/Common/workplace/zbookpowerg7/docs/sleep-tests/round3-kernel.log
W=/Volumes/Common/workplace/zbookpowerg7/docs/sleep-tests/round3-kernel.err

: > "$OUT"
: > "$W"

dump() {   # $1=label  $2=start  $3=end
  echo
  echo "########## $1  ($2 -> $3) ##########"
  /usr/bin/log show --start "$2" --end "$3" --info --debug --style compact \
      --predicate 'process == "kernel"' 2>>"$W"
  echo "  [$1] rc=$?"
}

{
  echo "=== dump v3 start $(date '+%F %T') | uid=$(id -u) ==="

  dump "SLEEP-1 窗口（pmset 请求 17:25:08，实际入睡 17:25:37）" "2026-09-20 17:25:34" "2026-09-20 17:25:46"
  dump "SLEEP-2 窗口（入睡 17:34:48）" "2026-09-20 17:34:45" "2026-09-20 17:34:57"
  dump "WAKE-1 窗口" "2026-09-20 17:28:28" "2026-09-20 17:28:36"

  echo
  echo "########## HBFX 复查（--info --debug，无时间窗限制，全量） ##########"
  /usr/bin/log show --last 30m --info --debug --style compact \
      --predicate 'eventMessage CONTAINS "HBFX"' 2>>"$W"
  echo "  [HBFX] rc=$?"

  echo
  echo "########## 错误 ##########"
  cat "$W"

  echo
  echo "=== dump v3 end $(date '+%F %T') ==="
} >> "$OUT" 2>&1

echo "done -> $OUT"
