# HP ZBook Power G7 — Windows fan/noise optimization (run as Administrator)
# Backs up disabled startup entries under HKCU\Software\zbookpowerg7\DisabledStartup

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Re-launching with Administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arg
    exit
}

Write-Host '==> Stopping heavy background apps...' -ForegroundColor Cyan
$procNames = @(
    'AndrowsXyAcc', 'AndrowsStore', 'AndrowsSvr', 'AndrowsAssistant', 'AndrowsDlSvr', 'leishenSdk_yyb',
    'Thunder', 'BaiduNetdisk', 'quark_cloud_drive', 'Docker Desktop', 'com.docker.backend'
)
foreach ($name in $procNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host '==> Disabling Androws service (Tencent Android emulator)...' -ForegroundColor Cyan
$androwsSvc = Get-Service -Name 'AndrowsSvr' -ErrorAction SilentlyContinue
if ($androwsSvc) {
    if ($androwsSvc.Status -eq 'Running') { Stop-Service -Name 'AndrowsSvr' -Force }
    Set-Service -Name 'AndrowsSvr' -StartupType Disabled
    Write-Host '    AndrowsSvr -> Disabled'
}

Write-Host '==> Disabling HP telemetry / analytics services...' -ForegroundColor Cyan
$hpServices = @(
    'HpTouchpointAnalyticsService',
    'HPAudioAnalytics',
    'HPAppHelperCap',
    'HPDiagsCap',
    'HPNetworkCap',
    'HPSysInfoCap'
)
foreach ($svcName in $hpServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    try {
        if ($svc.Status -eq 'Running') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $svcName -StartupType Disabled
        Write-Host "    $svcName -> Disabled"
    } catch {
        Write-Warning "    Could not disable ${svcName}: $($_.Exception.Message)"
    }
}

Write-Host '==> NVIDIA: prefer maximum power saving when idle...' -ForegroundColor Cyan
$nvGlobal = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
if (-not (Test-Path $nvGlobal)) { New-Item -Path $nvGlobal -Force | Out-Null }
New-ItemProperty -Path $nvGlobal -Name 'NvCplEnableActiveContextMenu' -Value 0 -PropertyType DWord -Force | Out-Null

# Hybrid GPU: 1 = prefer integrated graphics for most apps (Optimus)
$hybrid = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\Hybrid'
if (-not (Test-Path $hybrid)) { New-Item -Path $hybrid -Force | Out-Null }
New-ItemProperty -Path $hybrid -Name 'SHIM_MCCOMPAT' -Value 0x00000001 -PropertyType DWord -Force | Out-Null
Write-Host '    Set SHIM_MCCOMPAT=1 (prefer iGPU where possible)'

Write-Host '==> Power plan: Balanced' -ForegroundColor Cyan
$balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
powercfg /setactive $balanced | Out-Null
powercfg /change monitor-timeout-ac 10 | Out-Null
powercfg /change disk-timeout-ac 20 | Out-Null
powercfg /change standby-timeout-ac 30 | Out-Null
Write-Host '    Active plan set to Balanced with moderate timeouts'

Write-Host ''
Write-Host 'Done. Reboot recommended so services stay disabled.' -ForegroundColor Green
Write-Host 'To restore Androws:  Set-Service AndrowsSvr -StartupType Automatic; start from Start menu'
Write-Host 'To restore aTrust VPN: run from Start menu (autostart removed from user profile)'
