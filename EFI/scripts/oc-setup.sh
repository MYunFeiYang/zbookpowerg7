#!/bin/bash
#
# HP ZBook Power G7 — macOS 辅助脚本统一入口
#
# 用法:
#   ./oc-setup.sh <command> [args...]
#
# 常用:
#   ./oc-setup.sh install-all          # 推荐：pmset + 耳麦切换 + 睡眠 hook
#   ./oc-setup.sh status               # 查看已安装项
#   ./oc-setup.sh pmset                # 仅收紧 pmset
#   ./oc-setup.sh mic install
#   ./oc-setup.sh sleep install
#   ./oc-setup.sh lid install
#   ./oc-setup.sh esp install          # 开机挂载 ESP（需 sudo）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/${UID_NUM}"

usage() {
  cat <<EOF
Usage: $0 <command> [args...]

Commands:
  install-all              安装 pmset + 耳麦自动切换 + 睡眠 hook（推荐）
  uninstall-all            卸载耳麦 + 睡眠 hook（pmset 不自动还原）

  pmset                    收紧睡眠 pmset（需 sudo，系统更新后可重跑）
  status                   显示各组件安装/配置状态

  mic install|uninstall    耳麦输入自动切换（MicFix + MicInputSwitch）
  sleep install|uninstall  睡眠前关蓝牙/Wi-Fi，外接屏息屏
  lid install|uninstall    合盖延迟关机（install 支持 --skip-pmset）
  esp install|uninstall    开机自动挂载 ESP（需 sudo）

子命令会调用同目录下的具体脚本，也可单独运行那些脚本。

示例:
  $0 install-all
  $0 pmset
  $0 mic install
  $0 lid install --skip-pmset
EOF
}

need_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This command must run on macOS." >&2
    exit 1
  fi
}

agent_running() {
  launchctl print "${GUI_DOMAIN}/$1" &>/dev/null
}

daemon_running() {
  launchctl print "system/$1" &>/dev/null
}

cmd_status() {
  need_macos
  echo "==> macOS 辅助组件状态"
  echo ""

  echo "[pmset]"
  if pmset -g custom 2>/dev/null | grep -q 'tcpkeepalive.*0'; then
    echo "  tcpkeepalive=0  (已收紧，可重跑: $0 pmset)"
  else
    echo "  未收紧 → 运行: $0 pmset"
  fi
  pmset -g custom 2>/dev/null | grep -E 'powernap|womp|standby|tcpkeepalive' | sed 's/^/  /' || true
  echo ""

  echo "[mic] MicFix + MicInputSwitch"
  for label in com.WingLim.MicFix com.oc.micinputswitch; do
    if agent_running "$label"; then
      echo "  $label  running"
    else
      echo "  $label  not installed"
    fi
  done
  echo ""

  echo "[sleep] 睡眠 hook（蓝牙/Wi-Fi/外接屏）"
  if agent_running com.oc.sleephooks; then
    echo "  com.oc.sleephooks  running"
  else
    echo "  not installed → $0 sleep install"
  fi
  echo ""

  echo "[lid] 合盖关机"
  if daemon_running com.oc.lidshutdown; then
    echo "  com.oc.lidshutdown  running"
  else
    echo "  not installed"
  fi
  echo ""

  echo "[esp] 开机挂载 ESP"
  if daemon_running com.oc.mountesp; then
    echo "  com.oc.mountesp  running"
  else
    echo "  not installed"
  fi
}

cmd_install_all() {
  need_macos
  echo "==> install-all: pmset + mic + sleep"
  echo ""
  bash "${SCRIPT_DIR}/pmset-reduce-wake.sh"
  echo ""
  bash "${SCRIPT_DIR}/install-mic-auto-switch.sh"
  echo ""
  bash "${SCRIPT_DIR}/install-sleep-hooks.sh"
  echo ""
  echo "==> install-all 完成。查看状态: $0 status"
}

cmd_uninstall_all() {
  need_macos
  echo "==> uninstall-all: mic + sleep（pmset 保持当前值）"
  bash "${SCRIPT_DIR}/uninstall-mic-auto-switch.sh" || true
  bash "${SCRIPT_DIR}/uninstall-sleep-hooks.sh" || true
  echo ""
  echo "pmset 未自动还原。若需恢复默认睡眠策略请自行调整 pmset。"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    -h|--help|help|'')
      usage
      ;;
    status)
      cmd_status
      ;;
    install-all)
      cmd_install_all
      ;;
    uninstall-all)
      cmd_uninstall_all
      ;;
    pmset)
      need_macos
      exec bash "${SCRIPT_DIR}/pmset-reduce-wake.sh" "$@"
      ;;
    mic)
      need_macos
      case "${1:-}" in
        install)  shift; exec bash "${SCRIPT_DIR}/install-mic-auto-switch.sh" "$@" ;;
        uninstall) exec bash "${SCRIPT_DIR}/uninstall-mic-auto-switch.sh" "$@" ;;
        *) echo "Usage: $0 mic install|uninstall" >&2; exit 1 ;;
      esac
      ;;
    sleep)
      need_macos
      case "${1:-}" in
        install)  exec bash "${SCRIPT_DIR}/install-sleep-hooks.sh" "$@" ;;
        uninstall) exec bash "${SCRIPT_DIR}/uninstall-sleep-hooks.sh" "$@" ;;
        *) echo "Usage: $0 sleep install|uninstall" >&2; exit 1 ;;
      esac
      ;;
    lid)
      need_macos
      case "${1:-}" in
        install)  shift; exec bash "${SCRIPT_DIR}/install-lid-shutdown.sh" "$@" ;;
        uninstall) exec bash "${SCRIPT_DIR}/uninstall-lid-shutdown.sh" "$@" ;;
        *) echo "Usage: $0 lid install|uninstall [--skip-pmset]" >&2; exit 1 ;;
      esac
      ;;
    esp)
      need_macos
      case "${1:-}" in
        install)  exec bash "${SCRIPT_DIR}/install-mount-esp.sh" "$@" ;;
        uninstall) exec bash "${SCRIPT_DIR}/uninstall-mount-esp.sh" "$@" ;;
        *) echo "Usage: $0 esp install|uninstall" >&2; exit 1 ;;
      esac
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo ""
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
