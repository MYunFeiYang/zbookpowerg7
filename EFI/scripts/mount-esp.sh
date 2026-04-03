#!/bin/bash
#
# 挂载当前系统启动盘上的 EFI System Partition（ESP）。
# 适用于根卷在 APFS/HFS+ 上的常见单盘布局；多系统或外置系统请自行核对 diskutil。
#
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

find_whole_disk_for_root() {
  local dev
  dev=$(diskutil info / | awk -F': ' '/Device Identifier/ {print $2}' | tr -d ' ')
  [[ -n "$dev" ]] || return 1

  local guard=0
  while [[ $guard -lt 24 ]]; do
    ((guard++)) || true
    local info phys part_of
    info=$(diskutil info "$dev" 2>/dev/null) || return 1
    phys=$(echo "$info" | awk -F': ' '/APFS Physical Store/ {print $2}' | awk '{print $1}')
    if [[ -n "$phys" ]]; then
      dev="$phys"
      continue
    fi
    part_of=$(echo "$info" | awk -F': ' '/Part of Whole/ {print $2}' | tr -d ' ')
    if [[ -z "$part_of" || "$dev" == "$part_of" ]]; then
      break
    fi
    dev="$part_of"
  done
  printf '%s\n' "$dev"
}

find_efi_on_disk() {
  local whole="$1"
  local line
  line=$(diskutil list "$whole" | grep -E 'EFI EFI|EFI System Partition' | head -1) || true
  [[ -n "$line" ]] || return 1
  awk '{print $NF}' <<<"$line"
}

main() {
  local whole efi mp
  whole=$(find_whole_disk_for_root) || {
    log "Could not resolve whole disk for /"
    exit 1
  }

  efi=$(find_efi_on_disk "$whole") || {
    log "No EFI partition found on ${whole}"
    exit 1
  }

  mp=$(diskutil info "$efi" 2>/dev/null | awk -F': ' '/Mount Point/ {print $2}' | sed 's/^ *//')
  if [[ -n "$mp" && "$mp" != "Not applicable" && "$mp" != "(null)" ]]; then
    log "ESP ${efi} already mounted at ${mp}"
    exit 0
  fi

  if diskutil mount readOnly "$efi" 2>/dev/null; then
    log "Mounted ${efi} read-only"
    exit 0
  fi
  if diskutil mount "$efi"; then
    log "Mounted ${efi}"
    exit 0
  fi
  log "Failed to mount ${efi}"
  exit 1
}

main "$@"
