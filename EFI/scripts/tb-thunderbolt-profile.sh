#!/bin/bash
#
# 切换 macOS 雷电 ACPI 档位（改 EFI/OC/config.plist）。
# 推荐入口: ./oc-setup.sh tb off|on|lite|status
#
# 档位:
#   off   — SSDT-thunderbolt-disable（最省电，无 TB）
#   on    — SSDT-TB3HP-ZBook（force-power，功能最全、功耗最高）
#   lite  — SSDT-TB3HP-ZBook-lite（实验：无 force-power，保留唤醒 _DSW）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_ROOT}/EFI/OC/config.plist"

AML_OFF="SSDT-thunderbolt-disable.aml"
AML_ON="SSDT-TB3HP-ZBook.aml"
AML_LITE="SSDT-TB3HP-ZBook-lite.aml"
NHI_ID="com.apple.driver.AppleThunderboltNHI"

usage() {
  cat <<EOF
Usage: $0 off|on|lite|status

  off    禁用雷电（默认省电）
  on     全功能雷电（force-power）
  lite   实验档：无 force-power，测睡眠功耗/唤醒稳定性
  status 显示当前档位

修改: ${CONFIG}
改后请将 EFI 同步到 ESP 并重启。
EOF
}

need_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script must run on macOS." >&2
    exit 1
  fi
}

plist_set_acpi() {
  local aml="$1" enabled="$2"
  local i=0 path
  while path="$(/usr/libexec/PlistBuddy -c "Print :ACPI:Add:${i}:Path" "$CONFIG" 2>/dev/null || true)"; do
    [[ -z "$path" ]] && break
    if [[ "$path" == "$aml" ]]; then
      /usr/libexec/PlistBuddy -c "Set :ACPI:Add:${i}:Enabled ${enabled}" "$CONFIG"
      return 0
    fi
    i=$((i + 1))
  done
  echo "ERROR: ACPI entry not found: ${aml}" >&2
  exit 1
}

plist_set_nhi_patch() {
  local enabled="$1"
  local i=0 ident
  while ident="$(/usr/libexec/PlistBuddy -c "Print :Kernel:Patch:${i}:Identifier" "$CONFIG" 2>/dev/null || true)"; do
    [[ -z "$ident" ]] && break
    if [[ "$ident" == "$NHI_ID" ]]; then
      /usr/libexec/PlistBuddy -c "Set :Kernel:Patch:${i}:Enabled ${enabled}" "$CONFIG"
      return 0
    fi
    i=$((i + 1))
  done
  echo "ERROR: Kernel patch not found: ${NHI_ID}" >&2
  exit 1
}

acpi_enabled() {
  local aml="$1" i=0 path enabled
  while path="$(/usr/libexec/PlistBuddy -c "Print :ACPI:Add:${i}:Path" "$CONFIG" 2>/dev/null || true)"; do
    [[ -z "$path" ]] && break
    if [[ "$path" == "$aml" ]]; then
      enabled="$(/usr/libexec/PlistBuddy -c "Print :ACPI:Add:${i}:Enabled" "$CONFIG")"
      [[ "$enabled" == "true" ]] && return 0
      return 1
    fi
    i=$((i + 1))
  done
  return 1
}

cmd_status() {
  local profile="unknown"
  if acpi_enabled "$AML_OFF"; then
    profile="off"
  elif acpi_enabled "$AML_ON"; then
    profile="on"
  elif acpi_enabled "$AML_LITE"; then
    profile="lite"
  fi
  echo "thunderbolt profile: ${profile}"
}

apply_profile() {
  local profile="$1"
  case "$profile" in
    off)
      plist_set_acpi "$AML_OFF" true
      plist_set_acpi "$AML_ON" false
      plist_set_acpi "$AML_LITE" false
      plist_set_nhi_patch false
      ;;
    on)
      plist_set_acpi "$AML_OFF" false
      plist_set_acpi "$AML_ON" true
      plist_set_acpi "$AML_LITE" false
      plist_set_nhi_patch true
      ;;
    lite)
      plist_set_acpi "$AML_OFF" false
      plist_set_acpi "$AML_ON" false
      plist_set_acpi "$AML_LITE" true
      plist_set_nhi_patch true
      ;;
    *)
      echo "Unknown profile: $profile" >&2
      exit 1
      ;;
  esac
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    -h|--help|help|'')
      usage
      ;;
    status)
      need_macos
      [[ -f "$CONFIG" ]] || { echo "Missing ${CONFIG}" >&2; exit 1; }
      cmd_status
      ;;
    off|on|lite)
      need_macos
      [[ -f "$CONFIG" ]] || { echo "Missing ${CONFIG}" >&2; exit 1; }
      apply_profile "$cmd"
      echo "==> Thunderbolt profile set to: ${cmd}"
      cmd_status
      echo "请将 EFI 同步到 ESP 后重启。lite/on 请多测睡眠/唤醒与 TB 设备。"
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
