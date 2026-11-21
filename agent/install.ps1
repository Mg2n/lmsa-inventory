<#
.SYNOPSIS
  Installs the InventorySync agent on the store PC (run once, as Administrator).

.DESCRIPTION
  * Creates C:\InventorySync (script, config.json, logs, state, out)
  * Writes config.json and restricts it to Administrators, SYSTEM and the current user
  * Runs a DRY RUN (reads Spark Tech, writes a local JSON file, sends nothing)
  * Registers the scheduled task "InventorySync": every 5 minutes, below-normal
    priority, 2-minute limit, never two at once, runs even when nobody is logged in.
  Nothing here touches SQL Server settings, Spark Tech, the printer or the PC settings.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -IngestUrl https://<ref>.supabase.co/functions/v1/erp-ingest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IngestUrl,
    [string]$InstallDir = 'C:\InventorySync',
    [string]$SqlServer = '.',
    [string]$SqlDatabase = 'spark',
    [switch]$SkipDryRun,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$TaskName = 'InventorySync'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run this script as Administrator (right-click PowerShell > Run as administrator).'
}
if ($IngestUrl -notmatch '^https://') { throw 'IngestUrl must start with https://' }

function Read-Secret([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

Write-Host "Installing InventorySync to $InstallDir" -ForegroundColor Cyan
foreach ($d in @($InstallDir, "$InstallDir\logs", "$InstallDir\state", "$InstallDir\out")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}
Copy-Item -Path (Join-Path $PSScriptRoot 'InventorySync.ps1') -Destination "$InstallDir\InventorySync.ps1" -Force

# ---- config.json ----
$configPath = "$InstallDir\config.json"
if ((Test-Path $configPath) -and -not $Force) {
    Write-Host 'config.json already exists - keeping it (use -Force to rewrite).' -ForegroundColor Yellow
} else {
    $sqlPassword = Read-Secret 'Password of the read-only SQL login inventory_sync'
    $syncSecret = Read-Secret 'Sync secret (from the project owner)'
    if ($syncSecret.Length -lt 16) { throw 'Sync secret looks too short.' }
    $config = [ordered]@{
        SqlServer = $SqlServer; SqlDatabase = $SqlDatabase; SqlUser = 'inventory_sync'; SqlPassword = $sqlPassword
        IngestUrl = $IngestUrl; SyncSecret = $syncSecret
        BatchSize = 500; FullSyncHours = 24; SqlTimeoutSeconds = 60; MaxRunSeconds = 110
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# ---- lock down config.json: Administrators, SYSTEM (runs the task) and the current user ----
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)   # no inherited permissions
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($id in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', $me)) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
}
Set-Acl -Path $configPath -AclObject $acl
Write-Host "config.json restricted to Administrators, SYSTEM and $me" -ForegroundColor Green

# ---- dry run: proves the SQL login works, sends nothing ----
if (-not $SkipDryRun) {
    Write-Host 'Dry run (read-only, nothing is sent)...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\InventorySync.ps1" -DryRun
    if ($LASTEXITCODE -ne 0) { throw "Dry run failed - see $InstallDir\logs. The scheduled task was NOT created." }
}

# ---- scheduled task ----
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}\InventorySync.ps1"' -f $InstallDir) `
    -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -Priority 7 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal `
    -Description 'Read-only Spark Tech -> Supabase inventory sync (every 5 minutes).' | Out-Null

Write-Host ''
Write-Host "Done. The first sync runs in about 1 minute." -ForegroundColor Green
Write-Host "  Logs:       $InstallDir\logs"
Write-Host "  Run now:    Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Status:     Get-ScheduledTaskInfo -TaskName $TaskName"
Write-Host "  Uninstall:  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1"
