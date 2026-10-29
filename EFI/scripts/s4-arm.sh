#!/bin/bash
#
# S4 休眠 —— RTC 密钥路线 的体检 / 武装 / 回滚
#
# ── 一句话策略
#   让 macOS 内核把休眠密钥写进 **真实 RTC 0x80–0xAB**（AppleRTCHibernateVars，44 字节），
#   由 OpenCore 的 HibernateMode=RTC 在下次启动时读回并还原成 boot-signature / boot-image-key。
#
# ── 为什么必须走 RTC（2026-10-28 18:15 源码定论）
#   OcBootManagementLib/AppleHibernate.c:148 的 NVRAM 分支读的是
#   `IOHibernateRTCVariables` 这个 NVRAM 变量，注释原文 "Prior to 10.13.6"
#   ⇒ 现代 macOS 根本不写它 ⇒ HibernateMode=NVRAM 永远判定「非休眠唤醒」⇒ 必然冷启动。
#   只有 :134 的 RTC 分支（OcRtcRead 读 0x80–0xAB、校验 'AAPL' 签名）在现代系统上成立。
#
# ── 三层封锁，缺一不可地全部解开（这是本机历史「坏 RTC / 冷启动」的完整成因）
#   ① Kernel/Quirks/DisableRtcChecksum = true
#        阻止 AppleRTC 更新主校验和 0x58/0x59 ⇒ 内容变了校验和不跟 ⇒ boot.efi 判 mismatch
#        ⇒ 调 AppleRtcRamReset 清 0x40–0xFF ⇒ 密钥自毁。必须 false。
#   ② boot-args rtcfx_exclude 覆盖 0x80–0xAB
#        RTCMemoryFixup README：排除该区 ⇒ hibernation won't work。必须放开。
#   ③ UEFI/ProtocolOverrides/AppleRtcRam=true + NVRAM rtc-blacklist=[0x0E..0xFF]
#        这是**固件层**模拟，只影响 EfiBoot 经 EFI_RTC 协议的访问；
#        OC 自己用 OcRtcRead 直读端口、macOS 走内核端口 hook，均不经过它 ⇒ 保留即可。
#
# ── Apple 的 RTC 布局（OpenCore Include/Apple/IndustryStandard/AppleRtc.h）
#   MAIN_CHECKSUM_ADDR1/2 = 0x58 / 0x59，覆盖 [0x0E, 0x100)
#   HIBERNATION_KEY_ADDR  = 0x80，长度 0x2C(44) ⇒ 0x80–0xAB
#   RESERVED              = 0x78–0x7F（填 FF，PRAM 复位不清）
#   TRACE_DATA            = 0xB0–0xB6（唤醒进度日志）
#   ⇒ rtcfx_exclude 取 0E-57,5A-7F：封 BIOS 设置区，放开校验和与密钥区。
#
# ── 本机配置（2026-10-28 18:20）
#   Misc/Boot/HibernateMode      RTC
#   Kernel/Quirks/DisableRtcChecksum  false（必须允许更新 0x58/0x59）
#   boot-args                    rtcfx_exclude=0E-57,5A-7F -hbfxdbg -hbfxforce hfile=/var/vm/sleepimage
#   Misc/Debug/Target            69 (0x45)
#   Kernel/Quirks                PowerTimeoutKernelPanic=false
#   Misc/Security                不含 AllowNvramReset（OC 1.0.x 已移除该键，是死配置）
#   UEFI/Drivers                 ResetNvramEntry.efi=true（真正的 Reset NVRAM 逃生口）
#
# ── 用法
#   ./s4-arm.sh check      只读体检（不需要 root）：静态配置 + 运行态 + 电源策略
#   sudo ./s4-arm.sh arm   武装（自动 sudo）：**只武装当前电源源**，另一侧留安全档
#   sudo ./s4-arm.sh disarm 回滚到 Deep Idle 基线
#
# ── 判读（一次睡眠后三选一）
#   方向先记住：OC 读到 IOHibernateRTCVariables 后**立刻把它删掉**（AppleHibernate.c:173-183）
#   ⇒ 醒后 nvram 里还查得到它 = OC 压根没消费，是**坏信号**；查不到才是正常。
#
#   ★ kern.hibernatecount **不是**成功判据（2026-10-28 17:50 源码坐实）：
#     `gIOHibernateCount++` 在 `IOHibernateDone()`（IOHibernateIO.cpp:1442）里，而它有两条调用路径：
#       :886  —— 休眠写镜像**失败**时的清理分支
#       :1257 —— 唤醒时 `IOHibernateSystemWake()` 里（仅当 gFSState==kFSOpened）
#     ⇒ 失败也会 +1。它的正确含义只有一个：**已经越过 :504 那道 hfile 门槛、进到写镜像阶段**。
#       （17:23 那次 = 0，因为在 :504 就 return Unsupported；17:44 那次 = 1，说明门过了、后面才失败。）
#
#   成功判据（三条同时成立，缺一不可）：
#     a) 电源灯灭 / 风扇停（hibernatemode 25 写完镜像应断电，不是 DarkWake 秒回）
#     b) `pmset -g log` 里**没有** `/HibernateError` 字样（有它 = 失败，无论计数是多少）
#     c) 醒后能恢复会话（S4 是全量 reinit）
#
#   失败判据（任一即可确定失败）：
#     · `pmset -g log` 出现 `DarkWake from Standby ... due to /HibernateError`（秒回）
#     · 电源灯一直亮着、风扇没停
#

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CFG="$REPO/EFI/OC/config.plist"
KEXT_DIR="$REPO/EFI/OC/Kexts/HibernationFixup.kext"
PMSET=/usr/bin/pmset

ok=0; bad=0
pass() { printf '  ✔ %s\n' "$1"; ok=$((ok+1)); }
fail() { printf '  ✘ %s\n' "$1"; bad=$((bad+1)); }
warn() { printf '  ! %s\n' "$1"; }


# ───────────────────────── check ─────────────────────────
do_check() {
  local blocked=0

  echo "=== A. EFI 静态配置（${CFG}）"
  if [[ ! -f "$CFG" ]]; then echo "  ✘ config.plist 不存在"; return; fi

  python3 - "$CFG" "$KEXT_DIR" <<'PY'
import plistlib, sys, os
cfg, kdir = sys.argv[1], sys.argv[2]
d = plistlib.load(open(cfg, 'rb'))
def p(m): print("  ✔ " + m)
def f(m): print("  ✘ " + m)
def w(m): print("  ! " + m)

# 1 HibernationFixup 条目与顺序
add = d['Kernel']['Add']
names = [e.get('BundlePath') for e in add]
if 'HibernationFixup.kext' in names and 'Lilu.kext' in names:
    i, il = names.index('HibernationFixup.kext'), names.index('Lilu.kext')
    if i > il and add[i].get('Enabled'):
        p("Kernel/Add[%d] = HibernationFixup.kext（Enabled，在 Lilu[%d] 之后）" % (i, il))
    else:
        f("HibernationFixup 位置/启用异常：idx=%d, Lilu=%d, Enabled=%s" % (i, il, add[i].get('Enabled')))
else:
    f("Kernel/Add 缺 HibernationFixup.kext 或 Lilu.kext")

# 2 kext 是否为 fork 版
bin = os.path.join(kdir, 'Contents/MacOS/HibernationFixup')
if os.path.isfile(bin):
    raw = open(bin, 'rb').read()
    sz = len(raw)
    has_force = b'-hbfxforce' in raw
    has_log = b'NVStorage path entered' in raw
    if has_force and has_log:
        p("kext 是 fork 版：含 -hbfxforce 与调试日志（%d 字节）" % sz)
    elif has_force:
        w("kext 含 -hbfxforce 但无调试日志（Release 构建；%d 字节）" % sz)
    else:
        f("kext 是上游版（无 -hbfxforce）⇒ -hbfxforce 不会生效（%d 字节）" % sz)
else:
    f("kext 二进制缺失：%s" % bin)

# 3 HibernateMode
hm = d['Misc']['Boot'].get('HibernateMode')
if hm == 'RTC':
    p("Misc/Boot/HibernateMode = RTC（读 CMOS 0x80-0xAB 的 AAPL 签名，现代 macOS 唯一有效路径）")
elif hm == 'Auto':
    w("Misc/Boot/HibernateMode = Auto（RTC+NVRAM；RTC 读到即用，NVRAM 只作兜底，可用但多一层变量）")
elif hm == 'NVRAM':
    f("Misc/Boot/HibernateMode = NVRAM ⇒ OC 只读 NVRAM 变量 IOHibernateRTCVariables，"
      "源码注释写明该变量仅存在于 10.13.6 之前 ⇒ 本机永远判定'非休眠唤醒'，必然冷启动")
else:
    f("Misc/Boot/HibernateMode = %r（应为 RTC）" % hm)

# 3b Debug Target 是否含 0x40（本机 OC 文件日志坏；0x40 是否真能出 boot-log 未验证成功）
tgt = d['Misc']['Debug'].get('Target', 0) or 0
if tgt & 0x40:
    p("Misc/Debug/Target = %d (0x%02X)，含 0x40" % (tgt, tgt))
else:
    w("Misc/Debug/Target = %d (0x%02X)，缺 0x40" % (tgt, tgt))

if d['Misc']['Boot'].get('HibernateSkipsPicker') is True:
    p("Misc/Boot/HibernateSkipsPicker = true")
else:
    w("Misc/Boot/HibernateSkipsPicker = %r（建议 true）" % d['Misc']['Boot'].get('HibernateSkipsPicker'))

# 4 PowerTimeoutKernelPanic
if d['Kernel']['Quirks'].get('PowerTimeoutKernelPanic') is False:
    p("Kernel/Quirks/PowerTimeoutKernelPanic = false（超时不 panic）")
else:
    f("Kernel/Quirks/PowerTimeoutKernelPanic = %r（应为 false，否则超时会内核崩溃）" % d['Kernel']['Quirks'].get('PowerTimeoutKernelPanic'))

# 5 逃生口 —— OC 1.0.x 已移除 Misc/Security/AllowNvramReset，
#   Reset NVRAM 改由 ResetNvramEntry.efi 驱动提供（还带 CMD+OPT+P+R 热键）。
_esc = None
for _drv in d['UEFI']['Drivers']:
    if isinstance(_drv, dict):
        _path, _en = _drv.get('Path'), _drv.get('Enabled')
    else:
        _path, _en = _drv, True
    if _path == 'ResetNvramEntry.efi':
        _esc = _en
if _esc is True:
    p("UEFI/Drivers 已启用 ResetNvramEntry.efi（Reset NVRAM 逃生口，另有 CMD+OPT+P+R）")
elif _esc is False:
    f("ResetNvramEntry.efi 存在但 Enabled=false ⇒ 无逃生口")
else:
    f("未加载 ResetNvramEntry.efi ⇒ NVRAM 若被写坏将无菜单逃生口")
if 'AllowNvramReset' in d['Misc']['Security']:
    f("config 仍含已废弃的 Misc/Security/AllowNvramReset ⇒ ocvalidate 会报 No schema，应删")

# 6 boot-args
nv = d['NVRAM']['Add'].get('7C436110-AB2A-4BBB-A880-FE41995C9F82', {})
ba = nv.get('boot-args', '') or ''
if '-hbfxforce' in ba:
    p("boot-args 含 -hbfxforce")
else:
    f("boot-args 缺 -hbfxforce ⇒ fork 逻辑不触发，休眠变量无处可写")
if '-hbfxdbg' in ba:
    p("boot-args 含 -hbfxdbg（本机是自编译 fork，DEBUG 串已编入 ⇒ 日志可读）")
else:
    w("boot-args 缺 -hbfxdbg ⇒ fork 里的调试日志不会输出，失败时只剩内核码可看")

# 6b hfile —— 内核写休眠镜像的路径来源（2026-10-28 实测根因）
# IOHibernateIO.cpp:496-506：gIOHibernateFilename 只由两处赋值，
#   ① IOPMrootDomain 的 "Hibernate File" 属性（本机实测不存在）
#   ② boot-arg hfile=<path>（IOHibernateIO.cpp:1617）
# 两者都没有 ⇒ 504 行 `return kIOReturnUnsupported` ⇒ 不写镜像、立刻退回 ⇒ HibernateError
if 'hfile=' in ba:
    hv = [t for t in ba.split() if t.startswith('hfile=')][0].split('=', 1)[1]
    if hv == '/var/vm/sleepimage':
        p("boot-args 含 hfile=/var/vm/sleepimage（内核写镜像路径）")
    else:
        w("boot-args 里 hfile=%s（不是默认路径，确认它可写）" % hv)
else:
    f("boot-args 缺 hfile= ⇒ 若内核没收到 \"Hibernate File\" 属性就不写镜像（本机实测就是没收到）")

m = [t for t in ba.split() if t.startswith('rtcfx_exclude=')]
val = m[0].split('=', 1)[1] if m else ''
def covers(spec, lo, hi):
    for item in spec.split(','):
        item = item.strip()
        if not item: continue
        if '-' in item:
            a, b = item.split('-', 1); a, b = int(a, 16), int(b, 16)
        else:
            a = b = int(item, 16)
        if a <= lo and b >= hi: return True
    return False
def hits(spec, lo, hi):
    for item in spec.split(','):
        item = item.strip()
        if not item: continue
        if '-' in item:
            a, b = item.split('-', 1); a, b = int(a, 16), int(b, 16)
        else:
            a = b = int(item, 16)
        if not (b < lo or a > hi): return True
    return False
# 0x80–0xAB = AppleRTCHibernateVars（44 B），0x58/0x59 = Apple 主校验和（覆盖 0x0E–0xFF）
if not m:
    w("boot-args 无 rtcfx_exclude ⇒ RTC 全开：密钥可写，但 BIOS 设置区也裸露")
elif hits(val, 0x80, 0xAB):
    f("rtcfx_exclude=%s 覆盖了 0x80–0xAB ⇒ 休眠密钥写不进 RTC，RTC 模式必然失败"
      "（RTCMemoryFixup README：排除该区会让 hibernation 不工作）" % val)
elif hits(val, 0x58, 0x59):
    f("rtcfx_exclude=%s 封了主校验和 0x58/0x59 ⇒ 内容变了校验和不跟 ⇒ boot.efi 判 mismatch 清 RTC" % val)
else:
    p("rtcfx_exclude=%s：放开 0x58/0x59 校验和与 0x80–0xAB 密钥区（其余仍受保护）" % val)

# 7 rtc-blacklist + AppleRtcRam（固件层，只拦 EfiBoot 的 EFI_RTC 访问，不拦内核写入）
try:
    bl = d['NVRAM']['Add']['4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102']['rtc-blacklist']
    cov = set(bl)
    full = all(x in cov for x in range(0x0E, 0x100))
    rtcram = d['UEFI'].get('ProtocolOverrides', {}).get('AppleRtcRam', False)
    if rtcram and len(bl) == 242 and full:
        p("AppleRtcRam=true + rtc-blacklist 242 B（0x0E–0xFF）：固件层模拟生效，只影响 EfiBoot")
    elif not rtcram:
        w("AppleRtcRam=false ⇒ rtc-blacklist 无人消费（死配置，无害但也没保护）")
    else:
        w("rtc-blacklist = %d B，0x0E–0xFF 未全覆盖（%s）" % (len(bl), "全封" if full else "有缺口"))
except KeyError:
    w("NVRAM 里没有 rtc-blacklist ⇒ 固件层不模拟 RTC 写")

# 8 NVRAM/Delete 是否覆盖
dl = d['NVRAM'].get('Delete', {}).get('4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102', [])
if 'rtc-blacklist' in (dl or []):
    p("NVRAM/Delete 已列 rtc-blacklist（旧值会被清掉）")
else:
    w("NVRAM/Delete 未列 rtc-blacklist ⇒ 改动可能不生效")
PY

  echo
  echo "=== B. 运行态（要看本次开机是否真吃到新配置）"
  local RBA
  RBA="$(nvram -p 2>/dev/null | awk -F'\t' '$1=="boot-args"{print $2}')"
  if [[ "$RBA" == *"-hbfxforce"* ]]; then
    echo "  ✔ NVRAM boot-args 已含 -hbfxforce"
    case "$RBA" in
      *rtcfx_exclude=0E-57,5A-7F*)
        echo "  ✔ 运行态 rtcfx_exclude=0E-57,5A-7F（放开 0x58/0x59 校验和 + 0x80–0xAB 密钥）" ;;
      *rtcfx_exclude=0E-FF*|*rtcfx_exclude=0E-7F*)
        echo "  ✘ 运行态仍封着 0x80–0xAB（${RBA##*rtcfx_exclude=}）⇒ 密钥写不进 RTC，需重启生效"; blocked=1 ;;
      *)
        echo "  ✘ 运行态 rtcfx_exclude 非预期值（${RBA:-空}）"; blocked=1 ;;
    esac
  else
    echo "  ✘ NVRAM boot-args 尚无 -hbfxforce ⇒ 未重启或 ESP 未同步"; blocked=1
  fi
  # 注意：脚本开了 pipefail，`kextstat | grep -q` 会因 grep 提前退出触发 SIGPIPE
  # （kextstat 退出码 13）而误判为「未加载」。必须用变量匹配。
  local KS
  KS="$(kextstat 2>/dev/null || true)"
  if [[ "$KS" == *HibernationFixup* ]]; then
    echo "  ✔ HibernationFixup 已加载"
  else
    echo "  ! HibernationFixup 未加载（重启后仍未加载要看 Kernel/Add 与依赖顺序）"
  fi
  local HIB
  HIB="$(nvram -p 2>/dev/null | awk -F'\t' '$1=="IOHibernateRTCVariables"')"
  if [[ -n "$HIB" ]]; then
    echo "  ! IOHibernateRTCVariables 存在 ⇒ 上次休眠没被 OpenCore 消费（残留，不是好消息）"
  else
    echo "  ✔ IOHibernateRTCVariables 不存在（正常：OC 读到后会立刻删除它）"
  fi

  # ── 内核侧镜像路径：**唯一的硬判据**（2026-10-28 17:30 定位到真正根因）
  # IOHibernateIO.cpp:1520  SYSCTL_STRING(_kern, hibernatefile, gIOHibernateFilename, ...)
  #   ⇒ `sysctl kern.hibernatefile` **实时**就是内核里的写镜像路径，不是快照。
  # IOHibernateIO.cpp:496-506  该变量只有两个来源：
  #   ① IOPMrootDomain 的 "Hibernate File" 属性 —— 本机 ioreg 全量搜 `"Hibernate File"` = 0 次
  #   ② boot-arg hfile=<path>（IOHibernateIO.cpp:1617）
  # 两个都空 ⇒ `if (!gIOHibernateMode || !gIOHibernateFilename[0]) return kIOReturnUnsupported;`
  #   ⇒ 不写镜像、不 panic、立刻退回 ⇒ AppleACPIPlatform 报 (HibernateError)。
  #   这就是 17:23 那次 10 秒内回来、hibernatecount 仍为 0 的机制。
  local HF
  HF="$(sysctl -n kern.hibernatefile 2>/dev/null || true)"
  if [[ -n "$HF" ]]; then
    echo "  ✔ kern.hibernatefile = ${HF}（内核已持有写镜像路径）"
  else
    echo "  ✘ kern.hibernatefile 为空 ⇒ 内核不知道该往哪写镜像，休眠必然 HibernateError"
    echo "     本机成因：IOPMrootDomain 没有 \"Hibernate File\" 属性（ioreg 全量 0 命中）"
    echo "     修法一（免重启）：sudo sysctl -w kern.hibernatefile=/var/vm/sleepimage"
    echo "     修法二（持久）：boot-args 加 hfile=/var/vm/sleepimage，重启后这条自动变绿"
    blocked=1
  fi

  # ── sleepimage：它**不是**前提，是结果（2026-10-28 17:20 修正）
  # 早前把它当"硬前提"并断言"只在启动时按 hibernatemode 分配"——重启验证推翻：
  # hibernatemode=25 开机后镜像仍然不存在（VM 卷只有 kernelcore，swap 也是 0）。
  # 真正决定镜像写不写的是 standby / autopoweroff，见 man pmset：
  #   "Whether or not a hibernation image gets written is also dependent on the
  #    values of standby and autopoweroff"
  #   "To disable hibernation images completely, ensure hibernatemode standby and
  #    autopoweroff are all set to 0."
  # ⇒ standby=0 会直接抑制写入，hibernatemode=25 被静默降级成普通睡眠。
  #   所以这里只做提示，真正的判据在 C 段。
  # ★ 位置修正（17:30）：镜像写到 **hfile 指定的路径**，本机即 /var/vm/sleepimage（Data 卷），
  #   而不是 /System/Volumes/VM/sleepimage（VM 卷那份是 swap/内核转储用的，dev 不同）。
  #   之前把 /var/vm 那份当成"残留"是错的；它才是 XNU 的目标文件。
  local SI MEM SZ
  SI="$(sysctl -n kern.hibernatefile 2>/dev/null || true)"
  [[ -n "$SI" ]] || SI="/var/vm/sleepimage"
  MEM="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  # 不可变标志：会让内核直写打开失败（uchg ⇒ 0 ms 返回 kIOReturnNoSpace）
  if [[ -f "$SI" ]]; then
    local SFL; SFL="$(stat -f %Sf "$SI" 2>/dev/null || true)"
    case "$SFL" in
      *uchg*|*schg*|*restricted*)
        echo "  ✘ sleepimage 带不可变标志（${SFL}）⇒ 内核写不进去，必失败；arm 会自动清 uchg/schg"
        blocked=1
        ;;
      *) echo "  ✔ sleepimage 无不可变标志（${SFL:-无}）" ;;
    esac
  fi
  if [[ -f "$SI" ]]; then
    SZ="$(stat -f %z "$SI" 2>/dev/null || echo 0)"
    if [[ "$SZ" -gt $((MEM / 2)) ]]; then
      echo "  ✔ sleepimage 已分配：$(awk -v s="$SZ" 'BEGIN{printf "%.1f GiB", s/1073741824}')"
    else
      echo "  ! sleepimage 仅 ${SZ} 字节（内存 $((MEM / 1073741824)) GiB）"
      echo "     未分配不等于做不了：IOPMrootDomain 已有 \"Hibernate File Min\"（1 GiB）"
      echo "     ⇒ IOHibernateIO.cpp:578-612 的 preflight 会算出 setFileSizeMin 并自行扩展/创建"
    fi
  else
    echo "  ! sleepimage 尚未分配（不等于阻塞：standby=1 时内核休眠准备阶段会自行创建）"
    echo "     若 C 段 standby 已是 1 而这里仍长期不出现，才说明休眠路径根本没走到"
  fi

  echo
  echo "=== C. 电源策略"
  $PMSET -g custom 2>/dev/null | grep -E "hibernatemode|standby |standbydelay|autopoweroff|sleep " | sed 's/^/    /'
  local HM SB
  HM="$($PMSET -g | awk '/hibernatemode/{print $2}')"
  SB="$($PMSET -g | awk '/^ *standby /{print $2}')"
  # ★ pmset 里的值是「偏好」，内核真正用的是 gIOHibernateMode（sysctl 可直读）。
  #   2026-10-29 08:56 实测：pmset AC 侧 = 25，而 sysctl = 1 ⇒ 二者可以不一致，
  #   而决定睡法的只有内核那个。arm 会显式核对并 sysctl 补写。
  local KM
  KM="$(sysctl -n kern.hibernatemode 2>/dev/null || echo '')"
  if [[ "$HM" == "0" ]]; then
    echo "  ! hibernatemode = 0（尚未武装，属安全态）"
  else
    echo "  ✔ hibernatemode = ${HM}（pmset 偏好）"
  fi
  if [[ -n "$KM" && "$HM" != "0" && "$KM" != "$HM" ]]; then
    echo "  ✘ 内核态 kern.hibernatemode=${KM} ≠ pmset ${HM} ⇒ 真睡下去按 ${KM} 走，不是 25"
    echo "     修法：sudo sysctl -w kern.hibernatemode=${HM}（arm 会自动做）"; blocked=1
  elif [[ -n "$KM" ]]; then
    echo "  ✔ 内核态 kern.hibernatemode = ${KM}"
  fi
  # ★ standby=0 会直接抑制休眠镜像写入（man pmset 原文），此时 hibernatemode=25
  #   会被静默降级成普通睡眠 —— 这是 2026-10-28 17:04 那次失败的真正原因。
  if [[ "$HM" != "0" && "$SB" == "0" ]]; then
    echo "  ✘ standby = 0 ⇒ 镜像不会被写，hibernatemode ${HM} 会被降级成普通睡眠"; blocked=1
    echo "     依据：man pmset —— hibernation image 是否写入还取决于 standby / autopoweroff"
  elif [[ "$SB" == "1" ]]; then
    echo "  ✔ standby = 1（允许写休眠镜像）"
  fi

  echo
  if [[ "$blocked" -eq 0 ]]; then
    echo "=== 结论：静态与运行态均就绪，可以 sudo $0 arm"
  else
    echo "=== 结论：有 ✘ 项，按上面的提示处理后再武装（不一定是重启问题，看 ✘ 的具体内容）"
  fi
}

do_check_wrap() { do_check; }

# ───────────────────────── arm ─────────────────────────
do_arm() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "需要 root，正在提权重跑…"
    exec sudo "$0" arm
  fi

  echo "=== 前置门槛（不满足则拒绝武装，避免又做一次不可判读的测试）"
  local blocked=0
  local KS
  KS="$(/usr/sbin/kextstat 2>/dev/null || true)"
  if [[ "$KS" != *"as.lvs1974.HibernationFixup"* ]]; then
    echo "  ✘ HibernationFixup 未加载 ⇒ 重启后再说"; blocked=1
  else
    echo "  ✔ HibernationFixup 已加载"
  fi
  local RBA; RBA=$(nvram -p 2>/dev/null | awk -F'\t' '$1=="boot-args"{print $2}')
  case "$RBA" in
    *rtcfx_exclude=0E-57,5A-7F*)
      echo "  ✔ rtcfx_exclude=0E-57,5A-7F（放开校验和 0x58/0x59 与密钥区 0x80–0xAB）" ;;
    *rtcfx_exclude=0E-FF*|*rtcfx_exclude=0E-7F*)
      echo "  ✘ 运行态仍封着 0x80–0xAB ⇒ 休眠密钥写不进 RTC；需重启生效"; blocked=1 ;;
    *)
      echo "  ✘ 运行态 rtcfx_exclude 非预期值（${RBA:-空}）⇒ 本次开机没吃到新 config"; blocked=1 ;;
  esac
  # 校验和开关：必须 false，否则内容变了校验和不跟 ⇒ boot.efi 判 mismatch ⇒ 清 RTC
  local CFG=/Volumes/ESP/EFI/OC/config.plist
  [[ -f "$CFG" ]] || CFG=/Volumes/Common/workplace/zbookpowerg7/EFI/OC/config.plist
  local DRC
  DRC="$(/usr/libexec/PlistBuddy -c 'Print :Kernel:Quirks:DisableRtcChecksum' "$CFG" 2>/dev/null || echo unknown)"
  if [[ "$DRC" == "false" ]]; then
    echo "  ✔ DisableRtcChecksum=false（允许 AppleRTC 更新 0x58/0x59 主校验和）"
  else
    echo "  ✘ DisableRtcChecksum=${DRC} ⇒ 校验和不会随内容更新，恢复必失败"; blocked=1
  fi
  # 静态 config 改过但没重启 ⇒ quirk 不会生效，睡了也是旧配置，纯白测
  local CFG_MT BOOT_T
  CFG_MT="$(stat -f %m "$CFG" 2>/dev/null || echo 0)"
  BOOT_T="$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/')"
  if [[ -n "$BOOT_T" && "$CFG_MT" -gt "$BOOT_T" ]]; then
    echo "  ✘ config.plist 修改时间晚于本次启动（$(( (CFG_MT-BOOT_T)/60 )) 分钟）⇒ 改动未生效，必须重启"
    blocked=1
  fi
  if [[ "$RBA" == *"-hbfxforce"* ]]; then
    echo "  ✔ 运行态 boot-args 含 -hbfxforce"
  else
    echo "  ✘ 运行态 boot-args 缺 -hbfxforce ⇒ 本次开机没吃到新 config"; blocked=1
  fi
  # ★ 硬门槛：内核必须持有写镜像路径，否则睡下去必然 (HibernateError)
  #   依据 IOHibernateIO.cpp:504 `if (!gIOHibernateMode || !gIOHibernateFilename[0])
  #   return kIOReturnUnsupported;` —— 不写镜像、不 panic、几秒内退回。
  local HF; HF="$(sysctl -n kern.hibernatefile 2>/dev/null || true)"
  if [[ -z "$HF" ]]; then
    # 免重启通道：kern.hibernatefile 是 CTLFLAG_RW 的 SYSCTL_STRING
    #   IOHibernateIO.cpp:1519 `SYSCTL_STRING(_kern, OID_AUTO, hibernatefile,
    #     CTLFLAG_RW | CTLFLAG_KERN | CTLFLAG_LOCKED, gIOHibernateFilename, ...)`
    #   ⇒ 直接写 gIOHibernateFilename 数组本身，绕开 IOPMrootDomain 属性。
    # 反例（别再当主路）：`pmset <src> hibernatefile` 走 setProperties 那条
    #   （IOPMrootDomain.cpp:2002/2051 `kIOHibernateFileKey` ⇒ setProperty），
    #   本机实测不落地：写完 ioreg 里仍无 "Hibernate File" 属性、sysctl 仍为空。
    echo "  ! kern.hibernatefile 为空，尝试运行态直写 sysctl…"
    sysctl -w kern.hibernatefile=/var/vm/sleepimage >/dev/null 2>&1 || true
    HF="$(sysctl -n kern.hibernatefile 2>/dev/null || true)"
    if [[ -n "$HF" ]]; then
      echo "  ✔ 运行态下发成功：kern.hibernatefile = ${HF}（无需重启）"
    fi
  fi
  if [[ -n "$HF" ]]; then
    echo "  ✔ kern.hibernatefile = ${HF}"
  else
    echo "  ✘ kern.hibernatefile 仍为空 ⇒ 内核不知道往哪写镜像，睡了也是 HibernateError"
    echo "     成因：IOPMrootDomain 没有 \"Hibernate File\" 属性（ioreg 全量 0 命中），gIOHibernateFilename 无人赋值"
    echo "     修法一（免重启）：sudo sysctl -w kern.hibernatefile=/var/vm/sleepimage"
    echo "     修法二（持久）：boot-args 已含 hfile=/var/vm/sleepimage，重启后由 IOHibernateSystemInit 写入"
    blocked=1
  fi
  # sleepimage 不是前提，是结果：standby=1 时内核在休眠准备阶段自行创建/扩展。
  # 早前把它写成硬门槛并断言"只在启动时分配"，重启验证已推翻（见 check 的 B 段注释）。
  local SI; SI="${HF:-/var/vm/sleepimage}"
  # ★★ 不可变标志 = 2026-10-28 17:44 那次失败的真正根因
  #   uchg（UF_IMMUTABLE）/schg 下**即使 root 也不能写/扩/截断**该文件
  #   ⇒ `kern_open_file_for_direct_io()` 返回 NULL ⇒ IOPolledInterface.cpp:651
  #     把它一律映射成 kIOReturnNoSpace(e00002db)。
  #   证据链：内核日志 `IOPolledFileOpen(e00002db)` 与 preflight 同毫秒（0 ms 即失败）、
  #           文件至今 0 字节且 mtime 不动、`ls -lO` 显示 uchg。
  #   休眠路径自身不清这些标志（xnu 休眠相关文件 grep chflags/IMMUTABLE = 0 命中）。
  if [[ -f "$SI" ]]; then
    local FL; FL="$(stat -f %Sf "$SI" 2>/dev/null || true)"
    case "$FL" in
      *uchg*|*schg*)
        echo "  ! 镜像带不可变标志（${FL}）⇒ 内核无法写入，正在清除…"
        chflags nouchg "$SI" 2>/dev/null || true
        chflags noschg "$SI" 2>/dev/null || true
        FL="$(stat -f %Sf "$SI" 2>/dev/null || true)"
        if [[ "$FL" == *uchg* || "$FL" == *schg* ]]; then
          echo "  ✘ 清不掉（仍为 ${FL}）⇒ 别睡，先手动 chflags"; blocked=1
        else
          echo "  ✔ 已清除（现为 ${FL:-无}）"
        fi
        ;;
      *restricted*)
        echo "  ! 镜像带 restricted 标志（${FL}）—— 需 SIP 关闭才能清，若睡失败先查它"
        ;;
    esac
  fi
  if [[ -f "$SI" ]]; then
    echo "  ✔ 镜像文件已存在（$(awk -v s="$(stat -f %z "$SI" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f GiB", s/1073741824}')）"
  else
    echo "  ! 镜像文件尚未存在 —— 不拦，standby=1 时休眠准备阶段会自行创建"
  fi
  if [[ $blocked -ne 0 ]]; then
    echo
    echo "已中止：前置条件不满足，此刻武装等于再做一次不可判读的测试。"
    echo "按上面的 ✘ 项处理，然后跑：bash $0 check"
    exit 3
  fi

  # 只武装当前电源源 —— 另一侧保持 Deep Idle，避免「拔电出门踩到无人看管的地雷」（09-16 18:27 教训）
  local SRC SN
  local BATT
  BATT="$($PMSET -g batt 2>/dev/null || true)"
  if [[ "$BATT" == *"'AC Power'"* ]]; then SRC="-c"; SN="AC（插电）"; else SRC="-b"; SN="Battery（电池）"; fi

  echo
  echo "=== 武装【${SN}】侧（另一侧保持 hibernatemode 0 / standby 0）"
  # 镜像路径：内核写休眠镜像的唯一来源（powers 已由上面前置门槛校验并尝试下发）
  # ★ `pmset hibernatefile` 只写 plist（让 pmset -g 好看），对内核无效；
  #   真正落地的是 sysctl 直写 gIOHibernateFilename，两行都留。
  $PMSET "$SRC" hibernatefile /var/vm/sleepimage >/dev/null 2>&1 || true
  sysctl -w kern.hibernatefile=/var/vm/sleepimage >/dev/null 2>&1 || true
  $PMSET "$SRC" hibernatemode 25
  # ★ pmset 与内核态可以不一致（2026-10-29 08:56 实测 pmset=25 / sysctl=1）。
  #   kern.hibernatemode 是 SYSCTL_UINT + CTLFLAG_RW，直接指向 gIOHibernateMode
  #   （IOHibernateIO.cpp:1526）⇒ root 可直写。这是让"真按 25 睡"落地的硬保险。
  if [[ "$(sysctl -n kern.hibernatemode 2>/dev/null)" != "25" ]]; then
    echo "  ! 内核态 hibernatemode 不是 25，sysctl 直写修正…"
    sysctl -w kern.hibernatemode=25 >/dev/null 2>&1 || true
  fi
  local KM; KM="$(sysctl -n kern.hibernatemode 2>/dev/null || echo '?')"
  if [[ "$KM" != "25" ]]; then
    echo "  ✘ 内核态 kern.hibernatemode = ${KM}（不是 25）⇒ 这一觉会按 ${KM} 走，测了也判不出来"
    echo "     已回滚到安全档（hibernatemode 0 / standby 0 / sleep 15），请先把内核态弄成 25"
    $PMSET "$SRC" hibernatemode 0 >/dev/null 2>&1 || true
    $PMSET "$SRC" standby 0 >/dev/null 2>&1 || true
    $PMSET "$SRC" sleep 15 >/dev/null 2>&1 || true
    echo "=== 已中止武装。"
    return 1
  fi
  echo "  ✔ 内核态 kern.hibernatemode = 25"
  # ★ standby 必须为 1。man pmset 原文：hibernation image 是否写入"also dependent on
  #   the values of standby and autopoweroff"，而 standby=0 会彻底关掉镜像写入
  #   ⇒ hibernatemode 25 被静默降级成普通睡眠。这是 2026-10-28 17:04 失败的真正原因。
  $PMSET "$SRC" standby 1
  $PMSET "$SRC" highstandbythreshold 50
  # 25 理论上是"立刻写盘断电"，standbydelay 不参与；设成 300 s 只在 25 行为异常时兜底，
  # 让"睡下去 5 分钟后必落盘"这条退路仍然有效。
  $PMSET "$SRC" standbydelaylow 300
  $PMSET "$SRC" standbydelayhigh 300
  $PMSET "$SRC" sleep 0

  local OTHER
  if [[ "$SRC" == "-c" ]]; then OTHER="-b"; else OTHER="-c"; fi
  $PMSET "$OTHER" hibernatemode 0
  $PMSET "$OTHER" standby 0

  echo
  $PMSET -g custom | grep -E "hibernatemode|standby|sleep" | sed 's/^/    /'
  echo
  echo "=== 接下来的人工步骤"
  echo "  1) 拔掉外接 USB 鼠标 / U 盘（鼠标一动就立刻唤醒，会截断这次测试）"
  echo "     └ **外接显示器不用拔**：日常就是接屏用的，S4 必须在接屏状态下成立才有意义。"
  echo "       恢复后内建屏（port 0）先亮，它就是判读窗口；外屏（port 6/7）回没回来"
  echo "       是**独立观测项**，不是成败判据 —— 只记下来，别当失败。"
  echo "  2) 开盖状态，苹果菜单 → 睡眠（**别合盖**）"
  echo "     └ 本机实测 AppleClamshellCausesSleep = No：AC + 外屏时合盖进 clamshell，"
  echo "       机器继续跑根本不睡，你会白测一轮；且 DSDT 里有两个 LID 设备，"
  echo "       合盖事件归属不可靠、行为不可复现"
  echo "  3) 25 模式应在睡眠瞬间就写盘断电（20–60 s）；若迟迟不落盘，"
  echo "     standbydelay 300 s 会兜底 —— 但它只负责「写盘」，断电与否看电源灯"
  echo "     判据：电源灯灭、功率计掉到 ~0 W、风扇停"
  echo "  4) 按电源键唤醒 —— 不要指望开盖：本机 pmset 里没有 lidwake 项，开盖唤醒不可依赖"
  echo "  5) 若内建屏也不亮：先拔插一次 HDMI 再等 10 s。仍黑则长按电源键重启，"
  echo "     开机后查 pmset -g log 判「恢复了但屏没亮」还是「压根没恢复」"
  echo
  echo "=== 回来后的取证（判读见脚本头部，注意方向别搞反）"
  echo "  sysctl kern.hibernatecount               # 只表示'进过写镜像阶段'，失败也+1，**别拿它判成败**"
  echo "  pmset -g log | grep -e Hibernat -e 'Entering' -e 'Wake from' | tail -6"
  echo "                                           # 出现 /HibernateError = 失败；无它且断电 = 成功"
  echo "  sysctl -n kern.hibernatefile             # 醒后仍应为 /var/vm/sleepimage"
  echo "  ls -lh /var/vm/sleepimage                # ← 这才是写镜像的目标（Data 卷）"
  echo "                                           #   醒后应明显增长（≥1 GiB，大小随压缩率变，不是固定 16G）"
  echo "                                           #   /System/Volumes/VM/sleepimage 是 VM 卷的 swap/转储，别混"
  echo "  sudo log show --last 40m --predicate 'process == \"kernel\"' --style compact \\"
  echo "    | grep -e 'IOHibernateSystemSleep is called' -e 'IOHibernateSystemWake is called' \\"
  echo "           -e 'NVStorage path entered' -e 'kIOHibernateRTCVariables is' -e 'wake type is'"
  echo "                                           # 本机 kext 是自编译 fork，DEBUG 串已编入，日志可读"
  echo "                                           # result is: 0x0 = 成功；0xe00002c9/0xe00002db 等 = 失败码"
  echo "                                           # 'PMRootDomain key present' + '44 bytes' = 密钥已交出"
  echo "  nvram -p | grep -i hiber                 # 【注意】有输出反而是坏信号：OC 读到后会立刻删掉它"
  echo "  system_profiler SPDisplaysDataType | grep -e 'Connection Type' -e 'Resolution'"
  echo "                                           # 外屏是否自己回来了（独立观测项，不是成败判据）"
}

# ───────────────────────── disarm ─────────────────────────
do_disarm() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "需要 root，正在提权重跑…"
    exec sudo "$0" disarm
  fi
  echo "=== 回滚到 Deep Idle 基线（hibernatemode 0 / standby 0）"
  $PMSET -a hibernatemode 0
  $PMSET -a standby 0
  $PMSET -a standbydelaylow 10800
  $PMSET -a standbydelayhigh 86400
  $PMSET -c sleep 10
  $PMSET -b sleep 15
  $PMSET -a disksleep 1
  echo "  注意：hibernatemode 归 0 后写镜像目标 /var/vm/sleepimage 可能被回收（基线行为，不必在意）"
  $PMSET -g custom | grep -E "hibernatemode|standby|sleep" | sed 's/^/    /'
}

usage() {
  # 动态打印头部注释块（不再硬编码行号——注释一加长就会把「用法」段落截掉）
  awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"
  echo
  echo "用法: bash $0 {check|arm|disarm}"
  echo "  check   只读体检，不需要 root，不改任何状态（A 静态 / B 运行态 / C 电源策略）"
  echo "  arm     武装**当前电源源**为 hibernatemode=25，自动提权；另一侧留安全档"
  echo "  disarm  回滚到 Deep Idle 基线（hibernatemode 0 / standby 0），自动提权"
}

case "${1:-}" in
  check)  do_check_wrap ;;
  arm)    do_arm ;;
  disarm) do_disarm ;;
  *)      usage; exit 1 ;;
esac
