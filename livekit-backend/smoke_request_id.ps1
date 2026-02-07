param(
  [Parameter(Mandatory=$false)]
  [string]$BackendUrl = "https://square15-livekit-backend.onrender.com",

  [Parameter(Mandatory=$false)]
  [string]$ExpectedGitCommit = "6198eae",

  [Parameter(Mandatory=$false)]
  [switch]$IdTokenFromClipboard,

  [Parameter(Mandatory=$false)]
  [string]$IdToken,

  [Parameter(Mandatory=$false)]
  [switch]$SkipAction,

  [Parameter(Mandatory=$false)]
  [int]$HealthAttempts = 30,

  [Parameter(Mandatory=$false)]
  [int]$HealthDelaySeconds = 4
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-CurlPath() {
  $p = Join-Path $env:SystemRoot 'System32\curl.exe'
  if(Test-Path -LiteralPath $p) { return $p }
  $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
  if($cmd -and $cmd.Source) { return $cmd.Source }
  throw 'curl.exe not found on PATH'
}

function Normalize-BackendUrl([string]$u) {
  $s = ($(if($null -eq $u){ "" } else { $u })).Trim()
  if([string]::IsNullOrWhiteSpace($s)) { throw "BackendUrl is required" }
  return $s.TrimEnd('/')
}

function Get-IdToken([switch]$FromClipboard, [string]$Token) {
  $t = $Token
  if($FromClipboard) {
    $t = Get-Clipboard -Raw
  }
  $t = ($(if($null -eq $t){ "" } else { $t })).Trim()

  while(($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) {
    $t = $t.Substring(1, $t.Length - 2).Trim()
  }

  if($t -match 'Bearer\s+(eyJ[A-Za-z0-9-_]{10,}\.[A-Za-z0-9-_]{10,}\.[A-Za-z0-9-_]{10,})') {
    $t = $Matches[1]
  } elseif($t -match '(eyJ[A-Za-z0-9-_]{10,}\.[A-Za-z0-9-_]{10,}\.[A-Za-z0-9-_]{10,})') {
    $t = $Matches[1]
  } else {
    $t = ($t -replace '^Bearer\s+','').Trim()
    $t = ($t -replace '\s','')
  }

  if([string]::IsNullOrWhiteSpace($t)) {
    throw "Firebase ID token is empty. Provide -IdToken or use -IdTokenFromClipboard."
  }
  if($t -notmatch '^[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+$') {
    throw "Token does not look like a JWT (expected 3 dot-separated segments)."
  }
  return $t
}

function Invoke-CurlJsonWithHeaders {
  param(
    [Parameter(Mandatory=$true)][string]$Method,
    [Parameter(Mandatory=$true)][string]$Url,
    [hashtable]$Headers,
    [string]$BodyJson,
    [string]$OutgoingRequestId
  )

  $curl = Get-CurlPath
  $m = $Method.ToUpperInvariant()

  $headerArgs = @('-sS')
  if($Headers) {
    foreach($k in $Headers.Keys) {
      $v = [string]$Headers[$k]
      $headerArgs += @('-H', ("{0}: {1}" -f $k, $v))
    }
  }
  if($OutgoingRequestId) {
    $headerArgs += @('-H', ("x-request-id: {0}" -f $OutgoingRequestId))
  }

  $dataArgs = @()
  $reqBodyFile = $null
  if($BodyJson) {
    $reqBodyFile = Join-Path $env:TEMP ("curl_body_{0}.json" -f ([guid]::NewGuid().ToString()))
    Set-Content -LiteralPath $reqBodyFile -Value $BodyJson -Encoding Ascii
    $dataArgs = @('-H','Content-Type: application/json','--data', ("@{0}" -f $reqBodyFile))
  }

  $respHeaderFile = Join-Path $env:TEMP ("curl_headers_{0}.txt" -f ([guid]::NewGuid().ToString()))
  $respBodyFile = Join-Path $env:TEMP ("curl_resp_{0}.txt" -f ([guid]::NewGuid().ToString()))

  try {
    $statusMarker = & $curl -X $m $Url @headerArgs @dataArgs -D $respHeaderFile -o $respBodyFile -w "HTTPSTATUS:%{http_code}"
    if($LASTEXITCODE -ne 0) {
      throw "curl.exe failed with exit code $LASTEXITCODE"
    }

    $status = $null
    if($statusMarker -match 'HTTPSTATUS:(\d{3})') { $status = [int]$Matches[1] }

    $headerText = ''
    if(Test-Path -LiteralPath $respHeaderFile) {
      $headerText = Get-Content -LiteralPath $respHeaderFile -Raw -ErrorAction SilentlyContinue
    }
    $bodyText = ''
    if(Test-Path -LiteralPath $respBodyFile) {
      $bodyText = Get-Content -LiteralPath $respBodyFile -Raw -ErrorAction SilentlyContinue
    }

    $respReqId = $null
    $headerLines = $headerText -split "\r?\n"
    foreach($line in $headerLines) {
      if($line -match '^x-request-id:\s*(.+)\s*$') {
        $respReqId = $Matches[1].Trim()
      }
    }

    $json = $null
    $trimBody = ($bodyText | Out-String).Trim()
    if(-not [string]::IsNullOrWhiteSpace($trimBody)) {
      try { $json = $trimBody | ConvertFrom-Json } catch { $json = $null }
    }

    return [pscustomobject]@{
      status = $status
      headers = $headerText
      bodyText = $trimBody
      json = $json
      responseRequestId = $respReqId
    }
  } finally {
    if($reqBodyFile -and (Test-Path -LiteralPath $reqBodyFile)) { Remove-Item -LiteralPath $reqBodyFile -ErrorAction SilentlyContinue }
    if($respHeaderFile -and (Test-Path -LiteralPath $respHeaderFile)) { Remove-Item -LiteralPath $respHeaderFile -ErrorAction SilentlyContinue }
    if($respBodyFile -and (Test-Path -LiteralPath $respBodyFile)) { Remove-Item -LiteralPath $respBodyFile -ErrorAction SilentlyContinue }
  }
}

$BackendUrl = Normalize-BackendUrl $BackendUrl
Write-Host ("BackendUrl: {0}" -f $BackendUrl)

# 1) Wait for deployment signal
$ExpectedGitCommit = ($(if($null -eq $ExpectedGitCommit){ "" } else { $ExpectedGitCommit })).Trim()
$waitMsg = $(if([string]::IsNullOrWhiteSpace($ExpectedGitCommit)) { "Waiting for /health to include request_id / x-request-id..." } else { "Waiting for /health to include request_id / x-request-id AND gitCommit starting with '{0}'..." -f $ExpectedGitCommit })
Write-Host $waitMsg
$healthResp = $null
$ready = $false
for($i=1; $i -le $HealthAttempts; $i++) {
  try {
    $outgoing = "smoke-health-{0}" -f ([guid]::NewGuid().ToString('N'))
    $healthResp = Invoke-CurlJsonWithHeaders -Method Get -Url ($BackendUrl + '/health') -Headers @{} -BodyJson $null -OutgoingRequestId $outgoing

    $gitCommit = $null
    if($healthResp.json -and $healthResp.json.deploy -and $healthResp.json.deploy.render) {
      $gitCommit = [string]$healthResp.json.deploy.render.gitCommit
    }

    $ridBody = if($healthResp.json -and $healthResp.json.request_id) { [string]$healthResp.json.request_id } else { '' }
    $ridHdr  = if($healthResp.responseRequestId) { [string]$healthResp.responseRequestId } else { '' }

    $hasRid = (-not [string]::IsNullOrWhiteSpace($ridHdr)) -or (-not [string]::IsNullOrWhiteSpace($ridBody))
    $commitOk = $true
    if(-not [string]::IsNullOrWhiteSpace($ExpectedGitCommit)) {
      $commitOk = ($gitCommit -and $gitCommit.StartsWith($ExpectedGitCommit))
    }

    $gitCommitLabel = $(if($gitCommit) { $gitCommit } else { 'null' })
    $ridHdrLabel = $(if($ridHdr) { $ridHdr } else { '' })
    $ridBodyLabel = $(if($ridBody) { $ridBody } else { '' })
    Write-Host ("Health attempt {0}/{1}: status={2} gitCommit={3} headerRid={4} bodyRid={5}" -f $i, $HealthAttempts, $healthResp.status, $gitCommitLabel, $ridHdrLabel, $ridBodyLabel)

    if($hasRid -and $commitOk) {
      $ready = $true
      break
    }
  } catch {
    Write-Host ("Health attempt {0}/{1} failed: {2}" -f $i, $HealthAttempts, $_.Exception.Message)
  }
  Start-Sleep -Seconds $HealthDelaySeconds
}

if(-not $ready) {
  throw "Backend not ready yet (request_id not observed{0}). Deploy in Render, then re-run." -f $(if([string]::IsNullOrWhiteSpace($ExpectedGitCommit)) { '' } else { ", or gitCommit didn't match '$ExpectedGitCommit'" })
}

Write-Host "Backend ready: request_id observed on /health"

# 2) Verify action endpoint request id behavior
if($SkipAction) {
  Write-Host "Skipping /api/action/execute test (-SkipAction)"
  exit 0
}

$token = $null
try {
  $token = Get-IdToken -FromClipboard:$IdTokenFromClipboard -Token $IdToken
} catch {
  Write-Host "Skipping /api/action/execute test (no valid Firebase ID token found)."
  Write-Host "Copy a Firebase ID token to clipboard and re-run with -IdTokenFromClipboard." 
  exit 0
}
$outgoingExecRid = "smoke-exec-{0}" -f ([guid]::NewGuid().ToString('N'))

$bodyObj = @{
  action = 'create_order_booking'
  payload = @{
    is_rfq_requested = $true
    category_name = 'General'
    problem_description = 'Smoke test: request id tracing'
  }
  context = @{
    session_id = 'ps-smoke'
    room_name  = 'ps-smoke'
  }
}

$bodyJson = $bodyObj | ConvertTo-Json -Depth 12 -Compress
$headers = @{ Authorization = "Bearer $token"; Prefer = 'respond-async'; 'Idempotency-Key' = ("idem-smoke-{0}" -f ([guid]::NewGuid().ToString())) }

$exec = Invoke-CurlJsonWithHeaders -Method Post -Url ($BackendUrl + '/api/action/execute') -Headers $headers -BodyJson $bodyJson -OutgoingRequestId $outgoingExecRid

Write-Host ("Execute status: {0}" -f $exec.status)
$execHdrRidLabel = $(if($exec.responseRequestId) { [string]$exec.responseRequestId } else { '' })
Write-Host ("Execute x-request-id header: {0}" -f $execHdrRidLabel)
if($exec.json -and $exec.json.request_id) {
  Write-Host ("Execute request_id body: {0}" -f $exec.json.request_id)
}

if($exec.responseRequestId -ne $outgoingExecRid) {
  $incoming = $(if($exec.responseRequestId) { [string]$exec.responseRequestId } else { '' })
  Write-Host ("WARNING: response x-request-id did not echo outgoing value. outgoing={0} incoming={1}" -f $outgoingExecRid, $incoming)
}

if(-not ($exec.json -and $exec.json.poll)) {
  throw "Expected async response with poll URL. Body: $($exec.bodyText)"
}

Write-Host ("Poll URL: {0}" -f $exec.json.poll)
Write-Host "OK: request_id smoke test complete"
