#!/bin/bash
#
# RTC 写保护「四层」生效性核验（**只读**，不改任何东西、不需要 sudo）
#
# 背景与判读：docs/sleep-tests/round2-tierB-result.md §二十四
#
# 当前策略（2026-10-28 起）：**休眠变量走 NVRAM，RTC 全封不碰**。
#   本机「真休眠」(S4) 历史上失败 5 次、坏 RTC 2 次，所以 RTC 一个字节都不该被 macOS 改。
#   HibernationFixup 被改成强制把 IOHibernateRTCVariables 写进 NVRAM（-hbfxforce），
#   OpenCore 的 HibernateMode=Auto 会去 NVRAM 读，全程不依赖 RTC 0x80–0xAB。
#   ⇒ 防护恢复为**封满 0x0E–0xFF（242 字节）**，0x80–0xAB 必须缺席（即被封）。
# 为什么仍需本脚本：确认「四层」**真的都落地了**（改配置 ≠ 生效）。
#
# 用法：
#   ./EFI/scripts/rtc-protect-verify.sh                # ESP 默认挂载点 /Volumes/ESP
#   ./EFI/scripts/rtc-protect-verify.sh /Volumes/OCESP  # 自定义挂载点
#
# 判读：
#   1~2 项 = 运行期证据（要看本次开机是否真吃到新配置 → 必须**已重启**）
#   3 项   = 部署证据（工作区 ↔ ESP 是否逐字节一致）
#   4 项   = 当前电源策略（决定要不要开休眠档做实验）
#
set -u

GUID="4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"
BOOTARGS_GUID="7C436110-AB2A-4BBB-A880-FE41995C9F82"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_PLIST="$SCRIPT_DIR/../OC/config.plist"          # 工作区真源（git）
ESP_MOUNT="${1:-/Volumes/ESP}"
ESP_PLIST="$ESP_MOUNT/EFI/OC/config.plist"

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

plist_extract() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
plist_json()    { plutil -extract "$1" json -o - "$2" 2>/dev/null; }

# ---------------------------------------------------------------- 1) 运行期：boot-args
hdr "1) 运行期 boot-args（本次开机由 OpenCore 传入）"
BA="$(sysctl -n kern.bootargs 2>/dev/null || echo '')"
if [ -n "$BA" ]; then echo "  $BA"; else warn "读不到 kern.bootargs"; fi
case "$BA" in
  *rtcfx_exclude=0E-FF*)  ok "含 rtcfx_exclude=0E-FF —— 0x0E–0xFF 全封，RTC 一个字节都不让 macOS 改" ;;
  *rtcfx_exclude=0E-7F*)  bad "仍是 0E-7F,AC-FF（留出了 0x80–0xAB）⇒ 本次开机没吃到新配置（ESP 没同步？还没重启？）" ;;
  *rtcfx_exclude=80-FF*)  bad "仍是更旧的 80-FF ⇒ 本次开机没吃到新配置" ;;
  *rtcfx_exclude=*)       warn "有 rtcfx_exclude 但范围非预期，请自行核对：$(echo "$BA" | tr ' ' '\n' | grep rtcfx_exclude)" ;;
  *)                      bad "boot-args 里**没有** rtcfx_exclude ⇒ 新配置未生效" ;;
esac
case "$BA" in
  *-hbfxforce*) ok "含 -hbfxforce —— HibernationFixup 走强制 NVRAM 路线" ;;
  *)            bad "缺 -hbfxforce ⇒ fork 版 kext 不会被触发，休眠变量无处可写" ;;
esac
case "$BA" in
  *-hbfxdbg*) ok "含 -hbfxdbg —— 可看 HBFX 日志" ;;
  *)          warn "缺 -hbfxdbg ⇒ 失败时拿不到 kext 内部日志" ;;
esac

# ---------------------------------------------------------------- 2) 运行期：NVRAM 变量
hdr "2) 运行期 NVRAM 变量 $GUID:rtc-blacklist（AppleRtcRam 协议的寄存器名单）"
echo "  语义：名单内的偏移由 OpenCore 用**内存模拟**，读写都不落真实 RTC。"
if NVRAM_OUT="$(nvram "$GUID:rtc-blacklist" 2>&1)"; then
  if [ -n "$NVRAM_OUT" ]; then
    ok "变量存在（前 100 字符）：$(printf '%s' "$NVRAM_OUT" | cut -c1-100)"
    echo "     ⚠️ 需人工确认长度 = 242 字节（0x0E–0xFF 全段，含 0x80–0xAB）"
  else
    warn "变量存在但内容为空 —— 预期的 242 字节没写进去"
  fi
else
  warn "nvram 读不到该变量（有两种可能：① 真没写进去；② macOS 的 nvram 工具不列非 Apple GUID 变量）"
  echo "     ⇒ 以第 3 项的配置为准；进一步可用 OpenCore 自带的 RtcRw 从 EFI 侧 dump"
fi
echo
echo "  休眠变量落点（走 NVRAM 路线后应出现，值随每次休眠变化）："
if HIB="$(nvram "$BOOTARGS_GUID:IOHibernateRTCVariables" 2>&1)" && [ -n "$HIB" ]; then
  ok "IOHibernateRTCVariables 存在，${#HIB} 字符 ⇒ HibernationFixup 写入成功"
else
  warn "IOHibernateRTCVariables 不存在 —— 未休眠过属正常；休眠过仍缺席则说明 kext 没写进去"
fi

# ---------------------------------------------------------------- 3) 部署期：工作区 ↔ ESP
hdr "3) 部署期：工作区 config.plist 的四项（真源）+ 与 ESP 是否逐字节一致"
if [ ! -f "$WS_PLIST" ]; then
  bad "找不到工作区真源：$WS_PLIST"
else
  A="$(plist_extract UEFI.ProtocolOverrides.AppleRtcRam "$WS_PLIST")"
  [ "$A" = "true" ] && ok "UEFI/ProtocolOverrides/AppleRtcRam = true" \
                    || bad "UEFI/ProtocolOverrides/AppleRtcRam = ${A:-读不到}（应为 true）"

  B="$(plist_extract "NVRAM.Add.$BOOTARGS_GUID.boot-args" "$WS_PLIST")"
  case "$B" in
    *rtcfx_exclude=0E-FF*) ok "boot-args 含 rtcfx_exclude=0E-FF" ;;
    *)                     bad "boot-args 不含 0E-FF" ;;
  esac
  case "$B" in
    *-hbfxforce*) ok "boot-args 含 -hbfxforce" ;;
    *)            bad "boot-args 缺 -hbfxforce" ;;
  esac

  # ⚠️ 不能用 `plutil -extract … json`：data 类型会报 "Invalid object in plist for JSON format"。
  #    `raw` 对 data 输出的是 **base64 文本**（242 字节 ⇒ 324 字符，且以 `Dg8Q` 开头）。
  C="$(plist_extract "NVRAM.Add.$GUID.rtc-blacklist" "$WS_PLIST" | tr -d '[:space:]')"
  CLEN=${#C}
  if [ "$CLEN" = "324" ] && [ "${C:0:4}" = "Dg8Q" ]; then
    ok "rtc-blacklist = 324 字符 base64（= 242 字节：0x0E–0xFF 全封，首个 0x0E）✔"
  else
    bad "rtc-blacklist 长度 ${CLEN}（期望 324）/ 前缀 ${C:0:4}（期望 Dg8Q）"
  fi

  D="$(plist_json "NVRAM.Delete.$GUID" "$WS_PLIST" | tr -d ' \n')"
  case "$D" in
    *rtc-blacklist*) ok "NVRAM/Delete 已列 rtc-blacklist（否则旧值不会被覆盖）" ;;
    *)               bad "NVRAM/Delete 未列 rtc-blacklist ⇒ Add 可能不生效" ;;
  esac

  K="$(plist_extract Kernel.Add.1.BundlePath "$WS_PLIST")"
  [ "$K" = "HibernationFixup.kext" ] && ok "Kernel/Add[1] = HibernationFixup.kext（紧跟 Lilu）" \
                                     || warn "Kernel/Add[1] = ${K:-读不到}（顺序变了？）"
  M="$(plist_extract Misc.Boot.HibernateMode "$WS_PLIST")"
  [ "$M" = "Auto" ] && ok "Misc/Boot/HibernateMode = Auto（RTC 优先、NVRAM 兜底）" \
                    || bad "Misc/Boot/HibernateMode = ${M:-读不到}（应为 Auto）"
fi

if [ -f "$ESP_PLIST" ]; then
  H1="$(shasum -a 256 "$WS_PLIST"  | awk '{print $1}')"
  H2="$(shasum -a 256 "$ESP_PLIST" | awk '{print $1}')"
  echo "  工作区 $H1"
  echo "  ESP    $H2"
  if [ "$H1" = "$H2" ]; then ok "两边一致 —— ESP 已同步（可以重启做实验）"
  else bad "两边**不一致** ⇒ 先同步 ESP，再重启"; fi
else
  warn "ESP 未挂载（${ESP_MOUNT}）⇒ 跳过一致性比对；跳过前不要指望新配置生效"
fi

# ---------------------------------------------------------------- 4) 当前电源策略
hdr "4) 当前电源策略（决定要不要开休眠档）"
pmset -g custom 2>/dev/null | grep -E "^(AC|Battery| System-wide| hibernatemode| standby| standbydelay| autopoweroff| sleep | disksleep)" \
  || warn "pmset -g custom 无输出"
echo "  ⚠️ 现役安全态 = 两电源源 hibernatemode 0 / standby 0"

# ---------------------------------------------------------------- 5) 下一步
hdr "5) 下一步"
cat <<'EOF'
  全 ✔ 且已重启 ⇒ 可以武装并试睡（结论与判据见 docs/s4-nvram-route-2026-10-28.md）：
    bash EFI/scripts/s4-arm.sh check     # 只读体检
    sudo bash EFI/scripts/s4-arm.sh arm   # 武装当前电源源（hibernatemode 25）
    ... 睡眠一次 ...
    sudo bash EFI/scripts/s4-arm.sh disarm
  判读（决定性）：
    · v1) nvram 出现 IOHibernateRTCVariables + 能恢复 ⇒ NVRAM 路线成立
    · v2) 出现变量但醒不来   ⇒ 卡在 boot.efi 恢复，查密文/镜像
    · v3) 变量始终不出现     ⇒ macOS 26 没往 PMRootDomain 放密钥，此路需改 kext 取数方式
EOF
