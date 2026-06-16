# HP ZBook Power G7 — persist Windows fan/memory optimizations (run once, survives reboot)
# Restore: windows-restore-startup.ps1

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Re-launching with Administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$backupKey = 'HKCU:\Software\zbookpowerg7\DisabledStartup'
if (-not (Test-Path $backupKey)) { New-Item -Path $backupKey -Force | Out-Null }

Write-Host '==> Disable heavy HKCU startup (with backup)...' -ForegroundColor Cyan
$toDisable = @(
    'aTrustTray', 'BaiduYunDetect', 'BaiduYunGuanjia', 'Thunder', 'quark_cloud_drive',
    'Docker Desktop', 'GoogleChromeAutoLaunch_0DB0F82882B0A582B7376B6E7833E19F'
)
$current = Get-ItemProperty $runKey
foreach ($name in $toDisable) {
    if ($current.PSObject.Properties.Name -contains $name) {
        Set-ItemProperty -Path $backupKey -Name $name -Value $current.$name
        Remove-ItemProperty -Path $runKey -Name $name -Force
        Write-Host "    Removed Run: $name"
    }
}

$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ollama = Join-Path $startup 'Ollama.lnk'
$ollamaBak = Join-Path $startup '_disabled_Ollama.lnk'
if ((Test-Path $ollama) -and -not (Test-Path $ollamaBak)) {
    Move-Item $ollama $ollamaBak -Force
    Write-Host '    Disabled startup shortcut: Ollama.lnk'
}

Write-Host '==> Edge: open new tab on startup...' -ForegroundColor Cyan
$edgeKey = 'HKCU:\Software\Microsoft\Edge\Main'
if (-not (Test-Path $edgeKey)) { New-Item -Path $edgeKey -Force | Out-Null }
Set-ItemProperty -Path $edgeKey -Name 'RestoreOnStartup' -Value 5 -Type DWord

Write-Host '==> Disable telemetry / bloat services...' -ForegroundColor Cyan
$services = @(
    'AndrowsSvr',
    'HpTouchpointAnalyticsService', 'HPAudioAnalytics', 'HPAppHelperCap',
    # Keep HP Support Assistant dependencies enabled (driver/BIOS updates)
    # 'HPDiagsCap', 'HPNetworkCap', 'HPSysInfoCap', 'hptpsmarthealthservice',
    'DiagTrack', 'SangforPromoteService',
    'aTrustService'   # Manual: start aTrust app when VPN needed
)
foreach ($svcName in $services) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    $type = if ($svcName -eq 'aTrustService') { 'Manual' } else { 'Disabled' }
    if ($svc.Status -eq 'Running' -and $type -eq 'Disabled') {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $svcName -StartupType $type -ErrorAction SilentlyContinue
    Write-Host "    $svcName -> $type"
}

Write-Host '==> Disable WPS / HP / Google junk scheduled tasks...' -ForegroundColor Cyan
$tasks = @(
    '\WpsUpdateLogonTask_27283', '\WpsUpdateTask_27283', '\WpsWakeWnsLogonTask',
    # Keep HP Support Assistant scheduled tasks enabled
    # '\Hewlett-Packard\HP Support Assistant\HP Support Assistant Update Notice',
    # '\Hewlett-Packard\HP Support Assistant\HPPrinterLowInk',
    # '\Hewlett-Packard\HP Support Assistant\WarrantyChecker',
    # '\Hewlett-Packard\HP Support Assistant\WarrantyChecker_DeviceScan'
)
foreach ($t in $tasks) {
    schtasks /Change /TN $t /DISABLE 2>$null | Out-Null
}
Get-ScheduledTask -TaskPath '\GoogleUserPEH\' -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

Write-Host '==> NVIDIA: prefer iGPU when possible...' -ForegroundColor Cyan
$hybrid = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\Hybrid'
if (-not (Test-Path $hybrid)) { New-Item -Path $hybrid -Force | Out-Null }
New-ItemProperty -Path $hybrid -Name 'SHIM_MCCOMPAT' -Value 0x00000001 -PropertyType DWord -Force | Out-Null

Write-Host '==> Conservative power scheduling...' -ForegroundColor Cyan
& "$PSScriptRoot\windows-power-conservative.ps1"
if ($LASTEXITCODE -ne 0 -and -not $?) {
    Write-Warning 'Conservative power script may need a separate admin run.'
}

Write-Host '==> Disable Fast Startup (true shutdown, less fan/disk on power-off)...' -ForegroundColor Cyan
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Set-ItemProperty -Path $powerKey -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
powercfg /hibernate off 2>$null | Out-Null
Write-Host '    HiberbootEnabled=0'

Write-Host ''
Write-Host 'Persistent settings applied. Reboot recommended.' -ForegroundColor Green
Write-Host 'Kept startup: WXWork, Ditto, Mem Reduct, Clash-Verge (startup folder)'
Write-Host 'Restore: windows-restore-startup.ps1'
