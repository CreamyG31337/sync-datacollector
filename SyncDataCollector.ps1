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
        [string[]]$Extensions = @('.csv', '.dxf', '.xml', '.ttm')
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
        lastProfile = 'Collector over USB (MTP)'
        mtp         = New-MtpSettings
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
                New-Profile -Name $_.name -Direction $dir -SourcePath $_.sourcePath -TargetType $_.targetType `
                    -DeviceName $_.deviceName -DestinationPath $_.destinationPath `
                    -CollisionMode $coll -Extensions @($_.extensions)
            })
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

# Today's Julian date as YY-DDD (e.g. 2026-07-23 -> "26-204").
function Get-JulianDate {
    $now = Get-Date
    return ('{0}-{1:D3}' -f $now.ToString('yy'), $now.DayOfYear)
}

# Expand path tokens. {julian} -> today's YY-DDD. Case-insensitive.
function Expand-PathTokens {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return ($Path -replace '(?i)\{julian\}', (Get-JulianDate))
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
function Get-MtpDeviceNames {
    $pc = (Get-ShellApp).NameSpace(0x11)
    $items = $pc.Items()
    $names = @()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items.Item($i)
        if ($it.IsFolder -and ($it.Path -notmatch '^[A-Za-z]:\\')) { $names += $it.Name }
    }
    return $names
}

# Resolve a logical device dir ("Internal shared storage\...\Design") to its Shell
# FolderItem, creating missing folders when $Create. Cached per-run in $Ctx.FolderCache.
function Resolve-MtpDir {
    param($Ctx, [string]$LogicalDir, [bool]$Create)
    $key = ($LogicalDir -replace '/', '\').Trim('\')
    if ($Ctx.FolderCache.ContainsKey($key)) { return $Ctx.FolderCache[$key] }
    $segs = @($Ctx.DeviceName) + (Split-MtpPath $LogicalDir)
    $curFolder = (Get-ShellApp).NameSpace(0x11)
    $curItem = $null
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
function Get-DestRel {
    param([string]$Rel, [string]$Direction, [string]$CollisionMode, [string]$DeviceName)
    if ($Direction -ne 'pull') { return $Rel }
    switch ($CollisionMode) {
        'deviceSubfolder' { if ($DeviceName) { return "$DeviceName\$Rel" } else { return $Rel } }
        'prefix' {
            if (-not $DeviceName) { return $Rel }
            $parts = $Rel -split '\\', 2                    # prefix the first path segment only
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
    param($RawFiles, $RawDirs, [string[]]$Exts, [bool]$ApplyLandXml)
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
    $files = @(); $skippedXml = 0
    foreach ($r in $RawFiles) {
        $inc = $false
        if ($Exts -contains $r.Ext) {
            if ($ApplyLandXml -and $r.Ext -eq '.xml' -and $r.Local -and -not (Test-LandXml $r.Local)) { $skippedXml++ }
            else { $inc = $true }
        }
        if (-not $inc -and (& $underCompanion $r.Rel)) { $inc = $true }
        if ($inc) { $files += $r }
    }
    $dirs = @()
    foreach ($d in $RawDirs) { if (& $underCompanion $d) { $dirs += $d } }
    return @{ Files = $files; Dirs = $dirs; SkippedXml = $skippedXml }
}

# --------------------------------------------------------------------------
# Sync engine
# --------------------------------------------------------------------------
function Invoke-Sync {
    param(
        [pscustomobject]$Profile,
        [scriptblock]$OnLog,        # param($msg, $level)
        [scriptblock]$OnProgress    # param($current, $total)
    )

    $direction     = if ($Profile.PSObject.Properties['direction'] -and $Profile.direction) { [string]$Profile.direction } else { 'push' }
    $collectorType = [string]$Profile.targetType    # folder | mtp
    $collisionMode = if ($Profile.PSObject.Properties['collisionMode'] -and $Profile.collisionMode) { [string]$Profile.collisionMode } else { 'deviceSubfolder' }
    $deviceName    = [string]$Profile.deviceName
    if ($collectorType -ne 'folder' -and $collectorType -ne 'mtp') { throw "Unknown collector type '$collectorType'." }
    $collectorKind = if ($collectorType -eq 'mtp') { 'mtp' } else { 'fs' }

    # Which end is source, which is destination.
    if ($direction -eq 'pull') { $srcKind = $collectorKind; $dstKind = 'fs' }
    else                       { $srcKind = 'fs';           $dstKind = $collectorKind }

    & $OnLog "Profile '$($Profile.name)'  ($direction, collector=$collectorType)" 'INFO'

    # Endpoint paths (support the {julian} token).
    $srcPath = (Expand-PathTokens $Profile.sourcePath).Trim().TrimEnd('\')
    $dstPath = (Expand-PathTokens $Profile.destinationPath).Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($srcPath)) { throw 'Source path is empty.' }
    if ([string]::IsNullOrWhiteSpace($dstPath)) { throw 'Destination path is empty.' }

    $exts = @()
    foreach ($e in @($Profile.extensions)) { $exts += ([string]$e).ToLowerInvariant() }
    if (-not $exts) { throw 'No file extensions configured for this profile.' }

    $ctx = @{ DeviceName = $deviceName; Settings = $script:Config.mtp; FolderCache = @{} }
    try {
        # Prepare the MTP side (whichever end it is).
        if ($srcKind -eq 'mtp' -or $dstKind -eq 'mtp') {
            if ([string]::IsNullOrWhiteSpace($deviceName)) { throw 'This profile uses MTP but no device name is set.' }
            Ensure-MtpInterop
            & $OnLog "Locating MTP device '$deviceName'..." 'INFO'
            $names = @(Get-MtpDeviceNames)
            if ($names -notcontains $deviceName) {
                throw "MTP device '$deviceName' not found under This PC. Connected, unlocked, and set to File transfer (MTP)? Detected: $($names -join ', ')"
            }
            & $OnLog 'Device found.' 'INFO'
        }
        # Validate a filesystem source up front (MTP source absence is handled in enumeration).
        if ($srcKind -eq 'fs') {
            if (-not (Test-Path -LiteralPath $srcPath)) { throw "Source folder not found: '$srcPath'" }
            $srcPath = (Get-Item -LiteralPath $srcPath).FullName.TrimEnd('\')
        }

        # Per-device subfolder / prefix (pull only) needs a device name / label.
        if ($direction -eq 'pull' -and $collisionMode -in @('deviceSubfolder', 'prefix') -and [string]::IsNullOrWhiteSpace($deviceName)) {
            throw "Collision mode '$collisionMode' needs a device name / label (used to keep each collector's files separate)."
        }

        & $OnLog "Ensuring destination exists: $dstPath" 'INFO'
        Target-EnsureDir $ctx $dstKind $dstPath

        # Inventory ALL source files + dirs, then select what to sync (extension
        # filter + .jxl companion folders). LandXML content-check applies to push only.
        & $OnLog "Scanning source ($srcKind) ..." 'INFO'
        $rawFiles = @(); $rawDirs = @()
        if ($srcKind -eq 'fs') {
            Get-ChildItem -LiteralPath $srcPath -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSIsContainer) {
                    $rawDirs += $_.FullName.Substring($srcPath.Length).TrimStart('\')
                }
                else {
                    $rawFiles += @{ Rel = $_.FullName.Substring($srcPath.Length).TrimStart('\'); Length = [long]$_.Length; MtimeUtc = $_.LastWriteTimeUtc; Src = $_.FullName; Local = $_.FullName; Ext = $_.Extension.ToLowerInvariant() }
                }
            }
        }
        else {
            $inv = Get-MtpInventory $ctx $srcPath
            foreach ($m in $inv.Files) { $rawFiles += @{ Rel = $m.Rel; Length = $m.Length; MtimeUtc = $m.MtimeUtc; Src = $m.Item; Local = $null; Ext = $m.Ext } }
            foreach ($d in $inv.Dirs)  { $rawDirs += $d }
        }
        $sel = Select-SyncSet $rawFiles $rawDirs $exts ($direction -eq 'push')
        $records = @($sel.Files)
        $total = $records.Count
        $jxlNote = if ($sel.Dirs.Count) { " (+$($sel.Dirs.Count) scan subfolder(s))" } else { '' }
        $xmlNote = if ($sel.SkippedXml -gt 0) { " (excluded $($sel.SkippedXml) non-LandXML .xml)" } else { '' }
        & $OnLog "Found $total matching file(s)$jxlNote$xmlNote." 'INFO'
        & $OnProgress 0 $total

        $copyMode = "$srcKind`2$dstKind"   # fs2fs | fs2mtp | mtp2fs
        if ($copyMode -eq 'mtp2mtp') { throw 'MTP-to-MTP is not supported.' }

        # Pre-create companion (scan) subfolders on the destination so even empty
        # point-cloud directories are preserved.
        foreach ($drel in $sel.Dirs) {
            $ddestRel = Get-DestRel $drel $direction $collisionMode $deviceName
            try { Target-EnsureDir $ctx $dstKind ($dstPath + '\' + $ddestRel) } catch {}
        }

        $copied = 0; $skipped = 0; $failed = 0
        $i = 0
        foreach ($rec in $records) {
            if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
            $i++
            $rel = $rec.Rel
            $destRel = Get-DestRel $rel $direction $collisionMode $deviceName
            $dest = $dstPath + '\' + $destRel
            try {
                $need = $false; $reason = ''
                $di = Target-GetInfo $ctx $dstKind $dest     # one live lookup (Length = -1 if absent)
                if ($di.Length -lt 0) { $need = $true; $reason = 'new' }
                elseif ([long]$rec.Length -ne $di.Length) { $need = $true; $reason = 'size changed' }
                elseif ($null -ne $di.Mtime -and $null -ne $rec.MtimeUtc -and $rec.MtimeUtc -gt $di.Mtime.AddSeconds(2)) { $need = $true; $reason = 'source newer' }

                if ($need) {
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

        return [pscustomobject]@{ Total = $total; Copied = $copied; Skipped = $skipped; Failed = $failed }
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
$form.Size = New-Object System.Drawing.Size(760, 735)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(660, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# ---- Profile row ----------------------------------------------------------
$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Text = 'Profile:'; $lblProfile.Location = '15,18'; $lblProfile.AutoSize = $true
$form.Controls.Add($lblProfile)

$cboProfile = New-Object System.Windows.Forms.ComboBox
$cboProfile.Location = '70,15'; $cboProfile.Size = '330,24'
$cboProfile.DropDownStyle = 'DropDownList'
$cboProfile.Anchor = 'Top,Left,Right'
$form.Controls.Add($cboProfile)

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Text = 'New'; $btnNew.Location = '410,14'; $btnNew.Size = '60,26'; $btnNew.Anchor = 'Top,Right'
$form.Controls.Add($btnNew)

$btnRename = New-Object System.Windows.Forms.Button
$btnRename.Text = 'Rename'; $btnRename.Location = '475,14'; $btnRename.Size = '70,26'; $btnRename.Anchor = 'Top,Right'
$form.Controls.Add($btnRename)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = 'Delete'; $btnDelete.Location = '550,14'; $btnDelete.Size = '65,26'; $btnDelete.Anchor = 'Top,Right'
$form.Controls.Add($btnDelete)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'; $btnSave.Location = '620,14'; $btnSave.Size = '110,26'; $btnSave.Anchor = 'Top,Right'
$form.Controls.Add($btnSave)

# ---- Julian date ----------------------------------------------------------
$lblJulian = New-Object System.Windows.Forms.Label
$lblJulian.Location = '15,48'; $lblJulian.AutoSize = $true
$lblJulian.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblJulian)

# ---- Settings group -------------------------------------------------------
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Settings'; $grp.Location = '15,72'; $grp.Size = '715,278'; $grp.Anchor = 'Top,Left,Right'
$form.Controls.Add($grp)

# Direction
$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Text = 'Direction:'; $lblDir.Location = '15,28'; $lblDir.AutoSize = $true
$grp.Controls.Add($lblDir)
$cboDir = New-Object System.Windows.Forms.ComboBox
$cboDir.Location = '130,25'; $cboDir.Size = '140,24'; $cboDir.DropDownStyle = 'DropDownList'
[void]$cboDir.Items.Add('push'); [void]$cboDir.Items.Add('pull')
$grp.Controls.Add($cboDir)
$lblDirHint = New-Object System.Windows.Forms.Label
$lblDirHint.Text = '(push = PC -> collector   |   pull = collector -> PC/USB/cloud)'
$lblDirHint.Location = '290,28'; $lblDirHint.AutoSize = $true; $lblDirHint.ForeColor = 'Gray'
$grp.Controls.Add($lblDirHint)

# Collector type
$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Collector type:'; $lblType.Location = '15,63'; $lblType.AutoSize = $true
$grp.Controls.Add($lblType)
$cboType = New-Object System.Windows.Forms.ComboBox
$cboType.Location = '130,60'; $cboType.Size = '140,24'; $cboType.DropDownStyle = 'DropDownList'
[void]$cboType.Items.Add('folder'); [void]$cboType.Items.Add('mtp')
$grp.Controls.Add($cboType)
$lblTypeHint = New-Object System.Windows.Forms.Label
$lblTypeHint.Text = '(folder = USB / local path   |   mtp = data collector over USB)'
$lblTypeHint.Location = '290,63'; $lblTypeHint.AutoSize = $true; $lblTypeHint.ForeColor = 'Gray'
$grp.Controls.Add($lblTypeHint)

# Device name (mtp) / per-device label
$lblDev = New-Object System.Windows.Forms.Label
$lblDev.Text = 'Device name:'; $lblDev.Location = '15,98'; $lblDev.AutoSize = $true
$grp.Controls.Add($lblDev)
$txtDev = New-Object System.Windows.Forms.TextBox
$txtDev.Location = '130,95'; $txtDev.Size = '350,24'
$grp.Controls.Add($txtDev)
$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Detect...'; $btnDetect.Location = '488,94'; $btnDetect.Size = '90,26'
$grp.Controls.Add($btnDetect)

# Source
$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Text = 'Source:'; $lblSrc.Location = '15,133'; $lblSrc.AutoSize = $true
$grp.Controls.Add($lblSrc)
$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Location = '130,130'; $txtSrc.Size = '480,24'; $txtSrc.Anchor = 'Top,Left,Right'
$grp.Controls.Add($txtSrc)
$btnSrcBrowse = New-Object System.Windows.Forms.Button
$btnSrcBrowse.Text = 'Browse...'; $btnSrcBrowse.Location = '618,129'; $btnSrcBrowse.Size = '80,26'; $btnSrcBrowse.Anchor = 'Top,Right'
$grp.Controls.Add($btnSrcBrowse)

# Destination
$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Destination:'; $lblDest.Location = '15,168'; $lblDest.AutoSize = $true
$grp.Controls.Add($lblDest)
$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Location = '130,165'; $txtDest.Size = '480,24'; $txtDest.Anchor = 'Top,Left,Right'
$grp.Controls.Add($txtDest)
$btnDestBrowse = New-Object System.Windows.Forms.Button
$btnDestBrowse.Text = 'Browse...'; $btnDestBrowse.Location = '618,164'; $btnDestBrowse.Size = '80,26'; $btnDestBrowse.Anchor = 'Top,Right'
$grp.Controls.Add($btnDestBrowse)

# File types
$lblExt = New-Object System.Windows.Forms.Label
$lblExt.Text = 'File types:'; $lblExt.Location = '15,203'; $lblExt.AutoSize = $true
$grp.Controls.Add($lblExt)
$txtExt = New-Object System.Windows.Forms.TextBox
$txtExt.Location = '130,200'; $txtExt.Size = '250,24'
$grp.Controls.Add($txtExt)
$lblExtHint = New-Object System.Windows.Forms.Label
$lblExtHint.Text = 'comma separated, e.g.  .csv, .dxf   ({julian} allowed in paths)'
$lblExtHint.Location = '390,203'; $lblExtHint.AutoSize = $true; $lblExtHint.ForeColor = 'Gray'
$grp.Controls.Add($lblExtHint)

# Collision handling (pull only)
$lblColl = New-Object System.Windows.Forms.Label
$lblColl.Text = 'On collision:'; $lblColl.Location = '15,238'; $lblColl.AutoSize = $true
$grp.Controls.Add($lblColl)
$cboCollision = New-Object System.Windows.Forms.ComboBox
$cboCollision.Location = '130,235'; $cboCollision.Size = '150,24'; $cboCollision.DropDownStyle = 'DropDownList'
[void]$cboCollision.Items.Add('deviceSubfolder'); [void]$cboCollision.Items.Add('prefix'); [void]$cboCollision.Items.Add('overwrite')
$grp.Controls.Add($cboCollision)
$lblCollHint = New-Object System.Windows.Forms.Label
$lblCollHint.Text = '(pull only: keep files from each collector separate)'
$lblCollHint.Location = '290,238'; $lblCollHint.AutoSize = $true; $lblCollHint.ForeColor = 'Gray'
$grp.Controls.Add($lblCollHint)

# ---- Action buttons -------------------------------------------------------
$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'Sync now'; $btnSync.Location = '15,360'; $btnSync.Size = '150,36'
$btnSync.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSync)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = '175,360'; $btnCancel.Size = '90,36'; $btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '280,367'; $progress.Size = '450,22'; $progress.Anchor = 'Top,Left,Right'
$form.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready.'; $lblStatus.Location = '15,405'; $lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

# ---- Log ------------------------------------------------------------------
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = '15,430'; $txtLog.Size = '715,255'
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

function Update-FieldUi {
    $isMtp  = ($cboType.SelectedItem -eq 'mtp')
    $isPull = ($cboDir.SelectedItem -eq 'pull')

    # Device fields apply whenever the collector is MTP (source OR destination).
    $txtDev.Enabled    = $isMtp
    $btnDetect.Enabled = $isMtp
    $lblDev.Text = if ($isPull -and -not $isMtp) { 'Collector label:' } else { 'Device name:' }

    # Which end is a real folder we can Browse to.
    # push: source=PC(fs) always; dest=collector (folder browsable, mtp not).
    # pull: source=collector (folder browsable, mtp not); dest=PC/USB/cloud(fs) always.
    if ($isPull) {
        $lblSrc.Text  = 'Source (on collector):'
        $lblDest.Text = 'Destination (USB/cloud):'
        $btnSrcBrowse.Enabled  = -not $isMtp
        $btnDestBrowse.Enabled = $true
    }
    else {
        $lblSrc.Text  = 'Source (PC):'
        $lblDest.Text = 'Destination (collector):'
        $btnSrcBrowse.Enabled  = $true
        $btnDestBrowse.Enabled = -not $isMtp
    }

    # Collision handling only matters for pull.
    $cboCollision.Enabled = $isPull
    $lblColl.Enabled = $isPull
}

function Load-ProfileToUi {
    param([pscustomobject]$P)
    $script:CurrentProfile = $P
    $dir = if ($P.PSObject.Properties['direction'] -and $P.direction) { [string]$P.direction } else { 'push' }
    $cboDir.SelectedItem = $dir
    if ($cboDir.SelectedIndex -lt 0) { $cboDir.SelectedIndex = 0 }
    $cboType.SelectedItem = ([string]$P.targetType)
    if ($cboType.SelectedIndex -lt 0) { $cboType.SelectedIndex = 0 }
    $coll = if ($P.PSObject.Properties['collisionMode'] -and $P.collisionMode) { [string]$P.collisionMode } else { 'deviceSubfolder' }
    $cboCollision.SelectedItem = $coll
    if ($cboCollision.SelectedIndex -lt 0) { $cboCollision.SelectedIndex = 0 }
    $txtDev.Text  = [string]$P.deviceName
    $txtSrc.Text  = [string]$P.sourcePath
    $txtDest.Text = [string]$P.destinationPath
    $txtExt.Text  = (@($P.extensions) -join ', ')
    Update-FieldUi
}

function Commit-UiToProfile {
    if (-not $script:CurrentProfile) { return }
    $p = $script:CurrentProfile
    $p.direction       = [string]$cboDir.SelectedItem
    $p.sourcePath      = $txtSrc.Text.Trim()
    $p.targetType      = [string]$cboType.SelectedItem
    $p.deviceName      = $txtDev.Text.Trim()
    $p.destinationPath = $txtDest.Text.Trim()
    $p.collisionMode   = [string]$cboCollision.SelectedItem
    $p.extensions      = Parse-Extensions $txtExt.Text
}

function Refresh-ProfileList {
    param([string]$SelectName)
    $cboProfile.Items.Clear()
    foreach ($p in $script:Config.profiles) { [void]$cboProfile.Items.Add($p.name) }
    if ($SelectName) {
        $idx = $cboProfile.Items.IndexOf($SelectName)
        if ($idx -ge 0) { $cboProfile.SelectedIndex = $idx }
        elseif ($cboProfile.Items.Count -gt 0) { $cboProfile.SelectedIndex = 0 }
    }
    elseif ($cboProfile.Items.Count -gt 0) { $cboProfile.SelectedIndex = 0 }
}

function Prompt-Text {
    param([string]$Title, [string]$Message, [string]$Default = '')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = '420,160'; $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message; $lbl.Location = '15,15'; $lbl.Size = '380,20'
    $dlg.Controls.Add($lbl)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Default; $tb.Location = '15,45'; $tb.Size = '380,24'
    $dlg.Controls.Add($tb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = '225,85'; $ok.Size = '80,28'; $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'Cancel'; $cx.Location = '315,85'; $cx.Size = '80,28'; $cx.DialogResult = 'Cancel'
    $dlg.Controls.Add($cx); $dlg.CancelButton = $cx
    if ($dlg.ShowDialog($form) -eq 'OK') { return $tb.Text.Trim() }
    return $null
}

function Select-FromList {
    param([string]$Title, [string]$Message, [string[]]$Items)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = '420,300'; $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message; $lbl.Location = '15,12'; $lbl.Size = '380,20'
    $dlg.Controls.Add($lbl)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '15,38'; $lb.Size = '380,180'
    foreach ($it in $Items) { [void]$lb.Items.Add($it) }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    $dlg.Controls.Add($lb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use'; $ok.Location = '225,230'; $ok.Size = '80,28'; $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'Cancel'; $cx.Location = '315,230'; $cx.Size = '80,28'; $cx.DialogResult = 'Cancel'
    $dlg.Controls.Add($cx); $dlg.CancelButton = $cx
    if ($dlg.ShowDialog($form) -eq 'OK' -and $lb.SelectedItem) { return [string]$lb.SelectedItem }
    return $null
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsSyncing = $Busy
    $btnSync.Enabled = -not $Busy
    $btnCancel.Enabled = $Busy
    foreach ($c in @($cboProfile,$btnNew,$btnRename,$btnDelete,$btnSave,$cboDir,$txtSrc,$btnSrcBrowse,
                     $cboType,$txtDev,$btnDetect,$txtDest,$btnDestBrowse,$txtExt,$cboCollision)) {
        $c.Enabled = -not $Busy
    }
    if (-not $Busy) { Update-FieldUi }
}

# ---- Event handlers -------------------------------------------------------
$cboProfile.Add_SelectedIndexChanged({
    if ($script:IsSyncing) { return }
    $name = [string]$cboProfile.SelectedItem
    $p = $script:Config.profiles | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($p) { Load-ProfileToUi $p; Set-Pref 'LastProfile' $name }   # remember per-machine (registry)
})

$cboType.Add_SelectedIndexChanged({ Update-FieldUi })
$cboDir.Add_SelectedIndexChanged({ Update-FieldUi })

$btnSrcBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($txtSrc.Text -and (Test-Path -LiteralPath $txtSrc.Text)) { $fb.SelectedPath = $txtSrc.Text }
    if ($fb.ShowDialog() -eq 'OK') { $txtSrc.Text = $fb.SelectedPath }
})

$btnDestBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Pick the destination folder (USB stick or local path)'
    if ($txtDest.Text -and (Test-Path -LiteralPath $txtDest.Text)) { $fb.SelectedPath = $txtDest.Text }
    if ($fb.ShowDialog() -eq 'OK') { $txtDest.Text = $fb.SelectedPath }
})

$btnDetect.Add_Click({
    try {
        $lblStatus.Text = 'Detecting MTP devices...'; $form.Refresh()
        $names = @(Get-MtpDeviceNames)
        if ($names.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No MTP devices found. Connect the collector, unlock it, and set USB to File transfer (MTP).','Detect device','OK','Information') | Out-Null
        }
        elseif ($names.Count -eq 1) {
            $txtDev.Text = $names[0]
            Write-Log "Detected device: $($names[0])"
        }
        else {
            $sel = Select-FromList -Title 'Detect device' -Message 'Select the collector:' -Items $names
            if ($sel) { $txtDev.Text = $sel }
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Detect device','OK','Error') | Out-Null
    }
    finally { $lblStatus.Text = 'Ready.' }
})

$btnSave.Add_Click({
    Commit-UiToProfile
    Set-Pref 'LastProfile' $script:CurrentProfile.name   # per-machine default (registry, not the shared config)
    try { Save-Config; $lblStatus.Text = 'Saved settings to config.json.' ; Write-Log 'Settings saved.' }
    catch { [System.Windows.Forms.MessageBox]::Show("Could not save config.json:`r`n$($_.Exception.Message)",'Save','OK','Error') | Out-Null }
})

$btnNew.Add_Click({
    $name = Prompt-Text -Title 'New profile' -Message 'Name for the new profile:' -Default 'New profile'
    if (-not $name) { return }
    if ($script:Config.profiles | Where-Object { $_.name -eq $name }) {
        [System.Windows.Forms.MessageBox]::Show('A profile with that name already exists.','New profile','OK','Warning') | Out-Null
        return
    }
    Commit-UiToProfile
    $p = New-Profile -Name $name
    $script:Config.profiles = @($script:Config.profiles) + $p
    Refresh-ProfileList -SelectName $name
})

$btnRename.Add_Click({
    if (-not $script:CurrentProfile) { return }
    $name = Prompt-Text -Title 'Rename profile' -Message 'New name:' -Default $script:CurrentProfile.name
    if (-not $name) { return }
    if ($script:Config.profiles | Where-Object { $_.name -eq $name -and $_ -ne $script:CurrentProfile }) {
        [System.Windows.Forms.MessageBox]::Show('A profile with that name already exists.','Rename','OK','Warning') | Out-Null
        return
    }
    Commit-UiToProfile
    $script:CurrentProfile.name = $name
    Refresh-ProfileList -SelectName $name
})

$btnDelete.Add_Click({
    if (-not $script:CurrentProfile) { return }
    if ($script:Config.profiles.Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show('Keep at least one profile.','Delete','OK','Warning') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Delete profile '$($script:CurrentProfile.name)'?",'Delete','YesNo','Question')
    if ($r -ne 'Yes') { return }
    $keep = @($script:Config.profiles | Where-Object { $_ -ne $script:CurrentProfile })
    $script:Config.profiles = $keep
    Refresh-ProfileList
})

$btnCancel.Add_Click({ $script:CancelRequested = $true; $lblStatus.Text = 'Cancelling...' })

$btnSync.Add_Click({
    if ($script:IsSyncing) { return }
    Commit-UiToProfile
    $p = $script:CurrentProfile
    $script:CancelRequested = $false
    Set-Busy $true
    $progress.Value = 0
    $lblStatus.Text = 'Syncing...'
    Write-Log ('----- Sync started: ' + $p.name + ' -----')
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
            $lblStatus.Text = "Syncing... $cur / $tot"
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    try {
        $sum = Invoke-Sync -Profile $p -OnLog $onLog -OnProgress $onProg
        $msg = "Done. Copied $($sum.Copied), skipped $($sum.Skipped), failed $($sum.Failed) (of $($sum.Total))."
        if ($script:CancelRequested) { $msg = 'Cancelled. ' + $msg }
        $lblStatus.Text = $msg
        Write-Log ('----- ' + $msg + ' -----')
    }
    catch {
        $lblStatus.Text = 'Error: ' + $_.Exception.Message
        Write-Log ('ERROR: ' + $_.Exception.Message) 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Sync failed','OK','Error') | Out-Null
    }
    finally {
        Set-Busy $false
    }
})

# ---- Boot -----------------------------------------------------------------
# Julian date label + a timer so it stays correct if the app is left open past midnight.
$lblJulian.Text = "Today (Julian date):  $(Get-JulianDate)"
$julianTimer = New-Object System.Windows.Forms.Timer
$julianTimer.Interval = 60000
$julianTimer.Add_Tick({ $lblJulian.Text = "Today (Julian date):  $(Get-JulianDate)" })
$julianTimer.Start()

# Per-machine default profile from the registry (falls back to the shared config default).
$startProfile = [string](Get-Pref 'LastProfile' $script:Config.lastProfile)
Refresh-ProfileList -SelectName $startProfile
Write-Log 'Sync Data Collector ready.'
[void]$form.ShowDialog()
