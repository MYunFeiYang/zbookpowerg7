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
#   Misc/Security              不含 AllowNvramReset（OC 1.0.x 已移除该键，是死配置）
#   UEFI/Drivers               ResetNvramEntry.efi=true（真正的 Reset NVRAM 逃生口）
#
# ── 用法
#   ./s4-arm.sh check      只读体检（不需要 root）：静态配置 + 运行态 + 电源策略
#   sudo ./s4-arm.sh arm   武装（自动 sudo）：**只武装当前电源源**，另一侧留安全档
#   sudo ./s4-arm.sh disarm 回滚到 Deep Idle 基线
#
# ── 判读（一次睡眠后三选一）
#   方向先记住：OC 读到 IOHibernateRTCVariables 后**立刻把它删掉**（AppleHibernate.c:173-183）
#   ⇒ 醒后 nvram 里还查得到它 = OC 压根没消费，是**坏信号**；查不到才是正常。
#   v1) kern.hibernatecount 从 0 变 1 且会话原样恢复    ⇒ NVRAM 路线成立，可转日常用
#   v2) 计数变了但醒不来 / 半途重启                    ⇒ 卡在 boot.efi 恢复，查镜像/密文
#   v3) pmset -g log 只有 Entering Sleep、计数仍 0     ⇒ 没走休眠路径，或 macOS 26 没在
#       PMRootDomain 放密钥（HBFX 日志会直接打 "PMRootDomain key MISSING"）
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
  # ★ 位置：真实镜像在 VM 卷 /System/Volumes/VM/sleepimage；
  #   /var/vm/sleepimage 在 Data 卷上是另一份（0 字节残留，dev 不同）。
  local SI MEM SZ
  SI="/System/Volumes/VM/sleepimage"
  MEM="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  if [[ -f "$SI" ]]; then
    SZ="$(stat -f %z "$SI" 2>/dev/null || echo 0)"
    if [[ "$SZ" -gt $((MEM / 2)) ]]; then
      echo "  ✔ sleepimage 已分配：$(awk -v s="$SZ" 'BEGIN{printf "%.1f GiB", s/1073741824}')"
    else
      echo "  ! sleepimage 仅 ${SZ} 字节（内存 $((MEM / 1073741824)) GiB）"
      echo "     未分配不等于做不了：standby=1 时内核会在休眠准备阶段自行扩展（见 C 段）"
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
  if [[ "$HM" == "0" ]]; then
    echo "  ! hibernatemode = 0（尚未武装，属安全态）"
  else
    echo "  ✔ hibernatemode = ${HM}"
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
  # sleepimage 不是前提，是结果：standby=1 时内核在休眠准备阶段自行创建/扩展。
  # 早前把它写成硬门槛并断言"只在启动时分配"，重启验证已推翻（见 check 的 B 段注释）。
  local SI; SI="/System/Volumes/VM/sleepimage"
  if [[ -f "$SI" ]]; then
    echo "  ✔ sleepimage 已存在（$(awk -v s="$(stat -f %z "$SI" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f GiB", s/1073741824}')）"
  else
    echo "  ! sleepimage 尚未存在 —— 不拦，standby=1 时休眠准备阶段会自行创建"
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
  $PMSET "$SRC" hibernatemode 25
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
  echo "  sysctl kern.hibernatecount               # 成功一次 +1（基线 0）"
  echo "  ls -lh /System/Volumes/VM/sleepimage    # 应≈16G、mtime 是刚才（别查 /var/vm/，那是残留）"
  echo "  pmset -g log | grep -e Hibernat -e 'Entering Sleep' | tail -5"
  echo "                                           # 出现 'Entering Hibernate' = 走的是休眠不是普通睡"
  echo "  log show --last 30m --predicate 'eventMessage CONTAINS \"HBFX\"' | tail -30"
  echo "                                           # 'PMRootDomain key present/44 bytes' = 密钥交出来了"
  echo "                                           # 'MISSING' = macOS 26 没给，要改 kext 取数方式"
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
  echo "  注意：hibernatemode 归 0 后 macOS 会删掉 /System/Volumes/VM/sleepimage（基线行为）"
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
