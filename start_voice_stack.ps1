param(
  [string]$AppDir = "C:\Users\Thapelo\Downloads\square_15-master\square_15-master",
  [string]$RepoRoot = "C:\Users\Thapelo\Downloads\square_15-master",
  [int]$DispatchPort = 3001
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) {
  Write-Host $msg
}

function Stop-ListeningPort([int]$port) {
  $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $conn) {
    try {
      Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
      Write-Info "Stopped process PID $($conn.OwningProcess) listening on port $port"
    } catch {
      Write-Info ("Could not stop PID {0} on port {1}. Error: {2}" -f $conn.OwningProcess, $port, $_.Exception.Message)
    }
  }
}

function Stop-WorkerProcs() {
  Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like "*voice_agent_worker.py*" } |
    ForEach-Object {
      try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Info "Stopped old worker PID $($_.ProcessId)"
      } catch {
        Write-Info "Could not stop worker PID $($_.ProcessId): $($_.Exception.Message)"
      }
    }
}

# Paths
$dispatchOut = Join-Path $AppDir "scripts\dispatch_server.out.log"
$dispatchErr = Join-Path $AppDir "scripts\dispatch_server.err.log"
$workerOut = Join-Path $AppDir "scripts\voice_agent_worker.out.log"
$workerErr = Join-Path $AppDir "scripts\voice_agent_worker.err.log"
$venvPy = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$workerScript = Join-Path $AppDir "scripts\voice_agent_worker.py"

if (!(Test-Path $AppDir)) { throw "AppDir not found: $AppDir" }
if (!(Test-Path $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
if (!(Test-Path $venvPy)) { throw "Venv python not found: $venvPy" }
if (!(Test-Path $workerScript)) { throw "Worker script not found: $workerScript" }

Write-Info "=== Starting Square15 Voice Stack ==="
Write-Info "AppDir: $AppDir"
Write-Info "RepoRoot: $RepoRoot"
Write-Info "DispatchPort: $DispatchPort"

# Kill old instances
Stop-ListeningPort -port $DispatchPort
Stop-WorkerProcs

# Ensure Node deps exist (scripts/package.json lives in AppDir\scripts)
$nodeModules = Join-Path $AppDir "scripts\node_modules"
if (!(Test-Path $nodeModules)) {
  Write-Info "Installing Node dependencies (first time)..."
  Push-Location (Join-Path $AppDir "scripts")
  npm install
  Pop-Location
}

# Clear logs
foreach ($p in @($dispatchOut,$dispatchErr,$workerOut,$workerErr)) {
  if (Test-Path $p) { Remove-Item $p -Force }
}

# Start dispatch server
Write-Info "Starting dispatch server on port $DispatchPort..."
Start-Process -FilePath "node" -WorkingDirectory $AppDir -ArgumentList ".\scripts\dispatch_server.js" -RedirectStandardOutput $dispatchOut -RedirectStandardError $dispatchErr -NoNewWindow | Out-Null
Start-Sleep -Seconds 1

# Smoke test dispatch health
try {
  $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $DispatchPort) -Method GET
  Write-Info ("Dispatch /health OK (agentName={0})" -f $health.agentName)
} catch {
  Write-Info "WARNING: Dispatch /health failed. Check logs:"
  if (Test-Path $dispatchErr) { Get-Content $dispatchErr | Select-Object -Last 60 }
}

# Start python worker (IMPORTANT: requires 'start' subcommand)
Write-Info "Starting python worker (explicit dispatch)..."
Start-Process -FilePath $venvPy -WorkingDirectory $AppDir -ArgumentList @($workerScript, "start") -RedirectStandardOutput $workerOut -RedirectStandardError $workerErr -NoNewWindow | Out-Null
Start-Sleep -Seconds 2

Write-Info "--- Worker log tail ---"
if (Test-Path $workerErr) { Get-Content $workerErr | Select-Object -Last 80 }

Write-Info "--- Dispatch log tail ---"
if (Test-Path $dispatchErr) { Get-Content $dispatchErr | Select-Object -Last 80 }

Write-Info "Done. If the app says Dispatch Failed, check these logs:"
Write-Info "- $dispatchErr"
Write-Info "- $workerErr"
