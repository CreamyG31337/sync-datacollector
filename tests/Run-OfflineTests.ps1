# Offline tests for the Trimble Connect target. Nothing goes to Trimble: the API and the
# token endpoint are faked inside each test.
#
# Each test runs against a COPY of SyncDataCollector.ps1 in a temp folder, because the app
# writes sync-state.json and its log next to itself - running the tests must never touch a
# real install's state.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-OfflineTests.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $env:TEMP ('sdc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$failed = 0
try {
    Copy-Item (Join-Path $repo 'SyncDataCollector.ps1') $work
    foreach ($t in Get-ChildItem (Join-Path $repo 'tests') -Filter 'Test-*.ps1') {
        Copy-Item $t.FullName $work
        Write-Host "== $($t.Name)"
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work $t.Name) 2>&1
        $out | ForEach-Object { Write-Host "   $_" }
        if (-not ($out -match '^PASS')) { $failed++ }
    }
}
finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
if ($failed) { Write-Host "$failed test(s) FAILED"; exit 1 } else { Write-Host 'All offline tests passed.' }
