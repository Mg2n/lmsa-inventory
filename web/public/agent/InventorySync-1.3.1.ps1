<#
.SYNOPSIS
  Read-only sync agent: Spark Tech (SQL Server) -> Supabase erp-ingest Edge Function.

.DESCRIPTION
  Windows PowerShell 5.1, no installs. Runs every 5 minutes as a scheduled task.
  * Only SELECT ... WITH (NOLOCK) on ITEMES, ITMUNIT, ITEMSMASTER, WAREHOUSES and,
    for the sales log, chosen columns of GLVOUHEAD and ITMSALES. A guard refuses any other SQL.
  * Sends only rows that changed since the last successful run (plus deletes);
    a full snapshot is sent once every FullSyncHours (default 24).
  * Batches of 500 rows, TLS 1.2, retries with backoff, 60 s SQL timeout,
    ~4-minute total limit, below-normal priority, one instance at a time. Row
    formatting, diffing and the snapshot run in compiled C# (cached in state\).
  * Rolling log in <InstallDir>\logs (7 days).

.PARAMETER DryRun
  Read from SQL Server and write the payload to <InstallDir>\out\dryrun-*.json.
  Nothing is sent and the local state is not changed.

.PARAMETER Full
  Force a full snapshot (also removes rows deleted in Spark Tech).

.PARAMETER SourceJson
  Testing only: read a Spark-shaped JSON fixture instead of SQL Server.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\InventorySync\InventorySync.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [switch]$Full,
    [string]$SourceJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$AgentVersion = '1.3.1'
# Windows PowerShell 5.1: $PSScriptRoot is empty inside param() defaults, so resolve here
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
$LogDir = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
$OutDir = Join-Path $Root 'out'
$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:Deadline = 230
# Gregorian dates in file names/logs even on an Arabic (Hijri) Windows locale
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# Table definitions (the ONLY tables this agent may read)
# ---------------------------------------------------------------------------
$Tables = [ordered]@{
    products   = @{ Source = 'ITEMES';      Key = @('BRNID', 'ITMCODE');
                    Columns = @('BRNID', 'ITMCODE', 'ITMDESC', 'ITMLATIN', 'ITMCAT', 'ITMSUBCAT', 'ITMGROUP', 'SALEPRICE', 'REORDER', 'ITMSTOP', 'ACTIVATE') }
    barcodes   = @{ Source = 'ITMUNIT';     Key = @('BRNID', 'ITMCODE', 'UNITCODE');
                    Columns = @('BRNID', 'ITMCODE', 'UNITCODE', 'BARCODE', 'UNITNAME', 'UFACT', 'UNITPRICE') }
    # ~6 rows per item: summed per item + warehouse inside SQL Server (cheap there,
    # and 6x less work for this old PC). Stock formula is applied in Supabase.
    stock      = @{ Source = 'ITEMSMASTER'; Key = @('BRNID', 'ITMCODE', 'WHSNO');
                    Columns = @('BRNID', 'ITMCODE', 'WHSNO', 'BEGINQTY', 'PURCHQTY', 'SALEQTY', 'PURCHRTN', 'SALERTN', 'INQTY', 'OUTQTY', 'RESERVQTY');
                    Sum = @('BEGINQTY', 'PURCHQTY', 'SALEQTY', 'PURCHRTN', 'SALERTN', 'INQTY', 'OUTQTY', 'RESERVQTY') }
    warehouses = @{ Source = 'WAREHOUSES';  Key = @('BRNID', 'WHSNO');
                    Columns = @('WHSNO', 'BRNID', 'WHSNAME') }
    # sales audit log: bill headers (sales document types only) and their lines.
    # No customer, cost or ZATCA columns; SQL Server grants only these columns.
    sales_heads = @{ Source = 'GLVOUHEAD'; Key = @('BRNID', 'GLTYPE', 'VOUNO');
                    Columns = @('BRNID', 'GLTYPE', 'VOUNO', 'WHSNO', 'VOUDATE', 'SELLERNO', 'USERNO', 'POSNO', 'SHIFTNO', 'SHIFTID',
                                'INVQTY', 'INVTOTAL', 'DISCTOTAL', 'TAXTOTAL', 'INVNETAMT', 'ACTIVATE');
                    Optional = @('INVCOSTAMT');   # cost, read only once SQL Server grants it (profit)
                    Where = 'GLTYPE IN (SELECT DISTINCT GLTYPE FROM ITMSALES WITH (NOLOCK))' }
    sales_lines = @{ Source = 'ITMSALES';  Key = @('BRNID', 'GLTYPE', 'VOUNO', 'INVSERIAL');
                    Columns = @('BRNID', 'GLTYPE', 'VOUNO', 'INVSERIAL', 'WHSNO', 'ITMCODE', 'UNITCODE', 'UFACT', 'SALEQTY',
                                'UNITPRICE', 'DISCAMT', 'TAXAMT', 'ITMTOTAL');
                    Optional = @('TOTALCOST') }
}
$AllowedSourceTables = @('ITEMES', 'ITMUNIT', 'ITEMSMASTER', 'WAREHOUSES', 'ITMSALES', 'GLVOUHEAD')
# columns whose raw value matters (leading/trailing spaces are data-quality signals)
$KeepRawColumns = @('BARCODE')

# ---------------------------------------------------------------------------
# Logging (one file per day, 7 days kept)
# ---------------------------------------------------------------------------
function Write-Log([string]$Level, [string]$Message) {
    $now = [datetime]::Now
    $line = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss', $InvariantCulture), $Level, $Message
    try {
        $file = Join-Path $LogDir ('sync-{0}.log' -f $now.ToString('yyyyMMdd', $InvariantCulture))
        [System.IO.File]::AppendAllText($file, $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch { }
    if ([Environment]::UserInteractive) { Write-Host $line }
}

function Remove-OldLogs {
    $limit = (Get-Date).AddDays(-7)
    Get-ChildItem -Path $LogDir -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $OutDir -Filter 'dryrun-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Assert-Time([string]$Step) {
    if ($Clock.Elapsed.TotalSeconds -gt $script:Deadline) {
        throw ('Time limit of {0}s reached during {1}' -f $script:Deadline, $Step)
    }
}

# ---------------------------------------------------------------------------
# Read-only SQL guard: refuses anything that is not a plain SELECT ... WITH (NOLOCK)
# on the allowed tables.
# ---------------------------------------------------------------------------
function Assert-ReadOnlySql([string]$Sql) {
    $s = [regex]::Replace($Sql, '/\*.*?\*/', ' ', 'Singleline')
    $s = [regex]::Replace($s, '--[^\r\n]*', ' ')
    $s = $s.Trim()
    if ($s -notmatch '^(?i)SELECT\s') { throw "SQL guard: only SELECT is allowed. Refused: $Sql" }
    if ($s.Contains(';')) { throw "SQL guard: multiple statements are not allowed. Refused: $Sql" }
    $forbidden = '(?i)\b(INSERT|UPDATE|DELETE|MERGE|ALTER|DROP|CREATE|EXEC|EXECUTE|TRUNCATE|GRANT|REVOKE|DENY|BACKUP|RESTORE|DBCC|SHUTDOWN|RECONFIGURE|OPENROWSET|OPENQUERY|OPENDATASOURCE|BULK|INTO|WAITFOR|USE|SET|DECLARE|KILL|USERINFO|ZATCA\w*)\b|(?i)\b(xp_|sp_)\w*'
    if ($s -match $forbidden) { throw "SQL guard: forbidden keyword '$($Matches[0])'. Refused: $Sql" }
    $refs = [regex]::Matches($s, '(?i)\b(FROM|JOIN)\s+([\[\]\w\.]+)(\s+WITH\s*\(\s*NOLOCK\s*\))?')
    if ($refs.Count -eq 0) { throw "SQL guard: no table found. Refused: $Sql" }
    foreach ($m in $refs) {
        $table = ($m.Groups[2].Value -replace '[\[\]]', '').Split('.')[-1].ToUpperInvariant()
        if ($AllowedSourceTables -notcontains $table) { throw "SQL guard: table '$table' is not allowed. Refused: $Sql" }
        if (-not $m.Groups[3].Success) { throw "SQL guard: '$table' must be read WITH (NOLOCK). Refused: $Sql" }
    }
}

# ---------------------------------------------------------------------------
# Hot loops in compiled C# (PowerShell 5.1 needs ~8 ms per row on the old PC;
# this is ~100x faster). Compiled once per agent version and cached in state\.
# Output is identical to the original PowerShell implementation.
# ---------------------------------------------------------------------------
$FastCode = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.IO;
using System.Text;

public static class InvSyncFast {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static string JsonString(string text) {
        if (text == null) text = "";
        bool plain = true;
        foreach (char ch in text) { if (ch == '"' || ch == '\\' || ch < 0x20) { plain = false; break; } }
        if (plain) return "\"" + text + "\"";
        var sb = new StringBuilder(text.Length + 8);
        sb.Append('"');
        foreach (char ch in text) {
            if (ch == '"') sb.Append("\\\"");
            else if (ch == '\\') sb.Append("\\\\");
            else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4"));
            else sb.Append(ch);
        }
        sb.Append('"');
        return sb.ToString();
    }

    public static string JsonValue(object v, bool keepRaw) {
        if (v == null || v is DBNull) return "null";
        if (v is bool) return ((bool)v) ? "true" : "false";
        if (v is decimal || v is double || v is float || v is int || v is long || v is short || v is byte)
            return Convert.ToString(v, Inv);
        if (v is DateTime) return JsonString(((DateTime)v).ToString("s", Inv));
        if (v is byte[]) return "null";
        string text = Convert.ToString(v, Inv);
        if (!keepRaw) text = text.TrimEnd();   // CHAR padding
        return JsonString(text);
    }

    public static string KeyString(object[] values) {
        var parts = new string[values.Length];
        for (int i = 0; i < values.Length; i++) {
            object v = values[i];
            parts[i] = (v == null || v is DBNull) ? "" : Convert.ToString(v, Inv).Trim();
        }
        return string.Join("|", parts);
    }

    public static string FormatRow(string[] columns, object[] values, bool[] keepRaw) {
        var sb = new StringBuilder(256);
        sb.Append('{');
        for (int i = 0; i < columns.Length; i++) {
            if (i > 0) sb.Append(',');
            sb.Append('"').Append(columns[i]).Append("\":").Append(JsonValue(values[i], keepRaw[i]));
        }
        sb.Append('}');
        return sb.ToString();
    }

    public static Dictionary<string, string> ReadTable(IDataReader reader, string[] columns, int[] keyIdx, bool[] keepRaw) {
        var rows = new Dictionary<string, string>();
        var values = new object[columns.Length];
        var keyVals = new object[keyIdx.Length];
        while (reader.Read()) {
            reader.GetValues(values);
            for (int j = 0; j < keyIdx.Length; j++) keyVals[j] = values[keyIdx[j]];
            rows[KeyString(keyVals)] = FormatRow(columns, values, keepRaw);
        }
        return rows;
    }

    // rows that are new or changed (or all of them on a full sync)
    public static List<string> Upserts(Dictionary<string, string> current, Dictionary<string, string> old, bool full) {
        var list = new List<string>();
        foreach (var kv in current) {
            string prev;
            if (full || !old.TryGetValue(kv.Key, out prev) || prev != kv.Value) list.Add(kv.Value);
        }
        return list;
    }

    public static List<string> DeletedKeys(Dictionary<string, string> current, Dictionary<string, string> old) {
        var list = new List<string>();
        foreach (var k in old.Keys) if (!current.ContainsKey(k)) list.Add(k);
        return list;
    }

    // table name -> (key -> row JSON)
    public static Dictionary<string, Dictionary<string, string>> LoadSnapshot(string path) {
        var tables = new Dictionary<string, Dictionary<string, string>>();
        foreach (string line in File.ReadAllLines(path, Encoding.UTF8)) {
            string[] parts = line.Split(new[] { '\t' }, 3);
            if (parts.Length != 3) continue;
            Dictionary<string, string> rows;
            if (!tables.TryGetValue(parts[0], out rows)) { rows = new Dictionary<string, string>(); tables[parts[0]] = rows; }
            rows[Unescape(parts[1])] = parts[2];
        }
        return tables;
    }

    public static void WriteSnapshot(TextWriter w, string table, Dictionary<string, string> rows) {
        foreach (var kv in rows) { w.Write(table); w.Write('\t'); w.Write(Escape(kv.Key)); w.Write('\t'); w.WriteLine(kv.Value); }
    }

    // keys are written escaped so a tab or line break inside an item code cannot split the line
    static string Escape(string k) {
        if (k.IndexOfAny(new[] { '\\', '\t', '\r', '\n' }) < 0) return k;
        return k.Replace("\\", "\\\\").Replace("\t", "\\t").Replace("\r", "\\r").Replace("\n", "\\n");
    }
    static string Unescape(string k) {
        if (k.IndexOf('\\') < 0) return k;
        var sb = new StringBuilder(k.Length);
        for (int i = 0; i < k.Length; i++) {
            char c = k[i];
            if (c == '\\' && i + 1 < k.Length) {
                char n = k[++i];
                sb.Append(n == 't' ? '\t' : n == 'r' ? '\r' : n == 'n' ? '\n' : n);
            } else sb.Append(c);
        }
        return sb.ToString();
    }
}
'@

function Import-FastCode {
    if ('InvSyncFast' -as [type]) { return }
    $refs = @{}
    if ($PSVersionTable.PSEdition -ne 'Core') { $refs.ReferencedAssemblies = @('System.Data') }
    $dll = Join-Path $StateDir ("InvSyncFast-{0}.dll" -f $AgentVersion)
    if (Test-Path $dll) { try { Add-Type -Path $dll; return } catch { Write-Log 'WARN' "Cached helper not loadable, recompiling: $($_.Exception.Message)" } }
    try {
        Add-Type -TypeDefinition $FastCode -OutputAssembly $dll -OutputType Library @refs
        if (-not ('InvSyncFast' -as [type])) { Add-Type -Path $dll }
    } catch {
        Write-Log 'WARN' "Could not cache the compiled helper ($($_.Exception.Message)); compiling in memory."
        if (-not ('InvSyncFast' -as [type])) { Add-Type -TypeDefinition $FastCode @refs }
    }
}

function ConvertTo-JsonString([string]$Text) { return [InvSyncFast]::JsonString($Text) }
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
function Get-KeyString($Values) { return [InvSyncFast]::KeyString([object[]]@($Values)) }
function Get-KeepRaw($Columns) { return [bool[]]@(foreach ($c in $Columns) { $KeepRawColumns -contains $c }) }
function Format-Row($Columns, $Values) { return [InvSyncFast]::FormatRow([string[]]@($Columns), [object[]]@($Values), (Get-KeepRaw $Columns)) }

# ---------------------------------------------------------------------------
# Readers. Each returns Dictionary[key -> row JSON] for one table.
# ---------------------------------------------------------------------------
function Get-SelectSql($Def) {
    if ($Def.ContainsKey('Sum')) {
        $cols = foreach ($c in $Def.Columns) { if ($Def.Sum -contains $c) { "SUM($c) AS $c" } else { $c } }
        return 'SELECT {0} FROM {1} WITH (NOLOCK) GROUP BY {2}' -f ($cols -join ', '), $Def.Source, ($Def.Key -join ', ')
    }
    $sql = 'SELECT {0} FROM {1} WITH (NOLOCK)' -f ($Def.Columns -join ', '), $Def.Source
    if ($Def.ContainsKey('Where')) { $sql += ' WHERE ' + $Def.Where }
    return $sql
}

# Optional columns (cost) are read only if SQL Server allows it; a column-level
# "SELECT permission denied" (error 230) falls back to the required columns.
$script:OptionalDenied = @{}
function Get-FullDef($Def) {
    if (-not $Def.ContainsKey('Optional')) { return $Def }
    $full = $Def.Clone(); $full.Columns = @($Def.Columns + $Def.Optional); $full.Remove('Optional')
    return $full
}

function Read-SqlTable($Connection, [string]$Name, $Def, [int]$TimeoutSeconds) {
    if ($Def.ContainsKey('Optional')) {
        try { return , (Read-SqlTableCore $Connection $Name (Get-FullDef $Def) $TimeoutSeconds) }
        catch {
            $sqlEx = $_.Exception
            while ($sqlEx -and $sqlEx -isnot [System.Data.SqlClient.SqlException]) { $sqlEx = $sqlEx.InnerException }
            if (-not $sqlEx -or $sqlEx.Number -ne 230) { throw }
            $script:OptionalDenied[$Name] = $true
            Write-Log 'INFO' ("{0}: no permission for {1} yet - syncing without it" -f $Name, ($Def.Optional -join ', '))
        }
    }
    return , (Read-SqlTableCore $Connection $Name $Def $TimeoutSeconds)
}

function Read-SqlTableCore($Connection, [string]$Name, $Def, [int]$TimeoutSeconds) {
    $sql = Get-SelectSql $Def
    Assert-ReadOnlySql $sql
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $TimeoutSeconds
    $keyIdx = [int[]]@(foreach ($k in $Def.Key) { [array]::IndexOf($Def.Columns, $k) })
    $reader = $cmd.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)
    try {
        $rows = [InvSyncFast]::ReadTable($reader, [string[]]@($Def.Columns), $keyIdx, (Get-KeepRaw $Def.Columns))
    } finally { $reader.Close(); $cmd.Dispose() }
    return , $rows
}

function Read-FixtureTable($Fixture, [string]$Name, $Def) {
    # mirrors Get-SelectSql, including the GROUP BY + SUM for stock
    $grouped = [ordered]@{}
    foreach ($r in @($Fixture.($Def.Source))) {
        $values = @(foreach ($c in $Def.Columns) {
            $p = $r.PSObject.Properties[$c]
            if ($p) { $p.Value } else { $null }
        })
        $keyVals = @(foreach ($k in $Def.Key) { $values[[array]::IndexOf($Def.Columns, $k)] })
        $key = Get-KeyString $keyVals
        if ($Def.ContainsKey('Sum') -and $grouped.Contains($key)) {
            $acc = $grouped[$key]
            for ($i = 0; $i -lt $Def.Columns.Count; $i++) {
                if ($Def.Sum -contains $Def.Columns[$i]) { $acc[$i] = [decimal]$acc[$i] + [decimal]$values[$i] }
            }
        } else {
            $grouped[$key] = $values
        }
    }
    $rows = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($k in $grouped.Keys) { $rows[$k] = (Format-Row $Def.Columns $grouped[$k]) }
    return , $rows
}

# ---------------------------------------------------------------------------
# Local state of the last successful sync (for change detection)
# ---------------------------------------------------------------------------
function Read-State {
    $state = @{ LastFullUtc = [datetime]::MinValue; Tables = @{} }
    foreach ($t in $Tables.Keys) { $state.Tables[$t] = New-Object 'System.Collections.Generic.Dictionary[string,string]' }
    $file = Join-Path $StateDir 'snapshot.tsv'
    $meta = Join-Path $StateDir 'meta.txt'
    if (Test-Path $meta) {
        $txt = ([System.IO.File]::ReadAllText($meta)).Trim()
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($txt, $Invariant, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $state.LastFullUtc = $parsed }
    }
    if (Test-Path $file) {
        $loaded = [InvSyncFast]::LoadSnapshot($file)
        foreach ($t in $Tables.Keys) { if ($loaded.ContainsKey($t)) { $state.Tables[$t] = $loaded[$t] } }
    }
    return $state
}

function Save-State($Current, [datetime]$LastFullUtc) {
    $file = Join-Path $StateDir 'snapshot.tsv'
    $tmp = "$file.tmp"
    $w = New-Object System.IO.StreamWriter($tmp, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        foreach ($t in $Current.Keys) { [InvSyncFast]::WriteSnapshot($w, $t, $Current[$t]) }
    } finally { $w.Close() }
    if (Test-Path $file) { Remove-Item $file -Force }
    Move-Item $tmp $file
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'meta.txt'), $LastFullUtc.ToString('o'))
}

function Get-KeyJson($Def, [string]$Key) {
    $vals = $Key.Split('|')
    $pairs = for ($i = 0; $i -lt $Def.Key.Count; $i++) { '"{0}":{1}' -f $Def.Key[$i], (ConvertTo-JsonString $vals[$i]) }
    return '{' + ($pairs -join ',') + '}'
}

# ---------------------------------------------------------------------------
# HTTPS to the Edge Function (TLS 1.2, retries with backoff on network/5xx)
# ---------------------------------------------------------------------------
function Invoke-Ingest($Config, [string]$Json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $delays = @(2, 5, 10)
    for ($attempt = 0; ; $attempt++) {
        Assert-Time 'upload'
        try {
            $req = [System.Net.HttpWebRequest]::Create($Config.IngestUrl)
            $req.Method = 'POST'
            $req.ContentType = 'application/json; charset=utf-8'
            $req.Headers.Add('x-sync-secret', $Config.SyncSecret)
            $req.UserAgent = "InventorySync/$AgentVersion"
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 30000
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return ($text | ConvertFrom-Json)
        } catch [System.Net.WebException] {
            # PowerShell may wrap it in a MethodInvocationException: unwrap to the WebException
            $ex = $_.Exception
            while ($ex -isnot [System.Net.WebException] -and $ex.InnerException) { $ex = $ex.InnerException }
            $status = 0; $body = ''
            if ($ex.Response) {
                $status = [int]$ex.Response.StatusCode
                try { $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Close() } catch { }
            }
            $retryable = ($status -eq 0 -or $status -ge 500 -or $status -eq 429)
            if (-not $retryable -or $attempt -ge $delays.Count) {
                throw ('Ingest failed (HTTP {0}): {1} {2}' -f $status, $ex.Message, $body)
            }
            Write-Log 'WARN' ('Network/server error (HTTP {0}), retry {1} in {2}s: {3}' -f $status, ($attempt + 1), $delays[$attempt], $ex.Message)
            Start-Sleep -Seconds $delays[$attempt]
        }
    }
}

function Join-JsonArray($Items) { return '[' + (@($Items) -join ',') + ']' }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
foreach ($d in @($LogDir, $StateDir, $OutDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

# One run at a time, across all Windows sessions: an exclusively opened lock file.
# (A Global\ mutex needs a privilege the non-admin inventory_sync account does not have.)
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $StateDir 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch [System.IO.IOException] {
    Write-Log 'INFO' 'Previous run still in progress - skipping.'; exit 2
}

$exitCode = 0
$runId = $null
$config = $null
try {
    Remove-OldLogs
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $batchSize = 500; if ($config.PSObject.Properties['BatchSize']) { $batchSize = [int]$config.BatchSize }
    $fullHours = 24;  if ($config.PSObject.Properties['FullSyncHours']) { $fullHours = [int]$config.FullSyncHours }
    $sqlTimeout = 60; if ($config.PSObject.Properties['SqlTimeoutSeconds']) { $sqlTimeout = [int]$config.SqlTimeoutSeconds }
    # never below 230 s: the first full read + upload on the old PC needs it (older configs said 110)
    if ($config.PSObject.Properties['MaxRunSeconds']) { $script:Deadline = [Math]::Max(230, [int]$config.MaxRunSeconds) }
    if (-not $DryRun) {
        if (-not $config.IngestUrl -or $config.IngestUrl -notmatch '^https://') { throw 'IngestUrl must be an https:// URL' }
        if (-not $config.SyncSecret -or $config.SyncSecret.Length -lt 16) { throw 'SyncSecret missing or too short' }
    }

    Write-Log 'INFO' ("InventorySync {0} start (dryRun={1}, source={2})" -f $AgentVersion, [bool]$DryRun, $(if ($SourceJson) { 'fixture' } else { 'sql' }))
    Import-FastCode

    # ---- read ----
    $current = [ordered]@{}
    if ($SourceJson) {
        $fixture = [System.IO.File]::ReadAllText($SourceJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($t in $Tables.Keys) { $current[$t] = Read-FixtureTable $fixture $t (Get-FullDef $Tables[$t]) }
    } else {
        if ($config.SqlUser -ne 'inventory_sync') { throw "Refusing to run: SqlUser must be 'inventory_sync' (read-only login)." }
        $auth = 'Sql'; if ($config.PSObject.Properties['SqlAuth'] -and $config.SqlAuth) { $auth = [string]$config.SqlAuth }
        Add-Type -AssemblyName System.Data
        $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $csb['Data Source'] = $(if ($config.SqlServer) { $config.SqlServer } else { '.' })
        $csb['Initial Catalog'] = $(if ($config.SqlDatabase) { $config.SqlDatabase } else { 'Spark' })
        if ($auth -eq 'Windows') {
            # SQL Server in "Windows Authentication mode": connect as the Windows account
            # this process runs as, and only ever as the dedicated read-only account.
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            if ($me.Name.Split('\')[-1] -ne $config.SqlUser) {
                throw ("Refusing to run as '{0}': this agent must run as the Windows account '{1}' (use the scheduled task: Start-ScheduledTask -TaskName InventorySync)." -f $me.Name, $config.SqlUser)
            }
            if ((New-Object System.Security.Principal.WindowsPrincipal($me)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw "Refusing to run: the '$($config.SqlUser)' account must not be an Administrator."
            }
            $csb['Integrated Security'] = $true
        } elseif ($auth -eq 'Sql') {
            $csb['User ID'] = $config.SqlUser
            $csb['Password'] = $config.SqlPassword
        } else { throw "Unknown SqlAuth '$auth' (expected Windows or Sql)." }
        $csb['Connect Timeout'] = 15
        $csb['Application Name'] = "InventorySync $AgentVersion (read-only)"
        $csb['ApplicationIntent'] = 'ReadOnly'
        $csb['Pooling'] = $false
        $conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
        try {
            $conn.Open()
            foreach ($t in $Tables.Keys) {
                Assert-Time "read $t"
                $current[$t] = Read-SqlTable $conn $t $Tables[$t] $sqlTimeout
            }
        } finally { $conn.Close(); $conn.Dispose() }
    }
    $rowsRead = [ordered]@{}
    foreach ($t in $current.Keys) { $rowsRead[$t] = $current[$t].Count }
    Write-Log 'INFO' ('Read ' + (($rowsRead.Keys | ForEach-Object { "$_=$($rowsRead[$_])" }) -join ' ') + (' in {0:N1}s' -f $Clock.Elapsed.TotalSeconds))
    if ($rowsRead['products'] -eq 0) { throw 'ITEMES returned 0 rows - refusing to sync an empty catalogue.' }

    # ---- diff ----
    $state = Read-State
    $isFull = [bool]$Full -or ($state.LastFullUtc -lt [datetime]::UtcNow.AddHours(-$fullHours))
    $changes = [ordered]@{}
    foreach ($t in $Tables.Keys) {
        $old = $state.Tables[$t]
        $upserts = [InvSyncFast]::Upserts($current[$t], $old, $isFull)
        $deletes = New-Object System.Collections.Generic.List[string]
        if (-not $isFull) {
            foreach ($k in [InvSyncFast]::DeletedKeys($current[$t], $old)) { $deletes.Add((Get-KeyJson $Tables[$t] $k)) }
        }
        $changes[$t] = @{ Upserts = $upserts; Deletes = $deletes }
    }
    $summary = ($changes.Keys | ForEach-Object { '{0}: +{1} -{2}' -f $_, $changes[$_].Upserts.Count, $changes[$_].Deletes.Count }) -join ', '
    Write-Log 'INFO' ("Mode={0}; changes: {1}" -f $(if ($isFull) { 'FULL' } else { 'incremental' }), $summary)

    $rowsReadJson = '{' + (($rowsRead.Keys | ForEach-Object { '"{0}":{1}' -f $_, $rowsRead[$_] }) -join ',') + '}'

    # ---- dry run: write to file, send nothing ----
    if ($DryRun) {
        $file = Join-Path $OutDir ('dryrun-{0}.json' -f [datetime]::Now.ToString('yyyyMMdd-HHmmss', $Invariant))
        $w = New-Object System.IO.StreamWriter($file, $false, (New-Object System.Text.UTF8Encoding($false)))
        try {
            $w.Write('{"agent_version":' + (ConvertTo-JsonString $AgentVersion) + ',"generated_at":' + (ConvertTo-JsonString ([datetime]::UtcNow.ToString('o'))) +
                ',"full":' + $(if ($isFull) { 'true' } else { 'false' }) + ',"rows_read":' + $rowsReadJson + ',"tables":{')
            $first = $true
            foreach ($t in $changes.Keys) {
                if (-not $first) { $w.Write(',') }; $first = $false
                $w.Write((ConvertTo-JsonString $t) + ':{"source":' + (ConvertTo-JsonString $Tables[$t].Source) + ',"rows":' + (Join-JsonArray $changes[$t].Upserts) + ',"deletes":' + (Join-JsonArray $changes[$t].Deletes) + '}')
            }
            $w.Write('}}')
        } finally { $w.Close() }
        Write-Log 'INFO' "Dry run written to $file (nothing sent, state unchanged)."
    } else {
        # ---- send ----
        $start = Invoke-Ingest $config ('{"action":"start","agent_version":' + (ConvertTo-JsonString $AgentVersion) + ',"host":' +
            (ConvertTo-JsonString $env:COMPUTERNAME) + ',"full":' + $(if ($isFull) { 'true' } else { 'false' }) + ',"rows_read":' + $rowsReadJson + '}')
        $runId = [long]$start.run_id
        foreach ($t in $changes.Keys) {
            $up = $changes[$t].Upserts; $del = $changes[$t].Deletes
            for ($i = 0; $i -lt [Math]::Max($up.Count, 1); $i += $batchSize) {
                $chunk = @(); if ($up.Count -gt 0) { $chunk = $up.GetRange($i, [Math]::Min($batchSize, $up.Count - $i)) }
                $delJson = '[]'; if ($i -eq 0 -and $del.Count -gt 0) { $delJson = Join-JsonArray $del }
                if ($chunk.Count -eq 0 -and $delJson -eq '[]') { continue }
                $body = '{"action":"batch","run_id":' + $runId + ',"table":"' + $t + '","rows":' + (Join-JsonArray $chunk) + ',"deletes":' + $delJson + '}'
                $res = Invoke-Ingest $config $body
                Write-Log 'INFO' ('{0} batch {1}: upserted={2} deleted={3} skipped_empty={4}' -f $t, ($i / $batchSize + 1), $res.upserted, $res.deleted, $res.skipped_empty)
            }
        }
        $fin = Invoke-Ingest $config ('{"action":"finish","run_id":' + $runId + ',"status":"ok","rows_read":' + $rowsReadJson + ',"duration_ms":' + [int]$Clock.Elapsed.TotalMilliseconds + '}')
        $lastFull = $state.LastFullUtc; if ($isFull) { $lastFull = [datetime]::UtcNow }
        Save-State $current $lastFull
        $purge = ''; if ($fin.purge) { $purge = ' purge=' + ($fin.purge | ConvertTo-Json -Compress) }
        Write-Log 'INFO' ('Run {0} OK in {1:N1}s.{2}' -f $runId, $Clock.Elapsed.TotalSeconds, $purge)
    }
} catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    if ($config -and $config.PSObject.Properties['SqlPassword'] -and $config.SqlPassword) { $msg = $msg.Replace([string]$config.SqlPassword, '***') }
    Write-Log 'ERROR' $msg
    if (-not $DryRun -and $config -and $config.IngestUrl -and $config.SyncSecret) {
        try {
            $script:Deadline += 15  # allow the error report itself
            if (-not $runId) {
                # failed before upload started (e.g. SQL Server unreachable): still record it
                $runId = [long](Invoke-Ingest $config ('{"action":"start","agent_version":' + (ConvertTo-JsonString $AgentVersion) + ',"host":' + (ConvertTo-JsonString $env:COMPUTERNAME) + '}')).run_id
            }
            [void](Invoke-Ingest $config ('{"action":"finish","run_id":' + $runId + ',"status":"error","error":' + (ConvertTo-JsonString $msg) + ',"duration_ms":' + [int]$Clock.Elapsed.TotalMilliseconds + '}'))
        } catch { Write-Log 'ERROR' ('Could not report the error: ' + $_.Exception.Message) }
    }
} finally {
    if ($lock) { $lock.Dispose() }
}
exit $exitCode
