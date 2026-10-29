#!/bin/bash
#
# S4 恢复段日志采集 —— 读 ESP 上 OC 写的 opencore-*.txt，看 boot.efi 的
# `AAPL: #[EB...]` 流停在哪一行。停住的那一行就是失败点。
#
# 为什么这份日志能看见恢复段（2026-10-29 12:50 实测坐实）
#   Misc/Debug/AppleDebug=true  +  Target 含 0x04(DataHub) 与 0x40(文件)
#   ⇒ boot.efi 自己的调试流被 OC 转发进 ESP 根目录的 opencore-<UTC时间>.txt。
#   实测样本 opencore-2026-10-29-042738.txt 共 107 行，末行
#   `AAPL: #[EB|LOG:EXITBS:START]` —— 覆盖到 ExitBootServices 之前最后一条。
#   而 S4 恢复的关键动作（读镜像头 → 验签 → 解密 → 装回 wired pages → 拷 __HIB → 跳转）
#   全部发生在 ExitBootServices **之前** ⇒ 这一段是完全可观测的。
#
# 判读（最重要的一条）
#   末行含 `LOG:EXITBS:START`  ⇒ 该次启动顺利过了恢复段（或走的是冷启动），不是失败现场
#   末行不含                  ⇒ 就是失败现场，末行即死点
#   然后看最后几条 `EB.H.*`：
#     EB.H.CHK  = 镜像头 / 校验
#     EB.H.LV   = 装载与解密
#     EB.H.ST   = 装回页面（这一步之后才需要物理地址）
#     EB.H.EXIT = 恢复段收尾
#
# 用法: bash EFI/scripts/s4-log-collect.sh [份数，默认3]
#       只读，不改任何东西，不需要 root。

set -uo pipefail

ESP="${ESP:-/Volumes/ESP}"
N="${1:-3}"

if [[ ! -d "$ESP" ]]; then
  echo "ESP 未挂载。先执行: diskutil mount disk0s1"
  echo "（挂载偶发报 failed to mount 但实际已挂，用 mount | grep disk0s1 确认）"
  exit 1
fi

LOGS=$(ls -1t "$ESP"/opencore-*.txt 2>/dev/null | head -"$N")
if [[ -z "$LOGS" ]]; then
  echo "ESP 根目录没有 opencore-*.txt。"
  echo "检查 config: Misc/Debug/Target 是否含 0x40，以及 Misc/Debug/AppleDebug。"
  exit 1
fi

nz() { tr -d '\0' < "$1" | wc -c | tr -d ' '; }

echo "=== ESP 上最新 $N 份 OC 日志（文件名时间是 UTC，+8 为北京时间）==="
echo

i=0
for f in $LOGS; do
  i=$((i+1))
  base=$(basename "$f")
  sz=$(nz "$f")
  printf '[%d] %s  非零 %s B\n' "$i" "$base" "$sz"

  if [[ "$sz" -eq 0 ]]; then
    echo "    ⚠ 全零字节（旧毛病，该次没写出日志）"
    echo
    continue
  fi

  # boot.efi 日志首行时间
  first=$(tr -d '\0' < "$f" | grep -am1 'LOG:INIT' | sed 's/.*LOG:INIT\] //')
  [[ -n "$first" ]] && echo "    起始: $first (UTC)"

  # 末一条非空行
  last=$(tr -d '\0' < "$f" | grep -a . | tail -1)
  echo "    末行: ${last:0:160}"

  # 判读：是否越过 EXITBS
  if tr -d '\0' < "$f" | grep -aq 'LOG:EXITBS:START'; then
    echo "    ✔ 末段含 LOG:EXITBS:START ⇒ 该次启动**已越过恢复段**（不是失败现场）"
  else
    echo "    ★★ 末段**没有** LOG:EXITBS:START ⇒ 这就是失败现场，末行即死点 ★★"
  fi

  # EB.H.* 序列
  cnt=$(tr -d '\0' < "$f" | grep -ac 'EB\.H')
  echo "    EB.H.* 条目数: $cnt"
  if [[ "$cnt" -gt 0 ]]; then
    echo "    --- EB.H 序列（全量）---"
    tr -d '\0' < "$f" | grep -a 'EB\.H' | sed 's/^/      /'
  fi
  echo
done

echo "=== 判读速查 ==="
cat <<'EOF'
  EB.H.IS  0        = 不是休眠启动（冷启动的正常值）
  EB.H.IS  非0      = 认出休眠镜像状态
  EB.H.CHK BM <hex> = 镜像头校验位图
  EB.H.LV           = 装载/解密阶段
  EB.H.ST           = 装回页面阶段 ← 到这一步才和「绝对物理地址」有关
  LOG:EXITBS:START  = 恢复段走完、即将交接给内核（含此行的不是失败现场）

  若停在 EB.H.LV   ⇒ 密钥/解密问题，与地址无关
  若停在 EB.H.ST   ⇒ 物理布局问题，此时才需要 UEFI Shell memmap 取地址
EOF
