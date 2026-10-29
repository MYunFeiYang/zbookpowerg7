#!/bin/bash
#
# S4 恢复段日志采集 —— 读 ESP 上 OC 写的 opencore-*.txt，用 boot.efi 自己的
# `AAPL: #[EB...]` 流还原"恢复走到哪一步"。
#
# 通道原理（2026-10-29 13:05 实测坐实）
#   Misc/Debug/AppleDebug=true + Target 含 0x04(DataHub) 与 0x40(文件)
#   ⇒ boot.efi 调试流被 OC 转发进 ESP 根目录的 opencore-<UTC时间>.txt。
#
# ★ 判据（2026-10-29 13:10 重写：旧判据「末行含 EXITBS:START 就不是失败现场」是错的）
#   恢复失败那次同样以 EXITBS:START 结尾——boot.efi 的日志能力到
#   ExitBootServices 就断了，成功与失败在末行上不可区分。必须分段判读：
#
#     ① EB|H:IS] 1            认出休眠（0 = 冷启动）
#     ② EB|H:BI <...>         拿到镜像所在设备路径
#     ③ LOG:REAN:START/END    读回镜像并处理（END 前耗时 = 读盘耗时）
#     ④ EB.H.HB|DT n m        HB 阶段结果
#     ⑤ EB.H.HB|!] <- BS.Exit ExitBootServices **失败**才出现；没有 = 成功
#     ⑥ LOG:EXITBS:START      交给内核前最后一条（之后无可观测能力）
#
#   ②③④ 齐 + ⑤ 缺 + ⑥ 有 ⇒ 恢复流程**全部成功**，死在 ExitBootServices 之后
#   的内核恢复入口（hibernate_kernel_entrypoint），即页表/绝对物理地址还原。
#   本机 2026-10-29 13:00 那次就是这个形态。
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

nz()  { tr -d '\0' < "$1" | wc -c | tr -d ' '; }
txt() { tr -d '\0' < "$1"; }

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

  T=$(txt "$f")

  # ── 分段标记 ──
  hib=0;  echo "$T" | grep -aqm1 '\[EB|H:IS\] 1' && hib=1
  bi=0;   echo "$T" | grep -aqm1 '\[EB|H:BI\]'    && bi=1
  rean_s=0; echo "$T" | grep -aqm1 'LOG:REAN:START' && rean_s=1
  rean_e=0; echo "$T" | grep -aqm1 'LOG:REAN:END'   && rean_e=1
  hbdt=0; echo "$T" | grep -aqm1 'EB\.H\.HB|DT'     && hbdt=1
  bsexit=0; echo "$T" | grep -aqm1 'EB\.H\.HB|!].*BS\.Exit' && bsexit=1
  exitbs=0; echo "$T" | grep -aqm1 'LOG:EXITBS:START' && exitbs=1
  postfail=0; echo "$T" | grep -aqm1 'RESET:FAIL:POSTEXITBS' && postfail=1

  first=$(echo "$T" | grep -am1 'LOG:INIT' | sed 's/.*LOG:INIT\] //')
  [[ -n "$first" ]] && echo "    起始: $first (UTC)"
  last=$(echo "$T" | grep -a . | tail -1)
  echo "    末行: ${last:0:150}"
  echo "    分段: H:IS=1[$hib] H:BI[$bi] REAN开始[$rean_s] REAN结束[$rean_e] HB|DT[$hbdt] BS.Exit错[$bsexit] EXITBS[$exitbs]"

  # ── 定性 ──
  if [[ "$hib" -eq 0 ]]; then
    echo "    → 冷启动（boot.efi 没认出休眠镜像，走的是正常启动）"
  elif [[ "$rean_e" -eq 0 ]]; then
    echo "    ★★ 认出休眠，但**没读完镜像**（缺 REAN:END）⇒ 死点在读盘/解密段 ★★"
  elif [[ "$bsexit" -ne 0 ]]; then
    echo "    ★★ 恢复流程走完，但 **ExitBootServices 失败** ⇒ 死点在退出引导服务 ★★"
  elif [[ "$hbdt" -ne 0 && "$exitbs" -ne 0 ]]; then
    echo "    ★★ 恢复流程**全部成功**（校验 / 读盘 / HB 阶段 / 退出引导服务），"
    echo "       死在 ExitBootServices **之后**的内核恢复入口 ★★"
    echo "       ⇒ 这一步是页表与绝对物理地址还原，与「交给内核的内存映射」直接相关"
  else
    echo "    ? 认出休眠但末行不在已知节点，需看全量日志"
  fi
  [[ "$postfail" -ne 0 ]] && echo "    ⚠ 含 RESET:FAIL:POSTEXITBS（ExitBootServices 之后复位）"

  # ── 休眠/恢复相关行（全量）──
  cnt=$(echo "$T" | grep -acE 'H:IS|H:BI\]|H:WCK|H:BOOT|H:SIG|H:HBOPT|H:RDST|H:RDEND|EB\.H\.|REAN|EXITBS' || true)
  if [[ "$cnt" -gt 0 ]]; then
    echo "    --- 休眠/恢复相关行（共 $cnt 条）---"
    echo "$T" | grep -aE 'H:IS|H:BI\]|H:WCK|H:BOOT|H:SIG|H:HBOPT|H:RDST|H:RDEND|EB\.H\.|REAN|EXITBS' | sed 's/^/      /'
  fi
  echo
done

echo "=== 判读速查（模板取自本机 /System/Volumes/Preboot/*/System/Library/CoreServices/boot.efi）==="
cat <<'EOF'
  #[EB|H:IS] 0/1          0=冷启动  1=认出休眠
  #[EB.H.CHK|BM] 0x..     镜像头校验位图，0 = 通过
  #[EB|H:BI] <hex>        镜像所在设备路径
  #[EB|H:SIG] 0x..        hibernate 签名
  #[EB.H.HB|!] .. <- ..R MSWr   读 NVRAM 变量 MSWr 失败（实测不阻断流程）
  LOG:REAN:START/END      读回镜像；间隔 = 读盘耗时（本机 534 ms）
  #[EB.H.HB|DT] n m       HB 阶段结果
  #[EB.H.HB|!] .. <- BS.Exit    ExitBootServices 失败（**没有这行 = 成功**）
  LOG:EXITBS:START        交给内核前最后一条，之后无任何日志能力
  RESET:FAIL:POSTEXITBS   ExitBootServices 之后复位（特殊失败标记）

  三种死点
    缺 REAN:END                 ⇒ 读盘/解密段（密钥或代码签名）
    有 BS.Exit                  ⇒ 退出引导服务段
    以上都过、只到 EXITBS       ⇒ 内核恢复入口（页表/绝对物理地址还原）
EOF
