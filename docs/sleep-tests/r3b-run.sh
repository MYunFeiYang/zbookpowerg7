#!/bin/bash
# wb-r3b-run.sh —— R3b 执行（必须以 root 运行）
#
#   1) 留档改前基线
#   2) 写入唯一变量 standbydelaylow/high = 0
#   3) 读回校验（防钳位；被钳位 ⇒ 不睡，回滚退出）
#   4) 安装并启动看守（launchd LaunchDaemon，唤醒后自动取证+回滚；也兜住硬断电后的冷启动）
#   5) 触发睡眠
#
#  调用：osascript -e 'do shell script "bash /Volumes/Common/workplace/zbookpowerg7/docs/sleep-tests/r3b-run.sh" with administrator privileges'
set -u

REPO=/Volumes/Common/workplace/zbookpowerg7
OUT="$REPO/docs/sleep-tests/r3b-artifacts"
mkdir -p "$OUT"
LOG="$OUT/run.log"
exec >> "$LOG" 2>&1

echo "================================================================"
echo "RUN START $(date '+%F %T')  uid=$(id -u)  pid=$$"
ROLLBACK() { pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400; }

echo "--- [0] 改前基线 ---"
date '+%F %T'
sysctl kern.boottime kern.hibernatemode kern.hibernatecount
ls -la /var/vm/sleepimage
pmset -g custom | grep -iE "standbydelay|hibernatemode|standby|hibernatefile"
pmset -g ps | head -2
pmset -g log 2>/dev/null | grep -aE "Entering Sleep|Wake from" | tail -6

echo "--- [1] 写入唯一变量：standbydelaylow=0 / standbydelayhigh=0 ---"
pmset -a standbydelaylow 0 standbydelayhigh 0; echo "pmset rc=$?"
pmset -g custom | grep -i standbydelay
low=$(pmset -g custom | awk '/^Battery Power:/{f=1} f && $1=="standbydelaylow"{print $2; exit}')
high=$(pmset -g custom | awk '/^Battery Power:/{f=1} f && $1=="standbydelayhigh"{print $2; exit}')
echo "解析 low='$low' high='$high'"
if [ "$low" != "0" ] || [ "$high" != "0" ]; then
  echo "!! 未生效（钳位或被拒）⇒ 不触发睡眠；回滚退出（此路封闭）"
  ROLLBACK
  echo "ABORT-CLAMPED $(date '+%F %T')" > "$OUT/MARKER"
  exit 3
fi

echo "--- [2] 安装看守（launchd LaunchDaemon）---"
install -m 755 "$REPO/docs/sleep-tests/r3b-watch.sh" /usr/local/bin/wb-r3b-watch.sh || { echo "!! 安装看守失败"; ROLLBACK; echo "ABORT-INSTALL $(date '+%F %T')" > "$OUT/MARKER"; exit 5; }

cat > /Library/LaunchDaemons/com.wb.r3b.watch.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.wb.r3b.watch</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/usr/local/bin/wb-r3b-watch.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>StandardOutPath</key>
	<string>/var/log/wb-r3b-watch.out</string>
	<key>StandardErrorPath</key>
	<string>/var/log/wb-r3b-watch.err</string>
</dict>
</plist>
PLIST
chmod 644 /Library/LaunchDaemons/com.wb.r3b.watch.plist
chown root:wheel /Library/LaunchDaemons/com.wb.r3b.watch.plist
plutil -lint /Library/LaunchDaemons/com.wb.r3b.watch.plist

# ★ 锚定行首：贪婪 ".*sec = " 会匹配到 "usec = ..." ⇒ 必须用 ^\{ sec =
bt=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+).*/\1/')
echo "$bt $(date '+%F %T')" > "$OUT/.armed"
echo "ARM: boottime=$bt  → $OUT/.armed"

launchctl bootout system/com.wb.r3b.watch 2>/dev/null
launchctl bootstrap system /Library/LaunchDaemons/com.wb.r3b.watch.plist 2>&1; echo "bootstrap rc=$?"
sleep 3
if ! pgrep -f wb-r3b-watch.sh >/dev/null 2>&1; then
  echo "bootstrap 未起 ⇒ 改 launchctl load -w"
  launchctl load -w /Library/LaunchDaemons/com.wb.r3b.watch.plist 2>&1
  sleep 3
fi
if pgrep -f wb-r3b-watch.sh >/dev/null 2>&1; then
  echo "看守存活: $(pgrep -fl wb-r3b-watch.sh)"
else
  echo "!! 看守未存活 ⇒ 中止（不做没有自动回滚的实验）"
  ROLLBACK
  rm -f /Library/LaunchDaemons/com.wb.r3b.watch.plist /usr/local/bin/wb-r3b-watch.sh "$OUT/.armed"
  echo "ABORT-NOWATCH $(date '+%F %T')" > "$OUT/MARKER"
  exit 4
fi

echo "--- [3] 触发睡眠 $(date '+%F %T') ---"
echo "ARMED $(date '+%F %T')" > "$OUT/MARKER"
pmset sleepnow
rc=$?
echo "sleepnow rc=$rc  $(date '+%F %T')"
echo "（预期 ~30 s 内入睡；若真休眠 ⇒ 内存断电，需按电源键唤醒）"
exit 0
