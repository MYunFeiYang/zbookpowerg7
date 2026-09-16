#!/bin/bash
#
# 睡眠功耗：Deep Idle（~5W） -> 断电档（~0.2W）
#
# 背景：本机 FADT Flags=0x002384A5，bit21 LOW_POWER_S0_IDLE_CAPABLE = SET，
#   故 macOS 走 Deep Idle（S0ix）而非 S3。Deep Idle 下 CPU 停在 C10 但 SoC
#   部分带电 —— 实测睡眠恒约 5W（落在 OC-little 记录的 AOAC 5%~10%/h 区间）。
#
# 可用档位（依据本机 man pmset + pmset -g cap 实测，非推断）：
#   Deep Idle    不写盘、内存全程带电，唤醒最快                        ~5 W
#   Hibernate    hibernatemode 25 + standby 1，到 standbydelay 落盘断内存电  ~0.2 W
#   - ★★ **`hibernatemode` 单独设了不管用，必须同时给 `standby`** ——
#     本机 man pmset 原文：「Whether or not a hibernation image gets written is also
#     dependent on the values of standby and autopoweroff」。standby 是那个**触发计时器**。
#   - ★★ **撤回"插电侧不支持深睡"**（2026-09-16 17:2x 查证，四条）：
#     ① `pmset -g cap` 的 `-b` 与 `-c` 输出**逐行完全相同** ⇒ 能力是**机型级**的，
#        不是电源源级 —— "AC 侧 cap 没有 X"这种表述本身框架就错（`diff` 实测无差异）。
#     ② 本机 cap **列出了** `standby`/`standbydelaylow`/`standbydelayhigh`/`highstandbythreshold`，
#        且 `pmset -g custom` 的 **AC 段可见 `standby`** ⇒ 按 man 判据
#        （"The setting standby will be visible in pmset -g if the feature is supported
#        on this machine"）**AC 侧 standby 是受支持的**。
#     ③ 真正**不受支持**的只有 `autopoweroff`/`autopoweroffdelay` —— cap 未列出，且 man 原文
#        写的是 "enabled by default **on supported platforms**"。**这是机型级限制。**
#     ④ 反证（社区）：有教程专门教 `pmset -c standby 0` 去**关掉**插电时的待机
#        （原文语境："standby 1 + hibernatemode 3 … 合盖后**即使插电**，一段时间后也会把内存
#         写入磁盘并进入低功耗状态"）⇒ 若 AC 侧 standby 本不生效，就不需要"关"这一步。
#   - ★★ **撤回"14:39 实测证明 AC 走不通"—— 那是无效论证**：
#     那次 14:39:31 → 14:42:03 只睡了 **152 秒**，而当时 AC 的 `standbydelaylow` = **10800 秒**
#     （**差 71 倍**）⇒ **根本没到触发点就被手动唤醒**，看不到 `Entering Hibernate` 是必然结果，
#     不构成任何证据。且当时 AC 侧 `standby = 0` ⇒ **从来没配过触发条件**。
#     ⇒ "没进休眠"从头到尾是**配置结果**，不是平台能力；`PMRD: hibernateMode 0x0` 亦同源。
#   - ★ 四次睡眠实测（11:16 / 12:04 / 13:11 / 14:39）**全部发生在插电状态** ——
#     依据 `pmset -g log`（**跨启动持久**，比 `log show --start/--end` 可靠；后者查旧窗会返回
#     当日最新的行）。四次原话均为 `Entering Sleep state due to 'Software Sleep' … Using AC (Charge:100%)`。
#   - ★ 现在的策略（`auto` 档）：**两档都配深睡，靠"延迟"区分激进程度** ——
#     插电 1 h / 2 h 后落盘（日常短睡无感）｜电池 10 / 30 min 后落盘。两边都必须 `standby 1`。
#     ⚠️ `sleep` 计时器：AC 设 0（永不自动睡）、电池 15 min。
#   - standbydelayhigh/low 取哪个由**剩余电量** vs highstandbythreshold(50%)
#     决定，与 AC/电池无关；电量 100% 走 high —— 故 high 必须显式设短，
#     否则用默认 86400（24 小时）等于永不触发。
#
# 【第 3 条路：强制 S3 —— 实验级，脚本不代做】
#   本机 DSDT **已经暴露 S3**：根作用域 \SS3 = One（DSDT.dsl L5708），
#   于是 L38257 的 If (SS3) { Name (_S3, Package (0x04) { 0x05, Zero, Zero, Zero }) }
#   成立。真正拦住 S3 的是 FADT bit21，不是 _S3 缺失。
#   要试：ACPI/Patch TableSignature=FACP, Find=<A5842300>, Replace=<A5840300>
#   （已实测该 8 位模式在 FACP 中**唯一**，位置 = offset 112 即 Flags 本身），
#   并同时禁用 SSDT-DeepIdle.aml（LPS0/LXEN 是 S0ix 的 OS 侧接口）。
#   ⚠️ 社区零先例；daliansky/OC-little 立场相反（专门提供**禁用** S3 的 SSDT）。
#   ⚠️ 反例：Surface IceLake 在**完全同构**的 DSDT 上把 SS3 改成 One 后，
#      内核日志确实变为 "ACPI: sleep states S3 S4 S5"，但 S3 睡眠本身仍未修好，
#      他们最终靠 hibernatemode 25 解决。→ 优先级排在 Standby/Hibernate 之后。
#
# ⚠️⚠️ 【2026-09-16 关于 sleepimage 管理的完整闭环，务必先读】
#   **macOS 按「当前活动电源源」管理 /var/vm/sleepimage**，三条实测凑齐：
#     ① 15:22 改 `-c hibernatemode 0` ⇒ 文件**被删**（`/var/vm` 变 `total 0`）。
#     ② 16:45 重新下发 `-b hibernatemode 25`（此时活动源仍是 AC）⇒ **不会重建**，仍为空。
#     ③ 17:25 改 `-c hibernatemode 25`（活动源就是 AC）⇒ **立即重建**：
#        由手动预置的 8 GiB 稀疏文件变为 **1 GiB**（`Hibernate File Min` = 1073741824），
#        mtime 变新、权限变 `-rw------T`（macOS 自己建的签名）。
#   ⇒ 结论：**只有"当前活动电源源"的 hibernatemode 才会驱动这个文件**。
#     故 `auto` 档现在两边都是 25 ⇒ 文件由 macOS 自行维护，下面的 mkfile 只是兜底。
#   ℹ️ 尺寸线**已排除**（第 3 次失败时 sleepimage = 16 GiB 实分配，仍失败）⇒ 不为尺寸做任何处理。
#   ⚠️ 仍未验证：下次启动 / 拔电瞬间它会不会被回收重建。**拔电后先 `ls -la /var/vm/`。**
#
# ⚠️⚠️ 【USB 断言那件事 —— 悬案已结（2026-09-16 16:50）】
#      现象：kernel `0x4=USB` 断言列了 `HP HD Camera`、`Bluetooth USB Host Controller`、`USB Optical Mouse`。
#      ✅ **查清（16:50）**：`UTBMap_tahoe.kext` **注入成功** —— `ioreg -rc AppleUSBHostController`
#         的控制器节点上确有注入的 `ports` 字典：
#           `HS04 → port#7  usb-port-type=255 ★Internal` ← `HP HD Camera`（locationID 0x14400000）
#           `HS06 → port#14 usb-port-type=255 ★Internal` ← `Bluetooth USB Host Controller`（0x14600000）
#         其余 7 端口为 type 3/9（Type-A / Type-C）。⇒ **内置摄像头与蓝牙已按规范标为 255**，
#         与真机一致（社区口径：`macOS always expects Bluetooth as Internal`，标错会**反过来
#         影响 Sleep/Wake**）。此前看到的 `USBPortType = 0` 是 Apple 自产的另一条属性，与
#         USBToolBox 注入的 `usb-port-type` **不是同一个键** ⇒ 原"对不上"的判据作废。
#      ⚠️ **但不能据此断言** `USBExternalDevice` 因子一定来自谁：`pmset -g assertions` 里那四项
#         的断言名都是 `com.apple.usb.externaldevice.*`，那是 **USB 设备的通用断言名**（真机上
#         内置蓝牙同样用它），**不能**据此判定被误标。唯一确证的外设 = `USB Optical Mouse`
#         ＋ `HONOR DVD-AN80`（`pmset -g assertions` 实测在列）。
#      ⇒ 结论：**无需任何 EFI 改动**；本机 USB 映射与真机等价，standby 前提不被内部设备破坏。
#
# 前置（test/on/instant 都需要）—— ✅ 均已于 commit 2f5c047 完成：
#   1) Misc/Boot/HibernateMode: None -> NVRAM
#      OC 手册取值仅 None/Auto/RTC/NVRAM，Failsafe 默认即 None。
#      旧值 None = 忽略休眠状态，断电后 OpenCore 不去恢复镜像，开盖只会冷启动。
#   2) Misc/Security/AllowNvramReset = true
#      此前该键缺失 = 取 Failsafe false，即本机**没有** Reset NVRAM 逃生口。
#
# 用法：
#   ./pmset-hibernate.sh status    # 打印本机能力 + 当前状态
#   ./pmset-hibernate.sh auto      # ★ 推荐：按电源源分档 —— **两档都深睡**，靠延迟区分激进程度：
#                                  #            插电 hibernatemode 25 + standby 1 + 1h/2h
#                                  #            电池 hibernatemode 25 + standby 1 + 10/30min
#                                  #            拔插电源自动切，**不需要改变任何使用习惯**。
#                                  #            同时归一化 sleep / disksleep 计时器 + 预置休眠镜像。
#   ./pmset-hibernate.sh acfast    # 只让插电侧回到「永不写盘」（不碰 RTC / 最快醒 / 恒 ~5W）
#   ./pmset-hibernate.sh test      # 受控试验：合盖 5 分钟后断电（先跑这个）
#   ./pmset-hibernate.sh on        # 延迟断电：电量>50% 走 60 分钟，<50% 走 30 分钟
#   ./pmset-hibernate.sh instant   # 合盖即断电（hibernatemode 25，同 Win 侧做法；**全电源源**，慎用）
#   ./pmset-hibernate.sh off       # 回滚到现状（纯 Deep Idle，不写镜像）
#
# 判据 / 回滚：
#   成功   = 功率计 5W -> ~0.2W，开盖能回到原会话
#   半成功 = 断电了但开盖是冷启动 -> HibernateMode 值不对
#   失败   = 断电后起不来 -> 长按电源；能进系统就跑 ./pmset-hibernate.sh off
#            （若 macOS 也起不来：OpenCore 界面 Enter 进菜单 -> Reset NVRAM，
#              逃生口已由 2f5c047 打开）
#   ⚠️ 未验证风险：OCLP 根补丁注入的 Wi-Fi（IO80211 合并 + AirportItlwm）在
#      休眠恢复后能否起不来 —— 零先例，须实测。
#   ⚠️ 睡前**拔掉外接 USB 鼠标**：pmset -g assertions 里它有 0x4=USB 断言，
#      包里被蹭到就会唤醒整机。
#

set -euo pipefail

PMSET=/usr/bin/pmset
SYSCTL=/usr/sbin/sysctl

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

# status 是纯只读的，不需要 root；只有改系统电源设置的子命令才提权
case "${1:-}" in
  auto|acfast|test|on|instant|off)
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "Re-running with sudo..."
      exec sudo "$0" "$@"
    fi
    ;;
esac

val() { $PMSET -g custom 2>/dev/null | awk -v K="$1" '$1==K{print $2; exit}'; }
supported() { [[ -n "$(val "$1")" ]]; }

# 取指定电源源分块里的某个键值（pmset -g custom 里 "AC Power:" / "Battery Power:" 各一块）
# 用法：per_source "AC Power" hibernatemode
per_source() {
  $PMSET -g custom 2>/dev/null | awk -v sec="$1:" -v key="$2" '
    $0==sec {f=1; next}
    /^[A-Za-z].*:$/ {f=0}
    f && $1==key {print $2; exit}'
}

show_status() {
  echo "==> 本机能力（pmset -g cap 里能看到的才受支持）"
  if supported standby; then
    echo "  standby      : 受支持（当前 $(val standby)）"
  else
    echo "  standby      : 不受支持"
  fi
  if supported autopoweroff; then
    echo "  autopoweroff : 受支持（当前 $(val autopoweroff)）"
  else
    echo "  autopoweroff : 不受支持（设了也无效）"
  fi
  echo "  hibernatecount: $($SYSCTL -n kern.hibernatecount 2>/dev/null || echo '?')（历史真实休眠次数）"
  echo
  echo "==> 按电源源（拔插电源自动切换）"
  printf "    %-16s %-14s %-9s %-7s %-9s %s\n" "电源源" "hibernatemode" "standby" "sleep" "disksleep" "standbydelay(low/high)"
  for sec in 'AC Power' 'Battery Power'; do
    printf "    %-16s %-14s %-9s %-7s %-9s %s/%s\n" "$sec" \
      "$(per_source "$sec" hibernatemode)" "$(per_source "$sec" standby)" \
      "$(per_source "$sec" sleep)" "$(per_source "$sec" disksleep)" \
      "$(per_source "$sec" standbydelaylow)" "$(per_source "$sec" standbydelayhigh)"
  done
  echo "    （hibernatemode: 0=不写盘仅内存供电 / 3=safe sleep / 25=真休眠落盘断电）"
  echo "    （standby 是**触发计时器**；=0 ⇒ hibernatemode 25 也不会写盘 —— 14:39 实测：mode 25 + standby 0 = 全程 Deep Idle）"
  echo
  echo "==> 当前 pmset 关键项"
  $PMSET -g custom | grep -E 'hibernatemode|standby|standbydelay|powernap|womp|tcpkeepalive' || true
  echo
  echo "==> 历史 standby/hibernate 事件"
  if $PMSET -g log 2>/dev/null | grep -qE "Entering Standby state|Entering Hibernate"; then
    $PMSET -g log 2>/dev/null | grep -E "Entering Standby state|Entering Hibernate" | tail -5
  else
    echo "  (无 —— 从未真正进入过 standby/hibernate)"
  fi
  echo
  echo "==> 谁在阻止空闲睡眠"
  $PMSET -g assertions 2>/dev/null | grep -E "PreventUserIdleSystemSleep|NoIdleSleepAssertion|USB$|owner=" | head -8 || true
  echo
  echo "==> /var/vm (休眠镜像，目标 RAM 大小的文件)"
  ls -la /var/vm/ 2>/dev/null || true
}

case "${1:-}" in
  status)
    show_status
    ;;

  auto)
    echo "==> 按电源源分档（推荐档；拔插电源自动切换，**不需要改变使用习惯**）"
    # —— 插电档：惰性深睡。长延迟 ⇒ 日常短睡仍秒醒；只有长时间合盖才落盘断内存电。
    #    ⚠️ 2026-09-16 17:2x 修正：原先这里是 hibernatemode 0 + standby 0（策略叫"不追"）。
    #       查证后发现"AC 侧不支持"**从未被验证、且证据相反**（详见文件头 ★★ 四条）⇒
    #       改为与电池侧同构、仅把延迟拉长。想回到"插电永不写盘"：$0 acfast
    $PMSET -c hibernatemode 25
    $PMSET -c standby 1
    $PMSET -c highstandbythreshold 50
    $PMSET -c standbydelaylow 3600      # 电量低 → 1 h 后落盘断电
    $PMSET -c standbydelayhigh 7200     # 电量足 → 2 h 后落盘断电
    # —— 电池档：真休眠（落盘 → 断内存供电）
    $PMSET -b hibernatemode 25
    # ★ standby 必须为 1 —— 这不是可选美化，是**触发前提**：
    #   本机 man pmset 原文「Whether or not a hibernation image gets written is also
    #   dependent on the values of standby and autopoweroff」。本机**任何电源源都没有**
    #   `autopoweroff`（cap 未列出）⇒ standby 是**唯一**可用的触发计时器。
    $PMSET -b standby 1
    $PMSET -b highstandbythreshold 50
    #   延迟按剩余电量选：<50% 走 low、≥50% 走 high。默认 10800/86400（3h/24h）在真机上等于
    #   **永不触发** ⇒ 必须显式设短，否则上面那条 standby 1 等于白设。
    $PMSET -b standbydelaylow 600      # 电量低 → 10 min 后落盘断电
    $PMSET -b standbydelayhigh 1800    # 电量足 → 30 min 后落盘断电（短睡仍可秒醒）
    # 空闲计时器：测试期曾把两档都设成 1 分钟，配上「电池=25」会变成「空闲 1 分钟即休眠」
    #   ⇒ 反复写 RTC（正是 005 的成因）⇒ 必须同时归一化。AC 0 = 插电永不自动睡。
    $PMSET -c sleep 0
    $PMSET -b sleep 15
    # disksleep：sleep≠0 而 disksleep=0 时 pmset 会告警
    #   （"Disk sleep should be non-zero whenever system sleep is non-zero"）⇒ 归一化。
    $PMSET -b disksleep 10
    # 休眠镜像：macOS 按**当前活动电源源**管理 /var/vm/sleepimage —— 改 `-c hibernatemode 25`
    #   它会**自己重建**（17:25 实测：手动的 8 GiB 稀疏文件被换为 1 GiB，mtime 变新）。
    #   下面只是**兜底**，正常不触发（auto 档两边都是 25 ⇒ 文件由 macOS 维护）。
    if [[ ! -e /var/vm/sleepimage ]]; then
      /usr/sbin/mkfile -n 8g /var/vm/sleepimage
      /usr/sbin/chown root:wheel /var/vm/sleepimage
      /bin/chmod 600 /var/vm/sleepimage
      echo "    已预置 /var/vm/sleepimage（稀疏 8 GiB，实占约 32 KB）"
    fi
    echo "    插电 : hibernatemode 25 / standby 1 —— 短睡秒醒，1~2 h 后落盘并断内存供电"
    echo "    电池 : hibernatemode 25 / standby 1 —— 短睡秒醒，10~30 min 后落盘并断内存供电"
    echo
    echo "    依据："
    echo "      · 四次睡眠实测（11:16/12:04/13:11/14:39）**全在插电状态**（pmset -g log 原文"
    echo "        'Entering Sleep … Using AC (Charge:100%)' ×4）⇒ 电池场景从未测过。"
    echo "      · ⚠️ AC 侧原先 hibernatemode 0 + standby 0 = **从没配过触发条件** ⇒"
    echo "        '没进休眠'是配置结果、不是平台能力。14:39 那次只睡 152 s，距 standbydelay"
    echo "        10800 s 差 71 倍 ⇒ 属无效测试，不能用来断言'AC 走不通'。"
    echo "      · 想回到'插电永不写盘'（原方案）：$0 acfast"
    echo "      · 电池场景（拔电出门）是省电收益最确定的场景。"
    echo "      · USB 端口映射**已查证生效**（16:50）：内置摄像头 HS04 / 蓝牙 HS06 在 UTBMap 里"
    echo "        已是 Internal(255)，与真机一致 ⇒ 不再是备选原因，**无需任何 EFI 改动**。"
    echo "        确证的外设只有 USB Optical Mouse 与 HONOR DVD-AN80，拔掉后本机与真机等价。"
    echo "    回滚：$0 off（全回基线）｜$0 acfast（只让插电侧回到不写盘）"
    show_status
    ;;

  acfast)
    echo "==> 插电侧回到「永不写盘」（原方案）；电池侧保持深睡不变"
    $PMSET -c hibernatemode 0
    $PMSET -c standby 0
    $PMSET -c standbydelaylow 10800
    $PMSET -c standbydelayhigh 86400
    $PMSET -c sleep 0
    echo "    插电 : hibernatemode 0 / standby 0 —— 不写盘、**不碰 RTC**、唤醒最快；空闲不自动睡"
    echo "    （代价：插电时长睡恒 ~5 W，永远拿不到 0.2 W）"
    echo "    切回 : $0 auto"
    show_status
    ;;

  test)
    echo "==> 受控试验：合盖 5 分钟后写镜像并断电"
    echo "    前置已就绪（commit 2f5c047: HibernateMode=NVRAM, AllowNvramReset=true）"
    echo "    ⚠️ 睡前拔掉外接 USB 鼠标 —— 它有 0x4=USB 唤醒断言"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 300 standbydelayhigh 300
    echo "    已应用。现在合盖，等 8~10 分钟，看电源灯是否熄灭 / 功率计是否掉到 ~0.2W。"
    echo "    回滚：$0 off"
    show_status
    ;;

  on)
    echo "==> 延迟断电：>50% 电量 60 分钟，<50% 电量 30 分钟"
    $PMSET -a hibernatemode 3 standby 1 standbydelaylow 1800 standbydelayhigh 3600
    echo "    短睡(<30min)仍从内存唤醒，快；长睡自动落盘断电。"
    show_status
    ;;

  instant)
    echo "==> 合盖即断电（hibernatemode 25）"
    $PMSET -a hibernatemode 25
    echo "    注意：每次睡眠都要读镜像，唤醒明显变慢（等同 Win 侧 LIDACTION=2）。"
    echo "    参照先例：ThinkPad E480 / Surface Laptop 3 / Fujitsu Q958 均用此档。"
    show_status
    ;;

  off)
    echo "==> 回滚到纯 Deep Idle（当前基线）"
    $PMSET -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400
    $PMSET -a disksleep 0
    $PMSET -c sleep 0
    $PMSET -b sleep 15
    echo "    注意：hibernatemode 全部归 0 后 macOS 会删掉 /var/vm/sleepimage（正常，基线行为）。"
    show_status
    ;;

  *)
    awk 'NR>=3 && /^set -euo/{exit} NR>=3' "$0"
    exit 1
    ;;
esac
