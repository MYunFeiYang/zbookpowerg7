#!/bin/bash
#
# S4（真休眠）首测准备 / 武装 / 回滚
#
# 目的：把「hibernatemode 25 真休眠」所需配置一次配齐，并给出「是否真的配齐」的机器判据。
#       配置不齐就上机 = 测出来的结果不可判读（2026-09-16 / 09-21 两轮教训）。
#
# ── 原理：macOS 休眠依赖什么（源码级，不是社区经验）
#
#   入睡：kernel 把整份内存镜像加密写入 sleepimage，同时把 16 B AES 密钥 + 20 B 签名
#         连同 "AAPL" 标记打成 AppleRTCHibernateVars 交给「固件可读的地方」。
#   唤醒：boot.efi 必须拿回这 44 B，才能解密并还原内存；拿不到就按冷启动处理（丢会话）。
#
#   44 字节结构（OpenCorePkg Include/Apple/IndustryStandard/AppleHibernate.h）
#     typedef struct {
#       UINT8 signature[4];       // "AAPL"
#       UINT32 revision;
#       UINT8 booterSignature[20];
#       UINT8 wiredCryptKey[16];  // AES-128
#     } AppleRTCHibernateVars;    // sizeof = 44
#
#   黑苹果没有真 SMC，这 44 B 只有两个落点：
#     ① RTC 0x80–0xAB —— 正好 44 字节（0xAB-0x80+1=44），即 RTCMemoryFixup README 说的
#        "Offsets from 0x80 to 0xAB are used to store some hibernation information"
#     ② NVRAM 变量 IOHibernateRTCVariables，GUID = gAppleBootVariableGuid
#        = 7C436110-AB2A-4BBB-A880-FE41995C9F82（就是 SystemAudioVolume 那个域）
#
# ── OC 侧如何取回（Library/OcBootManagementLib/AppleHibernate.c :: OcActivateHibernateWake）
#     mask 定义（Include/Acidanthera/Library/OcBootManagementLib.h:1168）
#       HIBERNATE_MODE_NONE 0 / RTC 1 / NVRAM 2        ⇒ Auto = 1|2
#     if (HibernateMask & HIBERNATE_MODE_RTC) {
#         for (Index = 0; Index < sizeof(AppleRTCHibernateVars); Index++)
#             RtcRawVars[Index] = OcRtcRead(Index + 128);      // 读偏移 128 = 0x80 起
#         HasHibernateInfo = signature == "AAPL";
#     }
#     if (HibernateMask & HIBERNATE_MODE_NVRAM) {
#         GetVariable2("IOHibernateRTCVariables", &gAppleBootVariableGuid, ...);
#         if (!HasHibernateInfo && ...) { 用 NVRAM 的 };        // ← RTC 优先，NVRAM 只兜底
#         ... 取完立即 SetVariable(..., 0, NULL) 擦除（一次性）
#     }
#     if (HasHibernateInfo) {
#         SetVariable("boot-image-key",  wiredCryptKey);        // 16 B
#         SetVariable("boot-signature",  booterSignature);      // 20 B
#     }
#   ⇒ 这两条才是 boot.efi 真正吃的东西（OcIsAppleHibernateWake 也只认它们）。
#
# ── HibernationFixup 在本机到底做不做（1.5.4 kern_hbfx.cpp:91）
#     if (!callbackHBFX->checkRTCExtendedMemory()) { ...写 NVRAM... }
#   该判定的实现（Lilu Sources/kern_rtc.cpp:44）只有一句：
#     uint8_t off = 0xB4;  /* APPLERTC_POWER_BYTE_PM_ADDR */
#     return read(off, 1, &dst);          // 能读到 RTC 0xB4 ⇒ 认为 RTC 有扩展内存
#   ⇒ 本机 RTC 为 256 B（09-16 封到 0xFF 生效、并能把 CMOS 写坏，反证 0x80–0xFF 真实存在）
#   ⇒ checkRTCExtendedMemory() = true ⇒ **HibernationFixup 整段跳过，一个字节都不写**
#   ⇒ 这也解释了 09-16 失败后 nvram -p 里查无任何休眠变量：不是"来不及生效"，是主动不写。
#
# ── 于是本机只有一条可行链路，三个环节缺一不可
#   ① 44 B 必须真的落在 RTC 0x80–0xAB
#        ⇒ rtcfx_exclude / rtc-blacklist **不能**覆盖 80–AB（否则 macOS 写了也进不去）
#   ② OC 必须去查 RTC
#        ⇒ HibernateMode 必须含 RTC（Auto 或 RTC）。原值 NVRAM 是**死配置**：
#          本机 NVRAM 里永远不会有 IOHibernateRTCVariables（见上，kext 主动不写）
#   ③ OC 读到 "AAPL" 后自动转成 boot-image-key / boot-signature，无需额外配置
#
#   09-16 / 09-21 两轮失败的真正原因 = ① 与 ② 同时不满足：
#     封 80-FF（违反 ①）+ HibernateMode=NVRAM（违反 ②）⇒ 两个来源都是空的 ⇒ 冷启动。
#
# ── 理论可行性（FADT 实测，非推断）
#   FACP-1.aml: FLAGS=0x002384A5
#     bit7  RTC_S4      = 1   RTC 可唤醒 S4
#     bit16 S4_RTC_STS  = 1   S4 唤醒状态位存在
#     bit20 LOW_POWER_S0_IDLE_CAPABLE = 0   ← 注意：bit20 是 0
#     bit21 (规范 reserved)          = 1   ← HP 私有位，09-16 曾被误读成 AOAC
#   LPIT-1.aml: LPI 条目数 = 0 ⇒ 固件**不是** AOAC 低功耗平台，是标准 S3/S4 平台。
#   DSDT: _S3 / _S4(SLP_TYPa=0x06) / _PTS(30115 行完整实现) / _WAK(30205 行) 齐备。
#   跨 OS 反证：同一台机器 Windows / Linux 均可用 S4。
#
# ── 本机配置（2026-10-28，重启生效）
#   Misc/Boot/HibernateMode   NVRAM → **Auto**      ← 关键修正：原来只查 NVRAM，必然查空
#   boot-args                 + -hbfxdbg（取证：确认 kext 是否触发、RTC 是否读到 AAPL）
#   rtcfx_exclude / rtc-blacklist  保持 0E-7F,AC-FF / 198 B（**不含 0x80–0xAB**，58–59 仍保护）
#   Kernel/Add                + HibernationFixup 1.5.4（idx 1，紧跟 Lilu）
#       本机它不写 NVRAM（见上），保留它的理由是 README 的第二项功能：
#       "Enable patching IOPCIFamily in order to avoid hang & black screen after resume"
#       —— 只在休眠路径生效，不影响日常睡眠。
#   Kernel/Quirks             PowerTimeoutKernelPanic true → false
#       （电源转换超时若 panic，会污染判读：分不清是休眠失败还是超时崩溃）
#   Misc/Security             + AllowNvramReset = true（Reset NVRAM 逃生口；此前缺失=Failsafe false）
#   Misc/Boot                 HibernateSkipsPicker = true（已有）

# ── 明确**不加**的项，以及为什么（避免"抄配置"式瞎试）
#   RebuildAppleMemoryMap=false  ← 社区两例都用，但官方文档只说它修「映射>4096 B / MAT 权限 /
#       低内存描述符合并 UAF」三类**启动期**问题，**未**建立它与休眠的因果。
#       本机当前 true 且启动正常 ⇒ 不动（改了只是引入无依据变量）。
#   DiscardHibernateMap=true     ← 官方定义「让 XNU 忽略新内存映射、假设 S4 醒来后没变」，
#       并明确标注「仅老旧罕见硬件（Ivy Bridge + Insyde）的 workaround，不理解后果不要用」。
#       本机 Comet Lake + HP，无依据 ⇒ 保持 false。
#   ReservedMemory 0x8B000/0x1000/RuntimeCode
#       ← **机制有官方支撑**：Configuration.tex 的 ReservedMemory Note 原文
#         「Some types of firmware may not allocate memory areas used by S3 (sleep) and
#           S4 (hibernation) code unless CSM is enabled causing wake failures ... these
#           areas can be found in the lower memory」
#         ⇒ CSM 关闭时固件可能不保留 S4 代码区，这条机制成立。
#       ← 但**地址必须是本机的**：T530 的 0x8B000 是它自己「CSM 开/关对比内存映射」得来的。
#         本机 ioreg -n memory-map 返回空、boot-log 计数 0 ⇒ 拿不到本机映射。
#         盲填 4 KB 保留区没有依据，位置错还会挤掉固件真用的内存 ⇒ 本轮不填。
#         若首测失败且症状是「恢复黑屏 / 半途重启」，再取本机地址：
#           临时开 Misc/Debug/Target 0x40 → 重启 → 读 boot-log 的 memory map →
#           对比 CSM 开/关两版 → 找低内存差异 → 填 ReservedMemory。
#   NVRAM E09B9297-7928-4440-9AAB-D1F8536FBF0A
#       ← HibernationFixup 的 NVRAM options 域。本机不用任何 hbfx-* NVRAM 选项（全走 boot-args），
#         且 DisableVariableWrite=false 不拦写入 ⇒ 无需占位。
#   Kernel/Patch「Disable RTC wake scheduling」= true
#       ← 本机现有，用于压 DarkWake。它与休眠的交互**未证实**（T530 说它会阻止 RTC 定时唤醒，
#         但那是 ahbm 自动转休眠的场景，与本轮手动触发不同）⇒ 视为待观测变量，不动。

# ── 用法
#   ./s4-arm.sh check     只读体检（不需要 root）：静态配置 + 运行态 + 磁盘，逐项给 ✔/✘
#   sudo ./s4-arm.sh arm  武装（自动 sudo）：**只武装当前电源源**，另一侧保持 Deep Idle 安全档
#   sudo ./s4-arm.sh disarm 回滚到当前 Deep Idle 基线（AC sleep 10 / 电池 sleep 15）
#
# ── 判据（成功/失败怎么认）
#   成功   = 睡下后电源灯灭 / 功率计掉到 ~0.2W，开盖（或按电源）能回到原会话
#   半成功 = 断了电但开盖是冷启动 ⇒ Misc/Boot/HibernateMode 不对，或 boot.efi 没读到密钥
#   失败   = 断电后起不来 ⇒ 长按电源；能进系统先 `disarm`
#   硬失败 = 重启后 POST 报 **HP 005 Real-Time Clock Power Loss** + 时钟回 2019-01-01
#            ⇒ RTC 再次被写坏（09-16 发生 2 次、09-21 发生 1 次）
#            ⇒ macOS 也起不来时：OpenCore 选择器 → Reset NVRAM（AllowNvramReset 已开）
#
# ⚠️ 睡前必做：拔掉外接 USB 鼠标 / U 盘（pmset 里它们带 0x4=USB 唤醒断言，蹭一下就唤醒）
# ⚠️ 别合盖测：外接显示器接着会进 clamshell，根本不睡。用「苹果菜单 → 睡眠」。
# ⚠️ 武装期间拔电源 = 切到另一侧安全档，这次就测不出来。

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
  echo "=== A. EFI 静态配置（${CFG}）"
  if [[ ! -f "$CFG" ]]; then fail "config.plist 不存在"; return 1; fi

  local RES
  RES=$(python3 - "$CFG" "$KEXT_DIR" <<'PY'
import plistlib, sys, os
cfg, kdir = sys.argv[1], sys.argv[2]
d = plistlib.load(open(cfg, 'rb'))
ok = bad = 0
def p(m):
    global ok; ok += 1; print("  ✔ " + m)
def f(m):
    global bad; bad += 1; print("  ✘ " + m)
def w(m): print("  ! " + m)

# 1 HibernationFixup 条目
add = d['Kernel']['Add']
h = [e for e in add if e.get('BundlePath') == 'HibernationFixup.kext']
if h:
    p("Kernel/Add 含 HibernationFixup.kext（Enabled=%s，共 %d 项）" % (h[0].get('Enabled'), len(add)))
    idx = add.index(h[0])
    lilu = [i for i, e in enumerate(add) if e.get('BundlePath') == 'Lilu.kext']
    if lilu and idx > lilu[0]:
        p("加载顺序在 Lilu 之后（idx %d > %d）" % (idx, lilu[0]))
    else:
        f("加载顺序在 Lilu 之前或缺失 Lilu ⇒ 依赖不满足")
else:
    f("Kernel/Add 无 HibernationFixup.kext")

# 2 kext 文件
if os.path.isdir(kdir):
    p("kext 文件就位：%s" % os.path.basename(kdir))
else:
    f("kext 文件缺失：%s" % kdir)

# 3 HibernateMode —— 决定 OC 去哪个来源找休眠变量
hm = d['Misc']['Boot'].get('HibernateMode')
if hm == 'Auto':
    p("Misc/Boot/HibernateMode = Auto（mask=RTC|NVRAM，源码中 RTC 分支先跑、NVRAM 仅兜底）")
elif hm == 'NVRAM':
    f("Misc/Boot/HibernateMode = NVRAM ⇒ **只查 NVRAM**；而 HibernationFixup 在 RTC 可读 0xB4 时不写 NVRAM ⇒ 必然检测不到")
elif hm == 'RTC':
    w("Misc/Boot/HibernateMode = RTC（只查 RTC，能用但少了 NVRAM 兜底）")
else:
    f("Misc/Boot/HibernateMode = %r（None=忽略休眠状态，断电后只会冷启动）" % hm)

# 4 HibernateSkipsPicker
sp = d['Misc']['Boot'].get('HibernateSkipsPicker')
if sp is True:
    p("Misc/Boot/HibernateSkipsPicker = true")
else:
    w("Misc/Boot/HibernateSkipsPicker = %r（建议 true，恢复时跳过选择器）" % sp)

# 5 PowerTimeoutKernelPanic
pt = d['Kernel']['Quirks'].get('PowerTimeoutKernelPanic')
if pt is False:
    p("Kernel/Quirks/PowerTimeoutKernelPanic = false（电源转换超时不 panic）")
else:
    f("Kernel/Quirks/PowerTimeoutKernelPanic = %r（应为 false，否则超时会内核崩溃、污染判读）" % pt)

# 6 AllowNvramReset
an = d['Misc']['Security'].get('AllowNvramReset')
if an is True:
    p("Misc/Security/AllowNvramReset = true（Reset NVRAM 逃生口可用）")
else:
    f("Misc/Security/AllowNvramReset = %r（缺失即 false ⇒ 没有 Reset NVRAM 逃生口）" % an)

# 7 boot-args
nv = d['NVRAM']['Add'].get('7C436110-AB2A-4BBB-A880-FE41995C9F82', {})
ba = nv.get('boot-args', '') or ''
if '-hbfxdbg' in ba:
    p("boot-args 含 -hbfxdbg（取证日志开启）")
else:
    w("boot-args 无 -hbfxdbg ⇒ 无法从内核日志确认 kext 是否触发")
m = [t for t in ba.split() if t.startswith('rtcfx_exclude=')]
val = m[0].split('=', 1)[1] if m else ''
if not m:
    f("boot-args 无 rtcfx_exclude（RTC 写通道完全敞开，风险最高）")
else:
    def covers(spec, lo, hi):
        for item in spec.split(','):
            item = item.strip()
            if not item: continue
            if '-' in item:
                a, b = item.split('-', 1)
                a, b = int(a, 16), int(b, 16)
            else:
                a = b = int(item, 16)
            if a <= lo and b >= hi:
                return True
        return False
    if covers(val, 0x80, 0xAB):
        f("rtcfx_exclude=%s **覆盖** 0x80–0xAB ⇒ macOS 写的 AAPL 签名+密钥进不了 RTC，OC 必读不到" % val)
    else:
        p("rtcfx_exclude=%s 未覆盖 0x80–0xAB ⇒ 休眠变量可写入/读出" % val)

# 8 RTC 校验
if d['Kernel']['Quirks'].get('DisableRtcChecksum') is True:
    p("Kernel/Quirks/DisableRtcChecksum = true（0x58–0x59 不校验；已由 rtc-blacklist 另加保护）")

# 8b rtc-blacklist 口径（静态；运行态读不到，见 B 段说明）
try:
    bl = d['NVRAM']['Add']['4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102']['rtc-blacklist']
    cov = set(bl)
    hit = [x for x in range(0x80, 0xAC) if x in cov]
    if hit:
        f("rtc-blacklist 排除了 %d 个 0x80–0xAB 偏移（首个 0x%02X）⇒ 休眠变量写不进 RTC" % (len(hit), hit[0]))
    else:
        p("rtc-blacklist = %d B，未排除 0x80–0xAB；0x58–0x59 %s" % (
            len(bl), "已保护" if 0x58 in cov else "**未保护**"))
except KeyError:
    f("NVRAM rtc-blacklist 缺失 ⇒ AppleRtcRam 没有黑名单")

# 9 内存映射：与休眠**无**已证实的因果关系，只看是否被误改
rm = d['Booter']['Quirks'].get('RebuildAppleMemoryMap')
if rm is True:
    p("Booter/Quirks/RebuildAppleMemoryMap = true（保持原值：官方文档未建立它与休眠的因果）")
else:
    w("Booter/Quirks/RebuildAppleMemoryMap = %r（社区案例用 false，但无原理支撑；改了要自负风险）" % rm)

print("RESULT %d %d" % (ok, bad))
PY
)
  echo "$RES" | sed '/^RESULT /d'
  local ra rb
  ra=$(echo "$RES" | awk '/^RESULT /{print $2}')
  rb=$(echo "$RES" | awk '/^RESULT /{print $3}')
  ok=$((ok + ${ra:-0}))
  bad=$((bad + ${rb:-0}))

  echo
  echo "=== B. 运行态（重启后才反映新配置）"
  if /usr/sbin/kextstat 2>/dev/null | grep -q "as.lvs1974.HibernationFixup"; then
    ver=$(/usr/sbin/kextstat 2>/dev/null | awk '/as.lvs1974.HibernationFixup/{print $6}')
    pass "HibernationFixup 已加载（v${ver}）"
  else
    fail "HibernationFixup **未加载** ⇒ 尚未重启，或加载失败"
  fi
  RBA=$(nvram -p 2>/dev/null | awk -F'\t' '$1=="boot-args"{print $2}')
  if [[ "$RBA" == *"-hbfxdbg"* ]]; then
    pass "NVRAM boot-args 已含 -hbfxdbg（新配置已生效）"
  else
    fail "NVRAM boot-args 仍是旧值 ⇒ 尚未重启"
  fi
  if [[ "$RBA" == *"rtcfx_exclude=0E-7F,AC-FF"* ]]; then
    pass "NVRAM rtcfx_exclude = 0E-7F,AC-FF（80–AB 可写，休眠变量能落地）"
  else
    fail "NVRAM rtcfx_exclude 未更新：${RBA:-<空>}"
  fi
  BL=$(nvram -p 2>/dev/null | awk -F'\t' '$1=="rtc-blacklist"{print $2}' | base64 -D 2>/dev/null | wc -c | tr -d ' ')
  if [[ "${BL:-0}" -gt 0 ]]; then
    pass "rtc-blacklist 运行态可读，${BL} B"
  else
    warn "rtc-blacklist 运行态读不到（它在 4D1FDA02 GUID 下，macOS nvram 工具通常不列非 Apple GUID）⇒ 以 A 段静态检查为准"
  fi
  if [[ -d /Volumes/ESP/EFI/OC ]]; then
    A=$(shasum -a 256 "$CFG" 2>/dev/null | awk '{print $1}')
    B=$(shasum -a 256 /Volumes/ESP/EFI/OC/config.plist 2>/dev/null | awk '{print $1}')
    if [[ "$A" == "$B" && -n "$A" ]]; then
      pass "ESP 侧 config 与工作区一致（${A:0:8}…）"
    else
      fail "ESP 侧 config 不一致（工作区 ${A:0:8}… / ESP ${B:0:8}…）⇒ 同步未完成，重启吃的是旧配置"
    fi
  else
    warn "ESP 未挂载（diskutil mount disk0s1），跳过同步校验"
  fi

  echo
  echo "=== C. pmset 与磁盘"
  CUR=$($PMSET -g batt 2>/dev/null | head -1)
  if [[ "$CUR" == *"'AC Power'"* ]]; then SRC="-c"; SN="AC（插电）"; else SRC="-b"; SN="Battery（电池）"; fi
  echo "  当前电源源：$SN"
  HM=$($PMSET -g custom 2>/dev/null | awk -v s="$([[ $SRC == -c ]] && echo 'AC Power:' || echo 'Battery Power:')" '
     $0==s{f=1;next} /^[A-Za-z].*:$/{f=0} f&&$1=="hibernatemode"{print $2;exit}')
  echo "  hibernatemode($SRC) = ${HM:-?}   （0=不写盘 / 25=落盘断电）"
  echo "  standby      = $($PMSET -g | awk '$1=="standby"{print $2}')   （=0 ⇒ mode 25 也不会落盘）"
  echo "  disksleep    = $($PMSET -g | awk '$1=="disksleep"{print $2}')"
  if [[ -e /System/Volumes/VM/sleepimage ]]; then
    echo "  sleepimage   = $(ls -lh /System/Volumes/VM/sleepimage | awk '{print $5}')"
  else
    echo "  sleepimage   = 不存在（hibernatemode 0 下正常，武装后会由 macOS 自建）"
  fi
  AVAIL=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
  echo "  根卷可用     = ${AVAIL} GB"
  if [[ -n "$AVAIL" && "$AVAIL" -lt 20 ]]; then
    warn "可用空间 < 20 GB（sleepimage 由 macOS 自建，实测 1 GiB，但留余量更稳）"
  fi

  echo
  echo "─── 小结：$ok 项通过 / $bad 项未通过 ───"
  if [[ $bad -eq 0 ]]; then
    echo "配置已就位，可以上机。"
    return 0
  else
    echo "★ 有 $bad 项未通过（★ 标 ✘ 的多为「需重启生效」）。重启后再跑一次 check，全绿再 arm。"
    return 1
  fi
}

# 运行时直接调用 do_check 会因 subshell 丢失计数，改为此包装（见文末调用）
do_check_wrap() { do_check; }

# ───────────────────────── arm ─────────────────────────
do_arm() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "需要 root，正在提权重跑…"
    exec sudo "$0" arm
  fi

  echo "=== 前置门槛（不满足则拒绝武装，避免又做一次不可判读的测试）"
  local blocked=0
  if ! /usr/sbin/kextstat 2>/dev/null | grep -q "as.lvs1974.HibernationFixup"; then
    echo "  ✘ HibernationFixup 未加载 ⇒ 重启后再说"; blocked=1
  else
    echo "  ✔ HibernationFixup 已加载"
  fi
  local RBA; RBA=$(nvram -p 2>/dev/null | awk -F'\t' '$1=="boot-args"{print $2}')
  if [[ "$RBA" == *"rtcfx_exclude=0E-7F,AC-FF"* ]]; then
    echo "  ✔ rtcfx_exclude 未覆盖 0x80–0xAB（休眠变量可写）"
  else
    echo "  ✘ rtcfx_exclude 仍是旧值（${RBA:-空}）⇒ 重启后再说"; blocked=1
  fi
  if [[ $blocked -ne 0 ]]; then
    echo
    echo "已中止：当前机器跑的还是**旧配置**，此刻武装等于复刻 09-16/09-21 的失败前提。"
    echo "先重启（新 config 已同步 ESP），重启后跑：bash $0 check"
    exit 3
  fi

  # 只武装当前电源源 —— 另一侧保持 Deep Idle，避免「拔电出门踩到无人看管的地雷」（09-16 18:27 教训）
  local SRC SN
  if $PMSET -g batt 2>/dev/null | head -1 | grep -q "'AC Power'"; then SRC="-c"; SN="AC（插电）"; else SRC="-b"; SN="Battery（电池）"; fi

  echo
  echo "=== 武装【$SN】侧（另一侧保持 hibernatemode 0 / standby 0）"
  $PMSET "$SRC" hibernatemode 25
  $PMSET "$SRC" standby 1
  $PMSET "$SRC" highstandbythreshold 50
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
  echo "  1) 拔掉外接 USB 鼠标 / U 盘"
  echo "  2) 苹果菜单 → 睡眠（**别合盖**，接外屏会进 clamshell 不睡）"
  echo "  3) 等 8–10 分钟（standbydelay 300 s = 5 分钟后才落盘）"
  echo "  4) 看电源灯是否灭 / 功率计是否掉到 ~0.2 W"
  echo "  5) 开盖或按电源键唤醒"
  echo
  echo "=== 回来后的取证（一条条跑，判读见脚本头部）"
  echo "  pmset -g log | grep -E 'Entering Sleep|Entering Hibernate|Wake from' | tail -20"
  echo "  nvram -p | grep -i hiber                 # 有输出 = NVRAM 腿生效"
  echo "  ls -l /System/Volumes/VM/sleepimage      # 尺寸/mtime 变化 = 真的写了镜像"
  echo "  sysctl kern.hibernatecount               # 历史成功休眠计数"
  echo "  log show --last 30m --predicate 'eventMessage CONTAINS \"HBFX\"' | tail -30   # -hbfxdbg 日志"
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
  echo "  注意：hibernatemode 归 0 后 macOS 会删掉 /System/Volumes/VM/sleepimage（基线行为）"
  $PMSET -g custom | grep -E "hibernatemode|standby|sleep" | sed 's/^/    /'
}

case "${1:-}" in
  check)  do_check_wrap ;;
  arm)    do_arm ;;
  disarm) do_disarm ;;
  *)      sed -n '2,40p' "$0"; exit 1 ;;
esac
