#!/usr/bin/env python3
"""
hib-header.py — 解析 macOS 休眠镜像头 /var/vm/sleepimage

用途
----
在**没有串口、也没有 EXITBS 之后任何观测通道**的情况下，唯一能"看见"恢复前提的办法
就是直接读镜像本身。这个脚本把 `IOHibernateImageHeader` 里决定恢复成败的字段全部打出来，
并与本机 memmap 的 EFI runtime 段逐项对照。

结构来源（逐字核对）
    xnu @ xnu-8792.61.2  iokit/IOKit/IOHibernatePrivate.h
    struct IOHibernateImageHeader { ... }

为什么不用 ctypes 直接映射整个结构体
    该结构体有大量 __attribute__((packed))，且 x86_64 与 arm64 布局不同（arm64 追加
    hibSegInfo + 5×48B HMAC）。而**所有关键字段都在前 232 字节内**，偏移固定、不依赖
    sizeof 计算，所以按固定偏移解析更稳。

用法
    python3 hib-header.py                      # 默认读 /var/vm/sleepimage
    python3 hib-header.py <image>              # 指定镜像
    python3 hib-header.py <image> --memmap X   # 同时与某份 memmap 文本的 RT 段对照
"""

import os
import struct
import sys

# ---------------------------------------------------------------- 常量

SIGNATURES = {
    0x73696D65: "kIOHibernateHeaderSignature（有效，ASCII 'sime'）",
    0x7A7A7A7A: "kIOHibernateHeaderInvalidSignature（无效）",
    0xF1E0BE9D: "kIOHibernateHeaderOpenSignature（未加密）",
    0xFCDDFCDD: "kIOHibernateHeaderDebugDataSignature",
}

COMPRESSION = {0: "None", 1: "WKDM", 2: "WKDM(?)", 3: "LZ4(?)"}

OPTIONS = [
    (0x001, "SSD"),
    (0x002, "Color"),
    (0x004, "Progress"),
    (0x008, "DarkWake"),
    (0x010, "HWEncrypt"),
]

# ---------------------------------------------------------------- 解析

def parse_header(buf: bytes) -> dict:
    """按固定偏移解析前 232 字节。偏移取自结构体声明顺序（x86_64）。"""
    if len(buf) < 232:
        raise ValueError(f"文件太短（{len(buf)} B），不像休眠镜像")

    def u32(off):
        return struct.unpack_from("<I", buf, off)[0]

    def u64(off):
        return struct.unpack_from("<Q", buf, off)[0]

    return {
        "imageSize":              u64(0),
        "image1Size":             u64(8),
        "restore1CodePhysPage":   u32(16),
        "restore1CodeVirt":       u64(24),
        "restore1PageCount":      u32(32),
        "restore1CodeOffset":     u32(36),
        "restore1StackOffset":    u32(40),
        "pageCount":              u32(44),
        "bitmapSize":             u32(48),
        "restore1Sum":            u32(52),
        "image1Sum":              u32(56),
        "image2Sum":              u32(60),
        "actualRestore1Sum":      u32(64),
        "actualImage1Sum":        u32(68),
        "actualImage2Sum":        u32(72),
        "actualUncompressedPages": u32(76),
        "conflictCount":          u32(80),
        "nextFree":               u32(84),
        "signature":              u32(88),
        "processorFlags":         u32(92),
        "runtimePages":           u32(96),
        "runtimePageCount":       u32(100),
        "runtimeVirtualPages":    u64(104),
        "performanceDataStart":   u32(112),
        "performanceDataSize":    u32(116),
        "previewSize":            u32(136),
        "previewPageListSize":    u32(140),
        "handoffPages":           u32(160),
        "handoffPageCount":       u32(164),
        "systemTableOffset":      u32(168),
        "debugFlags":             u32(172),
        "options":                u32(176),
        "compression":            u32(188),
        "kernVirtSlide":          u64(224),
    }


def human(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(n) < 1024 or unit == "GiB":
            return f"{n:.2f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0
    return str(n)


def load_memmap_rt(path: str):
    """从 s4-memmap.py 归档的文本里取 RT_Code / RT_Data 段。"""
    segs = []
    if not os.path.exists(path):
        return segs
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[0] in ("RT_Code", "RT_Data"):
                try:
                    a, b = parts[1].split("-")
                    segs.append((parts[0], int(a, 16), int(b, 16)))
                except Exception:
                    pass
    return segs


def main() -> int:
    args = [a for a in sys.argv[1:]]
    memmap_path = None
    if "--memmap" in args:
        i = args.index("--memmap")
        memmap_path = args[i + 1]
        del args[i:i + 2]
    img = args[0] if args else "/var/vm/sleepimage"

    if not os.path.exists(img):
        print(f"找不到镜像：{img}")
        return 1

    st = os.stat(img)
    with open(img, "rb") as f:
        head = f.read(512)

    try:
        h = parse_header(head)
    except ValueError as e:
        print(f"解析失败：{e}")
        return 1

    sig = h["signature"]
    print("=" * 68)
    print(f"镜像文件 : {img}")
    print(f"实际大小 : {st.st_size} B ({human(st.st_size)})")
    print(f"文件 blocks: {st.st_blocks} × 512 = {st.st_blocks * 512} B"
          f"  ({'稀疏' if st.st_blocks * 512 < st.st_size * 0.9 else '实分配'})")
    print("=" * 68)

    print("\n--- 签名与压缩 ---")
    print(f"signature        : 0x{sig:08X}  {SIGNATURES.get(sig, '未知')}")
    ok = sig == 0x73696D65
    print(f"                   {'✔ 有效' if ok else '✘ 无效 —— 这份镜像不会被采用'}")
    comp = h["compression"]
    print(f"compression      : {comp} ({COMPRESSION.get(comp, '未知')})")
    print(f"options          : 0x{h['options']:08X}  "
          + " ".join(n for b, n in OPTIONS if h["options"] & b))
    print(f"processorFlags   : 0x{h['processorFlags']:08X}")

    print("\n--- 页账（决定镜像完整性）---")
    print(f"pageCount              : {h['pageCount']:>12d} 页 = {human(h['pageCount'] * 4096)}")
    print(f"actualUncompressedPages: {h['actualUncompressedPages']:>12d} 页 = {human(h['actualUncompressedPages'] * 4096)}")
    print(f"conflictCount          : {h['conflictCount']:>12d}"
          + ("  ← 非零表示有页发生冲突" if h["conflictCount"] else ""))
    print(f"nextFree               : 0x{h['nextFree']:08X} ({h['nextFree']})")
    print(f"bitmapSize             : {h['bitmapSize']:>12d} B")
    print(f"restore1PageCount      : {h['restore1PageCount']:>12d} 页")

    print("\n--- 大小账（镜像是否写得下）---")
    print(f"header.imageSize  : {h['imageSize']:>14d} B = {human(h['imageSize'])}")
    print(f"header.image1Size : {h['image1Size']:>14d} B = {human(h['image1Size'])}")
    print(f"文件实际大小      : {st.st_size:>14d} B = {human(st.st_size)}")
    if h["imageSize"] > st.st_size:
        print(f"  ✘ imageSize 超出文件 {human(h['imageSize'] - st.st_size)} ⇒ 镜像被截断")
    elif h["imageSize"] == 0:
        print("  ! imageSize 为 0 —— 可能还没写完或头部无效")
    else:
        print(f"  ✔ imageSize 未超出文件（剩余 {human(st.st_size - h['imageSize'])}）")

    print("\n--- 校验和（三项应 actual == 计划值）---")
    for plan, act, name in (
        (h["restore1Sum"], h["actualRestore1Sum"], "restore1"),
        (h["image1Sum"],   h["actualImage1Sum"],   "image1"),
        (h["image2Sum"],   h["actualImage2Sum"],   "image2"),
    ):
        mark = "✔" if plan == act else "✘ 不一致"
        print(f"{name:9s}: 计划 0x{plan:08X}  实际 0x{act:08X}  {mark}")

    print("\n--- EFI runtime 区（本机 §3z.3 的焦点）---")
    rp, rc = h["runtimePages"], h["runtimePageCount"]
    print(f"runtimePages      : 0x{rp:08X}  ({rp})")
    print(f"runtimePageCount  : {rc} 页 = {human(rc * 4096)}")
    print(f"runtimeVirtualPages: 0x{h['runtimeVirtualPages']:016X}")
    if rp == 0:
        print("  ! runtimePages 为 0 ⇒ hibernate_page_list_set_volatile() 会整段跳过，")
        print("    恢复期内核不会把 RT 区当 scratch（这对我们是好事，但说明 boot.efi 没算出 RT 区）")

    print("\n--- 恢复入口相关 ---")
    print(f"restore1CodePhysPage: 0x{h['restore1CodePhysPage']:08X}  ({h['restore1CodePhysPage']})")
    print(f"restore1CodeVirt   : 0x{h['restore1CodeVirt']:016X}")
    print(f"restore1CodeOffset : 0x{h['restore1CodeOffset']:08X}")
    print(f"restore1StackOffset: 0x{h['restore1StackOffset']:08X}")
    print(f"handoffPages       : 0x{h['handoffPages']:08X}    count {h['handoffPageCount']}")
    print(f"previewSize        : {h['previewSize']} B    previewPageListSize {h['previewPageListSize']} B")
    print(f"systemTableOffset  : 0x{h['systemTableOffset']:08X}")
    print(f"kernVirtSlide      : 0x{h['kernVirtSlide']:016X}")

    if memmap_path:
        segs = load_memmap_rt(memmap_path)
        print(f"\n--- 与 memmap 对照（{memmap_path}）---")
        if not segs:
            print("  （没读到 RT_Code / RT_Data 段）")
        else:
            for t, a, b in segs:
                print(f"  {t:8s} 0x{a:08X}-0x{b:08X}  {human(b - a + 1):>10s}")
            if rp:
                hit = [(t, a, b) for t, a, b in segs if a <= rp <= b]
                if hit:
                    t, a, b = hit[0]
                    print(f"  ⇒ header 的 runtimePages 0x{rp:08X} 落在 {t} 段 0x{a:08X}-0x{b:08X} 内 ✔")
                    need = (rp + rc - 1)
                    print(f"     需要覆盖到 0x{need:08X}"
                          + ("  ✔ 仍在同一段内" if need <= b else f"  ✘ 越出该段末尾 0x{b:08X}"))
                else:
                    print(f"  ✘ header 的 runtimePages 0x{rp:08X} 不落在任何 RT 段内 —— 地址对不上")

    print("\n" + "=" * 68)
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
