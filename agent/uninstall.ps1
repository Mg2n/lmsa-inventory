<#
.SYNOPSIS
  Removes InventorySync (run as Administrator): the scheduled tasks, C:\InventorySync,
  and the local Windows account inventory_sync. Spark Tech and SQL Server are not touched.
.PARAMETER KeepLogs
  Keep the logs folder.
.PARAMETER KeepAccount
  Keep the inventory_sync Windows account.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\InventorySync',
    [switch]$KeepLogs,
    [switch]$KeepAccount,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$AccountName = 'inventory_sync'
$Computer = $env:COMPUTERNAME

if (-not $Force) {
    $answer = Read-Host "Remove InventorySync (task, $InstallDir and the '$AccountName' Windows account)? (y/N)"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 0 }
}

foreach ($name in @('InventorySync', 'InventorySync-DryRun')) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Scheduled task '$name' removed." -ForegroundColor Green
    }
}

if (Test-Path $InstallDir) {
    if ($KeepLogs) {
        Get-ChildItem $InstallDir | Where-Object { $_.Name -ne 'logs' } | Remove-Item -Recurse -Force
        Write-Host "Removed $InstallDir (logs kept)." -ForegroundColor Green
    } else {
        Remove-Item $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir." -ForegroundColor Green
    }
}

if (-not $KeepAccount) {
    $machine = [ADSI]"WinNT://$Computer,computer"
    if ($machine.Children | Where-Object { $_.SchemaClassName -eq 'User' -and $_.Name -eq $AccountName }) {
        $machine.Delete('User', $AccountName)
        Write-Host "Windows account '$AccountName' removed." -ForegroundColor Green
    }
    $hideKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    Remove-ItemProperty -Path $hideKey -Name $AccountName -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Optional: in SSMS, Security > Logins > right-click '$Computer\$AccountName' > Delete removes its read access." -ForegroundColor Yellow
