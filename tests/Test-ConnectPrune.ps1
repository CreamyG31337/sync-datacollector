# Offline test: Connect prune deletes only design file types, never folders.
# Runs against a COPY of SyncDataCollector.ps1 in this folder (state/log files land here).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:SDC_NOGUI = '1'
. (Join-Path $here 'SyncDataCollector.ps1')

# --- source: the office design folder (only a.csv now) ---
$src = Join-Path $here 'src'
Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $src | Out-Null
Set-Content -LiteralPath (Join-Path $src 'a.csv') -Value 'pt,1,2,3' -Encoding ascii
$aLen = (Get-Item (Join-Path $src 'a.csv')).Length

# --- fake Trimble Connect project ---
$script:Deleted = New-Object System.Collections.ArrayList
$script:Uploaded = New-Object System.Collections.ArrayList
function mk($rel, $len, $id) { @{ Rel = $rel; Length = [long]$len; MtimeUtc = [datetime]::UtcNow.AddDays(1); Ext = [IO.Path]::GetExtension($rel).ToLower();
                               Item = [pscustomobject]@{ id = $id; name = (Split-Path $rel -Leaf); type = 'FILE'; parentId = 'p' } } }
function Get-ConnectAccessToken { 'fake-token' }
function Get-ConnectInventory { param($Ctx, $Root)
    @{ Files = @( (mk 'a.csv' $aLen 'f1'), (mk 'old.dxf' 10 'f2'), (mk 'scan.tsf' 999 'f3'),
                  (mk 'Jobs\day1.job' 50 'f4'), (mk 'Old\x.dxf' 10 'f5') );
       Dirs  = @('Jobs', 'Old') } }
function Get-ConnectInfo { param($Ctx, $Path)
    if ($Path -like '*\a.csv') { return @{ Length = $aLen; Mtime = [datetime]::UtcNow.AddDays(1); Item = $null; ParentId = 'p' } }
    return $null }
function Copy-FileConnect { param($Ctx, $Src, $Dest, $Verify) [void]$script:Uploaded.Add($Dest) }
function Resolve-ConnectDir { param($Ctx, $P, $Create) 'folder-id' }
function Invoke-ConnectRest { param($Ctx, $Method, $Path, $Body) if ($Method -eq 'Delete') { [void]$script:Deleted.Add($Path) }; @{} }

$profile = [pscustomobject]@{
    name = 'test design -> Connect'; direction = 'push'; targetType = 'connect'; deviceName = 'Connect'
    sourcePath = $src; destinationPath = 'TC:proj1\Design'; extensions = @('.csv', '.dxf')
    prune = $true; collectorSerial = 'TC-TEST'
    connectConfig = [pscustomobject]@{ clientId = 'x'; projectId = 'proj1'; rootFolderId = 'root'; region = 'us' }
}
$log = New-Object System.Collections.ArrayList
$onLog = { param($m, $l) [void]$log.Add("[$l] $m") }
$r = Invoke-Sync -Profile $profile -OnLog $onLog -OnProgress { param($a, $b) }

"--- log (prune-related):"
$log | Where-Object { $_ -match 'Prune|DELETE|Connect:|folder' }
"--- Delete calls: " + ($script:Deleted -join ', ')
$ok = ($script:Deleted.Count -eq 2) -and ($script:Deleted -match 'f2') -and ($script:Deleted -match 'f5') -and
      -not ($script:Deleted -match 'f3|f4|folders/')
if ($ok) { 'PASS: only old.dxf and Old\x.dxf deleted; scan.tsf, day1.job and all folders kept' } else { 'FAIL' }
