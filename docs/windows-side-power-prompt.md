# 任务：在这台 HP ZBook Power G7 的 Windows 侧做一次「**功耗/睡眠取证**」（第二轮）

> 用途：上一轮（`docs/backups/firmware-ledger-2026-09-20/win-side/`）已确认固件层无路可走。
> 本轮的**唯一目的**是回答一个问题：**同一台机器，Windows 的 Deep Idle（Modern Standby / S0ix）功耗到底是多少、睡到多深、谁在阻止它睡更深。**
> **本任务全程只读，不修改任何电源设置、不写注册表、不装软件。**

---

## 一、背景（直接采信，不要重新调查）

- 机器：HP ZBook Power G7，i7-10750H，**无独显**（只有 Intel UHD 630），WD SN570 1TB，AX201 无线网卡。
- 已确认（**不需要你再查**）：
  - `Modern Standby` 在固件里 = `Enable`，且**隐藏 + 只读** ⇒ S3 无法通过官方途径开启。
  - `powercfg /a` 已知输出：**S0 低电量待机（连接的网络）✅ / 休眠 ✅ / 快速启动 ✅ / S1 ❌ / S2 ❌ / S3 ❌ / 混合睡眠 ❌**。
  - `PlatformAoAcOverride` **不存在**（已直接 `reg query` 确认）。
- 这台机器的 macOS 侧（黑苹果）实测：**Deep Idle 掉电 6–11 %/h（≈4–7.5 W）**。
- 我们想知道 **Windows 侧对应的数字**，用来对比。

---

## 二、硬边界（违反即任务失败）

1. **只读。** 可以用 `powercfg /query`、`/a`、`/sleepstudy`、`/batteryreport`、`/devicequery`、`/lastwake`、`/requests`、
   `reg query`、`Get-CimInstance`、`Get-WmiObject`。
2. **禁止 `powercfg /set*`（setacvalueindex / setdcvalueindex / setactive）** —— 一个都不要用。
3. **禁止 `reg add` / `reg delete` / 任何写操作。**
4. **禁止改 BIOS 设置、禁止刷固件。**
5. **禁止安装任何第三方软件**（不装 HPCMSL、不装驱动、不装脚本）。
6. **禁止碰 UEFI / ESP 分区、禁止动任何 EFI 文件。**
7. **不要为了取证而故意重启或睡眠**（唯一例外见第四节，且那一步由**用户手动**完成）。
8. 遇到需要管理员权限的项：**直接说明"需要管理员"并跳过**，不要尝试提权绕过。

---

## 三、Phase A · 环境确认（只读，先把结果落盘目录准备好）

```cmd
:: 落盘目录（和上一轮同一个共享 exFAT 盘）
set OUT=D:\workplace\zbookpowerg7\docs\backups\win-side-power-2026-09-20
if not exist "%OUT%" mkdir "%OUT%"
```

> **兜底**：如果找不到那块 exFAT 盘或它不可写，就写到 `C:\Users\Public\`，并在报告里说明用了兜底路径。

```cmd
systeminfo | findstr /C:"OS Name" /C:"OS Version" /C:"BIOS Version" /C:"System Model" > "%OUT%\env.txt"
wmic bios get smbiosbiosversion /value >> "%OUT%\env.txt"
powercfg /a >> "%OUT%\env.txt"
```

---

## 四、★ Phase B · 核心产出：SleepStudy（需要"真的睡过一次"）

### B0 · 先看现有数据够不够（通常就够，先别急着重睡）

```cmd
powercfg /sleepstudy /output "%OUT%\sleepstudy.html" /duration 7
powercfg /batteryreport /output "%OUT%\batteryreport.html"
```

> 说明：`/sleepstudy` 默认分析**最近 3 天**；`/duration 7` 拉到 7 天。
> 它统计的是**电池供电（DC）下的待机会话** —— 如果最近几天都是插电用，报告可能是空的。

### B1 · 如果 SleepStudy 是空的 / 只有 AC 会话 ⇒ 需要用户手动睡一次

**把下面这段原样告诉用户（中文），不要自己去执行：**

> 请在**拔掉电源适配器**（用电池）的情况下，把屏幕关掉 / 合盖 / 点开始菜单的"睡眠"，**睡 20 分钟以上**，然后唤醒。
> 醒来后告诉我一声，我再重新生成报告。

**⚠️ 注意**：
- **不要**用 `powercfg /hibernate off` / `on` 之类命令来"帮忙"。
- **不要**替用户改任何电源计划。
- 睡之前请确认机器上没有未保存的工作（这是用户自己的判断）。

### B2 · 重新生成（用户睡过之后）

```cmd
powercfg /sleepstudy /output "%OUT%\sleepstudy.html" /duration 7
```

**然后从 HTML 里提取这几项**（HTML 是自包含的，可以直接用文本工具读；也可以只用下面的命令行等价物）：

```cmd
:: 各睡眠状态当前是否可用
powercfg /a > "%OUT%\powercfg-a.txt"

:: 最后一次唤醒是谁
powercfg /lastwake > "%OUT%\lastwake.txt"

:: 哪些设备被允许唤醒系统
powercfg /devicequery wake_armed > "%OUT%\wake_armed.txt"

:: 当前有哪些东西在阻止系统睡眠
powercfg /requests > "%OUT%\requests.txt"

:: 电源请求覆盖（谁在请求不休眠）
powercfg /requestsoverride > "%OUT%\requestsoverride.txt"

:: 电池设计容量 / 当前满充容量（用来算真实掉电百分比）
powercfg /batteryreport /output "%OUT%\batteryreport.html"
```

---

## 五、★ Phase C · Adaptive Hibernate 的真实配置（关键假设验证）

**要验证的假设**：Windows 会不会"掉 5% 电就自动转休眠"（S4）。这是两边功耗差异的最大嫌疑。

```cmd
:: 待机预算（StandbyBudgetPercent / RefreshInterval / RefreshCount）
powercfg /q SCHEME_CURRENT SUB_PRESENCE > "%OUT%\q-sub_presence.txt"

:: 人类可读版（需要管理员；失败就跳过）
powercfg /qh SCHEME_CURRENT SUB_PRESENCE > "%OUT%\qh-sub_presence.txt" 2>&1

:: 休眠文件与快启动状态
powercfg /a > "%OUT%\hibernate-capability.txt"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v HibernateEnabled > "%OUT%\reg-hibernate.txt" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v HibernateEnabledDefault >> "%OUT%\reg-hibernate.txt" 2>&1
dir /a C:\hiberfil.sys >> "%OUT%\reg-hibernate.txt" 2>&1
```

**要看的**：
- `SUB_PRESENCE` 下有没有 `StandbyBudgetPercent`（默认 **5**）与 `StandbyBudgetRefreshInterval`（默认 **12 小时**）。
- `HibernateEnabled` = 1 还是 0；`hiberfil.sys` 存不存在、多大。

---

## 六、Phase D · 设备级"谁在耗电"（只读）

```cmd
:: 所有 PCI 设备及其电源状态（设备管理器视角）
powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPClass -ne $null} | Select-Object Name,PNPClass,DeviceID,Status | Sort-Object PNPClass | Format-Table -AutoSize | Out-File -Encoding utf8 '%OUT%\pnp-devices.txt'"

:: 正在运行的进程里谁持有电源请求
powershell -NoProfile -Command "powercfg /requests" > "%OUT%\requests2.txt"

:: 显示/睡眠超时当前值
powercfg /q SCHEME_CURRENT SUB_VIDEO > "%OUT%\q-sub_video.txt"
powercfg /q SCHEME_CURRENT SUB_SLEEP > "%OUT%\q-sub_sleep.txt"
```

---

## 七、Phase E · 落盘 + **身份字段脱敏（强制，别跳过）**

⚠️ **这个仓库的 `origin` 是公开的 GitHub 仓库**。上一轮已因此把一批真机标识遮蔽过。**这一轮同样必须做。**

把 `%OUT%` 下**所有** `.txt` / `.html` 里下面这些模式替换掉（保留字段名，只遮蔽值）：

```powershell
$dir = "D:\workplace\zbookpowerg7\docs\backups\win-side-power-2026-09-20"

# 1) 序列号 / 主板 CT 号（形如 5CD0xxxxx / PKYRP0xxxxxx）
$patterns = @(
  '([Ss]erial\s*[Nn]umber[^\r\n]*?[:=]\s*)([A-Z0-9]{6,})',
  '([Ss]ystem\s*[Bb]oard\s*CT\s*[Nn]umber[^\r\n]*?[:=]\s*)([A-Z0-9]{6,})',
  '([Bb]ase\s*[Bb]oard\s*[Ss]erial[^\r\n]*?[:=]\s*)([A-Z0-9]{6,})'
)
# 2) UUID
$uuid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# 3) MAC
$mac  = '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
# 4) 主机名 / 用户名
$hostpat = '([Cc]omputer\s*[Nn]ame[^\r\n]*?[:=]\s*)(\S+)'

Get-ChildItem -Path $dir -Include *.txt,*.html -Recurse | ForEach-Object {
  $t = Get-Content $_.FullName -Raw
  foreach ($p in $patterns) { $t = [regex]::Replace($t, $p, '${1}<REDACTED-ID>') }
  $t = [regex]::Replace($t, $uuid, '<REDACTED-UUID>')
  $t = [regex]::Replace($t, $mac,  '<REDACTED-MAC>')
  $t = [regex]::Replace($t, $hostpat, '${1}<REDACTED-HOST>')
  Set-Content -Path $_.FullName -Value $t -NoNewline -Encoding utf8
}
Write-Host "脱敏完成"
```

**做完了自查一遍**（应无输出）：

```cmd
findstr /S /R /C:"5CD0" /C:"PKYRP" "%OUT%\*.*"
```

> ⚠️ **不要删行、不要删整段** —— 只遮蔽值。被遮蔽的字段名本身是我们要的证据。
> ⚠️ **保留**：型号 SKU、BIOS/EC 版本、PowerPlan 名称、所有设备名、所有电源设置值、**SleepStudy 的全部数字**。

最后再写一份 `%OUT%\SUMMARY.md`（中文），内容 = 第八节那份报告。

---

## 八、输出要求（报告格式）

写一份中文 Markdown，**按下面顺序**，每个数字都必须给出**来源文件**：

1. **环境**：OS 版本 / BIOS 版本 / 型号（已脱敏）。
2. **§ 睡眠能力对照表**：`powercfg /a` 逐项（S0/S1/S2/S3/S4/混合睡眠/快速启动）。
3. ★ **§ Adaptive Hibernate 配置**：`StandbyBudgetPercent` 是多少？`StandbyBudgetRefreshInterval` 多少？`HibernateEnabled`？
   —— **明确回答：理论上"掉 5% 电会不会自动休眠"在本机成不成立。**
4. ★ **§ SleepStudy 摘要**（**这一节最重要**）：
   - 报告里一共有几次 **DC 待机会话**？各自**时长 + 掉电率 %/h**？
   - **有没有 Hibernate（休眠）段**？如果有，从入睡到休眠隔了多久？
   - **DRIPS 直方图**：软件 DRIPS / 硬件 DRIPS 各占多少百分比？
   - **Top offenders 清单**：点名了哪些设备/驱动/进程？各自的 Active Time 百分比。
   - **PEP PRE-VETO COUNT** 是多少？
   - 若报告是空的，**明确说"空"并说明原因**（例如"最近 7 天没有电池待机会话"），不要编。
5. **§ 唤醒源**：`/lastwake` + `wake_armed` 列表 + `/requests` 当前阻止项。
6. **§ 存疑项**：你没读到、权限不够、或 HTML 解析不出来的，逐条诚实列出。

**严禁**：推断代替读数、把默认值当实测值、把 AC 会话当 DC 会话。

---

## 九、绝对不要做的事（重复一遍）

- ⛔ 不要 `powercfg /set*`、不要 `reg add`、不要改任何设置。
- ⛔ 不要关/开休眠功能（`powercfg /hibernate off|on`）。
- ⛔ 不要装 HPCMSL / BCU / 任何工具。
- ⛔ 不要刷 BIOS、不要动 EFI/ESP。
- ⛔ 不要擅自重启或睡眠 —— 需要"睡一次"时，**让用户手动做**。
