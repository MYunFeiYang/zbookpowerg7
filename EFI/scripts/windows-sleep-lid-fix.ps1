# HP ZBook Power G7 — fix hot lid-closed standby: hibernate on lid close
# Modern Standby (S0) keeps CPU/network active; hibernate powers off fully.

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Re-launching with Administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

function Set-LidHibernate {
    param([string]$SchemeGuid)
    $exists = powercfg /list | Select-String $SchemeGuid
    if (-not $exists) { return }
    # LIDACTION: 0=nothing, 1=sleep, 2=hibernate, 3=shutdown
    powercfg /setacvalueindex $SchemeGuid SUB_BUTTONS LIDACTION 2 | Out-Null
    powercfg /setdcvalueindex $SchemeGuid SUB_BUTTONS LIDACTION 2 | Out-Null
    Write-Host "    $SchemeGuid -> lid close = hibernate"
}

Write-Host '==> Enable hibernate...' -ForegroundColor Cyan
powercfg /hibernate on | Out-Null
# Keep fast startup off (true shutdown); hibernate still works for lid close
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Set-ItemProperty -Path $powerKey -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
Write-Host '    hibernate on, fast startup off (HiberbootEnabled=0)'

Write-Host '==> Lid close -> hibernate (all known plans)...' -ForegroundColor Cyan
$schemes = @(
    'fb5220ff-7e1a-47aa-9a42-50ffbf45c673',  # HP Optimized (Modern Standby)
    '3343ad1b-bad8-4007-af9b-287cd4a23510',  # ZBook Quiet
    '381b4222-f694-41f0-9685-ff5bb260df2e'   # Balanced
)
foreach ($s in $schemes) { Set-LidHibernate $s }

$active = (powercfg /getactivescheme) -replace '.*: ([0-9a-f-]+).*', '$1'
if ($active -match '^[0-9a-f-]{36}$') {
    powercfg /setactive $active | Out-Null
}

Write-Host '==> Reduce spurious wake (timers + common devices)...' -ForegroundColor Cyan
foreach ($scheme in $schemes) {
    if (-not (powercfg /list | Select-String $scheme)) { continue }
  # RTCWAKE: 0=disable, 1=enable, 2=important wake timers only
    powercfg /setacvalueindex $scheme SUB_SLEEP RTCWAKE 0 | Out-Null
    powercfg /setdcvalueindex $scheme SUB_SLEEP RTCWAKE 0 | Out-Null
}
powercfg /setactive $active | Out-Null

Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'mouse|Mouse|键盘|Keyboard|Wi-Fi|Ethernet|Bluetooth' } |
    ForEach-Object {
        powercfg /devicedisablewake $_.Name 2>$null | Out-Null
    }
# wake_armed list uses short names
foreach ($dev in @('HID-compliant mouse', 'HID Keyboard Device', 'Intel(R) Wi-Fi 6 AX201', 'Intel(R) Ethernet Connection')) {
    powercfg /devicedisablewake $dev 2>$null | Out-Null
}
Write-Host '    wake timers off; disabled wake on mouse/keyboard/network (if present)'

Write-Host ''
Write-Host 'Done. Close lid to hibernate (resume takes ~15-30s, should stay cool).' -ForegroundColor Green
Write-Host 'Tip: exit Sangfor VDI / aTrust before closing lid if resume feels slow.'
powercfg /availablesleepstates
