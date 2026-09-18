#!/bin/bash
#
# sleep-power-measure.sh —— 睡眠功耗实测工具（HP ZBook Power G7 / Deep Idle）
#
# 为什么要它：
#   本机长期引用的"≈5 W / ≈7 %/h"其实是**社区区间估算**，不是本机实测。
#   2026-09-17 唯一一次真测（50 min、裸机、电池、WiFi 开）得到 11.2 %/h ≈ 7.2 W（round3）。
#   而 50 min 采样会被"入睡后维护期"拉高，电量计又在 09-17 之后由 MaxCapacity 5536 → 5953 重标定
#   ⇒ 旧读数跨日不可直接比。**任何进一步"压功耗"之前，必须先有可重复的真值。**
#
# 用法：
#   tools/sleep-power-measure.sh status            # 现况：电源/电池/睡眠断言/计划唤醒
#   tools/sleep-power-measure.sh arm <标签>        # 睡前打点（记录精确 mAh / 电压 / 时刻）
#   tools/sleep-power-measure.sh report [--save]   # 醒后结算（默认结算日志里最后一个 sleep→wake 区间）
#
# 口径（与电量计百分比解耦，跨日可比）：
#   掉电率 %/h = ΔmAh ÷ 起始 MaxCapacity ÷ 小时数
#   功率   W   ≈ (ΔmAh/h) ÷ 1000 × 平均电压 V      ← 取 睡前/醒后 两次 Voltage 的均值
#   无 arm 快照时退化为 pmset 日志的 `Charge:N%` 字段（1 % 分辨率）⇒ 结果标注「粗测」
#
# 注意：
#   - 必须在**电池供电**下测（AC 下电池不放电，ΔmAh≈0）—— 脚本会检查并提醒。
#   - arm 与 report 之间不要重启（重启后日志窗口语义不同）。
#   - 本工具只读，不改任何系统设置。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/docs/sleep-tests/power-samples"
LOG_TXT="/tmp/spm-pmlog.txt"
mkdir -p "$STORE"

field() { # field <AppleSmartBattery 属性名> —— 取顶层第一个匹配
  ioreg -rn AppleSmartBattery -w0 2>/dev/null |
    grep -m1 "\"$1\" = " |
    sed -E 's/.*= *"?([0-9]+)"?.*/\1/'
}

batt_line() {
  local cc mx vv cy
  cc=$(field CurrentCapacity); mx=$(field MaxCapacity); vv=$(field Voltage); cy=$(field CycleCount)
  printf 'mAh=%s/%s (%.1f%%)  V=%.3f  cycles=%s' \
    "${cc:-?}" "${mx:-?}" \
    "$(echo "${cc:-0} ${mx:-1}" | awk '{printf "%.1f", ($2>0? $1*100/$2 : 0)}')" \
    "$(echo "${vv:-0}" | awk '{printf "%.3f", $1/1000}')" "${cy:-?}"
}

on_ac() { pmset -g batt | grep -q "AC Power" && echo yes || echo no; }

case "${1:-status}" in
status)
  echo "== 电源 =="
  pmset -g batt | head -3
  echo "供电: $( [ "$(on_ac)" = yes ] && echo 'AC（⚠️ 不能做睡眠掉电测量，需拔适配器）' || echo '电池' )"
  echo "== 电池 =="
  echo "  $(batt_line)"
  echo "== 睡眠断言 =="
  pmset -g assertions | sed -n '/Assertion status/,/^$/p' | head -12
  echo "== 待触发的计划唤醒（RTC 暗唤醒）=="
  pmset -g sched | sed -n '2,6p'
  ;;

arm)
  label="${2:-unlabeled}"
  ts=$(date +%s); human=$(date '+%Y-%m-%d %H:%M:%S %z')
  cc=$(field CurrentCapacity); mx=$(field MaxCapacity); vv=$(field Voltage)
  cy=$(field CycleCount); ac=$(on_ac)
  printf '{"kind":"arm","label":"%s","ts":%s,"time":"%s","mAh":%s,"max_mAh":%s,"voltage_mV":%s,"cycles":%s,"on_ac":"%s"}\n' \
    "$label" "$ts" "$human" "${cc:-0}" "${mx:-0}" "${vv:-0}" "${cy:-0}" "$ac" >> "$STORE/arms.jsonl"
  echo "已打点 [$label] $human"
  echo "  $(batt_line)"
  [ "$ac" = yes ] && echo "  ⚠️ 当前是 AC 供电 —— 睡眠期间电池不放电。若要做掉电测量，请先拔掉适配器再打点。"
  echo "  ⇒ 现在：合盖（或 菜单→睡眠）。醒来后跑：tools/sleep-power-measure.sh report"
  ;;

report)
  pmset -g log > "$LOG_TXT" 2>/dev/null
  S_T=$(awk '/Entering Sleep state/ { t=$1" "$2 } END { print t }' "$LOG_TXT")
  W_T=$(awk '/from (Deep Idle|Normal Sleep|Standby|S3|S4)/ { t=$1" "$2 } END { print t }' "$LOG_TXT")
  [ -z "${S_T:-}" ] || [ -z "${W_T:-}" ] && { echo "日志里找不到 sleep → wake 对，无法结算。"; exit 1; }

  se=$(date -j -f "%Y-%m-%d %H:%M:%S" "$S_T" +%s 2>/dev/null)
  we=$(date -j -f "%Y-%m-%d %H:%M:%S" "$W_T" +%s 2>/dev/null)
  [ "$we" -lt "$se" ] && { echo "⚠️ 最后一次唤醒早于最后一次入睡 —— 机器可能还在睡眠中，醒来后再跑。"; exit 1; }

  S_LINE=$(grep -m1 "^$S_T.*Entering Sleep state" "$LOG_TXT")
  W_LINE=$(grep -E -m1 "^$W_T.*from (Deep Idle|Normal Sleep|Standby)" "$LOG_TXT")

  dur=$(( we - se ))
  hours=$(echo "$dur" | awk '{printf "%.4f", $1/3600}')

  stype=$(echo "$W_LINE" | sed -E 's/.*(Wake|DarkWake) from //; s/ \[.*//')
  wreason=$(echo "$W_LINE" | sed -E 's/.*: due to //; s/ Using .*//')
  ssrc=$(echo "$S_LINE" | sed -E "s/.*due to '//; s/'.*//")
  wtime=$(grep -m1 "^$W_T.*WakeTime:" "$LOG_TXT" | sed -E 's/.*WakeTime: *([0-9.]+) sec.*/\1/')
  n_dark=$(awk -v a="$S_T" -v b="$W_T" '$0 ~ /DarkWake from/ { t=$1" "$2; if (t>=a && t<=b) c++ } END { print c+0 }' "$LOG_TXT")
  s_charge=$(echo "$S_LINE" | sed -E 's/.*Charge:([0-9]+)%.*/\1/')
  w_charge=$(echo "$W_LINE" | sed -E 's/.*Charge:([0-9]+)%.*/\1/')
  ac_sleep=$(echo "$S_LINE" | grep -q "Using AC" && echo yes || echo no)

  echo "== 睡眠区间 =="
  echo "  入睡: $S_T   [$ssrc]"
  echo "  唤醒: $W_T   [$stype / due to $wreason]"
  echo "  时长: ${dur}s ≈ $(echo "$hours" | awk '{printf "%.1f", $1*60}') min ($hours h)"
  echo "  区间内 DarkWake 数: $n_dark"
  [ -n "${wtime:-}" ] && echo "  WakeTime: ${wtime}s   （Deep Idle 正常基准 ≈2.4–2.8s）"
  echo "  供电: $( [ "$ac_sleep" = yes ] && echo 'AC' || echo '电池' )   pmset Charge: ${s_charge:-?}% → ${w_charge:-?}%"

  armed=$(awk -v b="$se" -v a="$we" '
    /"kind":"arm"/ {
      ts=$0; sub(/.*"ts":/,"",ts); sub(/,.*/,"",ts); ts=ts+0
      if (ts<=b) { s=$0 }
      if (ts> b && ts<=a) { e=$0 }
    }
    END { if (s!="" && e!="") print s"\n"e }' "$STORE/arms.jsonl" 2>/dev/null)

  if [ -n "$armed" ]; then
    get() { echo "$1" | sed -nE "s/.*\"$2\":([0-9.]+).*/\1/p"; }
    l1=$(echo "$armed" | sed -n 1p); l2=$(echo "$armed" | sed -n 2p)
    lab=$(echo "$l1" | sed -nE 's/.*"label":"([^"]*)".*/\1/p')
    c1=$(get "$l1" mAh); m1=$(get "$l1" max_mAh); v1=$(get "$l1" voltage_mV)
    c2=$(get "$l2" mAh); v2=$(get "$l2" voltage_mV)
    acc="精测（arm 快照 [$lab]：${c1} → ${c2} mAh）"
    dmAh=$(echo "$c1 $c2" | awk '{printf "%.1f", $1-$2}')
    vavg=$(echo "$v1 $v2" | awk '{printf "%.3f", ($1+$2)/2000}')
    basem="${m1:-0}"
  else
    acc="粗测（日志 Charge%，1% 分辨率 —— 下次请先 arm）"
    dmAh=$(echo "${s_charge:-0} ${w_charge:-0}" | awk '{printf "%.1f", $1-$2}')
    vavg=$(field Voltage | awk '{printf "%.3f", $1/1000}')
    basem=$(field MaxCapacity)
  fi

  echo
  echo "== 掉电结算 · $acc =="
  ph=$(echo "$dmAh $hours" | awk '{ if ($2>0) printf "%.2f", $1/$2; else print 0 }')
  wh=$(echo "$ph $vavg" | awk '{ printf "%.3f", $1/1000*$2 }')
  pcth=$(echo "$dmAh $basem $hours" | awk '{ if ($2>0 && $3>0) printf "%.2f", $1/$2/$3*100; else print "n/a" }')
  echo "  ΔmAh   = $dmAh   (平均电压 ${vavg} V)"
  echo "  掉电率 = ${pcth} %/h"
  echo "  功率   = ${ph} mAh/h ≈ ${wh} W"

  # 双口径对照：本机 ioreg mAh 与 pmset Charge% 历史上差近 2×（round3：9.4% vs 5%），必须并列看
  pcth_pm=$(echo "${s_charge:-0} ${w_charge:-0} $hours" | awk '{ if ($3>0) printf "%.2f", ($1-$2)/$3; else print "n/a" }')
  echo "  ★ 双口径对照：ioreg mAh → ${pcth} %/h ｜ pmset Charge → ${pcth_pm} %/h"
  if [ "$pcth_pm" != "n/a" ] && [ "$pcth" != "n/a" ] &&
     [ "$(echo "$pcth $pcth_pm" | awk '{ r=($2>0? $1/$2 : 0); print (r>1.5 || (r>0 && r<0.67)) ? 1 : 0 }')" = 1 ]; then
    echo "    ⚠️ 两口径相差 >1.5× —— 本机电量计（SMCBattery 仿真）内部不一致，绝对值只能当区间看。"
  fi
  if [ "$ac_sleep" = yes ]; then
    echo "  ⚠️ 本段是 AC 睡眠 —— 电池本就不放电，上面的数字**无物理意义**，仅供结构核对。"
  elif [ "$(echo "$dmAh" | awk '{print ($1<0)?1:0}')" = 1 ]; then
    echo "  ⚠️ ΔmAh 为负（睡眠期间电量上升）⇒ 中途充过电，本段作废。"
  fi
  echo
  echo "  对照：round3 实测 11.2 %/h（7.2 W；50 min、裸机、WiFi/BT 开）｜社区未压降区间 5–10 %/h｜Wall 空载 24.75 W"

  if [ "${2:-}" = "--save" ]; then
    row="| $S_T | $(echo "$hours" | awk '{printf "%.0f", $1*60}') min | $stype | ${pcth} | ${wh} | $n_dark | $acc |"
    out="$ROOT/docs/sleep-tests/power-measurements.md"
    [ -f "$out" ] || printf '# 睡眠功耗实测台账\n\n| 入睡时刻 | 时长 | 睡眠形态 | %% /h | W | DarkWake | 口径 |\n|---|---|---|---|---|---|---|\n' > "$out"
    echo "$row" >> "$out"
    echo "  已追加 → $out"
  fi
  ;;

*)
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
