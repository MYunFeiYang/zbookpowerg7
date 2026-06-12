#!/bin/bash
# 自动切换默认输入，优先级：蓝牙 > 有线耳机孔 > 内置麦。
# 需已安装 SwitchAudioSource；有线耳麦另需 MicFix 发 HDA verb。

set -euo pipefail

find_switch_audio() {
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    command -v SwitchAudioSource
    return 0
  fi
  for p in /opt/homebrew/bin/SwitchAudioSource /usr/local/bin/SwitchAudioSource; do
    if [[ -x "$p" ]]; then echo "$p"; return 0; fi
  done
  return 1
}

SWITCH_AUDIO="$(find_switch_audio || true)"
if [[ -z "$SWITCH_AUDIO" ]]; then
  echo "SwitchAudioSource not found. Run: brew install switchaudio-osx" >&2
  exit 1
fi

BUILTIN_OUTPUT="Built-in Output"
INPUT_LINE="Built-in Line Input"
INPUT_INTERNAL="Built-in Microphone"

current_output() {
  "$SWITCH_AUDIO" -c -t output 2>/dev/null || true
}

output_source() {
  system_profiler SPAudioDataType 2>/dev/null | awk -F': ' '/Output Source:/ { print $2; exit }'
}

bt_connected_names() {
  system_profiler SPBluetoothDataType 2>/dev/null | awk '
    /^      Connected:/ || /^      已连接:/ { connected=1; next }
    /^      Not Connected:/ || /^      未连接:/ { connected=0; next }
    connected && /^          [^ ].*:$/ {
      sub(/:$/, "", $1)
      print $1
    }
  '
}

input_exists() {
  local name="$1"
  "$SWITCH_AUDIO" -a -t input -f cli 2>/dev/null | awk -F, -v n="$name" '$1 == n { found=1 } END { exit found ? 0 : 1 }'
}

# 耳机孔状态：插入立即记住；拔出需连续 2 次 Internal Speakers 才清除
jack_plugged=0
jack_unplug_streak=0

update_jack_state() {
  local src
  src=$(output_source)
  if [[ "$src" == "Headphones" ]]; then
    jack_plugged=1
    jack_unplug_streak=0
  elif [[ "$src" == "Internal Speakers" ]]; then
    jack_unplug_streak=$((jack_unplug_streak + 1))
    if [[ $jack_unplug_streak -ge 2 ]]; then
      jack_plugged=0
    fi
  fi
}

# 返回: device|reason
pick_input() {
  local name out

  # 1. 默认输出已切到外接/蓝牙 → 同名输入（最快，不依赖 Bluetooth profiler）
  out=$(current_output)
  if [[ -n "$out" && "$out" != "$BUILTIN_OUTPUT" ]] && input_exists "$out"; then
    echo "${out}|bt-output"
    return
  fi

  # 2. Bluetooth profiler 里已连接且在输入列表
  while IFS= read -r name; do
    if [[ -n "$name" ]] && input_exists "$name"; then
      echo "${name}|bt"
      return
    fi
  done < <(bt_connected_names)

  # 3. 有线耳机孔（含蓝牙断开过渡期记忆）
  if [[ $jack_plugged -eq 1 ]]; then
    echo "${INPUT_LINE}|wired"
    return
  fi

  # 4. 内置麦
  echo "${INPUT_INTERNAL}|builtin"
}

switch_input() {
  local target="$1" reason="$2" current
  current=$("$SWITCH_AUDIO" -c -t input 2>/dev/null || true)
  if [[ "$current" != "$target" ]]; then
    "$SWITCH_AUDIO" -s "$target" -t input >/dev/null 2>&1 || true
    echo "$(date '+%H:%M:%S') input -> $target (${reason}, jack=${jack_plugged})"
  fi
}

last=""
echo "MicInputSwitch: priority bt > wired > builtin"
while true; do
  update_jack_state
  IFS='|' read -r want reason <<< "$(pick_input)"
  if [[ -n "$want" && "$want" != "$last" ]]; then
    switch_input "$want" "$reason"
    last=$want
  fi
  sleep 2
done
