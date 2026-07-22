<#
    SyncDataCollector.ps1
    Lightweight one-way file sync from a Windows PC to survey data collectors.

    - One-way push only (source -> collector). Never deletes on the target.
    - Copies only .csv / .dxf by default (configurable per profile).
    - Two target types:
        * "folder" : any drive-letter / UNC / local path (USB stick, collector's internal disk).
        * "mtp"    : an MTP device (over USB), via the bundled MediaDevices WPD library.
    - Mirrors the source subfolder tree under the destination.
    - Copies only new or changed files (size differs, or source newer than target).
    - Re-checks the live target every run; it never trusts a cached manifest.
    - MTP safeguards: atomic temp-upload + rename, per-file watchdog timeout,
      on-device size verification, and retry-with-reconnect.

    No build step: PowerShell 5.1 + .NET Framework + WinForms. Launch via
    SyncDataCollector.cmd (sets -STA and bypasses execution policy).
#>

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Paths / globals
# --------------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$DllPath    = Join-Path $ScriptDir 'lib\MediaDevices.dll'
$LogFile    = Join-Path $ScriptDir 'sync-log.txt'

$script:Config          = $null
$script:CurrentProfile  = $null
$script:IsSyncing       = $false
$script:CancelRequested = $false
$script:MtpLoaded       = $false

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
        retries           = 2       # extra attempts per file after the first (reconnects between tries)
        fileTimeoutSec    = 90      # base per-file timeout floor (seconds)
        minBytesPerSec    = 200000  # add (fileSize / this) seconds to the timeout for big files
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
function ConvertTo-MtpPath {
    param([string]$Path)
    $x = ($Path -replace '/', '\')
    $x = $x -replace '\\+', '\'
    $x = $x.Trim().Trim('\')
    return '\' + $x
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
#   $ctx = @{ Type = 'folder'|'mtp'; Device = <MediaDevice or $null> }
# Destination paths passed in are the *logical* path:
#   folder -> a normal Windows path; mtp -> on-device path (normalised inside).
# --------------------------------------------------------------------------
function Target-EnsureDir {
    param($Ctx, [string]$DirPath)
    if ($Ctx.Type -eq 'folder') {
        if (-not (Test-Path -LiteralPath $DirPath)) {
            New-Item -ItemType Directory -Force -Path $DirPath | Out-Null
        }
    }
    else {
        $norm = ConvertTo-MtpPath $DirPath
        if ($Ctx.Device.DirectoryExists($norm)) { return }
        $parts = $norm.Trim('\') -split '\\'
        $cur = ''
        foreach ($seg in $parts) {
            $cur = $cur + '\' + $seg
            if (-not $Ctx.Device.DirectoryExists($cur)) { $Ctx.Device.CreateDirectory($cur) }
        }
    }
}

function Target-FileExists {
    param($Ctx, [string]$FilePath)
    if ($Ctx.Type -eq 'folder') {
        return (Test-Path -LiteralPath $FilePath -PathType Leaf)
    }
    return $Ctx.Device.FileExists((ConvertTo-MtpPath $FilePath))
}

function Target-GetInfo {
    param($Ctx, [string]$FilePath)
    if ($Ctx.Type -eq 'folder') {
        $i = Get-Item -LiteralPath $FilePath
        return @{ Length = [long]$i.Length; Mtime = [datetime]$i.LastWriteTime }
    }
    $fi = $Ctx.Device.GetFileInfo((ConvertTo-MtpPath $FilePath))
    $mt = $null
    if ($fi.LastWriteTime -ne $null) { $mt = [datetime]$fi.LastWriteTime }
    return @{ Length = [long]$fi.Length; Mtime = $mt }
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

# One MTP upload, guarded by a watchdog that calls device.Cancel() if it hangs.
function Invoke-MtpUpload {
    param($Ctx, [string]$SourceFile, [string]$TempMtpPath, [int]$TimeoutSec)
    $fs = [System.IO.File]::OpenRead($SourceFile)
    $wd = New-Object SyncDC.MtpWatchdog($Ctx.Device, [int]($TimeoutSec * 1000))
    try {
        $Ctx.Device.UploadFile($fs, $TempMtpPath)
    }
    catch {
        if ($wd.Fired) { throw "transfer timed out after ${TimeoutSec}s (device not responding)" }
        throw
    }
    finally {
        $wd.Dispose()
        $fs.Dispose()
    }
}

# MTP copy: upload to a temp name, verify the on-device size, delete any existing
# final file, then rename temp -> final. So a partial/incomplete upload is never
# mistaken for the finished file; the next run overwrites the stale temp cleanly.
function Copy-FileMtp {
    param($Ctx, [string]$SourceFile, [string]$DestPath, [int]$TimeoutSec, [bool]$Verify)
    $norm = ConvertTo-MtpPath $DestPath
    $dir  = Split-Path -Parent $norm
    $leaf = Split-Path -Leaf $norm
    Target-EnsureDir $Ctx $dir
    $tempPath = $dir + '\' + $leaf + $script:TempSuffix
    if ($Ctx.Device.FileExists($tempPath)) { $Ctx.Device.DeleteFile($tempPath) }
    Invoke-MtpUpload $Ctx $SourceFile $tempPath $TimeoutSec
    if ($Verify) {
        $srcLen = [long](Get-Item -LiteralPath $SourceFile).Length
        $ti = $Ctx.Device.GetFileInfo($tempPath)
        if ([long]$ti.Length -ne $srcLen) {
            try { $Ctx.Device.DeleteFile($tempPath) } catch {}
            throw "incomplete upload (device $([long]$ti.Length) of $srcLen bytes)"
        }
    }
    if ($Ctx.Device.FileExists($norm)) { $Ctx.Device.DeleteFile($norm) }
    # Rename's newName is just the final leaf name (temp lives in the same dir).
    $Ctx.Device.Rename($tempPath, $leaf)
}

# Copy one file with retries. Between MTP attempts the device is reconnected,
# since a timeout/Cancel can leave the session unusable.
function Invoke-CopyWithRetry {
    param($Ctx, [string]$SourceFile, [string]$DestPath, [scriptblock]$OnLog)
    $s = $Ctx.Settings
    $maxAttempts = 1 + [int]$s.retries
    $sizeBytes = [long](Get-Item -LiteralPath $SourceFile).Length
    $timeoutSec = [int][math]::Ceiling([double]$s.fileTimeoutSec + ($sizeBytes / [double]$s.minBytesPerSec))
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Ctx.Type -eq 'mtp') {
                Copy-FileMtp $Ctx $SourceFile $DestPath $timeoutSec ([bool]$s.verifyAfterUpload)
            }
            else {
                Copy-FileFolder $SourceFile $DestPath ([bool]$s.verifyAfterUpload)
            }
            return
        }
        catch {
            if ($attempt -lt $maxAttempts) {
                & $OnLog ("  attempt $attempt/$maxAttempts failed: $($_.Exception.Message)") 'WARN'
                Start-Sleep -Milliseconds (500 * $attempt)
                if ($Ctx.Type -eq 'mtp') {
                    try { Reset-MtpConnection $Ctx $OnLog } catch {
                        throw "lost device and could not reconnect: $($_.Exception.Message)"
                    }
                }
            }
            else {
                throw
            }
        }
    }
}

# --------------------------------------------------------------------------
# MTP device enumeration / connection
# --------------------------------------------------------------------------
function Ensure-MtpLoaded {
    if ($script:MtpLoaded) { return }
    if (-not (Test-Path -LiteralPath $DllPath)) {
        throw "MediaDevices.dll not found next to the app (lib\MediaDevices.dll). MTP targets need it."
    }
    Add-Type -Path $DllPath
    # Watchdog: aborts a hung MTP upload by calling MediaDevice.Cancel() from a
    # threadpool timer. It must be pure .NET (not a PowerShell scriptblock) so it
    # can fire while the UI thread is blocked inside UploadFile.
    if (-not ('SyncDC.MtpWatchdog' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;
namespace SyncDC {
    public class MtpWatchdog : IDisposable {
        private Timer _timer;
        private object _device;
        public volatile bool Fired = false;
        public MtpWatchdog(object device, int timeoutMs) {
            _device = device;
            _timer = new Timer(OnTick, null, timeoutMs, Timeout.Infinite);
        }
        private void OnTick(object state) {
            Fired = true;
            try {
                MethodInfo mi = _device.GetType().GetMethod("Cancel", Type.EmptyTypes);
                if (mi != null) mi.Invoke(_device, null);
            } catch { }
        }
        public void Dispose() {
            Timer t = _timer; _timer = null;
            if (t != null) t.Dispose();
        }
    }
}
'@
    }
    $script:MtpLoaded = $true
}

function Get-MtpDeviceNames {
    Ensure-MtpLoaded
    $names = @()
    foreach ($d in [MediaDevices.MediaDevice]::GetDevices()) {
        $n = $d.FriendlyName
        if ([string]::IsNullOrWhiteSpace($n)) { $n = $d.Description }
        if ([string]::IsNullOrWhiteSpace($n)) { $n = $d.Manufacturer }
        if ($n) { $names += $n }
        $d.Dispose()
    }
    return $names
}

function Open-MtpDevice {
    param([string]$Name)
    Ensure-MtpLoaded
    $devices = @([MediaDevices.MediaDevice]::GetDevices())
    $match = $null
    foreach ($d in $devices) {
        if ($d.FriendlyName -eq $Name -or $d.Description -eq $Name) { $match = $d; break }
    }
    if (-not $match) {
        foreach ($d in $devices) {
            if (($d.FriendlyName -and $d.FriendlyName -like "*$Name*") -or
                ($d.Description  -and $d.Description  -like "*$Name*")) { $match = $d; break }
        }
    }
    foreach ($d in $devices) { if ($d -ne $match) { $d.Dispose() } }
    if (-not $match) {
        throw "MTP device '$Name' not found. Is it connected, unlocked, and in File-transfer (MTP) mode?"
    }
    # Explicit overload (PS 5.1 won't fill C# optional params). enableCache=$false
    # so every FileExists/GetFileInfo query hits the device live, never a cache.
    $match.Connect([MediaDevices.MediaDeviceAccess]::Default, [MediaDevices.MediaDeviceShare]::Default, $false)
    return $match
}

function Reset-MtpConnection {
    param($Ctx, [scriptblock]$OnLog)
    try { if ($Ctx.Device -and $Ctx.Device.IsConnected) { $Ctx.Device.Disconnect() } } catch {}
    try { if ($Ctx.Device) { $Ctx.Device.Dispose() } } catch {}
    $Ctx.Device = $null
    Start-Sleep -Milliseconds 400
    if ($OnLog) { & $OnLog '  reconnecting to device...' 'WARN' }
    $Ctx.Device = Open-MtpDevice -Name $Ctx.DeviceName
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
        Type       = $Profile.targetType
        Device     = $null
        DeviceName = $Profile.deviceName
        Settings   = $script:Config.mtp
    }
    try {
        if ($Profile.targetType -eq 'mtp') {
            & $OnLog "Connecting to MTP device '$($Profile.deviceName)'..." 'INFO'
            $ctx.Device = Open-MtpDevice -Name $Profile.deviceName
            & $OnLog "Connected." 'INFO'
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
                if (-not (Target-FileExists $ctx $dest)) {
                    $need = $true; $reason = 'new'
                }
                else {
                    $di = Target-GetInfo $ctx $dest
                    if ([long]$f.Length -ne $di.Length) {
                        $need = $true; $reason = 'size changed'
                    }
                    elseif ($di.Mtime -ne $null -and $f.LastWriteTime -gt $di.Mtime.AddSeconds(2)) {
                        $need = $true; $reason = 'source newer'
                    }
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
        if ($ctx.Device) {
            try { if ($ctx.Device.IsConnected) { $ctx.Device.Disconnect() } } catch {}
            try { $ctx.Device.Dispose() } catch {}
        }
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
