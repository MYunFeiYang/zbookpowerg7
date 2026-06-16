# Restore startup entries and services disabled by windows-optimize-fan.ps1

$backupKey = 'HKCU:\Software\zbookpowerg7\DisabledStartup'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

if (Test-Path $backupKey) {
    $backup = Get-ItemProperty $backupKey
    foreach ($prop in $backup.PSObject.Properties) {
        if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
        Set-ItemProperty -Path $runKey -Name $prop.Name -Value $prop.Value
        Write-Host "Restored startup: $($prop.Name)"
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    foreach ($svc in @(
        'AndrowsSvr', 'HpTouchpointAnalyticsService', 'HPAudioAnalytics', 'HPAppHelperCap',
        'HPDiagsCap', 'HPNetworkCap', 'HPSysInfoCap', 'hptpsmarthealthservice',
        'DiagTrack', 'SangforPromoteService', 'aTrustService'
    )) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Set-Service -Name $svc -StartupType Automatic
            Write-Host "Service $svc -> Automatic"
        }
    }
    $tasks = @(
        '\WpsUpdateLogonTask_27283', '\WpsUpdateTask_27283', '\WpsWakeWnsLogonTask',
        '\Hewlett-Packard\HP Support Assistant\HP Support Assistant Update Notice',
        '\Hewlett-Packard\HP Support Assistant\HPPrinterLowInk',
        '\Hewlett-Packard\HP Support Assistant\WarrantyChecker',
        '\Hewlett-Packard\HP Support Assistant\WarrantyChecker_DeviceScan'
    )
    foreach ($t in $tasks) { schtasks /Change /TN $t /ENABLE 2>$null | Out-Null }
    Get-ScheduledTask -TaskPath '\GoogleUserPEH\' -ErrorAction SilentlyContinue |
        Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

    $startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $ollamaBak = Join-Path $startup '_disabled_Ollama.lnk'
    $ollama = Join-Path $startup 'Ollama.lnk'
    if ((Test-Path $ollamaBak) -and -not (Test-Path $ollama)) {
        Move-Item $ollamaBak $ollama -Force
        Write-Host 'Restored startup shortcut: Ollama.lnk'
    }
} else {
    Write-Host 'Run as Administrator to restore services.'
}

Write-Host 'Done. Reboot or log off/on for full effect.'
