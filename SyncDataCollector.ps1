<#
    SyncDataCollector.ps1
    Lightweight one-way file sync from a Windows PC to survey data collectors.

    - One-way push only (source -> collector). Never deletes on the target.
    - Copies only .csv / .dxf by default (configurable per profile).
    - Two target types:
        * "folder" : any drive-letter / UNC / local path (USB stick, collector's internal disk).
        * "mtp"    : an MTP device (over USB), driven through the Windows Shell namespace
                     (what Explorer uses) + IFileOperation -- no third-party library.
    - Mirrors the source subfolder tree under the destination.
    - Copies only new or changed files (size differs, or source newer than target).
    - Re-checks the live target every run; it never trusts a cached manifest.
    - Safeguards: on-device size verification, retry, and (folder targets) atomic
      temp-copy + rename so an interrupted copy never leaves a truncated file.

    No build step: PowerShell 5.1 + .NET Framework + WinForms. Launch via
    SyncDataCollector.cmd (sets -STA and bypasses execution policy).
#>

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Paths / globals
# --------------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogFile    = Join-Path $ScriptDir 'sync-log.txt'

$script:Config          = $null
$script:CurrentProfile  = $null
$script:IsSyncing       = $false
$script:CancelRequested = $false
$script:ShellApp        = $null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------------------
# Config load / save
# --------------------------------------------------------------------------
function New-Profile {
    param(
        [string]$Name = 'New profile',
        [string]$Direction = 'push',                 # push (PC->collector) | pull (collector->PC)
        [string]$SourcePath = '',
        [string]$TargetType = 'folder',              # the collector-side type: folder | mtp
        [string]$DeviceName = '',                    # mtp device name; also the per-device subfolder label on pull
        [string]$DestinationPath = '',
        [string]$CollisionMode = 'deviceSubfolder',  # pull only: deviceSubfolder | prefix | overwrite
        [string[]]$Extensions = @('.csv', '.dxf', '.xml', '.ttm'),
        [string[]]$ExcludeFolders = @('SUPERSEDED'), # folder names skipped at any depth
        [bool]$Prune = $false                        # push only: delete extras at the destination
    )
    [pscustomobject]@{
        name            = $Name
        direction       = $Direction
        sourcePath      = $SourcePath
        targetType      = $TargetType
        deviceName      = $DeviceName
        destinationPath = $DestinationPath
        collisionMode   = $CollisionMode
        extensions      = $Extensions
        excludeFolders  = $ExcludeFolders
        prune           = $Prune
    }
}

# Sensible default file types when creating a new PULL profile (field exports).
$script:PullDefaultExtensions = @('.job', '.jxl', '.csv', '.dxf', '.rxl', '.xml')

function New-MtpSettings {
    # Safeguards for unreliable MTP transfers. Edit in config.json if needed.
    [pscustomobject]@{
        retries           = 2       # extra attempts per file after the first
        verifyAfterUpload = $true   # re-read the file size on the device and confirm it matches
    }
}

function Get-DefaultConfig {
    # Generic starter profiles. Edit these in the GUI (or config.json) for your site.
    [pscustomobject]@{
        activeProject = 'Example project'
        projects      = @(
            New-Project -Name 'Example project' `
                -DesignSource 'S:\02-DESIGN' `
                -ExportRoot 'C:\Users\you\OneDrive\Surveying\07-DATALOGGER BACKUP\{year}\{month}' `
                -DeviceProjectPath 'Internal shared storage\Trimble Data\Projects\Example project'
        )
        collectors    = @()                 # filled in as collectors are plugged in
        defaults      = New-CollectorDefaults
        lastProfile = 'Collector over USB (MTP)'
        mtp         = New-MtpSettings
        devices     = [pscustomobject]@{}   # hardware serial -> friendly name you assign
        profiles    = @(
            New-Profile -Name 'Collector over USB (MTP)' `
                -SourcePath 'C:\Design' -TargetType 'mtp' -DeviceName 'MyCollector' `
                -DestinationPath 'Internal shared storage\Projects\ExampleProject\Design'
            New-Profile -Name 'Stage to USB stick' `
                -SourcePath 'C:\Design' -TargetType 'folder' `
                -DestinationPath 'E:\Projects\ExampleProject\Design'
            New-Profile -Name 'Collector - pull from USB' `
                -SourcePath 'E:\Projects\ExampleProject\Design' -TargetType 'folder' `
                -DestinationPath 'C:\Projects\ExampleProject\Design'
        )
    }
}

# Derive a project from a pre-collector config. The push profile that targets a
# collector gives the design source and where the project lives on the device; a
# pull profile gives the export root. Best-effort -- a blank field is better than
# refusing to start, and the UI can fill the rest in.
function ConvertFrom-LegacyProfiles {
    param($Cfg)
    $profiles = @($Cfg.profiles)
    if (-not $profiles.Count) { return @(New-Project) }

    $push = @($profiles | Where-Object { [string]$_.targetType -eq 'mtp' -and [string]$_.direction -ne 'pull' }) | Select-Object -First 1
    if (-not $push) { $push = @($profiles | Where-Object { [string]$_.direction -ne 'pull' }) | Select-Object -First 1 }
    $pull = @($profiles | Where-Object { [string]$_.direction -eq 'pull' }) | Select-Object -First 1

    $devProject = ''; $name = 'Migrated project'
    if ($push -and $push.destinationPath) {
        # ...\Projects\2100 - EXAMPLE SITE\02-Design  ->  the project folder is the parent
        $devProject = (Split-Path -Parent ([string]$push.destinationPath))
        $leaf = Split-Path -Leaf $devProject
        if ($leaf) { $name = $leaf }
    }
    $exportRoot = ''
    if ($pull -and $pull.destinationPath) { $exportRoot = [string]$pull.destinationPath }

    $designSource = ''
    if ($push) { $designSource = [string]$push.sourcePath }

    return @(New-Project -Name $name -DesignSource $designSource -ExportRoot $exportRoot -DeviceProjectPath $devProject)
}

function Load-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
            $cfg = $raw | ConvertFrom-Json
            if (-not $cfg.profiles) { throw 'no profiles' }
            # Normalise: make sure every profile has all expected fields (older
            # configs won't have direction/collisionMode -> default to push).
            $cfg.profiles = @($cfg.profiles | ForEach-Object {
                $dir  = if ($_.PSObject.Properties['direction']     -and $_.direction)     { [string]$_.direction }     else { 'push' }
                $coll = if ($_.PSObject.Properties['collisionMode'] -and $_.collisionMode) { [string]$_.collisionMode } else { 'deviceSubfolder' }
                # Older configs predate excludeFolders. Absent means "never chose", so
                # take the safe default rather than shipping superseded designs to the field.
                # Assigning an 'if' whose branch yields an empty array gives
                # $null, which [string[]] widens to @('') -- settle it by hand.
                $excl = [string[]]@('SUPERSEDED')
                if ($_.PSObject.Properties['excludeFolders']) { $excl = [string[]]@($_.excludeFolders) }
                # Prune deletes, so it stays off unless a profile explicitly turns it on.
                $prn  = if ($_.PSObject.Properties['prune']) { [bool]$_.prune } else { $false }
                New-Profile -Name $_.name -Direction $dir -SourcePath $_.sourcePath -TargetType $_.targetType `
                    -DeviceName $_.deviceName -DestinationPath $_.destinationPath `
                    -CollisionMode $coll -Extensions @($_.extensions) -ExcludeFolders $excl -Prune $prn
            })
            # Projects / collectors. A config written before this model existed is
            # migrated from its profiles rather than discarded; the old profiles are
            # left in the file untouched (ignored, safe to delete by hand).
            if (-not $cfg.PSObject.Properties['projects'] -or -not @($cfg.projects).Count) {
                $cfg | Add-Member -NotePropertyName projects -NotePropertyValue @(ConvertFrom-LegacyProfiles $cfg) -Force
            }
            else {
                $cfg.projects = @(@($cfg.projects) | ForEach-Object {
                    New-Project -Name $_.name -DesignSource $_.designSource `
                        -ExportRoot $_.exportRoot -DeviceProjectPath $_.deviceProjectPath
                })
            }
            if (-not $cfg.PSObject.Properties['collectors']) {
                $cfg | Add-Member -NotePropertyName collectors -NotePropertyValue @() -Force
            }
            else {
                $cfg.collectors = @(@($cfg.collectors) | ForEach-Object {
                    $ec = [string[]]@('SUPERSEDED')
                    if ($_.PSObject.Properties['excludeFolders']) { $ec = [string[]]@($_.excludeFolders) }
                    $pr = if ($_.PSObject.Properties['prune']) { [bool]$_.prune } else { $true }
                    $xc = if ($_.PSObject.Properties['exportCollision'] -and $_.exportCollision) { [string]$_.exportCollision } else { 'prefix' }
                    New-Collector -Serial $_.serial -Name $_.name -Model $_.model -Type $_.type `
                        -DesignSubPath $_.designSubPath -ExportSubPath $_.exportSubPath `
                        -DesignExtensions @($_.designExtensions) -ExportExtensions @($_.exportExtensions) `
                        -ExcludeFolders $ec -Prune $pr -ExportCollision $xc
                })
            }
            # Shared baseline for collector settings. Always normalised to a
            # complete block, so nothing downstream has to cope with a partial
            # one, and a config written before defaults existed gains them.
            $rawDefaults = $null
            if ($cfg.PSObject.Properties['defaults']) { $rawDefaults = $cfg.defaults }
            $cfg | Add-Member -NotePropertyName defaults -NotePropertyValue (Resolve-Defaults $rawDefaults) -Force
            if (-not $cfg.PSObject.Properties['activeProject'] -or -not $cfg.activeProject) {
                $first = ''
                if (@($cfg.projects).Count) { $first = [string]@($cfg.projects)[0].name }
                $cfg | Add-Member -NotePropertyName activeProject -NotePropertyValue $first -Force
            }
            # Friendly names live in the shared config so every machine calls each
            # collector the same thing.
            if (-not $cfg.PSObject.Properties['devices'] -or -not $cfg.devices) {
                $cfg | Add-Member -NotePropertyName devices -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            # Ensure MTP safeguard settings exist (older config files won't have them).
            $def = New-MtpSettings
            if (-not $cfg.PSObject.Properties['mtp'] -or -not $cfg.mtp) {
                $cfg | Add-Member -NotePropertyName mtp -NotePropertyValue $def -Force
            }
            else {
                foreach ($prop in $def.PSObject.Properties.Name) {
                    if (-not $cfg.mtp.PSObject.Properties[$prop]) {
                        $cfg.mtp | Add-Member -NotePropertyName $prop -NotePropertyValue $def.$prop -Force
                    }
                }
            }
            return $cfg
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "config.json could not be read ($($_.Exception.Message)).`r`nUsing defaults.",
                'Sync Data Collector', 'OK', 'Warning') | Out-Null
        }
    }
    return Get-DefaultConfig
}

function Save-Config {
    $script:Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# --------------------------------------------------------------------------
# Per-machine preferences (registry, HKCU). config.json (profiles) is shared --
# it may live on OneDrive and run from several PCs/collectors -- but the
# last/default profile is machine-specific, so it lives here instead of in the
# shared file. All access is best-effort; a locked-down registry never crashes us.
# --------------------------------------------------------------------------
$script:RegKey = 'HKCU:\Software\SyncDataCollector'

function Get-Pref {
    param([string]$Name, $Default = $null)
    try {
        $item = Get-ItemProperty -Path $script:RegKey -Name $Name -ErrorAction Stop
        $v = $item.$Name
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    catch {}
    return $Default
}

function Set-Pref {
    param([string]$Name, $Value)
    try {
        if (-not (Test-Path $script:RegKey)) { New-Item -Path $script:RegKey -Force | Out-Null }
        New-ItemProperty -Path $script:RegKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
    catch {}
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Split-MtpPath {
    # A logical device path ("Internal shared storage\...\Design") -> clean segments.
    param([string]$Path)
    return @(($Path -replace '/', '\') -split '\\' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Parse-Extensions {
    param([string]$Text)
    $out = @()
    foreach ($t in ($Text -split '[,;\s]+')) {
        $t = $t.Trim()
        if ($t) {
            if ($t[0] -ne '.') { $t = '.' + $t }
            $out += $t.ToLowerInvariant()
        }
    }
    return ,([string[]]$out)
}

# Folder names for the exclusion list. Split on comma/semicolon ONLY -- folder
# names routinely contain spaces ("OLD DRAWINGS"), so whitespace can't be a separator.
function Parse-FolderList {
    param([string]$Text)
    $out = @()
    foreach ($t in ($Text -split '[,;]')) {
        $t = $t.Trim().Trim('\')
        if ($t) { $out += $t }
    }
    return ,([string[]]$out)
}

# Today's Julian date as YY-DDD (e.g. 2026-07-23 -> "26-204").
function Get-JulianDate {
    $now = Get-Date
    return ('{0}-{1:D3}' -f $now.ToString('yy'), $now.DayOfYear)
}

# Month folder in the shape the datalogger-backup tree already uses: "8-AUG", "10-OCT"
# -- unpadded month number, hyphen, three-letter month upper-cased.
function Get-MonthFolder {
    $now = Get-Date
    return ('{0}-{1}' -f $now.Month, $now.ToString('MMM', [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant())
}

# Expand path tokens, all case-insensitive:
#   {julian} -> YY-DDD  (26-236)      {year}  -> 2026
#   {month}  -> 8-AUG                 {date}  -> 2026-08-24
function Expand-PathTokens {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $now = Get-Date
    $out = $Path
    $out = $out -replace '(?i)\{julian\}', (Get-JulianDate)
    $out = $out -replace '(?i)\{year\}',   $now.ToString('yyyy')
    $out = $out -replace '(?i)\{month\}',  (Get-MonthFolder)
    $out = $out -replace '(?i)\{date\}',   $now.ToString('yyyy-MM-dd')
    return $out
}

# --------------------------------------------------------------------------
# Target providers -- a small interface parameterised by $Kind ('fs'|'mtp') so
# either the source or the destination can be MTP (push vs pull).
#   $ctx = @{ DeviceName=..; Settings=..; FolderCache=@{} }
# Paths are the *logical* path: fs -> a normal Windows path; mtp -> an on-device
# path under the device. MTP is driven via the Windows Shell + IFileOperation.
# All returned Mtime values are UTC so push/pull comparisons are apples-to-apples.
# --------------------------------------------------------------------------
function Target-EnsureDir {
    param($Ctx, [string]$Kind, [string]$DirPath)
    if ($Kind -eq 'fs') {
        if (-not (Test-Path -LiteralPath $DirPath)) {
            New-Item -ItemType Directory -Force -Path $DirPath | Out-Null
        }
    }
    else {
        [void](Resolve-MtpDir $Ctx $DirPath $true)
    }
}

# Returns @{ Length = <long>; Mtime = <datetime UTC|null> }. Length = -1 means the
# file does not exist at the target (one enumeration for MTP).
function Target-GetInfo {
    param($Ctx, [string]$Kind, [string]$FilePath)
    if ($Kind -eq 'fs') {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @{ Length = -1; Mtime = $null } }
        $i = Get-Item -LiteralPath $FilePath
        return @{ Length = [long]$i.Length; Mtime = [datetime]$i.LastWriteTimeUtc }
    }
    $info = Get-MtpInfo $Ctx $FilePath
    if (-not $info) { return @{ Length = -1; Mtime = $null } }
    return @{ Length = $info.Length; Mtime = $info.Mtime }   # MTP DateModified is already UTC
}

$script:TempSuffix = '.partsync'   # marks an in-progress / incomplete transfer

# Field data is irreplaceable, so a pull NEVER writes over something already there.
# Walk the base name and its " (n)" variants:
#   - a slot that already holds this same file  -> Skip (nothing to do)
#   - the first free slot                       -> write there, alongside the others
# Checking the variants is what stops repeated pulls from growing "(2)", "(3)", ...
# forever: the second run recognises its own earlier copy and skips.
function Resolve-NoOverwriteDest {
    param($Ctx, [string]$Kind, [string]$Path, [long]$SrcLen, $SrcMtimeUtc)
    $dir  = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext  = [System.IO.Path]::GetExtension($leaf)
    for ($i = 1; $i -lt 200; $i++) {
        $cand = $Path
        if ($i -gt 1) {
            $n = ('{0} ({1}){2}' -f $base, $i, $ext)
            $cand = if ($dir) { "$dir\$n" } else { $n }
        }
        $info = Target-GetInfo $Ctx $Kind $cand
        if ($info.Length -lt 0) { return @{ Path = $cand; Skip = $false } }
        if ([long]$info.Length -eq $SrcLen) {
            # Same size: already pulled, unless the source is clearly newer.
            if ($null -eq $info.Mtime -or $null -eq $SrcMtimeUtc -or $SrcMtimeUtc -le $info.Mtime.AddSeconds(2)) {
                return @{ Path = $cand; Skip = $true }
            }
        }
    }
    throw "too many name variants already exist for '$leaf'"
}

# Folder copy: write to a temp file, verify size, then atomically move into place.
# An interrupted copy therefore never leaves a truncated "real" file behind.
function Copy-FileFolder {
    param([string]$SourceFile, [string]$DestPath, [bool]$Verify)
    $dir = Split-Path -Parent $DestPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $DestPath + $script:TempSuffix
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $SourceFile -Destination $tmp -Force
    if ($Verify) {
        $srcLen = [long](Get-Item -LiteralPath $SourceFile).Length
        $dstLen = [long](Get-Item -LiteralPath $tmp).Length
        if ($srcLen -ne $dstLen) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            throw "incomplete copy ($dstLen of $srcLen bytes)"
        }
    }
    if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force }
    [System.IO.File]::Move($tmp, $DestPath)
}

# MTP copy via IFileOperation: silent, synchronous copy of a local file into the
# device folder, deleting any existing same-name item first (clean overwrite).
# IFileOperation blocks until the transfer completes, so no polling/temp/rename.
function Copy-FileMtp {
    param($Ctx, [string]$SourceFile, [string]$DestPath, [bool]$Verify)
    Ensure-MtpInterop
    $dir  = Split-Path -Parent $DestPath
    $leaf = Split-Path -Leaf $DestPath
    $dirItem = Resolve-MtpDir $Ctx $dir $true
    $destFolder = $dirItem.GetFolder
    $existing = Find-ShellChild $destFolder $leaf
    [SyncDC.MtpOp]::Upload($dirItem, $SourceFile, $existing, $leaf)
    if ($Verify) {
        $srcLen = [long](Get-Item -LiteralPath $SourceFile).Length
        $it = Find-ShellChild $destFolder $leaf
        $sz = -1
        if ($it) { try { $sz = [long][uint64]$it.ExtendedProperty('System.Size') } catch {} }
        if ($sz -ne $srcLen) { throw "size mismatch after upload (device $sz vs source $srcLen bytes)" }
    }
}

# MTP download via IFileOperation: pull a file OFF the device to a local temp name,
# verify size, then File.Move into place (atomic, mirrors the folder-copy pattern).
function Copy-FileMtpDownload {
    param($Ctx, $MtpItem, [string]$DestLocalPath, [long]$SrcLen, [bool]$Verify)
    Ensure-MtpInterop
    $dir = Split-Path -Parent $DestLocalPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $leaf = Split-Path -Leaf $DestLocalPath
    $tmpLeaf = $leaf + $script:TempSuffix
    $tmpPath = Join-Path $dir $tmpLeaf
    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    [SyncDC.MtpOp]::Download($MtpItem, $dir, $tmpLeaf)
    if ($Verify -and $SrcLen -ge 0) {
        $dstLen = [long](Get-Item -LiteralPath $tmpPath).Length
        if ($dstLen -ne $SrcLen) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
            throw "incomplete download ($dstLen of $SrcLen bytes)"
        }
    }
    if (Test-Path -LiteralPath $DestLocalPath) { Remove-Item -LiteralPath $DestLocalPath -Force }
    [System.IO.File]::Move($tmpPath, $DestLocalPath)
}

# Copy one file with retries, dispatching on direction:
#   fs2fs  -> Src is a local path      | fs2mtp -> Src is a local path (upload)
#   mtp2fs -> Src is an MTP FolderItem (download)
# On an MTP failure the folder cache is dropped so the next attempt re-resolves.
function Invoke-CopyWithRetry {
    param($Ctx, [string]$CopyMode, $Src, [string]$DestPath, [long]$SrcLen, [scriptblock]$OnLog)
    $maxAttempts = 1 + [int]$Ctx.Settings.retries
    $verify = [bool]$Ctx.Settings.verifyAfterUpload
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            switch ($CopyMode) {
                'fs2fs'  { Copy-FileFolder $Src $DestPath $verify }
                'fs2mtp' { Copy-FileMtp $Ctx $Src $DestPath $verify }
                'mtp2fs' { Copy-FileMtpDownload $Ctx $Src $DestPath $SrcLen $verify }
                default  { throw "unknown copy mode '$CopyMode'" }
            }
            return
        }
        catch {
            if ($attempt -lt $maxAttempts) {
                & $OnLog ("  attempt $attempt/$maxAttempts failed: $($_.Exception.Message)") 'WARN'
                Start-Sleep -Milliseconds (600 * $attempt)
                if ($CopyMode -ne 'fs2fs') { $Ctx.FolderCache.Clear() }
            }
            else { throw }
        }
    }
}

# --------------------------------------------------------------------------
# MTP provider (Windows Shell namespace + IFileOperation)
#
# Why not a WPD/MTP library: on real devices (e.g. the Trimble TSC5) the raw
# IPortableDevice.Open hangs indefinitely, while the Windows Shell namespace --
# exactly what File Explorer uses -- works reliably and coexists with an open
# Explorer window. So we navigate/list/create/stat via Shell.Application and do
# the actual copy/overwrite/delete via IFileOperation (silent, synchronous,
# no confirmation dialogs). No third-party DLL required.
# --------------------------------------------------------------------------
function Ensure-MtpInterop {
    if ('SyncDC.MtpOp' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SyncDC {
  [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IShellItem {
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem ppsi);
    void GetDisplayName(uint sigdnName, out IntPtr ppszName);
    void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
    void Compare(IShellItem psi, uint hint, out int piOrder);
  }
  [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IFileOperation {
    void Advise(IntPtr pfops, out uint pdwCookie);
    void Unadvise(uint dwCookie);
    void SetOperationFlags(uint dwOperationFlags);
    void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string pszMessage);
    void SetProgressDialog(IntPtr popd);
    void SetProperties(IntPtr pproparray);
    void SetOwnerWindow(IntPtr hwndOwner);
    void ApplyPropertiesToItem(IShellItem psiItem);
    void ApplyPropertiesToItems(object punkItems);
    void RenameItem(IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
    void RenameItems(object pUnkItems, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
    void MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
    void MoveItems(object punkItems, IShellItem psiDestinationFolder);
    void CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszCopyName, IntPtr pfopsItem);
    void CopyItems(object punkItems, IShellItem psiDestinationFolder);
    void DeleteItem(IShellItem psiItem, IntPtr pfopsItem);
    void DeleteItems(object punkItems);
    void NewItem(IShellItem psiDestinationFolder, uint dwFileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string pszName, [MarshalAs(UnmanagedType.LPWStr)] string pszTemplateName, IntPtr pfopsItem);
    void PerformOperations();
    void GetAnyOperationsAborted(out bool pfAnyOperationsAborted);
  }
  public static class MtpOp {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);
    [DllImport("shell32.dll", PreserveSig=false)]
    static extern void SHGetIDListFromObject([MarshalAs(UnmanagedType.IUnknown)] object punk, out IntPtr ppidl);
    [DllImport("shell32.dll", PreserveSig=false)]
    static extern void SHCreateItemFromIDList(IntPtr pidl, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr pv);

    static Guid IID_IShellItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
    static Guid CLSID_FileOperation = new Guid("3ad05575-8857-4850-9277-11b85bdb8e09");

    static IShellItem FromPath(string p) { IShellItem si; SHCreateItemFromParsingName(p, IntPtr.Zero, ref IID_IShellItem, out si); return si; }
    static IShellItem FromCom(object com) {
      IntPtr pidl; SHGetIDListFromObject(com, out pidl);
      try { IShellItem si; SHCreateItemFromIDList(pidl, ref IID_IShellItem, out si); return si; }
      finally { CoTaskMemFree(pidl); }
    }
    static IFileOperation NewOp() {
      IFileOperation op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FileOperation));
      // FOF_SILENT|FOF_NOCONFIRMATION|FOF_NOCONFIRMMKDIR|FOF_NOERRORUI
      op.SetOperationFlags(0x0004 | 0x0010 | 0x0200 | 0x0400);
      return op;
    }
    // Copy a local file into an MTP folder (Shell FolderItem COM object), deleting
    // any existing same-name item first, so overwrites are clean and silent.
    public static void Upload(object destFolderCom, string localPath, object existingComOrNull, string newName) {
      IShellItem dest = FromCom(destFolderCom);
      IFileOperation op = NewOp();
      if (existingComOrNull != null) op.DeleteItem(FromCom(existingComOrNull), IntPtr.Zero);
      op.CopyItem(FromPath(localPath), dest, newName, IntPtr.Zero);
      op.PerformOperations();
      bool aborted; op.GetAnyOperationsAborted(out aborted);
      if (aborted) throw new Exception("file operation aborted by the shell/device");
    }
    public static void Delete(object com) {
      IFileOperation op = NewOp();
      op.DeleteItem(FromCom(com), IntPtr.Zero);
      op.PerformOperations();
    }
    // Copy a file off an MTP device (Shell FolderItem COM object) into a local
    // folder (which must already exist), naming the result newName.
    public static void Download(object srcItemCom, string localDestDir, string newName) {
      IShellItem src = FromCom(srcItemCom);
      IShellItem dst = FromPath(localDestDir);
      IFileOperation op = NewOp();
      op.CopyItem(src, dst, newName, IntPtr.Zero);
      op.PerformOperations();
      bool aborted; op.GetAnyOperationsAborted(out aborted);
      if (aborted) throw new Exception("file operation aborted by the shell/device");
    }
  }
}
'@
}

function Get-ShellApp {
    if (-not $script:ShellApp) { $script:ShellApp = New-Object -ComObject Shell.Application }
    return $script:ShellApp
}

# Find an immediate child FolderItem by name (ParseName does not resolve MTP items).
function Find-ShellChild {
    param($Folder, [string]$Name)
    $items = $Folder.Items()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items.Item($i)
        if ($it.Name -eq $Name) { return $it }
    }
    return $null
}

# Portable devices appear under "This PC" as folders without a drive-letter path.
# Their Shell path carries the USB descriptor, which for these collectors holds the
# hardware serial:
#     ::{20D04FE0-...}\\\?\usb#vid_099e&pid_0261#jaj000000001#{guid}
#                                                ^^^^^^^^^^^^
# That serial is the only thing that tells two collectors of the same model apart --
# they both report the name "TSC5". Unlike our marker file it is known before the
# device has ever been synced, and it survives the device being wiped.
function Get-MtpDevices {
    $out = @()
    $pc = (Get-ShellApp).NameSpace(0x11)
    $items = $pc.Items()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items.Item($i)
        if (-not $it.IsFolder) { continue }
        if ($it.Path -match '^[A-Za-z]:\\') { continue }
        $serial = ''
        if ($it.Path -match '#(?:vid_[0-9a-f]{4}&pid_[0-9a-f]{4})#([^#]+)#') { $serial = $Matches[1].ToUpperInvariant() }
        $out += @{ Name = $it.Name; Serial = $serial; Path = $it.Path; Item = $it }
    }
    return $out
}

function Get-MtpDeviceNames {
    return @(@(Get-MtpDevices) | ForEach-Object { $_.Name })
}

# Pick the ONE device this profile should act on.
#   none      -> throw (not connected)
#   exactly 1 -> that one
#   several   -> ask through $OnChoose (the GUI shows a picker). With no chooser this
#                throws rather than silently syncing to whichever Windows enumerated
#                first -- that is how the wrong crew's controller gets overwritten.
function Resolve-CollectorDevice {
    param([string]$DeviceName, [string]$PreferSerial, [scriptblock]$OnChoose)
    $all = @(Get-MtpDevices)
    $match = @($all | Where-Object { $_.Name -eq $DeviceName })
    if ($match.Count -eq 0) {
        $seen = (@($all | ForEach-Object { $_.Name }) -join ', ')
        if (-not $seen) { $seen = '(none)' }
        throw "MTP device '$DeviceName' not found under This PC. Connected, unlocked, and set to File transfer (MTP)? Detected: $seen"
    }
    if ($PreferSerial) {
        $pin = @($match | Where-Object { $_.Serial -eq $PreferSerial })
        if ($pin.Count -eq 1) { return $pin[0] }
    }
    if ($match.Count -eq 1) { return $match[0] }
    if ($OnChoose) {
        $picked = & $OnChoose $match
        if ($picked) { return $picked }
        throw "Cancelled: $($match.Count) collectors named '$DeviceName' are connected and none was chosen."
    }
    $serials = (@($match | ForEach-Object { $_.Serial }) -join ', ')
    throw "More than one '$DeviceName' is connected ($serials). Disconnect all but one, or choose which to use."
}

# Resolve a logical device dir ("Internal shared storage\...\Design") to its Shell
# FolderItem, creating missing folders when $Create. Cached per-run in $Ctx.FolderCache.
function Resolve-MtpDir {
    param($Ctx, [string]$LogicalDir, [bool]$Create)
    $key = ($LogicalDir -replace '/', '\').Trim('\')
    if ($Ctx.FolderCache.ContainsKey($key)) { return $Ctx.FolderCache[$key] }
    # Start from the device we actually resolved, so two collectors reporting the same
    # name can never be confused. Falls back to a name lookup when nothing resolved it.
    $curItem = $null
    if ($Ctx.ContainsKey('DeviceItem') -and $Ctx.DeviceItem) {
        $curItem   = $Ctx.DeviceItem
        $curFolder = $Ctx.DeviceItem.GetFolder
        $segs      = @(Split-MtpPath $LogicalDir)
    }
    else {
        $curFolder = (Get-ShellApp).NameSpace(0x11)
        $segs      = @($Ctx.DeviceName) + (Split-MtpPath $LogicalDir)
    }
    foreach ($seg in $segs) {
        $child = Find-ShellChild $curFolder $seg
        if (-not $child) {
            if (-not $Create) { return $null }
            $curFolder.NewFolder($seg)
            $deadline = (Get-Date).AddSeconds(10)
            do { Start-Sleep -Milliseconds 300; $child = Find-ShellChild $curFolder $seg }
            while (-not $child -and (Get-Date) -lt $deadline)
            if (-not $child) { throw "could not create MTP folder '$seg'" }
        }
        $curItem = $child
        $curFolder = $child.GetFolder
    }
    $Ctx.FolderCache[$key] = $curItem
    return $curItem
}

# @{ Item=<FolderItem>; Length=<long>; Mtime=<datetime|null> } or $null if absent.
function Get-MtpInfo {
    param($Ctx, [string]$FilePath)
    $dir  = Split-Path -Parent $FilePath
    $leaf = Split-Path -Leaf $FilePath
    $dirItem = Resolve-MtpDir $Ctx $dir $false
    if (-not $dirItem) { return $null }
    $it = Find-ShellChild $dirItem.GetFolder $leaf
    if (-not $it) { return $null }
    $len = -1; $md = $null
    try { $len = [long][uint64]$it.ExtendedProperty('System.Size') } catch {}
    try { $md  = [datetime]$it.ExtendedProperty('System.DateModified') } catch {}
    return @{ Item = $it; Length = $len; Mtime = $md }
}

# Recursively inventory an MTP source dir (ALL files + all dirs; filtering happens
# later in Select-SyncSet so .jxl companion folders can be included wholesale).
# Returns @{ Files = @(@{ Rel; Length; MtimeUtc; Item; Ext }); Dirs = @(<rel>) }.
function Get-MtpInventory {
    param($Ctx, [string]$RootLogicalDir)
    $out = @{ Files = (New-Object System.Collections.ArrayList); Dirs = (New-Object System.Collections.ArrayList) }
    $rootItem = Resolve-MtpDir $Ctx $RootLogicalDir $false
    if (-not $rootItem) { return $out }   # source folder isn't on the device
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ Folder = $rootItem.GetFolder; Rel = '' })
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $items = $node.Folder.Items()
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items.Item($i)
            $rel = if ($node.Rel) { $node.Rel + '\' + $it.Name } else { $it.Name }
            if ($it.IsFolder) {
                [void]$out.Dirs.Add($rel)
                $stack.Push(@{ Folder = $it.GetFolder; Rel = $rel })
            }
            else {
                $len = -1; $md = $null
                try { $len = [long][uint64]$it.ExtendedProperty('System.Size') } catch {}
                try { $md  = [datetime]$it.ExtendedProperty('System.DateModified') } catch {}
                [void]$out.Files.Add(@{ Rel = $rel; Length = $len; MtimeUtc = $md; Item = $it; Ext = [System.IO.Path]::GetExtension($it.Name).ToLowerInvariant() })
            }
        }
    }
    return $out
}

# Inventory a filesystem source: every file and dir under $Root, as the raw records
# Select-SyncSet expects. Shared by the sync engine and the offline staleness check.
function Get-FsInventory {
    param([string]$Root)
    $files = @(); $dirs = @()
    Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            $dirs += $_.FullName.Substring($Root.Length).TrimStart('\')
        }
        else {
            $files += @{ Rel = $_.FullName.Substring($Root.Length).TrimStart('\'); Length = [long]$_.Length; MtimeUtc = $_.LastWriteTimeUtc; Src = $_.FullName; Local = $_.FullName; Ext = $_.Extension.ToLowerInvariant() }
        }
    }
    return @{ Files = $files; Dirs = $dirs }
}

# A .xml file is only synced if it is actually LandXML (root element <LandXML>).
# Streams just to the first element, so it is cheap even for large surfaces.
function Test-LandXml {
    param([string]$Path)
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit  # fast + safe (no external DTD)
        $settings.XmlResolver = $null
        $settings.IgnoreComments = $true
        $settings.IgnoreProcessingInstructions = $true
        $settings.IgnoreWhitespace = $true
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        try {
            while ($reader.Read()) {
                if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                    return ($reader.LocalName -eq 'LandXML')   # LocalName ignores any namespace prefix
                }
            }
            return $false
        }
        finally { $reader.Dispose() }
    }
    catch { return $false }
}

# Map a source-relative path to a destination-relative path, applying the pull
# collision mode. Used for both files and directories so a scan's .jxl and its
# "<name> Files" folder stay associated on the destination.
# $DeviceName here is the collector LABEL, not the MTP model name -- several units
# share a model, so labelling by model would defeat the whole point.
#
# 'prefix' deliberately prefixes the FIRST path segment rather than the filename.
# For a flat export folder those are the same thing, and for a scan it keeps the
# pieces together: "26-069-FE.jxl" and "26-069-FE Files\cloud.rcs" both gain the
# same prefix on their first segment, so the .jxl still finds its companion folder.
# Prefixing the leaf instead would rename the file and the folder's contents but not
# the folder, breaking the association.
function Get-DestRel {
    param([string]$Rel, [string]$Direction, [string]$CollisionMode, [string]$DeviceName)
    if ($Direction -ne 'pull') { return $Rel }
    switch ($CollisionMode) {
        'deviceSubfolder' { if ($DeviceName) { return "$DeviceName\$Rel" } else { return $Rel } }
        'prefix' {
            if (-not $DeviceName) { return $Rel }
            $parts = $Rel -split '\\', 2
            $first = $DeviceName + '_' + $parts[0]
            if ($parts.Count -gt 1) { return "$first\$($parts[1])" } else { return $first }
        }
        default { return $Rel }                             # overwrite
    }
}

# Pick which inventoried files to sync:
#   - files whose extension is in $Exts (LandXML content-check only when $ApplyLandXml)
#   - PLUS everything under a ".jxl" companion folder "<name> Files" (any extension),
#     so total-station scans travel with their point-cloud subfolder.
# Returns @{ Files = <records>; Dirs = <companion subdir rels, incl. empty>; SkippedXml = <int> }.
function Select-SyncSet {
    param($RawFiles, $RawDirs, [string[]]$Exts, [bool]$ApplyLandXml, [string[]]$ExcludeFolders)

    # Folder exclusions: drop anything sitting under a folder with an excluded name,
    # at any depth (case-insensitive). Keeps superseded designs off the collector.
    $exclSet = @{}
    foreach ($x in @($ExcludeFolders)) {
        $t = ([string]$x).Trim()
        if ($t) { $exclSet[$t.ToLowerInvariant()] = $true }
    }
    $isExcluded = {
        param([string]$dirRel)
        if ($exclSet.Count -eq 0 -or -not $dirRel) { return $false }
        foreach ($seg in ($dirRel -split '\\')) {
            if ($seg -and $exclSet.ContainsKey($seg.ToLowerInvariant())) { return $true }
        }
        return $false
    }

    $prefixes = @()
    if ($Exts -contains '.jxl') {
        foreach ($r in $RawFiles) {
            if ($r.Ext -eq '.jxl') {
                $dirRel = Split-Path -Parent $r.Rel
                $base   = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $r.Rel))
                $compRel = if ($dirRel) { "$dirRel\$base Files" } else { "$base Files" }
                $prefixes += ($compRel.ToLowerInvariant() + '\')
            }
        }
    }
    $underCompanion = {
        param([string]$rel)
        if (-not $prefixes.Count) { return $false }
        $rl = $rel.ToLowerInvariant()
        foreach ($p in $prefixes) { if ($rl.StartsWith($p)) { return $true } }
        return $false
    }
    $files = @(); $skippedXml = 0; $skippedExcluded = 0
    foreach ($r in $RawFiles) {
        # Never sync our own marker: it identifies the device it sits on, so copying
        # it onward would hand a second device the same identity.
        if ((Split-Path -Leaf $r.Rel) -eq $script:MarkerName) { continue }
        # Excluded folders win over everything, companion folders included.
        if (& $isExcluded (Split-Path -Parent $r.Rel)) { $skippedExcluded++; continue }
        $inc = $false
        if ($Exts -contains $r.Ext) {
            if ($ApplyLandXml -and $r.Ext -eq '.xml' -and $r.Local -and -not (Test-LandXml $r.Local)) { $skippedXml++ }
            else { $inc = $true }
        }
        if (-not $inc -and (& $underCompanion $r.Rel)) { $inc = $true }
        if ($inc) { $files += $r }
    }
    $dirs = @()
    foreach ($d in $RawDirs) {
        if (& $isExcluded $d) { continue }
        if (& $underCompanion $d) { $dirs += $d }
    }
    return @{ Files = $files; Dirs = $dirs; SkippedXml = $skippedXml; SkippedExcluded = $skippedExcluded }
}

# --------------------------------------------------------------------------
# Prune ("the tool owns this folder")
#
# Optional, per-profile, PUSH ONLY, and off by default: deleting is the one thing
# here that cannot be undone. When enabled, anything at the destination that the
# source does not account for is removed after the copy pass, so the destination
# becomes an exact mirror of the filtered source.
#
# Never removed: the tool's own marker file, and anything the source still claims.
# Excluded folders (SUPERSEDED) count as "not claimed", so turning on an exclusion
# and pruning together is what actually clears obsolete designs off a collector.
# --------------------------------------------------------------------------

# Everything currently under a target root: @{ Files=@(@{Rel;Length;Item}); Dirs=@(<rel>) }.
function Get-TargetInventory {
    param($Ctx, [string]$Kind, [string]$RootPath)
    $files = @(); $dirs = @()
    if ($Kind -eq 'fs') {
        if (-not (Test-Path -LiteralPath $RootPath)) { return @{ Files = $files; Dirs = $dirs } }
        $inv = Get-FsInventory $RootPath
        foreach ($f in $inv.Files) { $files += @{ Rel = $f.Rel; Length = $f.Length; Item = $null } }
        return @{ Files = $files; Dirs = @($inv.Dirs) }
    }
    $inv = Get-MtpInventory $Ctx $RootPath
    foreach ($f in $inv.Files) { $files += @{ Rel = $f.Rel; Length = $f.Length; Item = $f.Item } }
    return @{ Files = $files; Dirs = @($inv.Dirs) }
}

function Target-DeleteFile {
    param($Ctx, [string]$Kind, [string]$FilePath, $MtpItem)
    if ($Kind -eq 'fs') {
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) { Remove-Item -LiteralPath $FilePath -Force }
        return
    }
    Ensure-MtpInterop
    $it = $MtpItem
    if (-not $it) {
        $info = Get-MtpInfo $Ctx $FilePath
        if (-not $info) { return }
        $it = $info.Item
    }
    [SyncDC.MtpOp]::Delete($it)
}

function Target-DeleteDir {
    param($Ctx, [string]$Kind, [string]$DirPath)
    if ($Kind -eq 'fs') {
        if (Test-Path -LiteralPath $DirPath -PathType Container) { Remove-Item -LiteralPath $DirPath -Recurse -Force }
        return
    }
    Ensure-MtpInterop
    $Ctx.FolderCache.Clear()          # the tree is changing under us
    $it = Resolve-MtpDir $Ctx $DirPath $false
    if ($it) { [SyncDC.MtpOp]::Delete($it) }
}

# What is at the destination that the source does not account for.
# $Records = the selected source files; $CompanionDirs = scan subfolders to keep.
function Get-PruneSet {
    param($Ctx, [string]$DstKind, [string]$DstPath, $Records, $CompanionDirs,
          [string]$Direction, [string]$CollisionMode, [string]$DeviceName)

    $want     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $wantDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $addDirChain = {
        param([string]$rel)
        $p = Split-Path -Parent $rel
        while ($p) { [void]$wantDirs.Add($p); $p = Split-Path -Parent $p }
    }
    foreach ($r in $Records) {
        $rel = Get-DestRel $r.Rel $Direction $CollisionMode $DeviceName
        [void]$want.Add($rel)
        & $addDirChain $rel
    }
    # Companion (scan) folders are kept even when empty -- that is deliberate elsewhere.
    foreach ($d in @($CompanionDirs)) {
        $rel = Get-DestRel $d $Direction $CollisionMode $DeviceName
        [void]$wantDirs.Add($rel)
        & $addDirChain ($rel + '\x')
    }

    $inv = Get-TargetInventory $Ctx $DstKind $DstPath
    $files = @()
    foreach ($f in $inv.Files) {
        # The marker is the tool's own identity record; pruning it would orphan the device.
        if ((Split-Path -Leaf $f.Rel) -eq $script:MarkerName) { continue }
        if (-not $want.Contains($f.Rel)) { $files += $f }
    }
    $dirs = @()
    foreach ($d in $inv.Dirs) { if (-not $wantDirs.Contains($d)) { $dirs += $d } }
    # Deepest first, so a parent is only removed once its children are gone.
    $dirs = @($dirs | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)
    return @{ Files = $files; Dirs = $dirs }
}

# --------------------------------------------------------------------------
# Sync state + device marker  ("out of date" awareness)
#
# Two records let the app answer "does collector X need a re-sync?" whether or
# not the collector happens to be plugged in right now:
#
#   1. A marker file ($script:MarkerName) at the destination root -- i.e. on the
#      collector / USB stick itself. It carries a stable deviceId, so a stick is
#      still recognisable after its drive letter changes, plus a note of the last
#      sync written to it.
#   2. sync-state.json next to the app -- what THIS install last synced per
#      profile (when, how many files, the newest source timestamp). This is what
#      lets the app say "3 design files changed since the last sync" with nothing
#      connected at all.
#
# Both are best-effort: failing to read or write either never fails a sync.
# --------------------------------------------------------------------------
$script:MarkerName = '_SyncDataCollector.json'
$script:StatePath  = Join-Path $ScriptDir 'sync-state.json'

function Format-Utc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Parse-Utc {
    # [datetime] in UTC, or $null. Tolerates junk in a hand-edited state file.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture,
            ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
    }
    catch { return $null }
}

function Format-Local {
    # Display only -- stored timestamps are always UTC.
    param([datetime]$Utc)
    return $Utc.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Load-SyncState {
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $st = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st -and $st.PSObject.Properties['entries']) {
                $st.entries = @($st.entries)
                return $st
            }
        }
        catch {}   # corrupt or locked -> start clean rather than nag the user
    }
    return [pscustomobject]@{ version = 1; entries = @() }
}

function Save-SyncState {
    param($State)
    try { $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8 }
    catch {}
}

# Friendly names you assign, keyed by hardware serial. Shared via config.json so every
# machine calls the same collector by the same name.
function Get-DeviceFriendlyName {
    param([string]$Serial)
    if (-not $Serial) { return '' }
    $d = $script:Config.devices
    if ($d -and $d.PSObject.Properties[$Serial]) { return [string]$d.$Serial }
    return ''
}

function Set-DeviceFriendlyName {
    param([string]$Serial, [string]$Name)
    if (-not $Serial) { return }
    if (-not $script:Config.PSObject.Properties['devices'] -or -not $script:Config.devices) {
        $script:Config | Add-Member -NotePropertyName devices -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $script:Config.devices | Add-Member -NotePropertyName $Serial -NotePropertyValue $Name -Force
}

# One connected device, as a pickable line: "Crew A - TSC5 (JAJ000000001)".
function Format-DeviceChoice {
    param($Dev)
    $friendly = Get-DeviceFriendlyName ([string]$Dev.Serial)
    $s = [string]$Dev.Serial
    if (-not $s) { $s = 'no serial' }
    if ($friendly) { return ('{0} - {1} ({2})' -f $friendly, $Dev.Name, $s) }
    return ('{0} ({1})' -f $Dev.Name, $s)
}

# How a collector reads in the UI and the log. Best available name, qualified by the
# identifier: "Crew A (JAJ000000001)", else "TSC5 (JAJ000000001)". A fallback GUID (a
# folder target, which has no serial) is truncated since it means nothing to anyone.
function Get-DeviceLabel {
    param([string]$DeviceName, [string]$DeviceId)
    $id = [string]$DeviceId
    $base = Get-DeviceFriendlyName $id
    if (-not $base) { $base = $DeviceName }
    if (-not $base) { $base = 'collector' }
    if (-not $id) { return $base }
    $shown = $id
    if ($id.Length -ge 32 -and $id -match '^[0-9a-fA-F-]+$') { $shown = $id.Substring(0, 8) }
    return ('{0} ({1})' -f $base, $shown)
}

# Every collector recorded against a profile, most recently synced first.
function Get-SyncStateEntries {
    param([string]$ProfileName)
    return @(@((Load-SyncState).entries) | Where-Object { $_.profile -eq $ProfileName } |
             Sort-Object -Property @{ Expression = { [string]$_.lastSyncUtc } } -Descending)
}

# One collector's record. Without a DeviceId, the one synced most recently.
function Get-SyncStateEntry {
    param([string]$ProfileName, [string]$DeviceId)
    $all = Get-SyncStateEntries $ProfileName
    if ($DeviceId) { return (@($all | Where-Object { [string]$_.deviceId -eq $DeviceId }) | Select-Object -First 1) }
    return (@($all) | Select-Object -First 1)
}

# Replace the record for this profile AND device -- every other collector tracked
# under the same profile keeps its own record.
function Remove-SyncStateEntry {
    param([string]$ProfileName, [string]$DeviceId)
    $st = Load-SyncState
    $st.entries = @(@($st.entries) | Where-Object {
        -not ($_.profile -eq $ProfileName -and [string]$_.deviceId -eq [string]$DeviceId)
    })
    Save-SyncState $st
}

function Set-SyncStateEntry {
    param([pscustomobject]$Entry)
    $st = Load-SyncState
    $st.entries = @(@($st.entries) | Where-Object {
        -not ($_.profile -eq $Entry.profile -and [string]$_.deviceId -eq [string]$Entry.deviceId)
    }) + $Entry
    Save-SyncState $st
}

function New-DeviceMarker {
    param([string]$DeviceId, [string]$DeviceName, [string]$DeviceSerial, [string]$FriendlyName, [pscustomobject]$LastSync)
    [pscustomobject]@{
        app           = 'SyncDataCollector'
        markerVersion = 2
        deviceId      = $DeviceId
        deviceName    = $DeviceName
        deviceSerial  = $DeviceSerial
        friendlyName  = $FriendlyName
        lastSync      = $LastSync
    }
}

# Read the marker at a target root. Returns a pscustomobject or $null; never throws.
function Read-DeviceMarker {
    param($Ctx, [string]$Kind, [string]$RootPath)
    $path = $RootPath + '\' + $script:MarkerName
    try {
        if ($Kind -eq 'fs') {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
            return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        $info = Get-MtpInfo $Ctx $path
        if (-not $info) { return $null }
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sdc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        try {
            $local = Join-Path $tmpDir $script:MarkerName
            Copy-FileMtpDownload $Ctx $info.Item $local ([long]$info.Length) $false
            return (Get-Content -LiteralPath $local -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { return $null }
}

# Write/refresh the marker at a target root. Best-effort; $true when it landed.
function Write-DeviceMarker {
    param($Ctx, [string]$Kind, [string]$RootPath, [pscustomobject]$Marker)
    $path = $RootPath + '\' + $script:MarkerName
    try {
        $json = $Marker | ConvertTo-Json -Depth 6
        if ($Kind -eq 'fs') {
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8
            return $true
        }
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sdc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        try {
            $local = Join-Path $tmpDir $script:MarkerName
            Set-Content -LiteralPath $local -Value $json -Encoding UTF8
            Copy-FileMtp $Ctx $local $path $false
            return $true
        }
        finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { return $false }
}

# After a completed sync: refresh the marker on the target and this install's
# sync-state.json. Best-effort -- a marker we cannot write is logged, not fatal.
function Update-SyncRecords {
    param($Ctx, [string]$DstKind, [string]$DstPath, $Profile, [string]$Direction,
          [string]$DeviceName, [int]$Total, [int]$Copied, [int]$Failed, $NewestUtc, [scriptblock]$OnLog)

    $stamp = Format-Utc ([datetime]::UtcNow)

    # Identity, best first: the hardware serial (stable, meaningful, known before the
    # first sync, survives a wipe), then whatever the marker already carried, then a
    # fresh GUID for targets that have no serial at all (a USB stick).
    $existing = Read-DeviceMarker $Ctx $DstKind $DstPath
    $priorId = ''
    if ($existing -and $existing.PSObject.Properties['deviceId'] -and $existing.deviceId) { $priorId = [string]$existing.deviceId }
    $serial = ''
    if ($Ctx.ContainsKey('DeviceSerial')) { $serial = [string]$Ctx.DeviceSerial }

    $deviceId = $serial
    if (-not $deviceId) { $deviceId = $priorId }
    if (-not $deviceId) { $deviceId = [guid]::NewGuid().ToString() }

    # Promoting a GUID-identified collector to its real serial: retire the old record
    # so one physical unit does not show up twice in the fleet list.
    if ($priorId -and $deviceId -ne $priorId) {
        Remove-SyncStateEntry ([string]$Profile.name) $priorId
        & $OnLog "Device identity upgraded to hardware serial $deviceId (was $priorId)." 'INFO'
    }

    $last = [pscustomobject]@{
        utc = $stamp; profile = [string]$Profile.name; direction = $Direction
        copied = $Copied; failed = $Failed; total = $Total
    }
    # The marker identifies the COLLECTOR, so it only belongs on a push target. On a
    # pull the destination is a shared cloud folder every collector writes into --
    # each one would clobber the last, leaving a meaningless file in a team folder.
    # Identity on pull comes from the hardware serial instead.
    if ($Direction -eq 'pull') {
        & $OnLog 'Pull: no marker written to the export destination (it is shared; identity comes from the serial).' 'INFO'
    }
    else {
        $marker = New-DeviceMarker -DeviceId $deviceId -DeviceName $DeviceName -DeviceSerial $serial `
                    -FriendlyName (Get-DeviceFriendlyName $deviceId) -LastSync $last
        if (Write-DeviceMarker $Ctx $DstKind $DstPath $marker) {
            & $OnLog "Marker updated on target ($script:MarkerName, device $deviceId)." 'INFO'
        }
        else {
            & $OnLog "Could not write $script:MarkerName on the target; offline checks fall back to this PC record." 'WARN'
        }
    }

    $newestStr = ''
    if ($NewestUtc) { $newestStr = Format-Utc $NewestUtc }
    Set-SyncStateEntry ([pscustomobject]@{
        profile         = [string]$Profile.name
        direction       = $Direction
        deviceName      = $DeviceName
        deviceId        = $deviceId
        deviceSerial    = $serial
        deviceLabel     = (Get-DeviceLabel $DeviceName $deviceId)
        destinationPath = $DstPath
        lastSyncUtc     = $stamp
        sourceFileCount = $Total
        sourceNewestUtc = $newestStr
        copied          = $Copied
        failed          = $Failed
    })
}

# Can we reach the collector side of this profile right now? The collector is the
# destination on push and the source on pull.  Returns @{ Ok; Reason }.
function Test-CollectorReachable {
    param($Profile)
    $direction = 'push'
    if ($Profile.PSObject.Properties['direction'] -and $Profile.direction) { $direction = [string]$Profile.direction }

    if ([string]$Profile.targetType -eq 'mtp') {
        $dev = [string]$Profile.deviceName
        try {
            $names = @(Get-MtpDeviceNames)
            if ($names -contains $dev) { return @{ Ok = $true; Reason = '' } }
            return @{ Ok = $false; Reason = "MTP device '$dev' is not connected." }
        }
        catch { return @{ Ok = $false; Reason = "MTP devices could not be listed: $($_.Exception.Message)" } }
    }

    if ($direction -eq 'pull') {
        # The collector is the source; we have to read it to say anything at all.
        $p = (Expand-PathTokens ([string]$Profile.sourcePath)).Trim().TrimEnd('\')
        if ($p -and (Test-Path -LiteralPath $p)) { return @{ Ok = $true; Reason = '' } }
        return @{ Ok = $false; Reason = "Collector folder not found: '$p'." }
    }

    # Push to a folder: the destination may not exist yet on a first sync, so the
    # stick counts as reachable when its root is there (everything is then "new").
    $p = (Expand-PathTokens ([string]$Profile.destinationPath)).Trim().TrimEnd('\')
    if ($p -and (Test-Path -LiteralPath $p)) { return @{ Ok = $true; Reason = '' } }
    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($p) } catch {}
    if ($root -and (Test-Path -LiteralPath $root)) { return @{ Ok = $true; Reason = '' } }
    return @{ Ok = $false; Reason = "Destination drive not found: '$p'." }
}

# "Does this collector need a re-sync?" -- the entry point behind the Check button.
#   collector reachable -> live comparison (Invoke-Sync -CheckOnly): exact, writes nothing.
#   not reachable       -> compare the source against what the last sync recorded
#                          here, so the question still gets a useful answer.
# Returns @{ Mode = 'live'|'offline'|'unknown'; OutOfDate = <int, -1 = unknown>;
#            Total = <int>; Summary = <string> }.
function Invoke-SyncCheck {
    param(
        [pscustomobject]$Profile,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [scriptblock]$OnChooseDevice
    )

    $direction = 'push'
    if ($Profile.PSObject.Properties['direction'] -and $Profile.direction) { $direction = [string]$Profile.direction }
    $label = [string]$Profile.deviceName
    if (-not $label) { $label = 'the collector' }

    $reach = Test-CollectorReachable $Profile
    if ($reach.Ok) {
        # Work out WHICH collector this is before comparing. For MTP the hardware serial
        # answers that outright -- no marker needed, so even a brand-new unit is known.
        # For a folder target (a USB stick) the marker is all there is.
        $seenId = ''
        if ([string]$Profile.targetType -eq 'mtp') {
            try {
                $dev = Resolve-CollectorDevice ([string]$Profile.deviceName) '' $OnChooseDevice
                $seenId = [string]$dev.Serial
            }
            catch { & $OnLog $_.Exception.Message 'WARN' }
        }
        elseif ($direction -eq 'push') {
            $idCtx  = @{ DeviceName = [string]$Profile.deviceName; Settings = $script:Config.mtp; FolderCache = @{} }
            $idRoot = (Expand-PathTokens ([string]$Profile.destinationPath)).Trim().TrimEnd('\')
            $mk = Read-DeviceMarker $idCtx 'fs' $idRoot
            if ($mk -and $mk.PSObject.Properties['deviceId'] -and $mk.deviceId) { $seenId = [string]$mk.deviceId }
        }
        if ($seenId) {
            $label = Get-DeviceLabel ([string]$Profile.deviceName) $seenId
            $prior = Get-SyncStateEntry ([string]$Profile.name) $seenId
            if ($prior) {
                $pw = Parse-Utc ([string]$prior.lastSyncUtc)
                $pwTxt = 'an unknown time'
                if ($pw) { $pwTxt = Format-Local $pw }
                & $OnLog "Collector identified: $label (this profile last synced it $pwTxt)." 'INFO'
            }
            else {
                & $OnLog "Collector identified: $label - this profile has NOT synced this particular unit before." 'WARN'
            }
        }
        else {
            & $OnLog 'This unit reports no serial and carries no marker, so it cannot be told apart from others of the same name.' 'WARN'
        }

        $res = Invoke-Sync -Profile $Profile -OnLog $OnLog -OnProgress $OnProgress -CheckOnly -OnChooseDevice $OnChooseDevice
        $n = @($res.OutOfDate).Count
        if ($n -eq 0) { $summary = "Up to date - $($res.Total) file(s) checked on $label, none out of date." }
        else          { $summary = "NEEDS SYNC - $n of $($res.Total) file(s) out of date on $label." }
        $pc = @($res.PruneCandidates).Count
        if ($pc -gt 0) { $summary += "  $pc extra file(s) on the device would be DELETED by a sync." }
        return @{ Mode = 'live'; OutOfDate = $n; Total = $res.Total; Summary = $summary; PruneCount = $pc }
    }

    & $OnLog $reach.Reason 'WARN'
    & $OnLog 'Falling back to the last sync recorded on this PC.' 'INFO'

    $entries = @(Get-SyncStateEntries ([string]$Profile.name))
    if ($entries.Count -eq 0) {
        return @{ Mode = 'unknown'; OutOfDate = -1; Total = 0
                  Summary = "$($reach.Reason) No sync recorded here for this profile, so there is nothing to compare against." }
    }

    if ($direction -eq 'pull') {
        # The source IS the collector, so with it unplugged there is nothing to scan.
        $e0 = $entries[0]
        $w0 = Parse-Utc ([string]$e0.lastSyncUtc)
        $w0Txt = 'an unknown time'
        if ($w0) { $w0Txt = Format-Local $w0 }
        $l0 = Get-DeviceLabel ([string]$e0.deviceName) ([string]$e0.deviceId)
        return @{ Mode = 'offline'; OutOfDate = -1; Total = 0
                  Summary = "$($reach.Reason) Last pull from $l0 was $w0Txt; connect it to see what is new." }
    }

    # Push: the source is on this PC, so we can still say WHICH units have fallen behind.
    $srcPath = (Expand-PathTokens ([string]$Profile.sourcePath)).Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $srcPath)) {
        return @{ Mode = 'unknown'; OutOfDate = -1; Total = 0
                  Summary = "$($reach.Reason) Source folder not found either: '$srcPath'." }
    }
    $exts = @()
    foreach ($x in @($Profile.extensions)) { $exts += ([string]$x).ToLowerInvariant() }
    $excl = @()
    if ($Profile.PSObject.Properties['excludeFolders']) { $excl = @($Profile.excludeFolders) }
    & $OnLog "Scanning source: $srcPath" 'INFO'
    $inv = Get-FsInventory $srcPath
    $sel = Select-SyncSet $inv.Files $inv.Dirs $exts $true $excl
    $records = @($sel.Files)

    # One source scan, then score every collector this profile has ever synced.
    # The 2s tolerance matches the live comparison: stored stamps are truncated to
    # the second, so without it a file written in the same second as the sync reads
    # as "newer" and every check right after a sync cries "needs sync".
    $behind = @(); $worst = 0
    foreach ($e in $entries) {
        $lbl = Get-DeviceLabel ([string]$e.deviceName) ([string]$e.deviceId)
        $w = Parse-Utc ([string]$e.lastSyncUtc)
        $wTxt = 'an unknown time'
        if ($w) { $wTxt = Format-Local $w }

        $modified = 0
        if ($w) {
            $cutoff = $w.AddSeconds(2)
            foreach ($r in $records) {
                if ($null -ne $r.MtimeUtc -and $r.MtimeUtc -gt $cutoff) {
                    $modified++
                    # Only worth naming files when one unit is tracked; past that the
                    # per-collector summary is what you actually read.
                    if ($entries.Count -eq 1) { & $OnLog ("CHANGED SINCE  $($r.Rel)") 'COPY' }
                }
            }
        }
        $added = [Math]::Max(0, $records.Count - [int]$e.sourceFileCount)
        # The two signals overlap -- a newly added file usually has a fresh timestamp
        # too. Take the larger rather than the sum: `added` only adds information when
        # files arrived carrying timestamps older than the sync.
        $score = [Math]::Max($modified, $added)
        if ($score -gt $worst) { $worst = $score }

        if ($score -eq 0) {
            & $OnLog "  $lbl - up to date as of $wTxt" 'INFO'
        }
        else {
            $bits = @()
            if ($modified -gt 0) { $bits += "$modified changed" }
            if ($added -gt 0)    { $bits += "$added more than last time" }
            $behind += ('{0} (last sync {1}: {2})' -f $lbl, $wTxt, ($bits -join ', '))
            & $OnLog "  $lbl - NEEDS SYNC (last sync $wTxt : $($bits -join ', '))" 'COPY'
        }
    }

    if ($behind.Count -eq 0) {
        $summary = "Probably up to date - all $($entries.Count) tracked collector(s) current with the source. Connect one to be sure."
        return @{ Mode = 'offline'; OutOfDate = 0; Total = $records.Count; Summary = $summary }
    }
    $summary = "NEEDS SYNC - $($behind.Count) of $($entries.Count) tracked collector(s) behind: " + ($behind -join '; ') + '.'
    return @{ Mode = 'offline'; OutOfDate = $worst; Total = $records.Count; Summary = $summary }
}

# --------------------------------------------------------------------------
# Projects and collectors
#
# The unit of configuration is a COLLECTOR, identified by its hardware serial.
# Plug one in and the tool locks to that collector's settings. A collector never
# falls back to another's config: an unrecognised serial is refused outright, so
# adding a fourth controller can never quietly load the wrong setup onto it.
#
# Orthogonal to that is the PROJECT -- the design source, the OneDrive export
# root, and where the project lives on the collector. One project is active at a
# time and every collector follows it. A site may keep one project for years, but
# the two axes are genuinely independent, so they are modelled that way.
#
# A collector run is two one-way legs, never a merge:
#   design : project design folder -> collector   (mirrored: exclusions + prune)
#   export : collector Exports folder -> OneDrive (additive: NEVER prunes)
# --------------------------------------------------------------------------

function New-Project {
    param(
        [string]$Name = 'New project',
        [string]$DesignSource = '',        # S:\02-DESIGN
        [string]$ExportRoot = '',          # ...\07-DATALOGGER BACKUP\{year}\{month}
        [string]$DeviceProjectPath = ''    # Internal shared storage\Trimble Data\Projects\2100 - EXAMPLE SITE
    )
    [pscustomobject]@{
        name              = $Name
        designSource      = $DesignSource
        exportRoot        = $ExportRoot
        deviceProjectPath = $DeviceProjectPath
    }
}

# --------------------------------------------------------------------------
# Defaults
#
# Every collector is set up the same way in practice, so the shared settings
# live once in config.json under "defaults" and each new collector is seeded
# from them. A collector can still be tuned individually, but that stays with
# that collector: nothing in the GUI writes the baseline, so changing it means
# editing config.json by hand. That is on purpose -- the person tweaking a
# setting to get one controller working is rarely the person setting policy.
# New-CollectorDefaults holds the factory values -- the fallback when config
# has no defaults block, and what a fresh config is written with.
# --------------------------------------------------------------------------
function New-CollectorDefaults {
    param(
        [string]$DesignSubPath = '02-Design',
        [string]$ExportSubPath = 'Exports',
        [string[]]$DesignExtensions = @('.csv', '.dxf', '.xml', '.ttm'),
        [string[]]$ExportExtensions = @('.job', '.jxl', '.csv', '.dxf', '.rxl', '.xml'),
        [string[]]$ExcludeFolders = @('SUPERSEDED'),
        [bool]$Prune = $true,                # the design folder is owned by the tool
        [string]$ExportCollision = 'prefix'  # prefix | deviceSubfolder | overwrite
    )
    [pscustomobject]@{
        designSubPath    = $DesignSubPath
        exportSubPath    = $ExportSubPath
        designExtensions = $DesignExtensions
        exportExtensions = $ExportExtensions
        excludeFolders   = $ExcludeFolders
        prune            = $Prune
        exportCollision  = $ExportCollision
    }
}

# Overlay a config's "defaults" block on the factory values. Presence of a key
# is what counts, not truthiness -- an empty exclude list or a blank subfolder
# is a real choice, so it must survive. A missing or unreadable block just
# leaves the factory value in place.
function Resolve-Defaults {
    param($Raw)
    $f = New-CollectorDefaults
    if (-not $Raw) { return $f }
    $has = { param($n) $null -ne $Raw.PSObject.Properties[$n] }
    # Each value is settled in a variable before the call. An empty array inside
    # $( ) collapses to nothing and binds as $null, which [string[]] then widens
    # to @('') -- so "no exclusions at all" would come back as one blank entry.
    $designSub = $f.designSubPath
    $exportSub = $f.exportSubPath
    $designExt = $f.designExtensions
    $exportExt = $f.exportExtensions
    $exclude   = $f.excludeFolders
    $prune     = $f.prune
    $collision = $f.exportCollision
    if (& $has 'designSubPath')    { $designSub = [string]$Raw.designSubPath }
    if (& $has 'exportSubPath')    { $exportSub = [string]$Raw.exportSubPath }
    if (& $has 'designExtensions') { $designExt = [string[]]@($Raw.designExtensions) }
    if (& $has 'exportExtensions') { $exportExt = [string[]]@($Raw.exportExtensions) }
    if (& $has 'excludeFolders')   { $exclude   = [string[]]@($Raw.excludeFolders) }
    if (& $has 'prune')            { $prune     = [bool]$Raw.prune }
    if (& $has 'exportCollision')  { $collision = [string]$Raw.exportCollision }
    New-CollectorDefaults -DesignSubPath $designSub -ExportSubPath $exportSub `
        -DesignExtensions $designExt -ExportExtensions $exportExt -ExcludeFolders $exclude `
        -Prune $prune -ExportCollision $collision
}

# The defaults in force right now.
function Get-Defaults {
    $raw = $null
    if ($script:Config -and $script:Config.PSObject.Properties['defaults']) { $raw = $script:Config.defaults }
    return (Resolve-Defaults $raw)
}

function New-Collector {
    param(
        [string]$Serial = '',
        [string]$Name = '',                  # friendly name; blank falls back to model+serial
        [string]$Model = 'TSC5',             # the MTP name several units share
        [string]$Type = 'mtp',               # mtp | folder (a Windows tablet running this app)
        [string]$DesignSubPath = (Get-Defaults).designSubPath,
        [string]$ExportSubPath = (Get-Defaults).exportSubPath,
        [string[]]$DesignExtensions = (Get-Defaults).designExtensions,
        [string[]]$ExportExtensions = (Get-Defaults).exportExtensions,
        [string[]]$ExcludeFolders = (Get-Defaults).excludeFolders,
        [bool]$Prune = (Get-Defaults).prune,
        [string]$ExportCollision = (Get-Defaults).exportCollision
    )
    [pscustomobject]@{
        serial           = $Serial
        name             = $Name
        model            = $Model
        type             = $Type
        designSubPath    = $DesignSubPath
        exportSubPath    = $ExportSubPath
        designExtensions = $DesignExtensions
        exportExtensions = $ExportExtensions
        excludeFolders   = $ExcludeFolders
        prune            = $Prune
        exportCollision  = $ExportCollision
    }
}

function Get-ActiveProject {
    $projects = @($script:Config.projects)
    if ($projects.Count -eq 0) { return $null }
    $name = [string]$script:Config.activeProject
    $p = @($projects | Where-Object { $_.name -eq $name }) | Select-Object -First 1
    if ($p) { return $p }
    return $projects[0]
}

function Get-CollectorBySerial {
    param([string]$Serial)
    if (-not $Serial) { return $null }
    return (@(@($script:Config.collectors) | Where-Object { [string]$_.serial -eq $Serial }) | Select-Object -First 1)
}

# How a collector reads in the UI and the log.
function Get-CollectorLabel {
    param($Collector)
    $n = [string]$Collector.name
    if ($n) { return ('{0} ({1})' -f $n, [string]$Collector.serial) }
    return (Get-DeviceLabel ([string]$Collector.model) ([string]$Collector.serial))
}

# Folder-safe name for the per-collector export subfolder. Two crews exporting the
# same filename must never land on each other, so this has to be stable and unique.
function Get-CollectorFolderName {
    param($Collector)
    $n = [string]$Collector.name
    if (-not $n) { $n = [string]$Collector.serial }
    if (-not $n) { $n = [string]$Collector.model }
    return (($n -replace '[\\/:*?"<>|]', '-').Trim())
}

# Build a profile the sync engine already understands, for one leg of a run. This
# is the ONLY place the collector model touches the engine -- the engine, and every
# test around it, stays exactly as it was.
function New-LegProfile {
    param($Project, $Collector, [string]$Leg)

    $devRoot = ([string]$Project.deviceProjectPath).Trim().TrimEnd('\')
    $model   = [string]$Collector.model
    $type    = [string]$Collector.type
    $label   = Get-CollectorLabel $Collector

    if ($Leg -eq 'design') {
        # PC -> collector, mirrored: the tool owns this folder.
        return New-Profile -Name ("$label - design") -Direction 'push' `
            -SourcePath ([string]$Project.designSource) `
            -TargetType $type -DeviceName $model `
            -DestinationPath ($devRoot + '\' + ([string]$Collector.designSubPath).Trim('\')) `
            -Extensions @($Collector.designExtensions) `
            -ExcludeFolders @($Collector.excludeFolders) `
            -Prune ([bool]$Collector.prune)
    }

    # collector -> OneDrive, additive. Every collector exports into the SAME dated
    # folder, so files must carry which unit they came from or two crews exporting
    # 2100-25-346.csv collide (and OneDrive makes conflict copies).
    #   prefix          -> TSC5-01_2100-25-346.csv in one flat month folder
    #   deviceSubfolder -> TSC5-01\2100-25-346.csv
    # deviceName still has to be the MTP model name so the device can be found; the
    # per-collector label is separate, which is why collisionLabel exists.
    $coll = [string]$Collector.exportCollision
    if (-not $coll) { $coll = 'prefix' }
    $p = New-Profile -Name ("$label - export") -Direction 'pull' `
        -SourcePath ($devRoot + '\' + ([string]$Collector.exportSubPath).Trim('\')) `
        -TargetType $type -DeviceName $model `
        -DestinationPath ([string]$Project.exportRoot) `
        -CollisionMode $coll `
        -Extensions @($Collector.exportExtensions) `
        -ExcludeFolders @() -Prune $false
    $p | Add-Member -NotePropertyName collisionLabel -NotePropertyValue (Get-CollectorFolderName $Collector) -Force
    return $p
}

# One collector, both legs. Design first so a crew heading out has current drawings;
# exports second so nothing they collected is left behind. A failed leg does NOT stop
# the other -- getting field data off the device matters more than either leg alone.
function Invoke-CollectorSync {
    param(
        $Project, $Collector,
        [scriptblock]$OnLog, [scriptblock]$OnProgress,
        [switch]$CheckOnly, [scriptblock]$OnChooseDevice
    )
    $label = Get-CollectorLabel $Collector
    $verb  = if ($CheckOnly) { 'CHECK' } else { 'SYNC' }
    & $OnLog "===== $verb $label  (project: $($Project.name)) =====" 'INFO'

    $legs = @(
        @{ Key = 'design'; Title = 'Design  PC -> collector (mirrored)' }
        @{ Key = 'export'; Title = 'Export  collector -> OneDrive (additive)' }
    )
    $copied = 0; $pruned = 0; $failed = 0; $legErrors = @(); $lines = @()

    foreach ($leg in $legs) {
        if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
        & $OnLog "--- $($leg.Title) ---" 'INFO'
        $p = New-LegProfile $Project $Collector $leg.Key
        try {
            if ($CheckOnly) {
                $r = Invoke-SyncCheck -Profile $p -OnLog $OnLog -OnProgress $OnProgress -OnChooseDevice $OnChooseDevice
                $lines += ("{0}: {1}" -f $leg.Key, $r.Summary)
            }
            else {
                $r = Invoke-Sync -Profile $p -OnLog $OnLog -OnProgress $OnProgress -OnChooseDevice $OnChooseDevice
                $copied += [int]$r.Copied; $pruned += [int]$r.Pruned; $failed += [int]$r.Failed
                $d = ''
                if ([int]$r.Pruned -gt 0) { $d = ", deleted $($r.Pruned)" }
                $lines += ("{0}: copied {1}{2}, skipped {3}, failed {4}" -f $leg.Key, $r.Copied, $d, $r.Skipped, $r.Failed)
            }
        }
        catch {
            $failed++
            $legErrors += ("{0}: {1}" -f $leg.Key, $_.Exception.Message)
            & $OnLog ("$($leg.Key) leg FAILED :: $($_.Exception.Message)") 'ERROR'
            & $OnLog 'Carrying on with the next leg.' 'WARN'
        }
    }

    $summary = "$label - " + ($lines -join '  |  ')
    if ($legErrors.Count) { $summary += '  [' + ($legErrors -join '; ') + ']' }
    return [pscustomobject]@{
        Collector = $label; Copied = $copied; Pruned = $pruned; Failed = $failed
        Lines = $lines; Errors = $legErrors; Summary = $summary; CheckOnly = [bool]$CheckOnly
    }
}

# What is plugged in, split into collectors we know and ones we do not. An unknown
# serial is never matched to an existing collector -- that is the whole safety story
# for adding controllers later.
function Get-ConnectedCollectors {
    $devs = @(Get-MtpDevices | Where-Object { $_.Serial })
    $known = @(); $unknown = @()
    foreach ($d in $devs) {
        $c = Get-CollectorBySerial $d.Serial
        if ($c) { $known += [pscustomobject]@{ Device = $d; Collector = $c } }
        else    { $unknown += $d }
    }
    return @{ Known = @($known); Unknown = @($unknown); All = @($devs) }
}

# Turn a connected but unrecognised device into a collector entry, seeded from the
# active project's shape so it is usable immediately.
function Register-Collector {
    param($Device, [string]$FriendlyName)
    $c = New-Collector -Serial ([string]$Device.Serial) -Name $FriendlyName `
            -Model ([string]$Device.Name) -Type 'mtp'
    $script:Config.collectors = @(@($script:Config.collectors) + $c)
    return $c
}

# --------------------------------------------------------------------------
# Sync engine
# --------------------------------------------------------------------------
function Invoke-Sync {
    param(
        [pscustomobject]$Profile,
        [scriptblock]$OnLog,        # param($msg, $level)
        [scriptblock]$OnProgress,   # param($current, $total)
        [switch]$CheckOnly,         # compare only: no copies, no folders, no marker
        [scriptblock]$OnChooseDevice # param($candidates) -> one of them, when several match
    )

    $direction     = if ($Profile.PSObject.Properties['direction'] -and $Profile.direction) { [string]$Profile.direction } else { 'push' }
    $collectorType = [string]$Profile.targetType    # folder | mtp
    $collisionMode = if ($Profile.PSObject.Properties['collisionMode'] -and $Profile.collisionMode) { [string]$Profile.collisionMode } else { 'deviceSubfolder' }
    $deviceName    = [string]$Profile.deviceName
    # The label used to separate one collector's pulled files from another's. Distinct
    # from deviceName, which must stay the MTP model name so the device can be found.
    $collisionLabel = $deviceName
    if ($Profile.PSObject.Properties['collisionLabel'] -and $Profile.collisionLabel) { $collisionLabel = [string]$Profile.collisionLabel }
    if ($collectorType -ne 'folder' -and $collectorType -ne 'mtp') { throw "Unknown collector type '$collectorType'." }
    $collectorKind = if ($collectorType -eq 'mtp') { 'mtp' } else { 'fs' }

    # Which end is source, which is destination.
    if ($direction -eq 'pull') { $srcKind = $collectorKind; $dstKind = 'fs' }
    else                       { $srcKind = 'fs';           $dstKind = $collectorKind }

    $modeNote = ''
    if ($CheckOnly) { $modeNote = ', CHECK ONLY - nothing will be written' }
    & $OnLog "Profile '$($Profile.name)'  ($direction, collector=$collectorType$modeNote)" 'INFO'

    # Endpoint paths (support the {julian} token).
    $srcPath = (Expand-PathTokens $Profile.sourcePath).Trim().TrimEnd('\')
    $dstPath = (Expand-PathTokens $Profile.destinationPath).Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($srcPath)) { throw 'Source path is empty.' }
    if ([string]::IsNullOrWhiteSpace($dstPath)) { throw 'Destination path is empty.' }

    $exts = @()
    foreach ($e in @($Profile.extensions)) { $exts += ([string]$e).ToLowerInvariant() }
    if (-not $exts) { throw 'No file extensions configured for this profile.' }

    $excludeFolders = @()
    if ($Profile.PSObject.Properties['excludeFolders']) { $excludeFolders = @($Profile.excludeFolders) }
    if ($excludeFolders.Count) { & $OnLog ("Excluding folder(s): " + ($excludeFolders -join ', ')) 'INFO' }

    # Prune is push-only: on a pull the destination holds field data pulled from other
    # collectors and earlier days, and the source can never account for it.
    $prune = $false
    if ($Profile.PSObject.Properties['prune']) { $prune = [bool]$Profile.prune }
    if ($prune -and $direction -ne 'push') {
        & $OnLog 'Prune is ignored on pull: the destination collects field data the source cannot account for.' 'WARN'
        $prune = $false
    }
    if ($prune) { & $OnLog 'Prune ON - files at the destination that the source does not account for will be DELETED.' 'WARN' }

    # Pulls never overwrite. Exported field data cannot be re-collected, so a name
    # clash writes a new file next to the old one rather than replacing it. Pushes
    # keep overwriting: the design source is the authority there.
    $neverOverwrite = ($direction -eq 'pull')
    if ($Profile.PSObject.Properties['neverOverwrite']) { $neverOverwrite = [bool]$Profile.neverOverwrite }

    $ctx = @{ DeviceName = $deviceName; Settings = $script:Config.mtp; FolderCache = @{} }
    try {
        # Prepare the MTP side (whichever end it is).
        if ($srcKind -eq 'mtp' -or $dstKind -eq 'mtp') {
            if ([string]::IsNullOrWhiteSpace($deviceName)) { throw 'This profile uses MTP but no device name is set.' }
            Ensure-MtpInterop
            & $OnLog "Locating MTP device '$deviceName'..." 'INFO'
            $dev = Resolve-CollectorDevice $deviceName '' $OnChooseDevice
            # Pin the ctx to THIS device item so every later lookup walks the right unit.
            $ctx.DeviceItem   = $dev.Item
            $ctx.DeviceSerial = $dev.Serial
            if ($dev.Serial) { & $OnLog "Device found: $(Get-DeviceLabel $deviceName $dev.Serial)" 'INFO' }
            else             { & $OnLog 'Device found (no hardware serial reported).' 'WARN' }
        }
        # Validate a filesystem source up front (MTP source absence is handled in enumeration).
        if ($srcKind -eq 'fs') {
            if (-not (Test-Path -LiteralPath $srcPath)) { throw "Source folder not found: '$srcPath'" }
            $srcPath = (Get-Item -LiteralPath $srcPath).FullName.TrimEnd('\')
        }

        # Per-device subfolder / prefix (pull only) needs a device name / label.
        if ($direction -eq 'pull' -and $collisionMode -in @('deviceSubfolder', 'prefix') -and [string]::IsNullOrWhiteSpace($collisionLabel)) {
            throw "Collision mode '$collisionMode' needs a device name / label (used to keep each collector's files separate)."
        }

        if ($CheckOnly) {
            & $OnLog "Comparing against destination: $dstPath" 'INFO'
        }
        else {
            & $OnLog "Ensuring destination exists: $dstPath" 'INFO'
            Target-EnsureDir $ctx $dstKind $dstPath
        }

        # Inventory ALL source files + dirs, then select what to sync (extension
        # filter + .jxl companion folders). LandXML content-check applies to push only.
        & $OnLog "Scanning source ($srcKind) ..." 'INFO'
        $rawFiles = @(); $rawDirs = @()
        if ($srcKind -eq 'fs') {
            $fsInv = Get-FsInventory $srcPath
            $rawFiles = @($fsInv.Files); $rawDirs = @($fsInv.Dirs)
        }
        else {
            $inv = Get-MtpInventory $ctx $srcPath
            foreach ($m in $inv.Files) { $rawFiles += @{ Rel = $m.Rel; Length = $m.Length; MtimeUtc = $m.MtimeUtc; Src = $m.Item; Local = $null; Ext = $m.Ext } }
            foreach ($d in $inv.Dirs)  { $rawDirs += $d }
        }
        $sel = Select-SyncSet $rawFiles $rawDirs $exts ($direction -eq 'push') $excludeFolders
        $records = @($sel.Files)
        $total = $records.Count
        $jxlNote = if ($sel.Dirs.Count) { " (+$($sel.Dirs.Count) scan subfolder(s))" } else { '' }
        $xmlNote = if ($sel.SkippedXml -gt 0) { " (excluded $($sel.SkippedXml) non-LandXML .xml)" } else { '' }
        $excNote = if ($sel.SkippedExcluded -gt 0) { " (excluded $($sel.SkippedExcluded) in excluded folder(s))" } else { '' }
        & $OnLog "Found $total matching file(s)$jxlNote$xmlNote$excNote." 'INFO'
        & $OnProgress 0 $total

        $copyMode = "$srcKind`2$dstKind"   # fs2fs | fs2mtp | mtp2fs
        if ($copyMode -eq 'mtp2mtp') { throw 'MTP-to-MTP is not supported.' }

        # Pre-create companion (scan) subfolders on the destination so even empty
        # point-cloud directories are preserved. A check writes nothing, so skip it.
        if (-not $CheckOnly) {
            foreach ($drel in $sel.Dirs) {
                $ddestRel = Get-DestRel $drel $direction $collisionMode $collisionLabel
                try { Target-EnsureDir $ctx $dstKind ($dstPath + '\' + $ddestRel) } catch {}
            }
        }

        $copied = 0; $skipped = 0; $failed = 0
        $outOfDate = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($rec in $records) {
            if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
            $i++
            $rel = $rec.Rel
            $destRel = Get-DestRel $rel $direction $collisionMode $collisionLabel
            $dest = $dstPath + '\' + $destRel
            try {
                $need = $false; $reason = ''
                $di = Target-GetInfo $ctx $dstKind $dest     # one live lookup (Length = -1 if absent)
                if ($di.Length -lt 0) { $need = $true; $reason = 'new' }
                elseif ([long]$rec.Length -ne $di.Length) { $need = $true; $reason = 'size changed' }
                elseif ($null -ne $di.Mtime -and $null -ne $rec.MtimeUtc -and $rec.MtimeUtc -gt $di.Mtime.AddSeconds(2)) { $need = $true; $reason = 'source newer' }

                # Pulled field data is irreplaceable: never write over a different file
                # that is already there. Land alongside it under a "(n)" name instead.
                if ($need -and $neverOverwrite -and $di.Length -ge 0) {
                    $alt = Resolve-NoOverwriteDest $ctx $dstKind $dest ([long]$rec.Length) $rec.MtimeUtc
                    if ($alt.Skip) {
                        $need = $false
                        $destRel = $alt.Path.Substring($dstPath.Length).TrimStart('\')
                    }
                    elseif ($alt.Path -ne $dest) {
                        $dest = $alt.Path
                        $destRel = $dest.Substring($dstPath.Length).TrimStart('\')
                        $reason = 'kept alongside existing'
                    }
                }

                if ($need) { [void]$outOfDate.Add([pscustomobject]@{ Rel = $destRel; Reason = $reason }) }

                if ($CheckOnly) {
                    # Report only. Stay quiet about the files that are fine, so what
                    # actually needs syncing stands out in the log.
                    if ($need) { & $OnLog ("OUT OF DATE ($reason)  $destRel") 'COPY' }
                    else       { $skipped++ }
                }
                elseif ($need) {
                    Invoke-CopyWithRetry $ctx $copyMode $rec.Src $dest ([long]$rec.Length) $OnLog
                    $copied++
                    & $OnLog ("COPIED  ($reason)  $destRel") 'COPY'
                }
                else {
                    $skipped++
                    & $OnLog ("skip           $destRel") 'SKIP'
                }
            }
            catch {
                $failed++
                & $OnLog ("FAILED         $rel  ::  $($_.Exception.Message)") 'ERROR'
            }
            & $OnProgress $i $total
        }

        # ---- Prune: remove what the source does not account for -------------
        $pruned = 0; $pruneSet = @{ Files = @(); Dirs = @() }
        if ($prune -and -not $script:CancelRequested) {
            & $OnLog 'Scanning the destination for files the source does not account for...' 'INFO'
            $pruneSet = Get-PruneSet $ctx $dstKind $dstPath $records $sel.Dirs $direction $collisionMode $collisionLabel
            $pf = @($pruneSet.Files); $pd = @($pruneSet.Dirs)
            if ($pf.Count -eq 0 -and $pd.Count -eq 0) {
                & $OnLog 'Nothing to prune - the destination already matches the source.' 'INFO'
            }
            elseif ($CheckOnly) {
                & $OnLog "Would DELETE $($pf.Count) file(s) and $($pd.Count) folder(s):" 'WARN'
                foreach ($f in $pf) { & $OnLog ("WOULD DELETE   $($f.Rel)") 'COPY' }
            }
            else {
                foreach ($f in $pf) {
                    try {
                        Target-DeleteFile $ctx $dstKind ($dstPath + '\' + $f.Rel) $f.Item
                        $pruned++
                        & $OnLog ("DELETED        $($f.Rel)") 'COPY'
                    }
                    catch {
                        $failed++
                        & $OnLog ("DELETE FAILED  $($f.Rel)  ::  $($_.Exception.Message)") 'ERROR'
                    }
                }
                # Folders last, deepest first, so emptied ones go too.
                foreach ($d in $pd) {
                    try {
                        Target-DeleteDir $ctx $dstKind ($dstPath + '\' + $d)
                        & $OnLog ("DELETED FOLDER $d") 'COPY'
                    }
                    catch { & $OnLog ("could not remove folder $d :: $($_.Exception.Message)") 'WARN' }
                }
            }
        }

        # Newest source timestamp, recorded so a later check can tell whether the
        # source has moved on with the collector nowhere in sight.
        $newest = $null
        foreach ($rec in $records) {
            if ($null -ne $rec.MtimeUtc -and ($null -eq $newest -or $rec.MtimeUtc -gt $newest)) { $newest = $rec.MtimeUtc }
        }

        # Only a run that actually finished describes the target, so a cancelled
        # sync leaves the previous records (and their timestamp) alone.
        if (-not $CheckOnly -and -not $script:CancelRequested) {
            Update-SyncRecords $ctx $dstKind $dstPath $Profile $direction $deviceName $total $copied $failed $newest $OnLog
        }

        return [pscustomobject]@{
            Total     = $total
            Copied    = $copied
            Skipped   = $skipped
            Failed    = $failed
            OutOfDate = @($outOfDate)
            CheckOnly = [bool]$CheckOnly
            SourceNewestUtc = $newest
            Pruned    = $pruned
            PruneCandidates = @($pruneSet.Files)
        }
    }
    finally {
        $ctx.FolderCache.Clear()
    }
}

# ==========================================================================
# GUI
# ==========================================================================
$script:Config = Load-Config

# Headless hook: when SDC_NOGUI=1 the file can be dot-sourced to reuse the
# engine/providers (and $script:Config) without building or showing the window.
if ($env:SDC_NOGUI -eq '1') { return }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Sync Data Collector'
$form.Size = New-Object System.Drawing.Size(830, 915)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(740, 755)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:CurrentProject   = $null
$script:CurrentCollector = $null
$script:LastSeenSerials  = ''
$script:Loading          = $false

# ---- Project row ----------------------------------------------------------
$lblProject = New-Object System.Windows.Forms.Label
$lblProject.Text = 'Project:'; $lblProject.Location = '15,18'; $lblProject.AutoSize = $true
$form.Controls.Add($lblProject)

$cboProject = New-Object System.Windows.Forms.ComboBox
$cboProject.Location = '75,15'; $cboProject.Size = '330,24'
$cboProject.DropDownStyle = 'DropDownList'; $cboProject.Anchor = 'Top,Left,Right'
$form.Controls.Add($cboProject)

$btnProjNew = New-Object System.Windows.Forms.Button
$btnProjNew.Text = 'New'; $btnProjNew.Location = '415,14'; $btnProjNew.Size = '60,26'; $btnProjNew.Anchor = 'Top,Right'
$form.Controls.Add($btnProjNew)

$btnProjRename = New-Object System.Windows.Forms.Button
$btnProjRename.Text = 'Rename'; $btnProjRename.Location = '480,14'; $btnProjRename.Size = '70,26'; $btnProjRename.Anchor = 'Top,Right'
$form.Controls.Add($btnProjRename)

$btnProjDelete = New-Object System.Windows.Forms.Button
$btnProjDelete.Text = 'Delete'; $btnProjDelete.Location = '555,14'; $btnProjDelete.Size = '65,26'; $btnProjDelete.Anchor = 'Top,Right'
$form.Controls.Add($btnProjDelete)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save settings'; $btnSave.Location = '625,14'; $btnSave.Size = '175,26'; $btnSave.Anchor = 'Top,Right'
$form.Controls.Add($btnSave)

# ---- Collector banner -----------------------------------------------------
# The collector is DETECTED, not chosen: plug one in and the app locks to it.
$lblCollectorCap = New-Object System.Windows.Forms.Label
$lblCollectorCap.Text = 'Collector:'; $lblCollectorCap.Location = '15,52'; $lblCollectorCap.AutoSize = $true
$form.Controls.Add($lblCollectorCap)

$lblCollector = New-Object System.Windows.Forms.Label
$lblCollector.Location = '75,52'; $lblCollector.Size = '530,20'; $lblCollector.Anchor = 'Top,Left,Right'
$lblCollector.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblCollector)

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Detect'; $btnDetect.Location = '625,48'; $btnDetect.Size = '85,26'; $btnDetect.Anchor = 'Top,Right'
$form.Controls.Add($btnDetect)

$btnNameDev = New-Object System.Windows.Forms.Button
$btnNameDev.Text = 'Rename...'; $btnNameDev.Location = '715,48'; $btnNameDev.Size = '85,26'; $btnNameDev.Anchor = 'Top,Right'
$form.Controls.Add($btnNameDev)

$lblDates = New-Object System.Windows.Forms.Label
$lblDates.Location = '15,80'; $lblDates.AutoSize = $true; $lblDates.ForeColor = 'Gray'
$form.Controls.Add($lblDates)

# Everyday use is: plug a collector in, press Sync. Setup - naming devices,
# editing paths, choosing what gets mirrored - happens once, so it hides here.
$chkAdvanced = New-Object System.Windows.Forms.CheckBox
$chkAdvanced.Text = 'Advanced'; $chkAdvanced.Location = '710,78'; $chkAdvanced.Size = '90,22'
$chkAdvanced.Anchor = 'Top,Right'; $chkAdvanced.ForeColor = 'DimGray'
$form.Controls.Add($chkAdvanced)

# ---- Project settings -----------------------------------------------------
$grpProj = New-Object System.Windows.Forms.GroupBox
$grpProj.Text = 'Project paths'; $grpProj.Location = '15,105'; $grpProj.Size = '785,140'; $grpProj.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpProj)

$lblDesignSrc = New-Object System.Windows.Forms.Label
$lblDesignSrc.Text = 'Design source:'; $lblDesignSrc.Location = '15,28'; $lblDesignSrc.AutoSize = $true
$grpProj.Controls.Add($lblDesignSrc)
$txtDesignSrc = New-Object System.Windows.Forms.TextBox
$txtDesignSrc.Location = '150,25'; $txtDesignSrc.Size = '520,24'; $txtDesignSrc.Anchor = 'Top,Left,Right'
$grpProj.Controls.Add($txtDesignSrc)
$btnDesignSrcBrowse = New-Object System.Windows.Forms.Button
$btnDesignSrcBrowse.Text = 'Browse...'; $btnDesignSrcBrowse.Location = '678,24'; $btnDesignSrcBrowse.Size = '90,26'; $btnDesignSrcBrowse.Anchor = 'Top,Right'
$grpProj.Controls.Add($btnDesignSrcBrowse)

$lblExportRoot = New-Object System.Windows.Forms.Label
$lblExportRoot.Text = 'Export root:'; $lblExportRoot.Location = '15,63'; $lblExportRoot.AutoSize = $true
$grpProj.Controls.Add($lblExportRoot)
$txtExportRoot = New-Object System.Windows.Forms.TextBox
$txtExportRoot.Location = '150,60'; $txtExportRoot.Size = '520,24'; $txtExportRoot.Anchor = 'Top,Left,Right'
$grpProj.Controls.Add($txtExportRoot)
$btnExportRootBrowse = New-Object System.Windows.Forms.Button
$btnExportRootBrowse.Text = 'Browse...'; $btnExportRootBrowse.Location = '678,59'; $btnExportRootBrowse.Size = '90,26'; $btnExportRootBrowse.Anchor = 'Top,Right'
$grpProj.Controls.Add($btnExportRootBrowse)

$lblDevProj = New-Object System.Windows.Forms.Label
$lblDevProj.Text = 'Project on device:'; $lblDevProj.Location = '15,98'; $lblDevProj.AutoSize = $true
$grpProj.Controls.Add($lblDevProj)
$txtDevProj = New-Object System.Windows.Forms.TextBox
$txtDevProj.Location = '150,95'; $txtDevProj.Size = '520,24'; $txtDevProj.Anchor = 'Top,Left,Right'
$grpProj.Controls.Add($txtDevProj)
$lblTokenHint = New-Object System.Windows.Forms.Label
$lblTokenHint.Location = '150,118'; $lblTokenHint.Size = '620,18'; $lblTokenHint.ForeColor = 'Gray'
$lblTokenHint.Anchor = 'Top,Left,Right'
$grpProj.Controls.Add($lblTokenHint)

# ---- Collector settings ---------------------------------------------------
$grpColl = New-Object System.Windows.Forms.GroupBox
$grpColl.Text = 'This collector'; $grpColl.Location = '15,255'; $grpColl.Size = '785,240'; $grpColl.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpColl)

$lblDesignSub = New-Object System.Windows.Forms.Label
$lblDesignSub.Text = 'Design folder:'; $lblDesignSub.Location = '15,28'; $lblDesignSub.AutoSize = $true
$grpColl.Controls.Add($lblDesignSub)
$txtDesignSub = New-Object System.Windows.Forms.TextBox
$txtDesignSub.Location = '150,25'; $txtDesignSub.Size = '200,24'
$grpColl.Controls.Add($txtDesignSub)
$lblExportSub = New-Object System.Windows.Forms.Label
$lblExportSub.Text = 'Export folder:'; $lblExportSub.Location = '380,28'; $lblExportSub.AutoSize = $true
$grpColl.Controls.Add($lblExportSub)
$txtExportSub = New-Object System.Windows.Forms.TextBox
$txtExportSub.Location = '480,25'; $txtExportSub.Size = '200,24'
$grpColl.Controls.Add($txtExportSub)

$lblDesignExt = New-Object System.Windows.Forms.Label
$lblDesignExt.Text = 'Design types:'; $lblDesignExt.Location = '15,63'; $lblDesignExt.AutoSize = $true
$grpColl.Controls.Add($lblDesignExt)
$txtDesignExt = New-Object System.Windows.Forms.TextBox
$txtDesignExt.Location = '150,60'; $txtDesignExt.Size = '530,24'; $txtDesignExt.Anchor = 'Top,Left,Right'
$grpColl.Controls.Add($txtDesignExt)

$lblExportExt = New-Object System.Windows.Forms.Label
$lblExportExt.Text = 'Export types:'; $lblExportExt.Location = '15,98'; $lblExportExt.AutoSize = $true
$grpColl.Controls.Add($lblExportExt)
$txtExportExt = New-Object System.Windows.Forms.TextBox
$txtExportExt.Location = '150,95'; $txtExportExt.Size = '530,24'; $txtExportExt.Anchor = 'Top,Left,Right'
$grpColl.Controls.Add($txtExportExt)

$lblExcl = New-Object System.Windows.Forms.Label
$lblExcl.Text = 'Skip folders:'; $lblExcl.Location = '15,133'; $lblExcl.AutoSize = $true
$grpColl.Controls.Add($lblExcl)
$txtExcl = New-Object System.Windows.Forms.TextBox
$txtExcl.Location = '150,130'; $txtExcl.Size = '200,24'
$grpColl.Controls.Add($txtExcl)
$lblColl2 = New-Object System.Windows.Forms.Label
$lblColl2.Text = 'Export naming:'; $lblColl2.Location = '380,133'; $lblColl2.AutoSize = $true
$grpColl.Controls.Add($lblColl2)
$cboExportCollision = New-Object System.Windows.Forms.ComboBox
$cboExportCollision.Location = '480,130'; $cboExportCollision.Size = '200,24'; $cboExportCollision.DropDownStyle = 'DropDownList'
[void]$cboExportCollision.Items.Add('prefix'); [void]$cboExportCollision.Items.Add('deviceSubfolder'); [void]$cboExportCollision.Items.Add('overwrite')
$grpColl.Controls.Add($cboExportCollision)

$chkPrune = New-Object System.Windows.Forms.CheckBox
$chkPrune.Text = 'Mirror the design folder: DELETE anything on the collector the source does not have'
$chkPrune.Location = '150,163'; $chkPrune.Size = '600,22'
$chkPrune.ForeColor = [System.Drawing.Color]::FromArgb(160, 0, 0)
$grpColl.Controls.Add($chkPrune)

$btnResetDefaults = New-Object System.Windows.Forms.Button
$btnResetDefaults.Text = 'Reset to defaults'; $btnResetDefaults.Location = '150,196'; $btnResetDefaults.Size = '150,28'
$grpColl.Controls.Add($btnResetDefaults)

$lblDefaults = New-Object System.Windows.Forms.Label
$lblDefaults.Location = '312,202'; $lblDefaults.Size = '458,18'; $lblDefaults.ForeColor = 'Gray'
$grpColl.Controls.Add($lblDefaults)

# ---- Actions --------------------------------------------------------------
$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'Sync this collector'; $btnSync.Location = '15,512'; $btnSync.Size = '190,38'
$btnSync.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSync)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check'; $btnCheck.Location = '212,512'; $btnCheck.Size = '95,38'
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($btnCheck, 'Report what both legs would do. Writes nothing, deletes nothing.')
$tip.SetToolTip($btnSave, "Write the project paths above and this collector's settings to config.json." + [Environment]::NewLine +
    'Nothing is saved until you press this.')
$tip.SetToolTip($btnResetDefaults, 'Put this collector back on the defaults. Affects this collector only -' + [Environment]::NewLine +
    'the defaults themselves are read-only here, and live in config.json.')
$form.Controls.Add($btnCheck)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = '314,512'; $btnCancel.Size = '85,38'; $btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '410,520'; $progress.Size = '390,22'; $progress.Anchor = 'Top,Left,Right'
$form.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready.'; $lblStatus.Location = '15,559'; $lblStatus.Size = '785,20'; $lblStatus.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = '15,585'; $txtLog.Size = '785,270'
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.BackColor = 'White'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($txtLog)

# --------------------------------------------------------------------------
# UI logic
# --------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    $txtLog.AppendText($line + "`r`n")
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Prompt-Text {
    param([string]$Title, [string]$Message, [string]$Default = '')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = '440,160'; $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message; $lbl.Location = '15,15'; $lbl.Size = '400,20'
    $dlg.Controls.Add($lbl)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Default; $tb.Location = '15,45'; $tb.Size = '400,24'
    $dlg.Controls.Add($tb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = '245,85'; $ok.Size = '80,28'; $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'Cancel'; $cx.Location = '335,85'; $cx.Size = '80,28'; $cx.DialogResult = 'Cancel'
    $dlg.Controls.Add($cx); $dlg.CancelButton = $cx
    if ($dlg.ShowDialog($form) -eq 'OK') { return $tb.Text.Trim() }
    return $null
}

function Select-FromList {
    param([string]$Title, [string]$Message, [string[]]$Items)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = '460,300'; $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message; $lbl.Location = '15,12'; $lbl.Size = '420,20'
    $dlg.Controls.Add($lbl)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '15,38'; $lb.Size = '420,180'
    foreach ($it in $Items) { [void]$lb.Items.Add($it) }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    $dlg.Controls.Add($lb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use'; $ok.Location = '265,230'; $ok.Size = '80,28'; $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'Cancel'; $cx.Location = '355,230'; $cx.Size = '80,28'; $cx.DialogResult = 'Cancel'
    $dlg.Controls.Add($cx); $dlg.CancelButton = $cx
    if ($dlg.ShowDialog($form) -eq 'OK' -and $lb.SelectedItem) { return [string]$lb.SelectedItem }
    return $null
}

# Handed to the engine when several collectors share one model name.
function Choose-DeviceDialog {
    param($Candidates)
    $labels = @($Candidates | ForEach-Object { Format-DeviceChoice $_ })
    $sel = Select-FromList -Title 'Which collector?' `
        -Message "$($Candidates.Count) collectors are connected. Pick one:" -Items $labels
    if (-not $sel) { return $null }
    return $Candidates[[array]::IndexOf($labels, $sel)]
}

function Refresh-ProjectList {
    param([string]$SelectName)
    $cboProject.Items.Clear()
    foreach ($p in @($script:Config.projects)) { [void]$cboProject.Items.Add($p.name) }
    if ($SelectName) {
        $idx = $cboProject.Items.IndexOf($SelectName)
        if ($idx -ge 0) { $cboProject.SelectedIndex = $idx }
        elseif ($cboProject.Items.Count) { $cboProject.SelectedIndex = 0 }
    }
    elseif ($cboProject.Items.Count) { $cboProject.SelectedIndex = 0 }
}

function Load-ProjectToUi {
    param($P)
    $script:CurrentProject = $P
    if (-not $P) { return }
    $txtDesignSrc.Text  = [string]$P.designSource
    $txtExportRoot.Text = [string]$P.exportRoot
    $txtDevProj.Text    = [string]$P.deviceProjectPath
}

function Commit-UiToProject {
    $p = $script:CurrentProject
    if (-not $p) { return }
    $p.designSource      = $txtDesignSrc.Text.Trim()
    $p.exportRoot        = $txtExportRoot.Text.Trim()
    $p.deviceProjectPath = $txtDevProj.Text.Trim()
    $script:Config.activeProject = [string]$p.name
}


# --- Defaults --------------------------------------------------------------
# The settings above are shared by every collector, so they live once under
# "defaults" in config.json. Editing them here changes THIS collector only --
# there is no button that writes the baseline back, by design. The panel says
# which of the two you are looking at, so a one-off tweak made months ago is
# visible rather than silent.
function Get-UiSettings {
    New-CollectorDefaults `
        -DesignSubPath ($txtDesignSub.Text.Trim()) -ExportSubPath ($txtExportSub.Text.Trim()) `
        -DesignExtensions (Parse-Extensions $txtDesignExt.Text) `
        -ExportExtensions (Parse-Extensions $txtExportExt.Text) `
        -ExcludeFolders (Parse-FolderList $txtExcl.Text) `
        -Prune ([bool]$chkPrune.Checked) -ExportCollision ([string]$cboExportCollision.SelectedItem)
}

# Both sides go through the same parsers before comparing, so ".DXF" vs "dxf"
# or a stray trailing comma does not read as a difference.
function Format-Settings {
    param($S)
    '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f ([string]$S.designSubPath), ([string]$S.exportSubPath),
        ((Parse-Extensions ((@($S.designExtensions)) -join ',')) -join ','),
        ((Parse-Extensions ((@($S.exportExtensions)) -join ',')) -join ','),
        ((Parse-FolderList ((@($S.excludeFolders)) -join ',')) -join ','),
        ([bool]$S.prune), ([string]$S.exportCollision)
}

function Update-DefaultsIndicator {
    if ($script:Loading) { return }
    if (-not $script:CurrentCollector) { $lblDefaults.Text = ''; return }
    if ((Format-Settings (Get-UiSettings)) -eq (Format-Settings (Get-Defaults))) {
        $lblDefaults.Text = 'Matches the defaults.'
        $lblDefaults.ForeColor = 'Gray'
    }
    else {
        $lblDefaults.Text = 'Customised - differs from defaults.'
        $lblDefaults.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0)
    }
}

function Apply-SettingsToUi {
    param($S)
    $script:Loading = $true
    try {
        $txtDesignSub.Text = [string]$S.designSubPath
        $txtExportSub.Text = [string]$S.exportSubPath
        $txtDesignExt.Text = (@($S.designExtensions) -join ', ')
        $txtExportExt.Text = (@($S.exportExtensions) -join ', ')
        $txtExcl.Text      = (@($S.excludeFolders) -join ', ')
        $chkPrune.Checked  = [bool]$S.prune
        $mode = [string]$S.exportCollision
        if (-not $mode) { $mode = 'prefix' }
        $cboExportCollision.SelectedItem = $mode
        if ($cboExportCollision.SelectedIndex -lt 0) { $cboExportCollision.SelectedIndex = 0 }
    }
    finally { $script:Loading = $false }
    Update-DefaultsIndicator
}
function Load-CollectorToUi {
    param($C)
    $script:CurrentCollector = $C
    $has = ($null -ne $C)
    foreach ($ctl in @($txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl,$cboExportCollision,
                       $chkPrune,$btnNameDev,$btnResetDefaults)) {
        $ctl.Enabled = $has
    }
    $btnSync.Enabled  = $has
    $btnCheck.Enabled = $has
    if (-not $has) {
        $script:Loading = $true
        try {
            $txtDesignSub.Text = ''; $txtExportSub.Text = ''
            $txtDesignExt.Text = ''; $txtExportExt.Text = ''; $txtExcl.Text = ''
            $chkPrune.Checked = $false
        }
        finally { $script:Loading = $false }
        $lblDefaults.Text = ''
        return
    }
    Apply-SettingsToUi $C
}

function Commit-UiToCollector {
    $c = $script:CurrentCollector
    if (-not $c) { return }
    $c.designSubPath    = $txtDesignSub.Text.Trim()
    $c.exportSubPath    = $txtExportSub.Text.Trim()
    $c.designExtensions = Parse-Extensions $txtDesignExt.Text
    $c.exportExtensions = Parse-Extensions $txtExportExt.Text
    $c.excludeFolders   = Parse-FolderList $txtExcl.Text
    $c.prune            = [bool]$chkPrune.Checked
    $c.exportCollision  = [string]$cboExportCollision.SelectedItem
}

# The heart of it: work out which collector is plugged in and lock to it. An
# unrecognised serial is never matched to an existing collector.
function Update-DetectedCollector {
    param([bool]$Announce = $false)
    if ($script:IsSyncing) { return }
    $cc = $null
    try { $cc = Get-ConnectedCollectors } catch { }
    if (-not $cc) {
        $lblCollector.Text = 'Could not query connected devices.'
        $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(160,0,0)
        Load-CollectorToUi $null
        return
    }
    $known = @($cc.Known); $unknown = @($cc.Unknown)

    if ($known.Count -eq 0 -and $unknown.Count -eq 0) {
        $lblCollector.Text = 'No collector connected.  Plug one in over USB (File transfer / MTP).'
        $lblCollector.ForeColor = 'DimGray'
        Load-CollectorToUi $null
        return
    }
    if ($known.Count -eq 0 -and $unknown.Count -gt 0) {
        $s = ($unknown | ForEach-Object { "$($_.Name) ($($_.Serial))" }) -join ', '
        $lblCollector.Text = "Unrecognised: $s  -  press Detect to set it up."
        $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(180,90,0)
        Load-CollectorToUi $null
        return
    }
    $pick = $known[0]
    if ($known.Count -gt 1) {
        $labels = @($known | ForEach-Object { Get-CollectorLabel $_.Collector })
        $lblCollector.Text = "$($known.Count) collectors connected - press Detect to choose."
        $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(180,90,0)
        Load-CollectorToUi $null
        return
    }
    Load-CollectorToUi $pick.Collector
    $lbl = Get-CollectorLabel $pick.Collector
    $entries = @(@((Load-SyncState).entries) | Where-Object { [string]$_.deviceId -eq [string]$pick.Collector.serial })
    $when = 'never synced'
    if ($entries.Count) {
        $t = Parse-Utc ([string](@($entries | Sort-Object lastSyncUtc -Descending))[0].lastSyncUtc)
        if ($t) { $when = 'last synced ' + (Format-Local $t) }
    }
    $lblCollector.Text = "$lbl  -  $when"
    $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(0,110,0)
    if ($Announce) { Write-Log "Collector detected: $lbl ($when)." }
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsSyncing = $Busy
    $btnCancel.Enabled = $Busy
    foreach ($c in @($cboProject,$btnProjNew,$btnProjRename,$btnProjDelete,$btnSave,$btnDetect,$btnNameDev,
                     $txtDesignSrc,$btnDesignSrcBrowse,$txtExportRoot,$btnExportRootBrowse,$txtDevProj,
                     $txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl,$cboExportCollision,$chkPrune,
                     $btnResetDefaults)) {
        $c.Enabled = -not $Busy
    }
    $btnSync.Enabled  = (-not $Busy) -and ($null -ne $script:CurrentCollector)
    $btnCheck.Enabled = $btnSync.Enabled
    if (-not $Busy -and $null -eq $script:CurrentCollector) { Load-CollectorToUi $null }
}

# Shared by Sync and Check.
function Invoke-CollectorAction {
    param([bool]$CheckOnly)
    if ($script:IsSyncing) { return }
    if (-not $script:CurrentCollector) { return }
    Commit-UiToProject
    Commit-UiToCollector
    $script:CancelRequested = $false
    Set-Busy $true
    $progress.Value = 0
    $verb = if ($CheckOnly) { 'Checking' } else { 'Syncing' }
    $lblStatus.Text = "$verb..."
    $onLog = {
        param($m,$lvl)
        Write-Log $m $lvl
        [System.Windows.Forms.Application]::DoEvents()
    }
    $onProg = {
        param($cur,$tot)
        if ($tot -gt 0) {
            $progress.Maximum = $tot
            if ($cur -le $tot) { $progress.Value = $cur }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    try {
        $r = if ($CheckOnly) {
            Invoke-CollectorSync -Project $script:CurrentProject -Collector $script:CurrentCollector `
                -OnLog $onLog -OnProgress $onProg -CheckOnly -OnChooseDevice ${function:Choose-DeviceDialog}
        } else {
            Invoke-CollectorSync -Project $script:CurrentProject -Collector $script:CurrentCollector `
                -OnLog $onLog -OnProgress $onProg -OnChooseDevice ${function:Choose-DeviceDialog}
        }
        $msg = [string]$r.Summary
        if ($script:CancelRequested) { $msg = 'Cancelled. ' + $msg }
        $lblStatus.Text = $msg
        Write-Log ('----- ' + $msg + ' -----')
    }
    catch {
        $lblStatus.Text = 'Error: ' + $_.Exception.Message
        Write-Log ('ERROR: ' + $_.Exception.Message) 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Sync failed', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-Busy $false
        Update-DetectedCollector $false
    }
}


# Show or hide the setup half of the window. The layout is authored expanded;
# collapsing lifts the action row and log up over the freed space and shortens
# the form by the same amount, so the log keeps its size either way. The log's
# bottom anchor is dropped for the move - otherwise it would be resized twice
# (once by the move, once by the form shrinking) and collapse to nothing.
$script:AdvShift    = 395
$script:AdvCollapsed = $false

function Set-AdvancedMode {
    param([bool]$On)
    foreach ($c in @($btnProjNew,$btnProjRename,$btnProjDelete,$btnSave,$btnNameDev,$grpProj,$grpColl)) {
        $c.Visible = $On
    }
    # With Rename hidden, Detect slides into its slot so the row stays flush right.
    if ($On) { $btnDetect.Left = $btnNameDev.Left - 90 } else { $btnDetect.Left = $btnNameDev.Left }

    $wantCollapsed = (-not $On)
    if ($wantCollapsed -ne $script:AdvCollapsed) {
        $d = $script:AdvShift
        if ($wantCollapsed) { $d = -$script:AdvShift }
        $form.SuspendLayout()
        $txtLog.Anchor = 'Top,Left,Right'
        foreach ($c in @($btnSync,$btnCheck,$btnCancel,$progress,$lblStatus,$txtLog)) { $c.Top = $c.Top + $d }
        $minH = $form.MinimumSize.Height + $d
        $newH = $form.Height + $d
        if ($d -lt 0) {
            $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $minH)
            $form.Height = $newH
        } else {
            $form.Height = $newH
            $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $minH)
        }
        $txtLog.Anchor = 'Top,Bottom,Left,Right'
        $form.ResumeLayout()
        $script:AdvCollapsed = $wantCollapsed
    }
}
# ---- Event handlers -------------------------------------------------------
$cboProject.Add_SelectedIndexChanged({
    if ($script:IsSyncing) { return }
    $name = [string]$cboProject.SelectedItem
    $p = @($script:Config.projects) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($p) {
        Load-ProjectToUi $p
        $script:Config.activeProject = $name
        Set-Pref 'LastProject' $name
    }
})

$btnDesignSrcBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Design source folder on the PC'
    if ($txtDesignSrc.Text -and (Test-Path -LiteralPath $txtDesignSrc.Text)) { $fb.SelectedPath = $txtDesignSrc.Text }
    if ($fb.ShowDialog() -eq 'OK') { $txtDesignSrc.Text = $fb.SelectedPath }
})

$btnExportRootBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Where pulled field data is filed (OneDrive). You can add {year}\{month} afterwards.'
    $probe = Expand-PathTokens $txtExportRoot.Text
    if ($probe -and (Test-Path -LiteralPath $probe)) { $fb.SelectedPath = $probe }
    if ($fb.ShowDialog() -eq 'OK') { $txtExportRoot.Text = $fb.SelectedPath }
})

$btnDetect.Add_Click({
    try {
        $lblStatus.Text = 'Detecting collectors...'; $form.Refresh()
        $cc = Get-ConnectedCollectors
        $all = @($cc.All)
        if ($all.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'No collectors found. Connect one over USB, unlock it, and set USB mode to File transfer (MTP).',
                'Detect', 'OK', 'Information') | Out-Null
            Update-DetectedCollector $false
            return
        }
        $pick = $all[0]
        if ($all.Count -gt 1) {
            $picked = Choose-DeviceDialog $all
            if (-not $picked) { return }
            $pick = $picked
        }
        $existing = Get-CollectorBySerial $pick.Serial
        if ($existing) {
            Load-CollectorToUi $existing
            Update-DetectedCollector $true
            return
        }
        # Unknown serial: set it up deliberately, never inherit another collector's config.
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This collector is not set up yet.`r`n`r`nModel:  $($pick.Name)`r`nSerial: $($pick.Serial)`r`n`r`nAdd it now?",
            'New collector', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $nm = Prompt-Text -Title 'Name this collector' `
                -Message "Short name (used as the export filename prefix, e.g. TSC5-03):" -Default ''
        if (-not $nm) { return }
        $c = Register-Collector $pick $nm
        try { Save-Config } catch {}
        Write-Log "Registered collector '$nm' (serial $($pick.Serial))."
        Load-CollectorToUi $c
        Update-DetectedCollector $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Detect', 'OK', 'Error') | Out-Null
    }
    finally { $lblStatus.Text = 'Ready.' }
})

$btnNameDev.Add_Click({
    $c = $script:CurrentCollector
    if (-not $c) { return }
    $old = [string]$c.name
    $nm = Prompt-Text -Title 'Rename collector' `
            -Message "Name for serial $($c.serial).  Note: already-exported files keep the old prefix." -Default $old
    if (-not $nm -or $nm -eq $old) { return }
    $c.name = $nm
    try { Save-Config; Write-Log "Renamed $($c.serial): '$old' -> '$nm'." } catch {}
    Update-DetectedCollector $false
})

$btnSave.Add_Click({
    Commit-UiToProject
    Commit-UiToCollector
    try {
        Save-Config
        $lblStatus.Text = 'Saved to config.json.'
        Write-Log 'Settings saved.'
    }
    catch { [System.Windows.Forms.MessageBox]::Show("Could not save config.json:`r`n$($_.Exception.Message)", 'Save', 'OK', 'Error') | Out-Null }
})

$btnProjNew.Add_Click({
    $name = Prompt-Text -Title 'New project' -Message 'Name for the new project:' -Default 'New project'
    if (-not $name) { return }
    if (@($script:Config.projects) | Where-Object { $_.name -eq $name }) {
        [System.Windows.Forms.MessageBox]::Show('A project with that name already exists.', 'New project', 'OK', 'Warning') | Out-Null
        return
    }
    Commit-UiToProject
    $script:Config.projects = @(@($script:Config.projects) + (New-Project -Name $name))
    Refresh-ProjectList -SelectName $name
})

$btnProjRename.Add_Click({
    if (-not $script:CurrentProject) { return }
    $name = Prompt-Text -Title 'Rename project' -Message 'New name:' -Default $script:CurrentProject.name
    if (-not $name) { return }
    if (@($script:Config.projects) | Where-Object { $_.name -eq $name -and $_ -ne $script:CurrentProject }) {
        [System.Windows.Forms.MessageBox]::Show('A project with that name already exists.', 'Rename', 'OK', 'Warning') | Out-Null
        return
    }
    Commit-UiToProject
    $script:CurrentProject.name = $name
    Refresh-ProjectList -SelectName $name
})

$btnProjDelete.Add_Click({
    if (-not $script:CurrentProject) { return }
    if (@($script:Config.projects).Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show('Keep at least one project.', 'Delete', 'OK', 'Warning') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Delete project '$($script:CurrentProject.name)'?", 'Delete', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $script:Config.projects = @(@($script:Config.projects) | Where-Object { $_ -ne $script:CurrentProject })
    Refresh-ProjectList
})

# Editing a field changes THIS collector, never the baseline. The indicator
# tracks that live so it is always obvious which of the two you are looking at.
foreach ($ctl in @($txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl)) {
    $ctl.Add_TextChanged({ Update-DefaultsIndicator })
}
$cboExportCollision.Add_SelectedIndexChanged({ Update-DefaultsIndicator })
$chkPrune.Add_CheckedChanged({ Update-DefaultsIndicator })

# Resets THIS collector to the baseline. There is deliberately no button that
# writes the baseline: it is changed by editing config.json, so no amount of
# clicking in here can turn one person's experiment into everyone's default.
$btnResetDefaults.Add_Click({
    if (-not $script:CurrentCollector) { return }
    $d = Get-Defaults
    $mirror = 'off'
    if ($d.prune) { $mirror = 'on - deletes extras' }
    $msg = "Reset $(Get-CollectorLabel $script:CurrentCollector) to the defaults?`r`n`r`n" +
           "Design folder:  $($d.designSubPath)`r`n" +
           "Export folder:  $($d.exportSubPath)`r`n" +
           "Design types:   $((@($d.designExtensions)) -join ', ')`r`n" +
           "Export types:   $((@($d.exportExtensions)) -join ', ')`r`n" +
           "Skip folders:   $((@($d.excludeFolders)) -join ', ')`r`n" +
           "Export naming:  $($d.exportCollision)`r`n" +
           "Mirror:         $mirror`r`n`r`n" +
           "Anything set just for this collector is dropped. Other collectors, the " +
           "defaults themselves and the project paths are all left alone."
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Reset to defaults', 'YesNo', 'Question') -ne 'Yes') { return }
    Apply-SettingsToUi $d
    Commit-UiToCollector
    try {
        Save-Config
        $lblStatus.Text = 'Reset to defaults.'
        Write-Log "Reset $(Get-CollectorLabel $script:CurrentCollector) to the defaults."
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Reset to defaults', 'OK', 'Error') | Out-Null }
    Update-DefaultsIndicator
})


$btnCancel.Add_Click({ $script:CancelRequested = $true; $lblStatus.Text = 'Cancelling...' })
$btnCheck.Add_Click({ Invoke-CollectorAction $true })
$btnSync.Add_Click({ Invoke-CollectorAction $false })

$chkAdvanced.Add_CheckedChanged({
    Set-AdvancedMode ([bool]$chkAdvanced.Checked)
    Set-Pref 'Advanced' $(if ($chkAdvanced.Checked) { '1' } else { '0' })
})

# ---- Boot -----------------------------------------------------------------
function Update-DateLabel {
    $lblDates.Text = ("Today:  {0}     Julian {1}     exports file into  {2}\{3}" -f `
        (Get-Date -Format 'yyyy-MM-dd'), (Get-JulianDate), (Get-Date).ToString('yyyy'), (Get-MonthFolder))
    $lblTokenHint.Text = ("Path tokens:  {{year}}={0}   {{month}}={1}   {{julian}}={2}   {{date}}={3}" -f `
        (Get-Date).ToString('yyyy'), (Get-MonthFolder), (Get-JulianDate), (Get-Date -Format 'yyyy-MM-dd'))
}
Update-DateLabel

$dateTimer = New-Object System.Windows.Forms.Timer
$dateTimer.Interval = 60000
$dateTimer.Add_Tick({ Update-DateLabel })
$dateTimer.Start()

# Poll for a collector being plugged in or pulled out. Only acts when the set of
# connected serials actually changes, so it costs nothing while idle and never
# interrupts a run in progress.
$devTimer = New-Object System.Windows.Forms.Timer
$devTimer.Interval = 4000
$devTimer.Add_Tick({
    if ($script:IsSyncing) { return }
    try {
        $sig = ((@(Get-MtpDevices) | ForEach-Object { $_.Serial }) -join '|')
        if ($sig -ne $script:LastSeenSerials) {
            $script:LastSeenSerials = $sig
            Update-DetectedCollector $true
        }
    }
    catch {}
})
$devTimer.Start()

$startProject = [string](Get-Pref 'LastProject' $script:Config.activeProject)
Refresh-ProjectList -SelectName $startProject
Write-Log 'Sync Data Collector ready.'
try { $script:LastSeenSerials = ((@(Get-MtpDevices) | ForEach-Object { $_.Serial }) -join '|') } catch {}
Update-DetectedCollector $true
$chkAdvanced.Checked = ([string](Get-Pref 'Advanced' '0') -eq '1')
Set-AdvancedMode ([bool]$chkAdvanced.Checked)
[void]$form.ShowDialog()
