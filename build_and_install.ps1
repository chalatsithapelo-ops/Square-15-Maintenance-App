param(
  [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
  Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Kill-Lockers {
  Write-Step "Stopping build-related processes (java/gradle/cmake/ninja)"
  Get-Process java, gradle, cmake, ninja -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Remove-NativeCaches($projectRoot) {
  Write-Step "Removing native build caches (.cxx / intermediates\\cxx)"
  $paths = @(
    Join-Path $projectRoot 'build\\.cxx',
    Join-Path $projectRoot 'build\\app\\intermediates\\cxx',
    Join-Path $projectRoot 'build\\agora_rtc_engine\\intermediates\\cxx',
    Join-Path $projectRoot 'build\\iris_method_channel\\intermediates\\cxx'
  )

  foreach ($p in $paths) {
    if (Test-Path $p) {
      try { Remove-Item -Recurse -Force $p -ErrorAction Stop } catch { }
    }
  }
}

$projectRoot = Split-Path -Parent $PSCommandPath  # ...\scripts
$projectRoot = Split-Path -Parent $projectRoot    # ...\square_15-master

Write-Step "Project root: $projectRoot"
Set-Location $projectRoot

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  Write-Step "Attempt $attempt of $MaxAttempts"

  try {
    Kill-Lockers
    Remove-NativeCaches -projectRoot $projectRoot

    Write-Step "flutter clean"
    flutter clean

    Write-Step "flutter pub get"
    flutter pub get

    Write-Step "flutter build apk"
    flutter build apk

    Write-Step "flutter install"
    flutter install

    Write-Host "`n[OK] Build + install completed successfully." -ForegroundColor Green
    exit 0
  }
  catch {
    Write-Host "`n[WARN] Attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow

    # Common: Windows file-lock during native build.
    # Retry after killing lock holders and clearing caches again.
    Kill-Lockers
    Remove-NativeCaches -projectRoot $projectRoot

    if ($attempt -lt $MaxAttempts) {
      Write-Host "Retrying in 3 seconds..." -ForegroundColor Yellow
      Start-Sleep -Seconds 3
    } else {
      Write-Host "`n[FAIL] All attempts failed." -ForegroundColor Red
      throw
    }
  }
}
