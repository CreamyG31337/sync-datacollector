# Offline test: an idle browser pre-connection must not abort the localhost sign-in.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:SDC_NOGUI = '1'
. (Join-Path $here 'SyncDataCollector.ps1')

$urlFile = Join-Path $here 'auth_url.txt'
Remove-Item $urlFile -ErrorAction SilentlyContinue
$env:SDC_AUTH_URL_FILE = $urlFile
$port = 8799

# No network: fake the token endpoint, and keep tokens out of %LOCALAPPDATA%.
function Invoke-RestMethod { param($Uri, $Method, $ContentType, $Headers, $Body)
    if ($Body.code -ne 'abc123') { throw "wrong code '$($Body.code)'" }
    [pscustomobject]@{ access_token = 'AT'; refresh_token = 'RT'; expires_in = 3600 } }
function Write-ConnectTokenCache { param($ClientId, $Record) }

# Fake browser: idle speculative connection first, then the real callback.
$client = Start-Job -ArgumentList $urlFile, $port -ScriptBlock { param($urlFile, $port)
    while (-not (Test-Path $urlFile)) { Start-Sleep -Milliseconds 100 }
    $url = Get-Content $urlFile -Raw
    $state = [regex]::Match($url, 'state=([^&]+)').Groups[1].Value
    $idle = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)   # sends nothing
    Start-Sleep -Milliseconds 300
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
    $s = $c.GetStream()
    $req = [Text.Encoding]::ASCII.GetBytes("GET /callback?code=abc123&state=$state HTTP/1.1`r`nHost: localhost`r`n`r`n")
    $s.Write($req, 0, $req.Length)
    $resp = (New-Object IO.StreamReader($s)).ReadToEnd()
    $c.Close(); Start-Sleep -Seconds 7; $idle.Close()
    if ($resp -match 'Signed in') { 'browser saw: Signed in page' } else { "browser saw: $resp" }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $rec = Invoke-ConnectInteractiveAuth -ClientId 'test' -Scope 'openid' -RedirectPort $port -OnLog $null
    "sign-in returned access_token=$($rec.access_token) after $([int]$sw.Elapsed.TotalSeconds) s"
    $ok = ($rec.access_token -eq 'AT')
}
catch { "sign-in FAILED: $($_.Exception.Message)"; $ok = $false }
Receive-Job $client -Wait -AutoRemoveJob
if ($ok) { 'PASS: idle pre-connection did not break sign-in' } else { 'FAIL' }
