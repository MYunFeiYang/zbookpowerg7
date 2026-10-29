#!/bin/bash
# s4-expand-image.sh — 扩容 /var/vm/sleepimage
#
# 目的：排除「镜像容量不足」这一整类 S4 恢复失败。
#
# 背景（源码依据）：
#   osfmk/i386/hibernate_i386.c 的 hibernate_page_list_allocate() 按 EFI MemoryMap
#   逐段算出要写进镜像的页集合，页数写进镜像头；恢复时 boot.efi / 内核按这个页数
#   顺序还原。若 /var/vm/sleepimage 装不下，写镜像阶段的 pagesOut 与实际落盘量对不上，
#   恢复时序号错位，结果是硬复位，而 boot.efi 侧日志仍然全绿（H:IS 1 / REAN:END / HB|DT）。
#
# 本机实测基线（2026-10-29）：
#   hw.memsize            = 17,179,869,184  (16 GiB)
#   Pages wired down      = 940,251 页 = 3.59 GiB
#   /var/vm/sleepimage    = 1,073,741,824 (1.00 GiB)，blocks == size（非稀疏）
#   Hibernate File Min    = 1,073,741,824  ← 文件正好等于系统下限
#   ⇒ 1 GiB 要装 3.59 GiB wired 的 WKDM 压缩结果，压缩比需 ≥ 3.6:1（典型 2–3:1）
#
# 用法：
#   sudo bash s4-expand-image.sh           # 扩到 8 GiB
#   sudo bash s4-expand-image.sh 12        # 扩到 12 GiB
#   bash s4-expand-image.sh status         # 只读查看（不需要 root）
#   sudo bash s4-expand-image.sh restore   # 回滚到系统默认（删除后由系统重建）
#
# 重要：改完必须**重启一次**。IOHibernateIO 在启动时把文件大小读进内核对象，
#       运行中改文件不会更新已缓存的值。
#
# 回滚：删掉文件即可，系统下次启动自动重建（大小 = Hibernate File Min）。

set -u

IMG=/var/vm/sleepimage
SIZE_GIB="${2:-8}"

show() {
  echo "=== 当前状态 ==="
  if [ -e "$IMG" ]; then
    ls -lh "$IMG"
    /usr/bin/stat -f "  size=%z  blocks=%b  mtime=%Sm" -t "%F %T" "$IMG"
  else
    echo "  ($IMG 不存在)"
  fi
  echo "  物理内存      : $(/usr/sbin/sysctl -n hw.memsize) bytes"
  echo "  wired pages   : $(/usr/bin/vm_stat | awk '/wired down/{gsub(/\./,"",$4); print $4" 页 = "int($4*4096/1048576)" MiB"}')"
  echo "  Hibernate Min : $(/usr/sbin/ioreg -n IOPMrootDomain -r -d 1 2>/dev/null | awk -F'= ' '/Hibernate File Min/{print $2}')"
  echo "  卷可用        : $(/bin/df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
}

case "${1:-}" in
  status)
    show
    exit 0
    ;;
  restore)
    [ "$(/usr/bin/id -u)" = "0" ] || { echo "需要 root：sudo bash $0 restore"; exit 1; }
    show
    echo
    echo "==> 删除 $IMG（下次启动由系统按 Hibernate File Min 重建）"
    /bin/rm -f "$IMG"
    echo "==> 完成，请重启"
    exit 0
    ;;
  ""|expand)
    ;;
  *)
    /usr/bin/sed -n '2,30p' "$0"
    exit 1
    ;;
esac

[ "$(/usr/bin/id -u)" = "0" ] || { echo "需要 root：sudo bash $0 $SIZE_GIB"; exit 1; }

show
echo
echo "==> 目标：扩容到 ${SIZE_GIB} GiB"

# 记录原始状态，便于事后核对
LOG="/Volumes/Common/workplace/zbookpowerg7/docs/s4-memmap/sleepimage-expand.log"
if [ -d "$(dirname "$LOG")" ]; then
  {
    echo "--- $(/bin/date '+%F %T') ---"
    echo "before: $(/usr/bin/stat -f 'size=%z blocks=%b' "$IMG" 2>/dev/null)"
    echo "target: ${SIZE_GIB} GiB"
    echo "hw.memsize: $(/usr/sbin/sysctl -n hw.memsize)"
    echo "wired: $(/usr/bin/vm_stat | awk '/wired down/{print $4}')"
  } >> "$LOG"
  echo "    (已记录到 $LOG)"
fi

echo "==> 重建镜像文件（稀疏，mkfile -n）"
/bin/rm -f "$IMG"
/usr/bin/mkfile -n "${SIZE_GIB}g" "$IMG" || { echo "mkfile 失败"; exit 1; }
/bin/chown root:wheel "$IMG"
/bin/chmod 1600 "$IMG"

echo
show
echo
echo "==> 完成。必须重启一次才会被内核采用："
echo "      sudo shutdown -r now"
echo
echo "重启后核对（大小应仍为 ${SIZE_GIB} GiB，没被系统缩回）："
echo "      bash $0 status"
echo
echo "若重启后被缩回 1 GiB，说明系统强制按 Hibernate File Min 裁剪，"
echo "则扩容这条路作废，改用 restore 清理："
echo "      sudo bash $0 restore"
