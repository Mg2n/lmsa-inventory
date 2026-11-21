<#
.SYNOPSIS
  Removes the InventorySync scheduled task and C:\InventorySync (run as Administrator).
  Spark Tech and SQL Server are not touched.
.PARAMETER KeepLogs
  Keep the logs folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\InventorySync',
    [switch]$KeepLogs,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$TaskName = 'InventorySync'

if (-not $Force) {
    $answer = Read-Host "Remove the '$TaskName' task and $InstallDir ? (y/N)"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 0 }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
} else {
    Write-Host "No scheduled task '$TaskName' found."
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
