#!/bin/bash
#
# 挂载当前系统启动盘上的 EFI System Partition（ESP）。
# 仅在「尚未挂载」时用 diskutil mount（默认挂载，不使用 readOnly）；不尝试对已存在的只读挂载做 remount。
# 适用于根卷在 APFS/HFS+ 上的常见单盘布局；多系统或外置系统请自行核对 diskutil。
#
set -euo pipefail

# 固定英文输出，避免「设备标识符」等非英文关键字导致解析失败
export LC_ALL=C

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

mount_point_for() {
  diskutil info "$1" 2>/dev/null | awk -F': ' '/Mount Point/ {print $2}' | sed 's/^ *//'
}

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

# 用 plist 的 Content==EFI 识别 ESP，不依赖 diskutil list 的文本格式/语言
partition_content() {
  local part="$1"
  diskutil info -plist "$part" 2>/dev/null | plutil -extract Content raw - 2>/dev/null || true
}

find_efi_on_disk() {
  local whole="$1"
  local part content

  while read -r part; do
    [[ "$part" =~ ^${whole}s[0-9]+$ ]] || continue
    content=$(partition_content "$part")
    if [[ "$content" == "EFI" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done < <(diskutil list "$whole" | awk '/disk[0-9]+s[0-9]+$/ {print $NF}')

  return 1
}

main() {
  local whole efi mp
  whole=$(find_whole_disk_for_root) || {
    log "Could not resolve whole disk for /"
    exit 1
  }
  log "Resolved whole disk: ${whole}"

  efi=$(find_efi_on_disk "$whole") || {
    log "No EFI partition (Content=EFI) found on ${whole}. Try: diskutil list ${whole}"
    exit 1
  }
  log "ESP partition: ${efi}"

  mp=$(mount_point_for "$efi")
  if [[ -n "$mp" && "$mp" != "Not applicable" && "$mp" != "(null)" ]]; then
    log "ESP ${efi} already mounted at ${mp} (left unchanged)"
    exit 0
  fi

  if diskutil mount "$efi"; then
    log "Mounted ${efi} (diskutil mount, not readOnly)"
    exit 0
  fi
  log "Failed to mount ${efi}"
  exit 1
}

main "$@"
