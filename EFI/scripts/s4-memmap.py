#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S4 memmap 采样归档与比对

用途：把 UEFI Shell 里 `memmap` 写出的 memmap.txt 归档成两份（冷启动基线 / S4 恢复态），
      再做逐段比对，判定「冷 POST 后物理内存布局」与「S4 恢复后物理内存布局」是否一致。
      这是「绝对物理地址还原」假设唯一的直接检验。

用法：
  python3 EFI/scripts/s4-memmap.py status        # 看 ESP 上 memmap.txt 现状
  python3 EFI/scripts/s4-memmap.py save cold     # 归档为冷启动基线
  python3 EFI/scripts/s4-memmap.py save s4       # 归档为 S4 恢复态
  python3 EFI/scripts/s4-memmap.py diff          # 两份比对
"""

import os
import re
import sys
import shutil

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
STORE = os.path.join(REPO, 'docs', 's4-memmap')

# UEFI Shell 里 memmap.txt 可能落在的位置（工作目录可能是 Tools 目录，也可能是 ESP 根）
ESP_CANDIDATES = [
    '/Volumes/ESP/EFI/OC/Tools/memmap.txt',
    '/Volumes/ESP/memmap.txt',
    '/Volumes/ESP/EFI/OC/memmap.txt',
]

# 内存类型名：UEFI Shell 的 memmap 用简写（BS_Data / ACPI_NVS / MMIO …），
# 部分版本用全称，两套都收，避免因类型名不匹配而解析出 0 段。
TYPES = {
    # 简写（EDK2 Shell 实测输出，本机 2026-10-29 确认）
    'Available', 'Reserved',
    'BS_Code', 'BS_Data',
    'LoaderCode', 'LoaderData',
    'RT_Code', 'RT_Data',
    'ACPI_NVS', 'ACPI_Recl',
    'UnusableMem', 'MMIO', 'MMIO_Port',
    'PalCode', 'PersistentMem', 'ConventionalMemory',
    # 全称（部分构建）
    'BootServicesCode', 'BootServicesData',
    'RuntimeServicesCode', 'RuntimeServicesData',
    'ACPIReclaimMemory', 'ACPIMemoryNVS',
    'MemoryMappedIO', 'MemoryMappedIOPortSpace',
    'UnusableMemory', 'PersistentMemory', 'FreeMemory', 'MaxMemoryType',
}

RANGE_RE = re.compile(r'^([0-9A-Fa-f]{8,16})-([0-9A-Fa-f]{8,16})$')
ADDR_RE = re.compile(r'^[0-9A-Fa-f]{8,16}$')


def find_memmap():
    for p in ESP_CANDIDATES:
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p
    return None


def read_text(path):
    """读取 memmap.txt，自动识别编码。

    UEFI Shell 的 `>` 重定向默认写 UCS-2/UTF-16LE（带 BOM ff fe），
    不是 UTF-8 —— 这是首版解析出 0 段的原因。也兼容 `>a` 生成的 ASCII。
    """
    raw = open(path, 'rb').read()
    if raw[:2] == b'\xff\xfe':
        return raw[2:].decode('utf-16-le', errors='replace')
    if raw[:2] == b'\xfe\xff':
        return raw[2:].decode('utf-16-be', errors='replace')
    # 无 BOM 但零字节密集 -> UTF-16LE
    if raw and raw.count(b'\x00') > len(raw) // 4:
        return raw.decode('utf-16-le', errors='replace')
    return raw.decode('utf-8', errors='replace')


def parse(path):
    """解析 memmap 输出，返回 [(start, end, pages, attrs, type), ...]

    兼容两种排版：
      旧: Type  Start-End  Pages  Attributes
      新: Start-End  Pages  Attributes  Type
    """
    segs = []
    for raw in read_text(path).splitlines():
        line = raw.strip().replace('\t', ' ')
        if not line or line.startswith('#'):
            continue
        toks = line.split()
        if len(toks) < 2:
            continue

        start = end = None
        type_name = None
        pages = None
        attrs = None

        for t in toks:
            m = RANGE_RE.match(t)
            if m:
                start = int(m.group(1), 16)
                end = int(m.group(2), 16)
                break
        if start is None:
            continue

        # 类型：第一个 token 或最后一个 token
        if toks[0] in TYPES:
            type_name = toks[0]
            rest = [t for t in toks[1:] if not RANGE_RE.match(t)]
        elif toks[-1] in TYPES:
            type_name = toks[-1]
            rest = [t for t in toks[:-1] if not RANGE_RE.match(t)]
        else:
            continue

        hexes = [t for t in rest if ADDR_RE.match(t) or re.fullmatch(r'[0-9A-Fa-f]+', t)]
        if len(hexes) >= 1:
            try:
                pages = int(hexes[0], 16)
            except ValueError:
                pages = None
        if len(hexes) >= 2:
            attrs = hexes[1]

        segs.append((start, end, pages, attrs, type_name))

    segs.sort(key=lambda s: s[0])
    return segs


def fmt_addr(v):
    return '0x%016X' % v


def kb(v):
    return '%.0f KiB' % (v / 1024.0)


def cmd_status():
    p = find_memmap()
    if not p:
        print('ESP 上还没有 memmap.txt。')
        print('检查过这些位置：')
        for c in ESP_CANDIDATES:
            print('  -', c)
        return 1
    st = os.stat(p)
    segs = parse(p)
    print('memmap 文件 :', p)
    print('大小        :', st.st_size, 'B')
    import datetime
    print('mtime       :', datetime.datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M:%S'))
    print('解析到段数  :', len(segs))
    if segs:
        total = sum((s[1] - s[0] + 1) for s in segs)
        print('覆盖地址范围: %s .. %s' % (fmt_addr(segs[0][0]), fmt_addr(segs[-1][1])))
        print('总覆盖      : %.1f MiB' % (total / 1048576.0))
        print()
        print('%-22s %-20s %-20s %s' % ('Type', 'Start', 'End', 'Size'))
        for s in segs[:8]:
            print('%-22s %-20s %-20s %s' % (s[4], fmt_addr(s[0]), fmt_addr(s[1]), kb(s[1] - s[0] + 1)))
        if len(segs) > 8:
            print('... 共 %d 段' % len(segs))
    return 0


def cmd_save(tag):
    p = find_memmap()
    if not p:
        print('ESP 上找不到 memmap.txt，先跑一次 Shell 生成它。')
        return 1
    segs = parse(p)
    if len(segs) < 5:
        print('memmap.txt 解析到的段数只有 %d，疑似文件不完整或格式不符，先别归档。' % len(segs))
        return 1
    os.makedirs(STORE, exist_ok=True)
    dst = os.path.join(STORE, 'memmap-%s.txt' % tag)
    # 归档统一转 UTF-8：UEFI Shell 写的是 UTF-16LE，原样复制不便阅读与 diff
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        f.write(read_text(p))
    print('已归档 ->', os.path.relpath(dst, REPO), '（已转为 UTF-8）')
    print('段数 =', len(segs), '| 范围 %s .. %s' % (fmt_addr(segs[0][0]), fmt_addr(segs[-1][1])))

    # 把 ESP 上的源文件改名，避免下一次采样覆盖后两份混在一起
    done = os.path.join(os.path.dirname(p), 'memmap-%s-sampled.txt' % tag)
    try:
        if os.path.exists(done):
            os.remove(done)
        os.rename(p, done)
        print('源文件已改名 ->', done, '（下次进 Shell 会重新生成 memmap.txt）')
    except OSError as e:
        print('⚠ 源文件改名失败（%s），请手动确认 ESP 上的 memmap.txt 已被下次采样覆盖前先归档。' % e)
    return 0


def load_tag(tag):
    f = os.path.join(STORE, 'memmap-%s.txt' % tag)
    if not os.path.isfile(f):
        print('缺少归档：', os.path.relpath(f, REPO))
        return None
    return parse(f)


def cmd_diff():
    a = load_tag('cold')
    b = load_tag('s4')
    if a is None or b is None:
        print()
        print('需要先各归档一次：')
        print('  冷启动：重启后进 Shell 采样 -> python3 EFI/scripts/s4-memmap.py save cold')
        print('  S4 恢复：arm + 睡眠，恢复时停在 picker 进 Shell 采样 -> save s4')
        return 1

    ma = {(s[0], s[1]): s for s in a}
    mb = {(s[0], s[1]): s for s in b}
    only_a = sorted(set(ma) - set(mb))
    only_b = sorted(set(mb) - set(ma))
    common = sorted(set(ma) & set(mb))
    retyped = [k for k in common if ma[k][4] != mb[k][4]]

    print('冷启动基线段数 :', len(a))
    print('S4 恢复态段数 :', len(b))
    print('完全一致段数   :', len(common) - len(retyped))
    print('仅基线有       :', len(only_a))
    print('仅 S4 有       :', len(only_b))
    print('地址相同但类型变:', len(retyped))
    print()

    if not only_a and not only_b and not retyped:
        print('>>> 结论：两份 memmap **完全一致**。')
        print('    固件在 S4 之后恢复了与冷启动相同的物理布局。')
        print('    ⇒ 「绝对物理地址还原失败」假设被推翻，问题不在固件布局，')
        print('      而在内核恢复代码与断电后硬件状态（IGPU 等半初始化设备）。')
        return 0

    print('>>> 结论：两份 memmap **存在差异**。')
    print('    ⇒ 固件在 S4 之后没有恢复出与冷启动相同的物理布局，')
    print('      boot.efi 把 wired pages 装回写盘时的绝对地址就会落错位置。')
    print('      差异区间即 ReservedMemory 的候选目标。')
    print()

    def dump(title, keys, m, other):
        if not keys:
            return
        print('--- %s (%d 段) ---' % (title, len(keys)))
        print('%-22s %-20s %-20s %10s' % ('Type', 'Start', 'End', 'Size'))
        for k in keys:
            s = m[k]
            print('%-22s %-20s %-20s %10s' % (s[4], fmt_addr(s[0]), fmt_addr(s[1]), kb(s[1] - s[0] + 1)))
        print()

    dump('仅冷启动基线有', only_a, ma, mb)
    dump('仅 S4 恢复态有', only_b, mb, ma)

    if retyped:
        print('--- 地址相同但类型变化 (%d 段) ---' % len(retyped))
        print('%-20s %-20s %-20s %-20s' % ('Start', 'End', '冷启动类型', 'S4 类型'))
        for k in retyped:
            print('%-20s %-20s %-20s %-20s' % (fmt_addr(k[0]), fmt_addr(k[1]), ma[k][4], mb[k][4]))
        print()

    # 汇总差异区间
    diff_ranges = []
    for k in only_a + only_b:
        diff_ranges.append(k)
    diff_ranges.sort()
    if diff_ranges:
        merged = []
        for s, e in diff_ranges:
            if merged and s <= merged[-1][1] + 1:
                merged[-1] = (merged[-1][0], max(merged[-1][1], e))
            else:
                merged.append((s, e))
        print('--- 差异区间汇总 (%d 处) ---' % len(merged))
        for s, e in merged:
            print('  %s - %s   (%s)' % (fmt_addr(s), fmt_addr(e), kb(e - s + 1)))
        print()
        print('若要用 Booter/ReservedMemory 保护，候选区间就在上面。')
    return 0


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cmd = args[0]
    if cmd == 'status':
        return cmd_status()
    if cmd == 'save':
        if len(args) < 2 or args[1] not in ('cold', 's4'):
            print('用法: save cold | save s4')
            return 1
        return cmd_save(args[1])
    if cmd == 'diff':
        return cmd_diff()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main())
