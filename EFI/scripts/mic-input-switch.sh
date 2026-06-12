#!/bin/bash
# 监听耳机孔输出状态，自动切换 macOS 默认输入设备。
# 需已安装 SwitchAudioSource；与 MicFix 配合使用（MicFix 发 HDA verb，本脚本切输入）。

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

INPUT_LINE="Built-in Line Input"
INPUT_INTERNAL="Built-in Microphone"

output_source() {
  system_profiler SPAudioDataType 2>/dev/null | awk -F': ' '/Output Source:/ { print $2; exit }'
}

switch_input() {
  local target="$1" current
  current=$("$SWITCH_AUDIO" -c -t input 2>/dev/null || true)
  if [[ "$current" != "$target" ]]; then
    "$SWITCH_AUDIO" -s "$target" -t input >/dev/null 2>&1 || true
    echo "$(date '+%H:%M:%S') input -> $target (output: $(output_source))"
  fi
}

last=""
echo "MicInputSwitch watching headphone jack"
while true; do
  src=$(output_source)
  if [[ "$src" == "Headphones" ]]; then want=$INPUT_LINE; else want=$INPUT_INTERNAL; fi
  if [[ "$want" != "$last" ]]; then switch_input "$want"; last=$want; fi
  sleep 2
done
