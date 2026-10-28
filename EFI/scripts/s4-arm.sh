#!/bin/bash
#
# S4 休眠 —— 「NVRAM 存休眠变量、RTC 全封」路线的体检 / 武装 / 回滚
#
# ── 一句话策略
#   让 HibernationFixup 把 IOHibernateRTCVariables 写进 **NVRAM**，OpenCore 的
#   HibernateMode=NVRAM 只去 NVRAM 读；RTC 0x0E–0xFF 全程封死，macOS 一个字节都改不到。
#
# ── 为什么不是「走 RTC」（2026-10-28 结论）
#   Apple 的休眠密钥固定落在 RTC 0x80 起 44 字节：
#     AppleRtc.h: APPLE_RTC_HIBERNATION_KEY_ADDR=0x80, _LENGTH=0x2C
#                 注释 "effectively equals sizeof (AppleRTCHibernateVars)"
#   但 Apple 的主校验和 0x58/0x59 覆盖范围是 [0x0E, 0x100)，**包含 0x80–0xAB**。
#   而 OpenCore 的 rtc-blacklist 并非"拦截写"，而是**内存模拟**：
#     AppleRtcRam.c: mEmulatedRtcStatus[RtcBlacklist[i]] = TRUE
#                    SyncRtcWrite -> 命中则只写内存，永不落真实 RTC
#   ⇒ 若把 0x58/0x59 封着、却放开 0x80–0xAB，就会出现"内容变了、校验和不跟"
#     ⇒ boot.efi 判 mismatch ⇒ 调 AppleRtcRamReset 把 0x40–0xFF 清零 ⇒ 密钥自毁。
#     这正是本机历史上「坏 RTC 2 次」的机制。
#   ⇒ 结论：要么两边一起放开（等于让 Apple 自由改 BIOS 的 CMOS 区），要么两边都别碰。
#     选后者：完全不碰 RTC，只走 NVRAM。
#
# ── NVRAM 腿为什么以前不存在（已解决）
#   HibernationFixup 上游只服务「RTC 只有 1 bank(128 B)」的机器（README 开篇原话），
#   而本机 RTC 是 256 B ⇒ 判定函数只做 read(0xB4)（Lilu kern_rtc.cpp:44）
#   ⇒ 恒成功 ⇒ kern_hbfx.cpp:91 的 `if (!checkRTCExtendedMemory())` 整段跳过
#   ⇒ NVRAM 里永远没有休眠变量（实测至今 0 条）。
#   现改用**自编译 fork**：新增 boot-arg `-hbfxforce`，把该条件变为
#   `!checkRTCExtendedMemory() || forceNvram`，强制走 NVRAM 写入分支。
#   源码与构建记录：docs/s4-nvram-route-2026-10-28.md
#
# ── 本机配置（2026-10-28）
#   Kernel/Add[1]              HibernationFixup.kext（自编译 fork，紧跟 Lilu）
#   Misc/Boot/HibernateMode    NVRAM（只读 NVRAM；Auto 会被 RTC 残留 AAPL 签名劫持）
#   Misc/Debug/Target          69 (0x45)（含 0x40 ⇒ boot-log 走 Data Hub）
#   boot-args                  rtcfx_exclude=0E-FF -hbfxdbg -hbfxforce
#   rtc-blacklist              242 B（0x0E–0xFF 全封，含 0x80–0xAB）
#   Kernel/Quirks              PowerTimeoutKernelPanic=false（超时不 panic，免污染判读）
#   Misc/Security              AllowNvramReset=true（Reset NVRAM 逃生口）
#
# ── 用法
#   ./s4-arm.sh check      只读体检（不需要 root）：静态配置 + 运行态 + 电源策略
#   sudo ./s4-arm.sh arm   武装（自动 sudo）：**只武装当前电源源**，另一侧留安全档
#   sudo ./s4-arm.sh disarm 回滚到 Deep Idle 基线
#
# ── 判读（一次睡眠后三选一）
#   v1) nvram 出现 IOHibernateRTCVariables 且能恢复  ⇒ NVRAM 路线成立，可转日常用
#   v2) 变量出现但醒不来                            ⇒ 卡在 boot.efi 恢复，查镜像/密文
#   v3) 变量始终不出现                              ⇒ macOS 26 没往 PMRootDomain 放密钥
#                                                      ⇒ 需改 kext 取数方式（HBFX 日志会直接
#                                                        打印 "PMRootDomain key MISSING"）
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
if hm == 'NVRAM':
    p("Misc/Boot/HibernateMode = NVRAM（只读 NVRAM，不被 RTC 残留签名劫持）")
elif hm == 'Auto':
    w("Misc/Boot/HibernateMode = Auto（先读 RTC；若 RTC 有残留 AAPL 签名会盖掉 NVRAM 的正确值）")
else:
    f("Misc/Boot/HibernateMode = %r（应为 NVRAM，否则不读 NVRAM）" % hm)

# 3b Debug Target 是否含 0x40（本机 OC 文件日志坏，只能走 Data Hub）
tgt = d['Misc']['Debug'].get('Target', 0) or 0
if tgt & 0x40:
    p("Misc/Debug/Target = %d (0x%02X)，含 0x40 ⇒ boot-log 可从 Data Hub 取" % (tgt, tgt))
else:
    f("Misc/Debug/Target = %d (0x%02X)，缺 0x40 ⇒ 拿不到 OCB 休眠判读日志（本机文件日志是坏的）" % (tgt, tgt))

if d['Misc']['Boot'].get('HibernateSkipsPicker') is True:
    p("Misc/Boot/HibernateSkipsPicker = true")
else:
    w("Misc/Boot/HibernateSkipsPicker = %r（建议 true）" % d['Misc']['Boot'].get('HibernateSkipsPicker'))

# 4 PowerTimeoutKernelPanic
if d['Kernel']['Quirks'].get('PowerTimeoutKernelPanic') is False:
    p("Kernel/Quirks/PowerTimeoutKernelPanic = false（超时不 panic）")
else:
    f("Kernel/Quirks/PowerTimeoutKernelPanic = %r（应为 false，否则超时会内核崩溃）" % d['Kernel']['Quirks'].get('PowerTimeoutKernelPanic'))

# 5 逃生口
if d['Misc']['Security'].get('AllowNvramReset') is True:
    p("Misc/Security/AllowNvramReset = true（Reset NVRAM 逃生口可用）")
else:
    f("Misc/Security/AllowNvramReset = %r（缺失即 false ⇒ 无逃生口）" % d['Misc']['Security'].get('AllowNvramReset'))

# 6 boot-args
nv = d['NVRAM']['Add'].get('7C436110-AB2A-4BBB-A880-FE41995C9F82', {})
ba = nv.get('boot-args', '') or ''
if '-hbfxforce' in ba:
    p("boot-args 含 -hbfxforce")
else:
    f("boot-args 缺 -hbfxforce ⇒ fork 逻辑不触发，休眠变量无处可写")
if '-hbfxdbg' in ba:
    p("boot-args 含 -hbfxdbg（HBFX 日志可用）")
else:
    w("boot-args 缺 -hbfxdbg ⇒ 失败时看不到 kext 内部判读")

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
if not m:
    f("boot-args 无 rtcfx_exclude ⇒ RTC 写通道完全敞开（本机曾因此坏 RTC 2 次）")
elif covers(val, 0x0E, 0xFF):
    p("rtcfx_exclude=%s 覆盖 0x0E–0xFF（RTC 全封，休眠不依赖它）" % val)
else:
    f("rtcfx_exclude=%s 未覆盖 0x0E–0xFF ⇒ 有 RTC 区会被 macOS 改写，风险面变大" % val)

# 7 rtc-blacklist
try:
    bl = d['NVRAM']['Add']['4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102']['rtc-blacklist']
    cov = set(bl)
    full = all(x in cov for x in range(0x0E, 0x100))
    if len(bl) == 242 and full:
        p("rtc-blacklist = 242 B，0x0E–0xFF 全覆盖（含 0x80–0xAB）")
    elif len(bl) == 198 and not any(0x80 <= x <= 0xAB for x in cov):
        f("rtc-blacklist = 198 B 且留出 0x80–0xAB ⇒ 这是旧的 RTC 路线配置（校验和会失配）")
    else:
        f("rtc-blacklist = %d B（期望 242），含 0x80–0xAB=%s" % (len(bl), any(0x80 <= x <= 0xAB for x in cov)))
except KeyError:
    f("NVRAM 里没有 rtc-blacklist ⇒ AppleRtcRam 无名单，RTC 不受控")

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
    if [[ "$RBA" == *"rtcfx_exclude=0E-FF"* ]]; then
      echo "  ✔ 运行态 rtcfx_exclude=0E-FF（RTC 全封已生效）"
    else
      echo "  ✘ 运行态 rtcfx_exclude 非 0E-FF"; blocked=1
    fi
  else
    echo "  ✘ NVRAM boot-args 尚无 -hbfxforce ⇒ 未重启或 ESP 未同步"; blocked=1
    # 注意：旧配置的运行态本来就是 rtcfx_exclude=0E-FF，单看它无法区分新旧 ⇒ 只作提示
    if [[ "$RBA" == *"rtcfx_exclude=0E-FF"* ]]; then
      echo "  ! 运行态 rtcfx_exclude=0E-FF —— 与旧配置同值，不能作为'新配置已生效'的证据"
    fi
  fi
  if kextstat 2>/dev/null | grep -q HibernationFixup; then
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

  echo
  echo "=== C. 电源策略"
  $PMSET -g custom 2>/dev/null | grep -E "hibernatemode|standby |standbydelay|sleep " | sed 's/^/    /'
  local HM
  HM="$($PMSET -g | awk '/hibernatemode/{print $2}')"
  if [[ "$HM" == "0" ]]; then
    echo "  ! hibernatemode = 0（尚未武装，属安全态）"
  else
    echo "  ✔ hibernatemode = ${HM}"
  fi

  echo
  if [[ "$blocked" -eq 0 ]]; then
    echo "=== 结论：静态与运行态均就绪，可以 sudo $0 arm"
  else
    echo "=== 结论：有 ✘ 项，重启或同步 ESP 后再武装"
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
  if ! /usr/sbin/kextstat 2>/dev/null | grep -q "as.lvs1974.HibernationFixup"; then
    echo "  ✘ HibernationFixup 未加载 ⇒ 重启后再说"; blocked=1
  else
    echo "  ✔ HibernationFixup 已加载"
  fi
  local RBA; RBA=$(nvram -p 2>/dev/null | awk -F'\t' '$1=="boot-args"{print $2}')
  if [[ "$RBA" == *"rtcfx_exclude=0E-FF"* ]]; then
    echo "  ✔ rtcfx_exclude=0E-FF（RTC 0x0E–0xFF 全封，走 NVRAM 不依赖 RTC）"
  else
    echo "  ✘ 运行态 rtcfx_exclude 不是 0E-FF（${RBA:-空}）⇒ 本次开机没吃到新 config"; blocked=1
  fi
  if [[ "$RBA" == *"-hbfxforce"* ]]; then
    echo "  ✔ 运行态 boot-args 含 -hbfxforce"
  else
    echo "  ✘ 运行态 boot-args 缺 -hbfxforce ⇒ 本次开机没吃到新 config"; blocked=1
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
  # hibernatemode 25 是「立刻写镜像 + 断内存电」，与 3 的 standby 渐进逻辑无关。
  # standby 必须为 0，否则多一条 Apple 私有策略参与，变量越多越难判读。
  $PMSET "$SRC" standby 0
  $PMSET "$SRC" sleep 0

  local OTHER
  if [[ "$SRC" == "-c" ]]; then OTHER="-b"; else OTHER="-c"; fi
  $PMSET "$OTHER" hibernatemode 0
  $PMSET "$OTHER" standby 0

  echo
  $PMSET -g custom | grep -E "hibernatemode|standby|sleep" | sed 's/^/    /'
  echo
  echo "=== 接下来的人工步骤"
  echo "  1) 拔掉外接 USB 鼠标 / U 盘 / 外接显示器"
  echo "  2) 苹果菜单 → 睡眠（**别合盖**：合盖会进 clamshell，走别的路径）"
  echo "  3) 约 20–60 s 内镜像就落盘并断电（25 模式不等 standbydelay）"
  echo "     判据：电源灯灭、功率计掉到 ~0 W、风扇停"
  echo "  4) 按电源键唤醒（或开盖）"
  echo
  echo "=== 回来后的取证（判读见脚本头部，注意方向别搞反）"
  echo "  ls -l /System/Volumes/VM/sleepimage      # 尺寸≈内存、mtime 变成刚才 = 真的写了镜像"
  echo "  sysctl kern.hibernatecount               # 历史成功休眠计数是否 +1"
  echo "  ioreg -lw0 -p IODeviceTree | grep boot-log | sed 's/.*<\\(.*\\)>.*/\\1/' | xxd -r -p | grep -a OCB"
  echo "                                           # ↑ 出现 'NVRAM hibernation is 1 / Success / 44' = 成立"
  echo "  nvram -p | grep -i hiber                 # 【注意】有输出反而是坏信号：OC 读到后会立刻删掉它"
  echo "  log show --last 30m --predicate 'eventMessage CONTAINS \"HBFX\"' | tail -30"
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
