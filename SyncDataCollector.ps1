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
        [string]$SourcePath = '',
        [string]$TargetType = 'folder',
        [string]$DeviceName = '',
        [string]$DestinationPath = '',
        [string[]]$Extensions = @('.csv', '.dxf')
    )
    [pscustomobject]@{
        name            = $Name
        sourcePath      = $SourcePath
        targetType      = $TargetType
        deviceName      = $DeviceName
        destinationPath = $DestinationPath
        extensions      = $Extensions
    }
}

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
            # Normalise: make sure every profile has all expected fields.
            $cfg.profiles = @($cfg.profiles | ForEach-Object {
                New-Profile -Name $_.name -SourcePath $_.sourcePath -TargetType $_.targetType `
                    -DeviceName $_.deviceName -DestinationPath $_.destinationPath `
                    -Extensions @($_.extensions)
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

# --------------------------------------------------------------------------
# Target providers (folder | mtp) -- unified small interface via $ctx
#   $ctx = @{ Type='folder'|'mtp'; DeviceName=..; Settings=..; FolderCache=@{} }
# Destination paths passed in are the *logical* path:
#   folder -> a normal Windows path; mtp -> an on-device path under the device.
# MTP is driven through the Windows Shell (navigate/list/create/size/date) and
# IFileOperation (copy/overwrite/delete) -- see the MTP provider section below.
# --------------------------------------------------------------------------
function Target-EnsureDir {
    param($Ctx, [string]$DirPath)
    if ($Ctx.Type -eq 'folder') {
        if (-not (Test-Path -LiteralPath $DirPath)) {
            New-Item -ItemType Directory -Force -Path $DirPath | Out-Null
        }
    }
    else {
        [void](Resolve-MtpDir $Ctx $DirPath $true)
    }
}

# Returns @{ Length = <long>; Mtime = <datetime|null> }. Length = -1 means the
# file does not exist on the target (single call = one enumeration for MTP).
function Target-GetInfo {
    param($Ctx, [string]$FilePath)
    if ($Ctx.Type -eq 'folder') {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @{ Length = -1; Mtime = $null } }
        $i = Get-Item -LiteralPath $FilePath
        return @{ Length = [long]$i.Length; Mtime = [datetime]$i.LastWriteTime }
    }
    $info = Get-MtpInfo $Ctx $FilePath
    if (-not $info) { return @{ Length = -1; Mtime = $null } }
    return @{ Length = $info.Length; Mtime = $info.Mtime }
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

# Copy one file with retries. On an MTP failure the folder cache is dropped so
# the next attempt re-resolves fresh Shell folder handles.
function Invoke-CopyWithRetry {
    param($Ctx, [string]$SourceFile, [string]$DestPath, [scriptblock]$OnLog)
    $maxAttempts = 1 + [int]$Ctx.Settings.retries
    $verify = [bool]$Ctx.Settings.verifyAfterUpload
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Ctx.Type -eq 'mtp') { Copy-FileMtp $Ctx $SourceFile $DestPath $verify }
            else { Copy-FileFolder $SourceFile $DestPath $verify }
            return
        }
        catch {
            if ($attempt -lt $maxAttempts) {
                & $OnLog ("  attempt $attempt/$maxAttempts failed: $($_.Exception.Message)") 'WARN'
                Start-Sleep -Milliseconds (600 * $attempt)
                if ($Ctx.Type -eq 'mtp') { $Ctx.FolderCache.Clear() }
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

# --------------------------------------------------------------------------
# Sync engine
# --------------------------------------------------------------------------
function Invoke-Sync {
    param(
        [pscustomobject]$Profile,
        [scriptblock]$OnLog,        # param($msg, $level)
        [scriptblock]$OnProgress    # param($current, $total)
    )

    & $OnLog "Profile '$($Profile.name)'  ($($Profile.targetType))" 'INFO'

    $src = $Profile.sourcePath
    if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src)) {
        throw "Source folder not found: '$src'"
    }
    $src = (Get-Item -LiteralPath $src).FullName.TrimEnd('\')

    $exts = @()
    foreach ($e in @($Profile.extensions)) { $exts += ([string]$e).ToLowerInvariant() }
    if (-not $exts) { throw 'No file extensions configured for this profile.' }

    $destRoot = ($Profile.destinationPath).Trim()
    if ([string]::IsNullOrWhiteSpace($destRoot)) { throw 'Destination path is empty.' }
    $destRoot = $destRoot.TrimEnd('\')

    # Build the target context.
    $ctx = @{
        Type        = $Profile.targetType
        DeviceName  = $Profile.deviceName
        Settings    = $script:Config.mtp
        FolderCache = @{}
    }
    try {
        if ($Profile.targetType -eq 'mtp') {
            Ensure-MtpInterop
            & $OnLog "Locating MTP device '$($Profile.deviceName)'..." 'INFO'
            $names = @(Get-MtpDeviceNames)
            if ($names -notcontains $Profile.deviceName) {
                throw "MTP device '$($Profile.deviceName)' not found under This PC. Is it connected, unlocked, and set to File transfer (MTP)? Detected: $($names -join ', ')"
            }
            & $OnLog 'Device found.' 'INFO'
        }
        elseif ($Profile.targetType -ne 'folder') {
            throw "Unknown target type '$($Profile.targetType)'."
        }

        & $OnLog "Ensuring destination exists: $destRoot" 'INFO'
        Target-EnsureDir $ctx $destRoot

        & $OnLog "Scanning source for $($exts -join ', ') ..." 'INFO'
        $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLowerInvariant() })
        $total = $files.Count
        & $OnLog "Found $total matching file(s)." 'INFO'
        & $OnProgress 0 $total

        $copied = 0; $skipped = 0; $failed = 0
        $i = 0
        foreach ($f in $files) {
            if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
            $i++
            $rel  = $f.FullName.Substring($src.Length).TrimStart('\')
            $dest = $destRoot + '\' + $rel
            try {
                $need = $false; $reason = ''
                $di = Target-GetInfo $ctx $dest        # one live lookup (Length = -1 if absent)
                # MTP devices report DateModified in UTC; folder targets preserve local mtime.
                $srcTime = if ($ctx.Type -eq 'mtp') { $f.LastWriteTimeUtc } else { $f.LastWriteTime }
                if ($di.Length -lt 0) {
                    $need = $true; $reason = 'new'
                }
                elseif ([long]$f.Length -ne $di.Length) {
                    $need = $true; $reason = 'size changed'
                }
                elseif ($null -ne $di.Mtime -and $srcTime -gt $di.Mtime.AddSeconds(2)) {
                    $need = $true; $reason = 'source newer'
                }

                if ($need) {
                    Invoke-CopyWithRetry $ctx $f.FullName $dest $OnLog
                    $copied++
                    & $OnLog ("COPIED  ($reason)  $rel") 'COPY'
                }
                else {
                    $skipped++
                    & $OnLog ("skip           $rel") 'SKIP'
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
$form.Size = New-Object System.Drawing.Size(760, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(640, 520)
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

# ---- Settings group -------------------------------------------------------
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Settings'; $grp.Location = '15,50'; $grp.Size = '715,205'; $grp.Anchor = 'Top,Left,Right'
$form.Controls.Add($grp)

# Source
$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Text = 'Source folder:'; $lblSrc.Location = '15,28'; $lblSrc.AutoSize = $true
$grp.Controls.Add($lblSrc)
$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Location = '130,25'; $txtSrc.Size = '480,24'; $txtSrc.Anchor = 'Top,Left,Right'
$grp.Controls.Add($txtSrc)
$btnSrcBrowse = New-Object System.Windows.Forms.Button
$btnSrcBrowse.Text = 'Browse...'; $btnSrcBrowse.Location = '618,24'; $btnSrcBrowse.Size = '80,26'; $btnSrcBrowse.Anchor = 'Top,Right'
$grp.Controls.Add($btnSrcBrowse)

# Target type
$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Target type:'; $lblType.Location = '15,63'; $lblType.AutoSize = $true
$grp.Controls.Add($lblType)
$cboType = New-Object System.Windows.Forms.ComboBox
$cboType.Location = '130,60'; $cboType.Size = '160,24'; $cboType.DropDownStyle = 'DropDownList'
[void]$cboType.Items.Add('folder'); [void]$cboType.Items.Add('mtp')
$grp.Controls.Add($cboType)
$lblTypeHint = New-Object System.Windows.Forms.Label
$lblTypeHint.Text = '(folder = USB / local path   |   mtp = data collector over USB)'
$lblTypeHint.Location = '300,63'; $lblTypeHint.AutoSize = $true; $lblTypeHint.ForeColor = 'Gray'
$grp.Controls.Add($lblTypeHint)

# Device name (mtp)
$lblDev = New-Object System.Windows.Forms.Label
$lblDev.Text = 'Device name:'; $lblDev.Location = '15,98'; $lblDev.AutoSize = $true
$grp.Controls.Add($lblDev)
$txtDev = New-Object System.Windows.Forms.TextBox
$txtDev.Location = '130,95'; $txtDev.Size = '350,24'
$grp.Controls.Add($txtDev)
$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Detect...'; $btnDetect.Location = '488,94'; $btnDetect.Size = '90,26'
$grp.Controls.Add($btnDetect)

# Destination
$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Destination:'; $lblDest.Location = '15,133'; $lblDest.AutoSize = $true
$grp.Controls.Add($lblDest)
$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Location = '130,130'; $txtDest.Size = '480,24'; $txtDest.Anchor = 'Top,Left,Right'
$grp.Controls.Add($txtDest)
$btnDestBrowse = New-Object System.Windows.Forms.Button
$btnDestBrowse.Text = 'Browse...'; $btnDestBrowse.Location = '618,129'; $btnDestBrowse.Size = '80,26'; $btnDestBrowse.Anchor = 'Top,Right'
$grp.Controls.Add($btnDestBrowse)

# Extensions
$lblExt = New-Object System.Windows.Forms.Label
$lblExt.Text = 'File types:'; $lblExt.Location = '15,168'; $lblExt.AutoSize = $true
$grp.Controls.Add($lblExt)
$txtExt = New-Object System.Windows.Forms.TextBox
$txtExt.Location = '130,165'; $txtExt.Size = '250,24'
$grp.Controls.Add($txtExt)
$lblExtHint = New-Object System.Windows.Forms.Label
$lblExtHint.Text = 'comma separated, e.g.  .csv, .dxf'
$lblExtHint.Location = '390,168'; $lblExtHint.AutoSize = $true; $lblExtHint.ForeColor = 'Gray'
$grp.Controls.Add($lblExtHint)

# ---- Action buttons -------------------------------------------------------
$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'Sync now'; $btnSync.Location = '15,265'; $btnSync.Size = '150,36'
$btnSync.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSync)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = '175,265'; $btnCancel.Size = '90,36'; $btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '280,272'; $progress.Size = '450,22'; $progress.Anchor = 'Top,Left,Right'
$form.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready.'; $lblStatus.Location = '15,310'; $lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

# ---- Log ------------------------------------------------------------------
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = '15,335'; $txtLog.Size = '715,235'
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

function Update-TypeUi {
    $isMtp = ($cboType.SelectedItem -eq 'mtp')
    $txtDev.Enabled = $isMtp
    $btnDetect.Enabled = $isMtp
    $btnDestBrowse.Enabled = -not $isMtp
}

function Load-ProfileToUi {
    param([pscustomobject]$P)
    $script:CurrentProfile = $P
    $txtSrc.Text  = [string]$P.sourcePath
    $cboType.SelectedItem = ([string]$P.targetType)
    if ($cboType.SelectedIndex -lt 0) { $cboType.SelectedIndex = 0 }
    $txtDev.Text  = [string]$P.deviceName
    $txtDest.Text = [string]$P.destinationPath
    $txtExt.Text  = (@($P.extensions) -join ', ')
    Update-TypeUi
}

function Commit-UiToProfile {
    if (-not $script:CurrentProfile) { return }
    $p = $script:CurrentProfile
    $p.sourcePath      = $txtSrc.Text.Trim()
    $p.targetType      = [string]$cboType.SelectedItem
    $p.deviceName      = $txtDev.Text.Trim()
    $p.destinationPath = $txtDest.Text.Trim()
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
    foreach ($c in @($cboProfile,$btnNew,$btnRename,$btnDelete,$btnSave,$txtSrc,$btnSrcBrowse,
                     $cboType,$txtDev,$btnDetect,$txtDest,$btnDestBrowse,$txtExt)) {
        $c.Enabled = -not $Busy
    }
    if (-not $Busy) { Update-TypeUi }
}

# ---- Event handlers -------------------------------------------------------
$cboProfile.Add_SelectedIndexChanged({
    if ($script:IsSyncing) { return }
    $name = [string]$cboProfile.SelectedItem
    $p = $script:Config.profiles | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($p) { Load-ProfileToUi $p }
})

$cboType.Add_SelectedIndexChanged({ Update-TypeUi })

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
    $script:Config.lastProfile = $script:CurrentProfile.name
    try { Save-Config; $lblStatus.Text = "Saved settings to config.json." ; Write-Log 'Settings saved.' }
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
Refresh-ProfileList -SelectName $script:Config.lastProfile
Write-Log 'Sync Data Collector ready.'
[void]$form.ShowDialog()
