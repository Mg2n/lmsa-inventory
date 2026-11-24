<#
.SYNOPSIS
  Self-update for the InventorySync agent. Runs as SYSTEM from the scheduled task
  "InventorySync-Update" (every 6 hours). Installs a newer InventorySync.ps1 only if
  it is signed with the project's private key.

.DESCRIPTION
  1. Downloads the manifest (UpdateUrl in config.json): { version, file, sha256, signature }.
  2. Does nothing unless the manifest version is newer than the installed agent.
  3. Downloads the new script and checks its SHA-256 against the manifest.
  4. Verifies the RSA-SHA256 signature over "InventorySync|<version>|<sha256>" with the
     public key in update-public-key.xml (installed next to this script; only
     Administrators/SYSTEM can change that folder). The private key never leaves the
     project owner's computer.
  5. Checks the script parses and declares that version, keeps the old one as
     InventorySync.prev.ps1, swaps it in, and starts one sync run.
  It never changes SQL Server, Spark Tech, config.json or the scheduled tasks.
#>
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log([string]$Level, [string]$Message) {
    $now = [datetime]::Now
    $line = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss', $Invariant), $Level, $Message
    try { [IO.File]::AppendAllText((Join-Path $LogDir ('update-{0}.log' -f $now.ToString('yyyyMMdd', $Invariant))), $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
    if ([Environment]::UserInteractive) { Write-Host $line }
}

function Get-InstalledVersion([string]$Path) {
    $m = [regex]::Match([IO.File]::ReadAllText($Path), "\`$AgentVersion = '([0-9]+\.[0-9]+\.[0-9]+)'")
    if (-not $m.Success) { throw "Cannot find the installed agent version in $Path" }
    return $m.Groups[1].Value
}

function New-RsaFromXml([string]$Xml) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $p = New-Object System.Security.Cryptography.RSAParameters
    $p.Modulus = [Convert]::FromBase64String($doc.RSAKeyValue.Modulus)
    $p.Exponent = [Convert]::FromBase64String($doc.RSAKeyValue.Exponent)
    $rsa = $null
    try { $rsa = New-Object System.Security.Cryptography.RSACng } catch { $rsa = [System.Security.Cryptography.RSA]::Create() }
    $rsa.ImportParameters($p)
    return $rsa
}

function Test-Signature([byte[]]$Data, [string]$SignatureB64, [string]$KeyXml) {
    $rsa = New-RsaFromXml $KeyXml
    try {
        return $rsa.VerifyData($Data, [Convert]::FromBase64String($SignatureB64),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

$exit = 0
try {
    $agentPath = Join-Path $Root 'InventorySync.ps1'
    $keyPath = Join-Path $Root 'update-public-key.xml'
    $config = [IO.File]::ReadAllText((Join-Path $Root 'config.json')) | ConvertFrom-Json
    if (-not ($config.PSObject.Properties['UpdateUrl']) -or -not $config.UpdateUrl) { Write-Log 'INFO' 'No UpdateUrl configured - nothing to do.'; exit 0 }
    if ($config.UpdateUrl -notmatch '^https://') { throw 'UpdateUrl must be https://' }
    if (-not (Test-Path $keyPath)) { throw "Public key missing: $keyPath" }
    $keyXml = [IO.File]::ReadAllText($keyPath)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'InventorySync-Updater'
    $wc.Encoding = [Text.Encoding]::UTF8
    $manifestUri = New-Object System.Uri($config.UpdateUrl)
    $m = $wc.DownloadString($manifestUri.AbsoluteUri + '?t=' + [DateTime]::UtcNow.Ticks) | ConvertFrom-Json

    $current = Get-InstalledVersion $agentPath
    if ([string]$m.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Bad version in manifest: $($m.version)" }
    if ([version]$m.version -le [version]$current) { Write-Log 'INFO' "Up to date ($current; published $($m.version))."; exit 0 }
    Write-Log 'INFO' "Update available: $current -> $($m.version)"
    if ($CheckOnly) { exit 0 }

    $fileUri = New-Object System.Uri($manifestUri, [string]$m.file)
    if ($fileUri.Scheme -ne 'https') { throw 'Update file must be https://' }
    $bytes = $wc.DownloadData($fileUri)
    if ($bytes.Length -lt 1000 -or $bytes.Length -gt 2MB) { throw "Unexpected update size: $($bytes.Length) bytes" }

    $sha = Get-Sha256Hex $bytes
    if ($sha -ne ([string]$m.sha256).ToLowerInvariant()) { throw "SHA-256 mismatch: got $sha, manifest says $($m.sha256)" }
    $signed = [Text.Encoding]::UTF8.GetBytes("InventorySync|$($m.version)|$sha")
    if (-not (Test-Signature $signed ([string]$m.signature) $keyXml)) { throw 'SIGNATURE INVALID - update refused.' }

    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { throw "New agent does not parse: $($errs[0].Message)" }
    if ($text -notmatch [regex]::Escape("`$AgentVersion = '$($m.version)'")) { throw 'New agent does not declare the manifest version.' }

    $tmp = "$agentPath.new"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Copy-Item $agentPath (Join-Path $Root 'InventorySync.prev.ps1') -Force
    Move-Item $tmp $agentPath -Force
    Write-Log 'INFO' "Installed agent $($m.version) (previous kept as InventorySync.prev.ps1). Signature OK."
    try { Start-ScheduledTask -TaskName 'InventorySync' } catch { Write-Log 'WARN' "Could not start a sync run now: $($_.Exception.Message)" }
} catch {
    $exit = 1
    Write-Log 'ERROR' $_.Exception.Message
}
exit $exit
