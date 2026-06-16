# Re-enable HP Support Assistant scheduled tasks and services

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Re-launching with Administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$taskPath = '\Hewlett-Packard\HP Support Assistant\'
$tasks = @(
    'HP Support Assistant Update Notice',
    'HPPrinterLowInk',
    'WarrantyChecker',
    'WarrantyChecker_DeviceScan'
)

Write-Host '==> Enabling HP Support Assistant scheduled tasks...' -ForegroundColor Cyan
foreach ($name in $tasks) {
    $tn = "$taskPath$name"
    schtasks /Change /TN $tn /ENABLE 2>$null | Out-Null
    Write-Host "    $name -> Enabled"
}

Write-Host '==> Ensuring HP Support Assistant services are Automatic...' -ForegroundColor Cyan
foreach ($svcName in @('HPDiagsCap', 'HPNetworkCap', 'HPSysInfoCap', 'hptpsmarthealthservice')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    Set-Service -Name $svcName -StartupType Automatic
    if ($svc.Status -ne 'Running') {
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
    }
    Write-Host "    $svcName -> Automatic"
}

Write-Host ''
Write-Host 'Done. Reboot once, then open HP Support Assistant.' -ForegroundColor Green
