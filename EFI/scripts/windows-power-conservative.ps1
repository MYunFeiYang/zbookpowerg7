# HP ZBook Power G7 — moderate CPU/thermal power scheduling (persistent)
# "ZBook Quiet": slightly quieter than Balanced, without heavy CPU throttling.

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Re-launching with Administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$cfgKey = 'HKCU:\Software\zbookpowerg7'
$schemeGuid = $null
if (Test-Path $cfgKey) {
    $schemeGuid = (Get-ItemProperty $cfgKey -Name ConservativeSchemeGuid -ErrorAction SilentlyContinue).ConservativeSchemeGuid
}
if (-not $schemeGuid) {
    $dup = powercfg /duplicatescheme $balanced 2>&1 | Out-String
    if ($dup -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        $schemeGuid = $matches[1].ToLower()
        if (-not (Test-Path $cfgKey)) { New-Item -Path $cfgKey -Force | Out-Null }
        Set-ItemProperty -Path $cfgKey -Name ConservativeSchemeGuid -Value $schemeGuid
        Write-Host "Created power scheme: $schemeGuid"
    } else {
        $schemeGuid = $balanced
        Write-Warning 'Could not duplicate scheme; applying to Balanced.'
    }
}

powercfg /changename $schemeGuid 'ZBook Quiet' 'Moderate: 95% CPU, efficient turbo, iGPU preferred' | Out-Null

function Set-PowerValue {
    param([string]$Scheme, [string]$Sub, [string]$Setting, [int]$Ac, [int]$Dc)
    powercfg /setacvalueindex $Scheme $Sub $Setting $Ac | Out-Null
    powercfg /setdcvalueindex $Scheme $Sub $Setting $Dc | Out-Null
}

Write-Host '==> Moderate processor scheduling...' -ForegroundColor Cyan
# Max CPU: 95% AC / 80% battery (room for turbo without full workstation heat)
Set-PowerValue $schemeGuid SUB_PROCESSOR PROCTHROTTLEMAX 95 80
Set-PowerValue $schemeGuid SUB_PROCESSOR PROCTHROTTLEMIN 5 5
# Efficient turbo (not fully off, not aggressive)
Set-PowerValue $schemeGuid SUB_PROCESSOR PERFBOOSTMODE 3 3
# Active cooling on AC (snappy); passive on battery (quieter unplugged)
Set-PowerValue $schemeGuid SUB_SYSTEM SYSCOOLPOL 1 0
# PCIe moderate power saving
Set-PowerValue $schemeGuid SUB_PCIEXPRESS ASPM 1 2

Write-Host '    Max CPU 95% (AC) / 80% (battery), efficient turbo, active cool on AC'

Write-Host '==> Display / idle timeouts...' -ForegroundColor Cyan
powercfg /change monitor-timeout-ac 15 | Out-Null
powercfg /change monitor-timeout-dc 8 | Out-Null
powercfg /change disk-timeout-ac 20 | Out-Null
powercfg /change disk-timeout-dc 15 | Out-Null
powercfg /change standby-timeout-ac 30 | Out-Null
powercfg /change standby-timeout-dc 20 | Out-Null

Write-Host '==> NVIDIA: prefer iGPU when possible...' -ForegroundColor Cyan
$hybrid = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\Hybrid'
if (-not (Test-Path $hybrid)) { New-Item -Path $hybrid -Force | Out-Null }
New-ItemProperty -Path $hybrid -Name 'SHIM_MCCOMPAT' -Value 0x00000001 -PropertyType DWord -Force | Out-Null

powercfg /setactive $schemeGuid | Out-Null
Write-Host ''
Write-Host "Active plan: ZBook Quiet ($schemeGuid)" -ForegroundColor Green
powercfg /query $schemeGuid SUB_PROCESSOR PROCTHROTTLEMAX
