#!/bin/bash
#
# RTC 写保护「四层」生效性核验（**只读**，不改任何东西、不需要 sudo）
#
# 背景与判读：docs/sleep-tests/round2-tierB-result.md §二十四
#
# 为什么需要它：本机「真休眠」失败 5 次、坏 RTC 2 次，长尾原因是**防护一直是残缺的** ——
#   · Apple 的写路径每次会把 `0x0E–0xFF` 共 242 字节**整体重写**（AppleRtcRam.c）
#   · 而 `0x0E–0x7F` 以前从没被任何一层拦过；`boot.efi` 协议层更是零防护
#   ⇒ 本脚本用来确认「四层」是否**真的都落地了**（改配置 ≠ 生效）。
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
WS_PLIST="$SCRIPT_DIR/../oc/config.plist"          # 工作区真源（git）
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
  *rtcfx_exclude=0E-FF*) ok "含 rtcfx_exclude=0E-FF —— bank1 的 0E–7F 也封了（新配置已生效）" ;;
  *rtcfx_exclude=80-FF*) bad "仍是旧值 80-FF ⇒ 本次开机**没吃到**新配置（ESP 没同步？还没重启？）" ;;
  *rtcfx_exclude=*)      warn "有 rtcfx_exclude 但不是 0E-FF，请自行核对：$(echo "$BA" | tr ' ' '\n' | grep rtcfx_exclude)" ;;
  *)                     bad "boot-args 里**没有** rtcfx_exclude ⇒ 新配置未生效" ;;
esac

# ---------------------------------------------------------------- 2) 运行期：NVRAM 变量
hdr "2) 运行期 NVRAM 变量 $GUID:rtc-blacklist（AppleRtcRam 协议的寄存器名单）"
if NVRAM_OUT="$(nvram "$GUID:rtc-blacklist" 2>&1)"; then
  if [ -n "$NVRAM_OUT" ]; then
    ok "变量存在（前 100 字符）：$(printf '%s' "$NVRAM_OUT" | cut -c1-100)"
    echo "     ⚠️ 需人工确认长度 = 242 字节（内容 0E 0F … FF）"
  else
    warn "变量存在但内容为空 —— 预期的 242 字节没写进去"
  fi
else
  warn "nvram 读不到该变量（有两种可能：① 真没写进去；② macOS 的 nvram 工具不列非 Apple GUID 变量）"
  echo "     ⇒ 以第 3 项的 ESP 配置为准；进一步可用 OpenCore 自带的 RtcRw 从 EFI 侧 dump"
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

  # ⚠️ 不能用 `plutil -extract … json`：data 类型会报 "Invalid object in plist for JSON format"。
  #    `raw` 对 data 输出的是 **base64 文本**（242 字节 ⇒ 324 字符，且以 `Dg8Q` 开头）。
  C="$(plist_extract "NVRAM.Add.$GUID.rtc-blacklist" "$WS_PLIST" | tr -d '[:space:]')"
  CLEN=${#C}
  if [ "$CLEN" = "324" ] && [ "${C:0:4}" = "Dg8Q" ]; then
    ok "rtc-blacklist = 324 字符 base64（= 242 字节，首个 0x0E）✔"
  else
    bad "rtc-blacklist 长度 ${CLEN}（期望 324）/ 前缀 ${C:0:4}（期望 Dg8Q）"
  fi

  D="$(plist_json "NVRAM.Delete.$GUID" "$WS_PLIST" | tr -d ' \n')"
  case "$D" in
    *rtc-blacklist*) ok "NVRAM/Delete 已列 rtc-blacklist（否则旧值不会被覆盖）" ;;
    *)               bad "NVRAM/Delete 未列 rtc-blacklist ⇒ Add 可能不生效" ;;
  esac
fi

if [ -f "$ESP_PLIST" ]; then
  H1="$(shasum -a 256 "$WS_PLIST"  | awk '{print $1}')"
  H2="$(shasum -a 256 "$ESP_PLIST" | awk '{print $1}')"
  echo "  工作区 $H1"
  echo "  ESP    $H2"
  if [ "$H1" = "$H2" ]; then ok "两边一致 —— ESP 已同步（可以重启做实验）"
  else bad "两边**不一致** ⇒ 先在 FreeFileSync 手动点「开始」同步，再重启"; fi
else
  warn "ESP 未挂载（$ESP_MOUNT）⇒ 跳过一致性比对；跳过前不要指望新配置生效"
fi

# ---------------------------------------------------------------- 4) 当前电源策略
hdr "4) 当前电源策略（决定要不要开休眠档）"
pmset -g custom 2>/dev/null | grep -E "^(AC|Battery| System-wide| hibernatemode| standby| standbydelay| autopoweroff| sleep | disksleep)" \
  || warn "pmset -g custom 无输出"
echo "  ⚠️ 现役安全态 = 两电源源 hibernatemode 0 / standby 0"

# ---------------------------------------------------------------- 5) 下一步
hdr "5) 下一步"
cat <<'EOF'
  四项全 ✔ 且已重启 ⇒ 可以开始实验（务必先看好回滚）：
    FORCE_HIBERNATE=1 ./EFI/scripts/pmset-hibernate.sh auto   # 重新武装休眠档
    ... 睡眠一次，记录结果 ...
    ./EFI/scripts/pmset-hibernate.sh off                       # 无论成败先回滚
  判读（决定性，二选一）：
    · 不再报 HP POST 005 ⇒ 属「软件写 RTC」⇒ 风险归零，可从容往下二分定位
    · 照样 005           ⇒ 「软件写 RTC」这一整类**一次性证伪** ⇒ 转固件侧或收手
  失败签名 / 判据：docs/sleep-tests/README.md
EOF
