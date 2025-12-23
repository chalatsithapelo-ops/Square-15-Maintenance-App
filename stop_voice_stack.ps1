param(
  [string]$AppDir = "C:\Users\Thapelo\Downloads\square_15-master\square_15-master",
  [int]$DispatchPort = 3001
)

$ErrorActionPreference = "SilentlyContinue"

function Stop-ListeningPort([int]$port) {
  $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $conn) {
    Stop-Process -Id $conn.OwningProcess -Force
    Write-Host "Stopped process PID $($conn.OwningProcess) listening on port $port"
  } else {
    Write-Host "No process is listening on port $port"
  }
}

function Stop-WorkerProcs() {
  $workers = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*voice_agent_worker.py*" }
  if ($null -eq $workers -or $workers.Count -eq 0) {
    Write-Host "No worker processes found"
    return
  }

  foreach ($w in $workers) {
    Stop-Process -Id $w.ProcessId -Force
    Write-Host "Stopped worker PID $($w.ProcessId)"
  }
}

Write-Host "=== Stopping Square15 Voice Stack ==="
Stop-ListeningPort -port $DispatchPort
Stop-WorkerProcs

Write-Host "Done"
