<#
.SYNOPSIS
  Installs the InventorySync agent on the store PC (run once, as Administrator).

.DESCRIPTION
  For SQL Server in "Windows Authentication mode" (no SQL Server restart needed):
  * Creates a normal (non-admin) local Windows account "inventory_sync" with a long
    random password that nobody needs to know, hidden from the Windows sign-in screen.
  * Creates C:\InventorySync (script, config.json, logs, state, out) and locks it down:
    only Administrators and SYSTEM can change it; inventory_sync can read it and write
    only to logs, state and out.
  * Writes create-login.sql to your Desktop and waits while you run it in SSMS
    (read-only access to 4 Spark Tech tables for that Windows account).
  * Runs a DRY RUN as inventory_sync (reads Spark Tech, writes a local JSON file, sends nothing).
  * Registers the scheduled task "InventorySync" as inventory_sync: every 5 minutes,
    below-normal priority, 2-minute limit, never two at once, runs with nobody logged in.
  Nothing here touches SQL Server settings, Spark Tech, the printer or other PC settings.
  Run it again any time (e.g. with -Force to re-enter the sync secret); it is safe to repeat.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -IngestUrl https://<ref>.supabase.co/functions/v1/erp-ingest -SqlServer "." -SqlDatabase "Spark"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IngestUrl,
    [string]$InstallDir = 'C:\InventorySync',
    [string]$SqlServer = '.',
    [string]$SqlDatabase = 'Spark',
    [string]$SecretFile,
    [switch]$SkipDryRun,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$TaskName = 'InventorySync'
$DryTaskName = 'InventorySync-DryRun'
$AccountName = 'inventory_sync'
$Computer = $env:COMPUTERNAME
$Tables = @('ITEMES', 'ITMUNIT', 'ITEMSMASTER', 'WAREHOUSES')

# Built-in groups by SID (their names are translated on Arabic Windows)
$SidAdmins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$SidUsers = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
$SidSystem = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run this script as Administrator (right-click PowerShell > Run as administrator).'
}
if ($IngestUrl -notmatch '^https://') { throw 'IngestUrl must start with https://' }
if ($SqlDatabase -notmatch '^[A-Za-z0-9_\-]+$') { throw "Unexpected database name '$SqlDatabase'." }

# A local Windows account can only sign in to a SQL Server on this same PC.
$sqlHost = $SqlServer.Split('\')[0].Split(',')[0] -replace '^(tcp|np|lpc):', ''
if (@('.', '(local)', 'localhost', '127.0.0.1', $Computer) -notcontains $sqlHost) {
    throw "SQL Server '$SqlServer' looks like another computer. This installer only supports SQL Server on this PC - contact the project owner."
}

function Read-Secret([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] 28
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes); $rng.Dispose()
    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    return 'Is#7' + $sb.ToString()   # always meets Windows complexity rules
}

function Get-GroupAdsi([Security.Principal.SecurityIdentifier]$Sid) {
    $name = $Sid.Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    return [ADSI]"WinNT://$Computer/$name,group"
}

# Membership by SID (ADSI IsMember() compares path strings and can miss a real member)
function Test-GroupHasSid($Group, [Security.Principal.SecurityIdentifier]$Sid) {
    foreach ($m in @($Group.Invoke('Members'))) {
        try {
            $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
            if ((New-Object Security.Principal.SecurityIdentifier($bytes, 0)).Equals($Sid)) { return $true }
        } catch { }
    }
    return $false
}

function Read-SyncSecret {
    if ($SecretFile) {
        if (-not (Test-Path $SecretFile)) { throw "Secret file not found: $SecretFile" }
        $value = ([IO.File]::ReadAllText((Resolve-Path $SecretFile))).Trim()
        if ($value -notmatch '^[0-9a-fA-F]{64}$') { throw "The secret file must contain exactly the 64-character secret (it has $($value.Length) characters)." }
        Remove-Item $SecretFile -Force
        Write-Host "Secret read from the file (64 characters) and the file was deleted." -ForegroundColor Green
        return $value
    }
    for ($try = 1; $try -le 3; $try++) {
        $value = (Read-Secret 'Paste the sync secret (right-click to paste, nothing shows) and press Enter').Trim()
        if ($value -match '^[0-9a-fA-F]{64}$') { Write-Host 'Secret received (64 characters).' -ForegroundColor Green; return $value }
        Write-Host ("Received {0} characters - the secret is 64 characters (0-9, a-f). Copy it again and retry." -f $value.Length) -ForegroundColor Yellow
    }
    throw 'Could not read the sync secret. Save it in a text file (e.g. C:\secret.txt) and run the installer again with -SecretFile C:\secret.txt'
}

function New-Rule($Identity, [string]$Rights, [bool]$Inherit) {
    $inh = [Security.AccessControl.InheritanceFlags]::None
    if ($Inherit) { $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
    return New-Object Security.AccessControl.FileSystemAccessRule($Identity, $Rights, $inh, 'None', 'Allow')
}

# ---------------------------------------------------------------------------
Write-Step "1/6  Windows account '$AccountName' (normal user, not an administrator)"
$password = New-RandomPassword
$userPath = "WinNT://$Computer/$AccountName,user"
$machine = [ADSI]"WinNT://$Computer,computer"
$existing = $machine.Children | Where-Object { $_.SchemaClassName -eq 'User' -and $_.Name -eq $AccountName }
if ($existing) {
    $user = [ADSI]$userPath
    $user.SetPassword($password)
    Write-Host 'Account already exists - password renewed.'
} else {
    $user = $machine.Create('User', $AccountName)
    $user.SetPassword($password)
    $user.SetInfo()
    Write-Host 'Account created.'
}
$user.Put('FullName', 'Inventory sync (read-only)')
$user.Put('Description', 'Reads Spark Tech stock for the inventory scanner. Runs the InventorySync task only.')
$flags = [int]$user.Get('UserFlags')
$flags = ($flags -band (-bnot 0x2)) -bor 0x10000 -bor 0x40   # enabled, password never expires, cannot change password
$user.Put('UserFlags', $flags)
$user.SetInfo()

$AccountSid = (New-Object Security.Principal.NTAccount("$Computer\$AccountName")).Translate([Security.Principal.SecurityIdentifier])
$usersGroup = Get-GroupAdsi $SidUsers
if (-not (Test-GroupHasSid $usersGroup $AccountSid)) {
    try { $usersGroup.Add("WinNT://$Computer/$AccountName") }
    catch { if ($_.Exception.Message -notmatch 'already a member') { throw } }
}
if (Test-GroupHasSid (Get-GroupAdsi $SidAdmins) $AccountSid) {
    throw "'$AccountName' is a member of Administrators. Remove it from that group first (it must be a normal user)."
}

# keep it off the Windows sign-in screen so store staff never see it
$hideKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
if (-not (Test-Path $hideKey)) { New-Item -Path $hideKey -Force | Out-Null }
New-ItemProperty -Path $hideKey -Name $AccountName -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host 'Hidden from the sign-in screen.'

# ---------------------------------------------------------------------------
Write-Step "2/6  Files in $InstallDir"
foreach ($d in @($InstallDir, "$InstallDir\logs", "$InstallDir\state", "$InstallDir\out")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}
Copy-Item -Path (Join-Path $PSScriptRoot 'InventorySync.ps1') -Destination "$InstallDir\InventorySync.ps1" -Force

$configPath = "$InstallDir\config.json"
$writeConfig = $true
if ((Test-Path $configPath) -and -not $Force) {
    $old = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if ($old.PSObject.Properties['SqlAuth'] -and $old.SqlAuth -eq 'Windows' -and $old.SqlServer -eq $SqlServer -and $old.SqlDatabase -eq $SqlDatabase) {
        Write-Host 'config.json already exists - keeping it (use -Force to re-enter the sync secret).' -ForegroundColor Yellow
        $writeConfig = $false
    }
}
if ($writeConfig) {
    $syncSecret = Read-SyncSecret
    $config = [ordered]@{
        SqlServer = $SqlServer; SqlDatabase = $SqlDatabase; SqlAuth = 'Windows'; SqlUser = $AccountName
        IngestUrl = $IngestUrl; SyncSecret = $syncSecret
        BatchSize = 500; FullSyncHours = 24; SqlTimeoutSeconds = 60; MaxRunSeconds = 110
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'config.json written.'
}

# Folder: only Administrators/SYSTEM can change anything; inventory_sync reads,
# and may write only logs/state/out. (Also stops other users editing the script.)
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Rule $SidAdmins 'FullControl' $true))
$acl.AddAccessRule((New-Rule $SidSystem 'FullControl' $true))
$acl.AddAccessRule((New-Rule $AccountSid 'ReadAndExecute' $true))
Set-Acl -Path $InstallDir -AclObject $acl
foreach ($d in @('logs', 'state', 'out')) {
    $a = Get-Acl "$InstallDir\$d"
    $a.AddAccessRule((New-Rule $AccountSid 'Modify' $true))
    Set-Acl -Path "$InstallDir\$d" -AclObject $a
}
# config.json holds the sync secret: Administrators, SYSTEM and inventory_sync (read) only
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Rule $SidAdmins 'FullControl' $false))
$acl.AddAccessRule((New-Rule $SidSystem 'FullControl' $false))
$acl.AddAccessRule((New-Rule $AccountSid 'Read' $false))
Set-Acl -Path $configPath -AclObject $acl
Write-Host 'Permissions set (Administrators, SYSTEM, inventory_sync read-only).'

# ---------------------------------------------------------------------------
Write-Step '3/6  Read-only access in SQL Server (you do this in SSMS)'
$login = "$Computer\$AccountName"
$grants = ($Tables | ForEach-Object { "GRANT SELECT ON dbo.$_ TO [$AccountName];" }) -join "`r`n"
$sql = @"
-- InventorySync: read-only access for the Windows account $login
-- Creates a login and gives SELECT on $($Tables.Count) tables only. Changes no data.
USE [master];
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$login')
    CREATE LOGIN [$login] FROM WINDOWS WITH DEFAULT_DATABASE = [$SqlDatabase];
GO
USE [$SqlDatabase];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AccountName')
    CREATE USER [$AccountName] FOR LOGIN [$login];
$grants
GO
"@
# on the Desktop: SSMS (not elevated) cannot open files inside the locked-down folder
$sqlFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'create-login.sql'
[IO.File]::WriteAllText($sqlFile, $sql, (New-Object Text.UTF8Encoding($true)))
Write-Host $sql -ForegroundColor Gray
Write-Host "Saved as $sqlFile" -ForegroundColor Yellow
Write-Host 'In SSMS (connected as before): File > Open > File... > choose that file > press F5.'
Write-Host 'Wait for "Commands completed successfully."'
[void](Read-Host 'Then come back here and press Enter')

# ---------------------------------------------------------------------------
function Register-AgentTask([string]$Name, [string]$ExtraArgs, $Trigger, [string]$Description) {
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $Name -Confirm:$false }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}\InventorySync.ps1"{1}' -f $InstallDir, $ExtraArgs) `
        -WorkingDirectory $InstallDir
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -Priority 7 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
    $p = @{ TaskName = $Name; Action = $action; Settings = $settings; User = "$Computer\$AccountName"; Password = $password; RunLevel = 'Limited'; Description = $Description }
    if ($Trigger) { $p.Trigger = $Trigger }
    try { Register-ScheduledTask @p | Out-Null }
    catch { throw "Could not create the scheduled task as $AccountName : $($_.Exception.Message)" }
}

function Show-LogTail {
    $log = Get-ChildItem "$InstallDir\logs\sync-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) { Get-Content $log.FullName -Tail 8 | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray } }
}

if (-not $SkipDryRun) {
    Write-Step "4/6  Dry run as $AccountName (reads Spark Tech, sends nothing)"
    Register-AgentTask $DryTaskName ' -DryRun' $null 'InventorySync test run (temporary).'
    Start-ScheduledTask -TaskName $DryTaskName
    $until = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        $state = [string](Get-ScheduledTask -TaskName $DryTaskName).State
        Write-Host -NoNewline '.'
    } while (($state -eq 'Running' -or $state -eq 'Queued') -and (Get-Date) -lt $until)
    Write-Host ''
    $result = (Get-ScheduledTaskInfo -TaskName $DryTaskName).LastTaskResult
    Unregister-ScheduledTask -TaskName $DryTaskName -Confirm:$false
    Show-LogTail
    if ($result -ne 0) {
        $hint = ''
        if ($result -eq 267011) { $hint = ' (the task did not start)' }
        throw "Dry run failed, result $result$hint. See the log lines above / $InstallDir\logs. The scheduled task was NOT created. If it says 'Login failed', run create-login.sql in SSMS again, then run this installer again."
    }
    Write-Host 'Dry run OK - Spark Tech was read successfully.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Step '5/6  Scheduled task (every 5 minutes)'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-AgentTask $TaskName '' $trigger 'Read-only Spark Tech -> Supabase inventory sync (every 5 minutes).'
$password = $null
Write-Host "Task '$TaskName' created; it runs as $Computer\$AccountName." -ForegroundColor Green

Write-Step '6/6  Done'
Write-Host 'The first sync runs in about 1 minute. Check the Sync page in the app.' -ForegroundColor Green
Write-Host "  Logs:       $InstallDir\logs"
Write-Host "  Run now:    Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Status:     Get-ScheduledTaskInfo -TaskName $TaskName   (LastTaskResult 0 = OK)"
Write-Host "  Uninstall:  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1"
