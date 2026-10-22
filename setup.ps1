<#
.SYNOPSIS
    One-command setup on Windows: build the HospitalOps database, run all tests,
    and prepare (optionally launch) the dashboard.

.DESCRIPTION
    1. Checks prerequisites: SQL Server reachable with Windows authentication; Python 3.10+.
    2. Builds the database from scratch (sql/01..09, ~1.4M rows) and runs all 107 tests.
    3. Optionally re-runs the before/after index benchmark (-Benchmark).
    4. Creates dashboard\.venv, installs pinned requirements, runs the dashboard smoke test.
    5. Optionally starts the dashboard at http://localhost:8501 (-Launch).

    Re-runnable: the build recreates all tables, and existing venvs are reused.
    No SQL Server on Windows? Use Docker instead:  docker compose up

.EXAMPLE
    .\setup.ps1                       # build + test + dashboard check
    .\setup.ps1 -Launch               # ...and open the dashboard
    .\setup.ps1 -Server .\SQLEXPRESS  # named instance
    .\setup.ps1 -SkipDashboard        # database only
#>
[CmdletBinding()]
param(
    [string] $Server = 'localhost',
    [switch] $SkipTests,
    [switch] $SkipDashboard,
    [switch] $Benchmark,
    [switch] $Launch
)

$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$total = [Diagnostics.Stopwatch]::StartNew()

function Step([string] $text) { Write-Host "`n=== $text" -ForegroundColor Cyan }
function Fail([string] $text) { Write-Host "`nSETUP FAILED: $text" -ForegroundColor Red; exit 1 }

# --- 1. Prerequisites --------------------------------------------------------------
Step "Checking prerequisites"
try {
    $c = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=true;TrustServerCertificate=true;Connect Timeout=10"
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(20)) + ' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(60))"
    Write-Host "  SQL Server: $($cmd.ExecuteScalar()) on '$Server'"
    $c.Close()
} catch {
    Fail "Can't connect to SQL Server '$Server' with Windows authentication.`n  Install SQL Server 2019+ Developer/Express, pass -Server for a named instance, or use 'docker compose up'.`n  ($($_.Exception.Message))"
}

$python = $null
if (-not $SkipDashboard) {
    foreach ($candidate in @('py -3', 'python')) {
        try {
            $ver = Invoke-Expression "$candidate -c `"import sys; print('%d.%d' % sys.version_info[:2])`"" 2>$null
            if ($ver -and [version]$ver -ge [version]'3.10') { $python = $candidate; break }
        } catch { }
    }
    if (-not $python) { Fail "Python 3.10+ not found (needed for the dashboard). Install it, or rerun with -SkipDashboard." }
    Write-Host "  Python: $ver ($python)"
}

# --- 2. Database build + tests -------------------------------------------------------
Step ($(if ($SkipTests) { "Building database" } else { "Building database and running tests" }))
$sw = [Diagnostics.Stopwatch]::StartNew()
$runArgs = @{ Server = $Server }
if (-not $SkipTests) { $runArgs.Test = $true }
& (Join-Path $root 'run_sql.ps1') @runArgs | Out-Host
if ($LASTEXITCODE -ne 0) { Fail "database build or tests failed (see output above)." }
Write-Host ("  Done in {0:N0} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green

# --- 3. Benchmark (optional) -----------------------------------------------------------
if ($Benchmark) {
    Step "Running before/after index benchmark"
    & (Join-Path $root 'performance\run_benchmark.ps1') -Server $Server | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "benchmark failed." }
}

# --- 4. Dashboard --------------------------------------------------------------------------
if (-not $SkipDashboard) {
    Step "Preparing dashboard"
    $dash = Join-Path $root 'dashboard'
    $venvPy = Join-Path $dash '.venv\Scripts\python.exe'
    if (-not (Test-Path $venvPy)) {
        Write-Host "  Creating virtual environment"
        Invoke-Expression "$python -m venv `"$dash\.venv`""
    }
    Write-Host "  Installing requirements"
    & $venvPy -m pip install --quiet --disable-pip-version-check -r (Join-Path $dash 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { Fail "pip install failed." }

    $env:HOSPITALOPS_SERVER = $Server
    Push-Location $dash
    try {
        & $venvPy smoke_test.py | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "dashboard smoke test failed." }
    } finally { Pop-Location }
}

Write-Host ("`nSetup complete in {0:N0} s." -f $total.Elapsed.TotalSeconds) -ForegroundColor Green

if ($Launch -and -not $SkipDashboard) {
    Step "Starting dashboard at http://localhost:8501 (Ctrl+C to stop)"
    Push-Location (Join-Path $root 'dashboard')
    try { & (Join-Path $root 'dashboard\.venv\Scripts\streamlit.exe') run app.py }
    finally { Pop-Location }
} elseif (-not $SkipDashboard) {
    Write-Host "Start the dashboard:  cd dashboard; .venv\Scripts\streamlit run app.py"
}
