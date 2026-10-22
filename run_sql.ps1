<#
.SYNOPSIS
    Builds the HospitalOps database by running the numbered scripts in sql/, and optionally the tests.

.DESCRIPTION
    Splits each .sql file on GO batch separators (like sqlcmd/SSMS) and runs the
    batches in order over one connection. PRINT messages are echoed. Stops at the
    first error and exits with code 1.

    Uses the .NET SqlClient built into Windows PowerShell, so it needs no sqlcmd
    or ODBC driver.

    sqlcmd-style variables such as $(DataDir) are substituted before execution.
    DataDir defaults to the repo's data folder; pass -Variables to override or add.

.EXAMPLE
    .\run_sql.ps1                       # build (sql/*.sql)
    .\run_sql.ps1 -Test                 # build, then run tests/*.sql
    .\run_sql.ps1 -Server ".\SQLEXPRESS"
    .\run_sql.ps1 -Files tests\test_constraints.sql
#>
[CmdletBinding()]
param(
    [string]   $Server = 'localhost',
    [string[]] $Files,
    [switch]   $Test,
    [hashtable]$Variables = @{}
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Variables.ContainsKey('DataDir')) { $Variables['DataDir'] = Join-Path $root 'data' }

if (-not $Files) {
    $Files = @(Get-ChildItem (Join-Path $root 'sql') -Filter '*.sql' | Sort-Object Name | ForEach-Object FullName)
    if ($Test) {
        $Files += @(Get-ChildItem (Join-Path $root 'tests') -Filter '*.sql' | Sort-Object Name | ForEach-Object FullName)
    }
}

$conn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=true;TrustServerCertificate=true"
$conn.FireInfoMessageEventOnUserErrors = $false
$conn.add_InfoMessage({
    param($s, $e)
    foreach ($m in $e.Errors) {
        # Skip SQL Server's routine status chatter; keep PRINT output and warnings.
        if ($m.Message -match '^(Changed database context|Nonqualified transactions)') { continue }
        Write-Host "    $($m.Message)"
    }
})
$conn.Open()

$failed = $false
try {
    foreach ($file in $Files) {
        $path = (Resolve-Path $file).Path
        Write-Host "==> $(Split-Path $path -Leaf)" -ForegroundColor Cyan
        $text = [System.IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '\$\((\w+)\)', {
            param($m)
            $name = $m.Groups[1].Value
            if (-not $Variables.ContainsKey($name)) { throw "Script variable `$($name) is not defined. Pass -Variables @{ $name = '...' }." }
            $Variables[$name]
        })
        # A batch separator is a line containing only GO (case-insensitive).
        $batches = [regex]::Split($text, '(?im)^\s*GO\s*;?\s*$') | Where-Object { $_.Trim() }
        $n = 0
        foreach ($batch in $batches) {
            $n++
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = 0
            try {
                $reader = $cmd.ExecuteReader()
                while (-not $reader.IsClosed) {
                    if ($reader.FieldCount -gt 0) {
                        # DataTable.Load consumes this result set and advances to the next one itself.
                        $table = New-Object System.Data.DataTable
                        $table.Load($reader)
                        $table | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
                    }
                    elseif (-not $reader.NextResult()) { $reader.Close() }
                }
            }
            catch {
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                Write-Host "    ERROR in batch $n of $(Split-Path $path -Leaf): $($inner.Message)" -ForegroundColor Red
                throw
            }
        }
    }
    Write-Host "Done: $($Files.Count) file(s) ran successfully." -ForegroundColor Green
}
catch {
    $failed = $true
}
finally {
    $conn.Close()
}
if ($failed) { exit 1 }
