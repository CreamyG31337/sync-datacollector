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
        [string[]]$Extensions = @('.csv', '.dxf', '.xml', '.ttm', '.rxl'),
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

# A drive letter the tool may create with `subst` when it is missing, and the
# folders it is allowed to point at. Several targets because one config.json is
# shared by the whole crew: the first target that exists on THIS machine wins,
# so a single entry covers everybody. %ENVVAR% is expanded, which is normally
# all it takes -- "%OneDriveCommercial%\Teams - Surveying" is right for every
# user on every machine, where a C:\Users\<name>\... path is right for one.
function New-DriveMap {
    param(
        [string]$Letter = '',
        [string[]]$Targets = @()
    )
    [pscustomobject]@{
        letter  = (Get-DriveLetter $Letter)
        targets = $Targets
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
        driveMap      = @(                  # letters the tool re-creates with subst
            New-DriveMap -Letter 'S' -Targets @(
                '%OneDriveCommercial%\Teams - Surveying'
                '%USERPROFILE%\OneDrive - Company\Teams - Surveying'
            )
        )
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
                    # $prj, not $_: the route loop below rebinds $_ and would
                    # otherwise read the route's fields as the project's.
                    $prj = $_
                    $rts = @()
                    if ($prj.PSObject.Properties['exportRoutes']) {
                        foreach ($r in @($prj.exportRoutes)) {
                            if (-not $r) { continue }
                            $rf = if ($r.PSObject.Properties['from']      -and $r.from)      { [string]$r.from }      else { 'export' }
                            $rc = if ($r.PSObject.Properties['collision'] -and $r.collision) { [string]$r.collision } else { 'prefix' }
                            $rd = if ($r.PSObject.Properties['dateFrom']  -and $r.dateFrom)  { [string]$r.dateFrom }  else { 'run' }
                            $rts += New-ExportRoute -Name ([string]$r.name) -From $rf `
                                        -Extensions @($r.extensions) -Root ([string]$r.root) `
                                        -Collision $rc -DateFrom $rd
                        }
                    }
                    New-Project -Name $prj.name -DesignSource $prj.designSource `
                        -ExportRoot $prj.exportRoot -DeviceProjectPath $prj.deviceProjectPath `
                        -ExportRoutes $rts
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
                    $jr = if ($_.PSObject.Properties['jobRetentionDays']) { [int]$_.jobRetentionDays } else { (Get-Defaults).jobRetentionDays }
                    New-Collector -Serial $_.serial -Name $_.name -Model $_.model -Type $_.type `
                        -DesignSubPath $_.designSubPath -ExportSubPath $_.exportSubPath `
                        -DesignExtensions @($_.designExtensions) -ExportExtensions @($_.exportExtensions) `
                        -ExcludeFolders $ec -Prune $pr -ExportCollision $xc -JobRetentionDays $jr
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
            # Drive letters the tool may create with subst. Absent means the
            # config predates the feature: leave it empty rather than inventing
            # a mapping, since substituting the wrong folder onto S: would point
            # every path in the file at the wrong site's design tree.
            $dm = @()
            if ($cfg.PSObject.Properties['driveMap']) {
                $dm = @(@($cfg.driveMap) | ForEach-Object { New-DriveMap -Letter ([string]$_.letter) -Targets @($_.targets) })
            }
            $cfg | Add-Member -NotePropertyName driveMap -NotePropertyValue $dm -Force
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
    # Depth 8: projects -> exportRoutes -> a route -> its extensions array bottoms
    # out at 6, so 6 left no margin for the next nested thing anyone adds.
    $script:Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
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
    param($When = $null)
    $now = if ($When) { [datetime]$When } else { Get-Date }
    return ('{0}-{1:D3}' -f $now.ToString('yy'), $now.DayOfYear)
}

# The julian stamp crews put in export filenames: YY-DDD, so 26-219 is day 219 of
# 2026. Deliberately strict -- exactly two digits, a dash, exactly three digits,
# with no digit either side. That is what keeps a project number (2100-...), a
# two-digit day (2100-26-06-ABC) and an MMDDYYYY stamp (11182025) from being read
# as a date. Anything it is not sure about, it returns nothing for, and the caller
# falls back to the file's own timestamp.
function Get-JulianFromName {
    param([string]$Name)
    $m = [regex]::Match([string]$Name, '(?<![0-9])([0-9]{2})-([0-9]{3})(?![0-9])')
    if (-not $m.Success) { return $null }
    $dd = [int]$m.Groups[2].Value
    if ($dd -lt 1 -or $dd -gt 366) { return $null }
    $year = 2000 + [int]$m.Groups[1].Value
    try { $d = (New-Object datetime $year, 1, 1).AddDays($dd - 1) } catch { return $null }
    # Day 366 of a common year rolls into January of the next one -- not a date
    # this filename can have meant.
    if ($d.Year -ne $year) { return $null }
    return $d
}

# Where a pulled file is filed can depend on the FILE rather than the run: an
# export made in March belongs in March's folder even when it is pulled in
# September. Split a destination template at its first dated segment so the part
# before it is a fixed root, and the part after can be resolved per file.
function Split-DatedRoot {
    param([string]$Template)
    $t = ([string]$Template).Trim().TrimEnd('\')
    $segs = @($t -split '\\')
    $idx = -1
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($segs[$i] -match '(?i)\{(julian|year|month|date)\}') { $idx = $i; break }
    }
    if ($idx -lt 0) { return @{ Base = $t; Tail = '' } }
    $base = ''
    if ($idx -gt 0) { $base = (@($segs[0..($idx - 1)]) -join '\') }
    return @{ Base = $base; Tail = (@($segs[$idx..($segs.Count - 1)]) -join '\') }
}

# Month folder in the shape the datalogger-backup tree already uses: "8-AUG", "10-OCT"
# -- unpadded month number, hyphen, three-letter month upper-cased.
function Get-MonthFolder {
    # Zero-padded, so a year's folders sort in calendar order. Unpadded they do not:
    # 10-OCT, 11-NOV and 12-DEC sort above 2-FEB, which puts the end of the year at
    # the top of the list for the rest of it.
    param($When = $null)
    $now = if ($When) { [datetime]$When } else { Get-Date }
    return ('{0:D2}-{1}' -f $now.Month, $now.ToString('MMM', [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant())
}

# Expand path tokens, all case-insensitive:
#   {julian}  -> YY-DDD  (26-236)     {year}  -> 2026
#   {month}   -> 8-AUG                {date}  -> 2026-08-24
#   {apphome} -> the folder this app is running from
#   %ENVVAR%  -> expanded too (%USERPROFILE%, %OneDriveCommercial%, ...)
#
# {apphome} exists for the USB workflow: the app runs from the stick, so the stick's
# own design and export folders can be named without knowing its drive letter. The
# tablet may mount it as D: today and E: tomorrow, and a config that hard-codes a
# letter breaks the moment it does. Emitted without a trailing backslash so a root-
# mounted app ("D:\") still composes as "{apphome}\Trimble Data" -> "D:\Trimble Data".
function Expand-PathTokens {
    # $When dates the path from something other than right now -- the date read off
    # a file being pulled, so it lands in the folder for when it was surveyed.
    param([string]$Path, $When = $null)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $now = if ($When) { [datetime]$When } else { Get-Date }
    # Environment variables first, so one config.json fits every user.
    $out = Expand-EnvVars $Path
    $out = $out -replace '(?i)\{apphome\}', ([string]$ScriptDir).TrimEnd('\')
    $out = $out -replace '(?i)\{julian\}', (Get-JulianDate $now)
    $out = $out -replace '(?i)\{year\}',   $now.ToString('yyyy')
    $out = $out -replace '(?i)\{month\}',  (Get-MonthFolder $now)
    $out = $out -replace '(?i)\{date\}',   $now.ToString('yyyy-MM-dd')
    return $out
}

# --------------------------------------------------------------------------
# Mapped drives (subst)
#
# The design tree lives in OneDrive, but every path in config.json calls it S:.
# That letter is a `subst`, which lives and dies with the logon session -- so
# after a reboot S: is simply gone and every run fails with "Source folder not
# found" until somebody remembers to run a per-user .bat. The tool re-creates
# the mapping itself instead, from config.driveMap: once at startup, and again
# before any leg whose path needs it, in case it went away mid-session.
#
# The rules, in order of how much damage getting them wrong would do:
#   * a letter that already resolves is NEVER touched, whatever it points at;
#   * a letter held by a real disk or a network drive is never taken over;
#   * a stale subst (still mapped, but its folder is gone) is dropped first,
#     and only to re-point it at a folder that does exist.
# subst is per logon session AND per elevation level -- a mapping made here is
# invisible to an elevated process, and vice versa -- which is why every run
# re-checks instead of trusting that some earlier run set it up.
# --------------------------------------------------------------------------
$script:SubstExe = Join-Path $env:SystemRoot 'System32\subst.exe'

# %USERPROFILE%, %OneDriveCommercial%, ... -- what lets one config.json serve
# the whole crew, since the same folder is C:\Users\<them>\... on each machine.
function Expand-EnvVars {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

# The drive letter something names: 'S', 's:', 'S:\02-DESIGN' -> 'S'.
# A UNC path or a relative path names none, and gets ''.
function Get-DriveLetter {
    param([string]$Text)
    if ([string]$Text -match '^\s*([A-Za-z])(:|\s*$)') { return $Matches[1].ToUpperInvariant() }
    return ''
}

# Every OneDrive root this user has. The last-resort way to find the team folder
# when the configured paths were written on a machine that spells it differently.
function Get-OneDriveRoots {
    $roots = @()
    foreach ($v in @($env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer)) {
        if ($v -and (Test-Path -LiteralPath $v -PathType Container)) { $roots += ([string]$v).TrimEnd('\') }
    }
    try {
        foreach ($d in @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
            $roots += $d.FullName.TrimEnd('\')
        }
    }
    catch {}
    return @($roots | Select-Object -Unique)
}

# The driveMap entry for a letter, or $null if the tool was never told about it.
function Get-DriveMapEntry {
    param([string]$Letter)
    $L = Get-DriveLetter $Letter
    if (-not $L -or -not $script:Config) { return $null }
    if (-not $script:Config.PSObject.Properties['driveMap']) { return $null }
    return (@(@($script:Config.driveMap) | Where-Object { (Get-DriveLetter ([string]$_.letter)) -eq $L }) | Select-Object -First 1)
}

# Where the letter should point on THIS machine: the first configured target
# that exists, else the same folder name under any OneDrive root here.
function Resolve-DriveMapTarget {
    param($Entry)
    $targets = @()
    foreach ($t in @($Entry.targets)) {
        $p = (Expand-EnvVars ([string]$t)).Trim().TrimEnd('\')
        if ($p) { $targets += $p }
    }
    foreach ($p in $targets) {
        if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    }
    if ($targets.Count) {
        $leaf = Split-Path -Leaf $targets[0]
        if ($leaf) {
            foreach ($root in @(Get-OneDriveRoots)) {
                $p = Join-Path $root $leaf
                if (Test-Path -LiteralPath $p -PathType Container) { return $p.TrimEnd('\') }
            }
        }
    }
    return ''
}

# What `subst` says this letter points at, '' if it is not a subst at all.
function Get-SubstTarget {
    param([string]$Letter)
    $L = Get-DriveLetter $Letter
    if (-not $L) { return '' }
    try {
        foreach ($line in @(& $script:SubstExe)) {
            # "S:\: => C:\Users\you\OneDrive - Company\Teams - Surveying"
            if ([string]$line -match ('^\s*' + $L + ':.*?=>\s*(.+?)\s*$')) { return $Matches[1] }
        }
    }
    catch {}
    return ''
}

# Make <Letter>: resolve, creating the subst if it does not already.
# Returns @{ Ok; Action = ready|mapped|remapped|skipped|failed; Message }.
function Ensure-MappedDrive {
    param([string]$Letter)
    $L = Get-DriveLetter $Letter
    if (-not $L) { return @{ Ok = $false; Action = 'skipped'; Message = "'$Letter' is not a drive letter." } }
    $root = $L + ':\'

    # Already there. Never second-guess a letter that works, even if it points
    # somewhere other than driveMap says -- it may have been mapped on purpose.
    if (Test-Path -LiteralPath $root) { return @{ Ok = $true; Action = 'ready'; Message = "$L`: is available." } }

    $entry = Get-DriveMapEntry $L
    if (-not $entry) {
        return @{ Ok = $false; Action = 'skipped'
                  Message = "$L`: is not available, and config.json has no driveMap entry for it." }
    }

    # Not ready, but possibly still taken: an empty card reader, a dropped network
    # drive, or a subst whose folder went away. Only the last is ours to clear.
    $stale = Get-SubstTarget $L
    if (-not $stale) {
        $held = @([System.IO.DriveInfo]::GetDrives() | Where-Object { (Get-DriveLetter $_.Name) -eq $L })
        if ($held.Count) {
            return @{ Ok = $false; Action = 'skipped'
                      Message = "$L`: is held by a $($held[0].DriveType) drive that is not ready -- leaving it alone." }
        }
    }

    $target = Resolve-DriveMapTarget $entry
    if (-not $target) {
        $tried = ((@($entry.targets) | ForEach-Object { (Expand-EnvVars ([string]$_)) }) -join '  |  ')
        return @{ Ok = $false; Action = 'failed'
                  Message = "Cannot map $L`: -- none of these folders exist here: $tried" }
    }

    $action = 'mapped'
    if ($stale) {
        # Mapped, but at a folder that is gone (OneDrive re-homed it, the profile
        # was renamed). Drop it so the letter can be pointed at the real one.
        $action = 'remapped'
        try { & $script:SubstExe ($L + ':') '/D' | Out-Null } catch {}
    }
    try { & $script:SubstExe ($L + ':') $target | Out-Null }
    catch { return @{ Ok = $false; Action = 'failed'; Message = "subst $L`: failed: $($_.Exception.Message)" } }

    # subst reports failure on stderr, which a windowed process has nowhere to
    # show, so the drive itself is the only answer worth trusting.
    if (-not (Test-Path -LiteralPath $root)) {
        return @{ Ok = $false; Action = 'failed'; Message = "subst $L`: '$target' did not take (exit code $LASTEXITCODE)." }
    }
    $verb = if ($action -eq 'remapped') { 'Re-mapped' } else { 'Mapped' }
    return @{ Ok = $true; Action = $action; Message = "$verb $L`: -> $target" }
}

# Ensure + log. Silent when the drive was already there (which is every run,
# normally); it speaks up only when it had to act, or could not.
function Confirm-MappedDrive {
    param([string]$Letter, [scriptblock]$OnLog)
    $r = Ensure-MappedDrive $Letter
    if ($OnLog -and $r.Action -ne 'ready') {
        $lvl = if ($r.Ok) { 'INFO' } else { 'WARN' }
        & $OnLog $r.Message $lvl
    }
    return $r
}

# Every letter driveMap knows about -- the startup pass.
function Confirm-MappedDrives {
    param([scriptblock]$OnLog)
    if (-not $script:Config -or -not $script:Config.PSObject.Properties['driveMap']) { return }
    foreach ($e in @($script:Config.driveMap)) {
        $L = Get-DriveLetter ([string]$e.letter)
        if ($L) { [void](Confirm-MappedDrive $L $OnLog) }
    }
}

# The letter a path is rooted on, but only if it is one of ours and missing --
# the per-run pass, so a drive lost mid-session is back before the leg needs it.
function Confirm-PathDrive {
    param([string]$Path, [scriptblock]$OnLog)
    $L = Get-DriveLetter ((Expand-EnvVars ([string]$Path)).Trim())
    if (-not $L) { return }
    if (Test-Path -LiteralPath ($L + ':\')) { return }
    if (-not (Get-DriveMapEntry $L)) { return }
    [void](Confirm-MappedDrive $L $OnLog)
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
    param($Ctx, [string]$Kind, [string]$Path, [long]$SrcLen, $SrcMtimeUtc, [string]$AltLabel = 'ORIG')
    $dir  = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext  = [System.IO.Path]::GetExtension($leaf)
    for ($i = 1; $i -lt 200; $i++) {
        $cand = $Path
        if ($i -gt 1) {
            # The first alternate says WHY it is there rather than just numbering it:
            # it is the collector's original, kept beside a copy the office has since
            # edited -- normally check shots deleted during review. Later ones number
            # off that, which only happens if a third version turns up.
            $tag = if ($i -eq 2) { $AltLabel } else { '{0} {1}' -f $AltLabel, ($i - 1) }
            $n = ('{0} ({1}){2}' -f $base, $tag, $ext)
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
        $out += @{ Name = $it.Name; Serial = $serial; Path = $it.Path; Item = $it; Kind = 'mtp'; Root = '' }
    }
    return $out
}

# Removable volumes (USB sticks), shaped like Get-MtpDevices so one list can carry
# both kinds. Identity is the VOLUME SERIAL, never the drive letter: Windows hands a
# stick whatever letter happens to be free, so today's D: is tomorrow's E: -- and
# pushing a mirrored design folder onto "whatever is on D:" is exactly the accident
# worth engineering out. "VOL-" prefixes it so a volume id can never be mistaken for
# an MTP hardware serial. A volume with no serial is skipped: nothing to lock to.
function Get-VolumeDevices {
    $out = @()
    $vols = @()
    try { $vols = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 2' -ErrorAction Stop) }
    catch { return $out }
    foreach ($v in $vols) {
        $vs = ([string]$v.VolumeSerialNumber).Trim().ToUpperInvariant()
        if (-not $vs) { continue }
        $name = ([string]$v.VolumeName).Trim()
        if (-not $name) { $name = 'USB volume' }
        $root = ([string]$v.DeviceID).TrimEnd('\') + '\'
        $out += @{ Name = $name; Serial = ('VOL-' + $vs); Path = $root; Item = $null; Kind = 'folder'; Root = $root }
    }
    return $out
}

# The bare volume serial behind a folder collector's id ("VOL-00000000" -> "00000000").
function Get-VolumeSerial {
    param([string]$Serial)
    return (([string]$Serial) -replace '^VOL-', '').Trim().ToUpperInvariant()
}

# Is this collector pinned to a removable volume, as opposed to being a plain folder
# target? Both are type "folder", and they behave differently: a volume-pinned target
# is found by serial wherever it is mounted, while a plain folder target -- a Windows
# tablet running this app against its own disk -- is just the path in the config. Only
# the "VOL-" id says which, so that is what decides it.
function Test-VolumeCollector {
    param($Collector)
    if ([string]$Collector.type -ne 'folder') { return $false }
    return (([string]$Collector.serial) -match '^VOL-')
}

# Where Windows has mounted the volume this folder collector is pinned to, right now.
# '' when it is not plugged in -- callers treat that as "not connected" rather than
# falling back to a letter, which is the whole point of pinning to the serial.
function Resolve-VolumeRoot {
    param([string]$Serial)
    $want = Get-VolumeSerial $Serial
    if (-not $want) { return '' }
    $m = @(@(Get-VolumeDevices) | Where-Object { (Get-VolumeSerial $_.Serial) -eq $want })
    if ($m.Count -ge 1) { return [string]$m[0].Root }
    return ''
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
            # The Shell occasionally hands back a half-initialised item whose Name is
            # empty. Left alone it becomes a record with a trailing-backslash Rel --
            # a "file" the source can never account for, so prune proposes deleting
            # it, and the item it carries is really the FOLDER. Dropping it here is
            # the only safe reading: an entry we cannot name is one we must not act on.
            $nm = [string]$it.Name
            if ([string]::IsNullOrWhiteSpace($nm)) { continue }
            $rel = if ($node.Rel) { $node.Rel + '\' + $nm } else { $nm }
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
# 'prefix' prefixes the FIRST path segment rather than the filename. For a flat
# export folder those are the same thing.
#
# WARNING -- 'prefix' IS NOT SAFE FOR SCANS. A .jxl stores the companion folder name
# EXPLICITLY inside the file (e.g. "2100-25-CONTROL Files/AR-01.JPG"), so renaming
# that folder to "TSC5-02_2100-25-CONTROL Files" breaks the link: the media is on
# disk but the job can no longer find it, and nothing about the copy looks wrong.
# Prefixing the .jxl itself is harmless -- the stored path is relative to whatever
# folder the .jxl sits in -- but the FOLDER must keep its name.
#
# So a collector that exports scans wants 'deviceSubfolder', which separates crews
# by folder and leaves every name untouched. Invoke-Sync warns when 'prefix' is
# combined with .jxl in the export types.
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

# Has this file already been pulled, but filed somewhere other than where we would
# put it? The office files by company subfolder, and moves things between them; the
# exact-path check alone would pull such a file again on every sync for ever. Match
# on name AND size, within one month's folder only -- that is a narrow enough scope
# that the same name and the same byte count really is the same file.
function Test-AlreadyFiled {
    param($Ctx, [string]$Kind, [string]$ScopeDir, [string]$Leaf, [long]$Length)
    if ($Kind -ne 'fs' -or -not $ScopeDir -or $Length -lt 0) { return '' }
    if (-not (Test-Path -LiteralPath $ScopeDir)) { return '' }
    if (-not $Ctx.ContainsKey('FiledIndex')) { $Ctx.FiledIndex = @{} }
    $key = $ScopeDir.ToLowerInvariant()
    if (-not $Ctx.FiledIndex.ContainsKey($key)) {
        # Built once per month folder and cached: a sync touches the same handful of
        # months over and over, and these folders hold tens of files, not thousands.
        $idx = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $ScopeDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $k = $f.Name.ToLowerInvariant() + '|' + $f.Length
            if (-not $idx.ContainsKey($k)) { $idx[$k] = $f.FullName }
        }
        $Ctx.FiledIndex[$key] = $idx
    }
    $probe = ([string]$Leaf).ToLowerInvariant() + '|' + $Length
    if ($Ctx.FiledIndex[$key].ContainsKey($probe)) { return [string]$Ctx.FiledIndex[$key][$probe] }
    return ''
}

# --------------------------------------------------------------------------
# Job tidy-up
#
# A controller accumulates .job files until it runs out of room. Old ones are
# clutter; recent ones are the crew's working set, and a job nobody can replace
# is the worst thing this tool could destroy. So removal answers to three
# separate conditions, and every one of them must say yes.
# --------------------------------------------------------------------------

# Pure decision, deliberately: this is the one place in the app that decides to
# destroy field data, so it takes plain values and can be exercised without a
# device. $Now is injectable for the same reason.
function Test-JobRemovable {
    param(
        [string]$Leaf,
        $MtimeUtc,
        [int]$RetentionDays,
        [string]$BackupPath,        # '' when no verified copy was found
        $Now = $null
    )
    $now = if ($Now) { ([datetime]$Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $cut = $now.AddDays(-$RetentionDays)

    # 1. There has to be a copy somewhere else. No backup, no deletion, ever --
    #    this is the condition that makes the whole feature safe rather than clever.
    if (-not $BackupPath) { return @{ Remove = $false; Why = 'no backup copy found' } }

    # 2. A date in the name is what marks a job as one day's work. A generic name
    #    (2100-25-CONTROL) is a job the crew reopens, and age says nothing about it.
    $named = Get-JulianFromName $Leaf
    if (-not $named) { return @{ Remove = $false; Why = 'no date in the name - a job that gets reused' } }

    # 3. Both clocks must agree it is old. The julian says when the work was done,
    #    the timestamp says when the file was last touched; either one being inside
    #    the window keeps the file. An old survey reopened yesterday is in use.
    if ($null -eq $MtimeUtc) { return @{ Remove = $false; Why = 'no timestamp to judge its age by' } }
    $m = ([datetime]$MtimeUtc).ToUniversalTime()
    $days = [int][Math]::Floor(($now - $m).TotalDays)
    if ($m -gt $cut) { return @{ Remove = $false; Why = "modified $days day(s) ago" } }
    if ($named.ToUniversalTime() -gt $cut) { return @{ Remove = $false; Why = 'the date in its name is inside the window' } }

    return @{ Remove = $true; Why = "$days day(s) old, backed up" }
}

# Work out what a tidy-up would do, without doing any of it. Returns one row per
# .job on the collector -- kept ones included, with the reason -- so the dialog can
# show the whole picture rather than only the casualties.
function Get-JobCleanupPlan {
    param($Ctx, $Project, $Collector, [int]$RetentionDays, [scriptblock]$OnLog)

    $route = @(@(Get-ExportRoutes $Project $Collector) | Where-Object { @($_.extensions) -contains '.job' })[0]
    if (-not $route) {
        throw ('Nothing backs up .job files for this collector, so none can be confirmed safe to delete. ' +
               'Add an export route that carries .job before tidying.')
    }
    $devRoot = Get-CollectorDeviceRoot $Project $Collector
    if (-not $devRoot) { throw 'The collector is not connected.' }

    # Jobs live where the .job route reads from -- the project folder, normally.
    $src = $devRoot
    if ([string]$route.from -ne 'root') {
        $sub = ([string]$Collector.exportSubPath).Trim('\')
        if ($sub) { $src = $devRoot + '\' + $sub }
    }
    $kind = if ([string]$Collector.type -eq 'mtp') { 'mtp' } else { 'fs' }

    & $OnLog "Reading jobs from $src ..." 'INFO'
    $files = @()
    if ($kind -eq 'mtp') {
        # A locked or charging-only controller still enumerates, but exposes no
        # storage -- which reads as "no jobs here". Harmless for a delete (nothing
        # would go), but it would report a clean tidy on a device never actually
        # read. Say what happened instead.
        $storage = 0
        try {
            $f = $Ctx.DeviceItem.GetFolder
            if ($f) { $storage = [int]$f.Items().Count }
        }
        catch { $storage = 0 }
        if ($storage -le 0) {
            throw ("The collector is connected but exposing no storage, so its jobs cannot be read. " +
                   "Unlock the screen and set the USB connection to file transfer, then try again.")
        }
        $inv = Get-MtpInventory $Ctx $src
        foreach ($m in $inv.Files) { $files += @{ Rel = $m.Rel; Length = $m.Length; MtimeUtc = $m.MtimeUtc; Item = $m.Item } }
    }
    else {
        $inv = Get-FsInventory $src
        foreach ($m in $inv.Files) { $files += @{ Rel = $m.Rel; Length = $m.Length; MtimeUtc = $m.MtimeUtc; Item = $null } }
    }
    # Top-level only. A .job nested under a scan folder or inside 02-Design is
    # something else's business, and tidying is not the place to find out whose.
    $jobs = @($files | Where-Object {
        ([System.IO.Path]::GetExtension([string]$_.Rel)).ToLowerInvariant() -eq '.job' -and
        ([string]$_.Rel).IndexOf('\') -lt 0
    })

    # Index the whole backup tree by name and size, so a file counts as saved
    # wherever it was filed -- by month, or moved by hand afterwards.
    $base = (Split-DatedRoot (Expand-EnvVars ([string]$route.root))).Base
    $base = (Expand-PathTokens $base).Trim().TrimEnd('\')
    Confirm-PathDrive $base $OnLog
    $have = @{}
    if (Test-Path -LiteralPath $base) {
        foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $have[$f.Name.ToLowerInvariant() + '|' + $f.Length] = $f.FullName
        }
    }
    & $OnLog "Backup index: $($have.Count) file(s) under $base." 'INFO'

    $label = Get-CollectorFolderName $Collector
    $coll  = [string]$route.collision
    if (-not $coll) { $coll = 'prefix' }

    $rows = @()
    foreach ($j in $jobs) {
        # Two names to try. The backup carries whatever name the pull gave it, and
        # that has not always been today's: earlier runs filed under deviceSubfolder,
        # which leaves the filename bare. Accept either form -- the size has to match
        # regardless, and that is what makes a name match mean something.
        $destRel = Get-DestRel ([string]$j.Rel) 'pull' $coll $label
        $li = $destRel.LastIndexOf('\')
        $leaf = if ($li -ge 0) { $destRel.Substring($li + 1) } else { $destRel }
        $bare = [System.IO.Path]::GetFileName([string]$j.Rel)
        $backup = ''
        foreach ($n in @($leaf, $bare)) {
            $key = $n.ToLowerInvariant() + '|' + [long]$j.Length
            if ($have.ContainsKey($key)) { $backup = [string]$have[$key]; break }
        }
        $d = Test-JobRemovable ([string]$j.Rel) $j.MtimeUtc $RetentionDays $backup
        $rows += [pscustomobject]@{
            Rel = [string]$j.Rel; Length = [long]$j.Length; MtimeUtc = $j.MtimeUtc
            Item = $j.Item; Backup = $backup; Remove = [bool]$d.Remove; Why = [string]$d.Why
            Path = $src + '\' + [string]$j.Rel
        }
    }
    return @{ Rows = @($rows); Source = $src; BackupRoot = $base; Kind = $kind }
}

# Carry out a plan that has already been shown and agreed to. Re-checks the backup
# immediately before each delete: the plan may have been on screen for a while, and
# nothing here is worth a race.
function Invoke-JobCleanup {
    param($Ctx, $Plan, [scriptblock]$OnLog)
    $done = 0; $failed = 0
    foreach ($row in @($Plan.Rows | Where-Object { $_.Remove })) {
        try {
            if (-not $row.Backup -or -not (Test-Path -LiteralPath $row.Backup)) {
                throw 'its backup copy is no longer there'
            }
            $b = Get-Item -LiteralPath $row.Backup
            if ([long]$b.Length -ne [long]$row.Length) {
                throw ("the backup is a different size now ($($b.Length) vs $($row.Length))")
            }
            Target-DeleteFile $Ctx $Plan.Kind $row.Path $row.Item
            $done++
            & $OnLog ("REMOVED  $($row.Rel)   (saved at $($row.Backup))") 'COPY'
        }
        catch {
            $failed++
            & $OnLog ("KEPT     $($row.Rel)  ::  $($_.Exception.Message)") 'ERROR'
        }
    }
    return @{ Removed = $done; Failed = $failed }
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
    $files = @(); $malformed = 0
    foreach ($f in $inv.Files) {
        # Belt and braces behind the Get-MtpInventory guard: a rel that is blank or
        # ends in a separator names no file we can identify, and deleting something
        # we cannot name is exactly the mistake prune must never make.
        $rel = [string]$f.Rel
        if ([string]::IsNullOrWhiteSpace($rel) -or $rel.EndsWith('\')) { $malformed++; continue }
        # The marker is the tool's own identity record; pruning it would orphan the device.
        if ((Split-Path -Leaf $rel) -eq $script:MarkerName) { continue }
        if (-not $want.Contains($rel)) { $files += $f }
    }
    $dirs = @()
    foreach ($d in $inv.Dirs) {
        $dr = [string]$d
        if ([string]::IsNullOrWhiteSpace($dr)) { continue }
        if (-not $wantDirs.Contains($dr)) { $dirs += $dr }
    }
    # Deepest first, so a parent is only removed once its children are gone.
    $dirs = @($dirs | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)
    return @{ Files = $files; Dirs = $dirs; Malformed = $malformed }
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
    # A USB stick reads by where it is mounted -- "External (D:)" is what the user can
    # actually see in Explorer; the volume serial is what the tool matches on.
    $name = [string]$Dev.Name
    if ([string]$Dev['Kind'] -eq 'folder' -and $Dev['Root']) {
        $name = ('{0} [USB {1}]' -f $name, ([string]$Dev.Root).TrimEnd('\'))
    }
    if ($friendly) { return ('{0} - {1} ({2})' -f $friendly, $name, $s) }
    return ('{0} ({1})' -f $name, $s)
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

    # A volume-pinned folder target answers on identity, before any path is touched.
    # Asking "does the path exist?" is not the same question: with the stick out, a
    # different stick on the same letter would answer yes and get mirrored over.
    if ($Profile.PSObject.Properties['volumeSerial'] -and $Profile.volumeSerial) {
        $vs = Get-VolumeSerial ([string]$Profile.volumeSerial)
        if (-not (Resolve-VolumeRoot ([string]$Profile.volumeSerial))) {
            return @{ Ok = $false; Reason = "USB target (volume $vs) is not plugged in." }
        }
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
        [scriptblock]$OnChooseDevice,
        [scriptblock]$OnItem,
        [string[]]$Rescue = @()
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

        $res = Invoke-Sync -Profile $Profile -OnLog $OnLog -OnProgress $OnProgress -CheckOnly `
                    -OnChooseDevice $OnChooseDevice -OnItem $OnItem -Rescue $Rescue
        $n = @($res.OutOfDate).Count
        if ($n -eq 0) { $summary = "Up to date - $($res.Total) file(s) checked on $label, none out of date." }
        else          { $summary = "NEEDS SYNC - $n of $($res.Total) file(s) out of date on $label." }
        $pc = @($res.PruneCandidates).Count
        if ($pc -gt 0) { $summary += "  $pc extra file(s) on the device would be DELETED by a sync." }
        if ([int]$res.Kept -gt 0 -or @($Rescue).Count -gt 0) {
            $summary += "  $(@($Rescue).Count) marked to keep would be copied back instead."
        }
        return @{ Mode = 'live'; OutOfDate = $n; Total = $res.Total; Summary = $summary; PruneCount = $pc
                  Plan = @($res.Plan); SourceRoot = $res.SourceRoot; DestinationRoot = $res.DestinationRoot }
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
    # S: may be a subst that died with the logon session -- put it back
    # before reporting the design folder missing.
    Confirm-PathDrive $srcPath $OnLog
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
        [string]$DeviceProjectPath = '',   # Internal shared storage\Trimble Data\Projects\2100 - EXAMPLE SITE
        $ExportRoutes = @()                # empty = file every export type under ExportRoot
    )
    [pscustomobject]@{
        name              = $Name
        designSource      = $DesignSource
        exportRoot        = $ExportRoot
        deviceProjectPath = $DeviceProjectPath
        exportRoutes      = @($ExportRoutes)
    }
}

# One pull leg. Not every export belongs in the same place: raw .job files are
# datalogger state and belong in the backup tree, while the .csv and scans a
# surveyor deliberately exported are deliverables and belong with the QC data. So
# the export side is a LIST of routes, each with its own file types, destination
# and naming, rather than one destination for everything.
#   from  'export' -> the collector's export subfolder (03-Export, Exports, ...)
#         'root'   -> the project folder on the device itself, where Trimble Access
#                     leaves .job files
function New-ExportRoute {
    param(
        [string]$Name = 'Export',
        [string]$From = 'export',
        [string[]]$Extensions = @(),
        [string]$Root = '',
        [string]$Collision = 'prefix',
        # 'run'  - date folders come from when the sync runs (the original behaviour)
        # 'file' - from the julian date in the filename, or the file's own timestamp
        [string]$DateFrom = 'run'
    )
    [pscustomobject]@{
        name       = $Name
        from       = $From
        extensions = @($Extensions)
        root       = $Root
        collision  = $Collision
        dateFrom   = $DateFrom
    }
}

function Get-ExportRoutes {
    param($Project, $Collector)
    $routes = @()
    if ($Project.PSObject.Properties['exportRoutes']) {
        $routes = @(@($Project.exportRoutes) | Where-Object { $_ -and [string]$_.root })
    }
    if ($routes.Count) { return $routes }
    # Nothing configured: the original single-destination behaviour, so every config
    # written before routing existed keeps working without being touched.
    return @(New-ExportRoute -Name 'Export' -From 'export' `
                -Extensions @($Collector.exportExtensions) `
                -Root ([string]$Project.exportRoot) `
                -Collision ([string]$Collector.exportCollision))
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
        [string[]]$DesignExtensions = @('.csv', '.dxf', '.xml', '.ttm', '.rxl'),
        [string[]]$ExportExtensions = @('.job', '.jxl', '.csv', '.dxf', '.rxl', '.xml'),
        [string[]]$ExcludeFolders = @('SUPERSEDED'),
        [bool]$Prune = $true,                # the design folder is owned by the tool
        [string]$ExportCollision = 'prefix', # prefix | deviceSubfolder | overwrite
        [int]$JobRetentionDays = 7           # how much recent work Tidy jobs never touches
    )
    [pscustomobject]@{
        designSubPath    = $DesignSubPath
        exportSubPath    = $ExportSubPath
        designExtensions = $DesignExtensions
        exportExtensions = $ExportExtensions
        excludeFolders   = $ExcludeFolders
        prune            = $Prune
        exportCollision  = $ExportCollision
        jobRetentionDays = $JobRetentionDays
    }
}

# How many days of jobs Tidy must never touch. Clamped low so a mistyped 0 cannot
# turn "keep the last week" into "delete everything backed up".
function Get-JobRetentionDays {
    param($Collector)
    $d = 0
    if ($Collector -and $Collector.PSObject.Properties['jobRetentionDays']) { $d = [int]$Collector.jobRetentionDays }
    if ($d -lt 1) { $d = (Get-Defaults).jobRetentionDays }
    if ($d -lt 1) { $d = 7 }
    return $d
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
    $retain = $f.jobRetentionDays
    if (& $has 'jobRetentionDays') { $retain = [int]$Raw.jobRetentionDays }
    New-CollectorDefaults -DesignSubPath $designSub -ExportSubPath $exportSub `
        -DesignExtensions $designExt -ExportExtensions $exportExt -ExcludeFolders $exclude `
        -Prune $prune -ExportCollision $collision -JobRetentionDays $retain
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
        [string]$ExportCollision = (Get-Defaults).exportCollision,
        [int]$JobRetentionDays = (Get-Defaults).jobRetentionDays
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
        jobRetentionDays = $JobRetentionDays
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
    $n = Expand-EnvVars ([string]$Collector.name)
    if ($n) { return ('{0} ({1})' -f $n, [string]$Collector.serial) }
    return (Get-DeviceLabel ([string]$Collector.model) ([string]$Collector.serial))
}

# Folder-safe name for the per-collector export subfolder. Two crews exporting the
# same filename must never land on each other, so this has to be stable and unique.
# Environment variables are expanded here so ONE generated config can serve several
# tablets sharing a stick: a name of "%COMPUTERNAME%" resolves per machine, giving each
# tablet its own export prefix with nothing to type on a device that has no keyboard.
function Get-CollectorFolderName {
    param($Collector)
    $n = Expand-EnvVars ([string]$Collector.name)
    if (-not $n) { $n = [string]$Collector.serial }
    if (-not $n) { $n = [string]$Collector.model }
    return (($n -replace '[\\/:*?"<>|]', '-').Trim())
}

# Build a profile the sync engine already understands, for one leg of a run. This
# is the ONLY place the collector model touches the engine -- the engine, and every
# test around it, stays exactly as it was.
# The project's deviceProjectPath is written MTP-shaped: its first segment is the
# device's storage root ("Internal shared storage"), and the rest is the tree the job
# lives in ("Trimble Data\Projects\2100 - EXAMPLE"). A folder collector has a real
# drive root instead, so swap that first segment for wherever the volume is mounted
# now and the rest of the tree carries over unchanged -- one project path serves both
# kinds. Returns '' when a folder collector's volume is not plugged in; callers treat
# that as "not connected" rather than guessing a drive letter.
# deviceProjectPath minus its leading storage segment -- "Trimble Data\Projects\2100
# - EXAMPLE". This is the part of the tree that is the same wherever it is rooted, so
# both the volume rooting below and the generated tablet config work from it.
function Get-DeviceProjectSubPath {
    param($Project)
    $segs = @(Split-MtpPath (([string]$Project.deviceProjectPath).Trim().TrimEnd('\')))
    if ($segs.Count -gt 1) { return (@($segs[1..($segs.Count - 1)]) -join '\') }
    return ''
}

function Get-CollectorDeviceRoot {
    param($Project, $Collector)
    $devRoot = ([string]$Project.deviceProjectPath).Trim().TrimEnd('\')
    # A plain folder target keeps deviceProjectPath as the real path it already is;
    # only a volume-pinned one gets its root swapped for the current mount point.
    if (-not (Test-VolumeCollector $Collector)) { return $devRoot }
    $vol = Resolve-VolumeRoot ([string]$Collector.serial)
    if (-not $vol) { return '' }
    return ($vol.TrimEnd('\') + '\' + (Get-DeviceProjectSubPath $Project)).TrimEnd('\')
}

function New-LegProfile {
    param($Project, $Collector, [string]$Leg, $Route = $null)

    $devRoot = Get-CollectorDeviceRoot $Project $Collector
    $model   = [string]$Collector.model
    $type    = [string]$Collector.type
    $label   = Get-CollectorLabel $Collector

    # A folder collector is pinned to a volume serial, and $devRoot was resolved from
    # it above. Carry the serial on the profile so reachability can ask "is THAT stick
    # mounted?" rather than "does this path exist?" -- with the stick unplugged the
    # path either does not resolve or, worse, resolves onto a different stick.
    $isVol = Test-VolumeCollector $Collector
    $stamp = {
        param($P)
        if ($isVol) {
            $P | Add-Member -NotePropertyName volumeSerial -NotePropertyValue ([string]$Collector.serial) -Force
        }
        return $P
    }

    if ($Leg -eq 'design') {
        # PC -> collector, mirrored: the tool owns this folder. The project root is
        # carried along so the engine can refuse to mirror onto it -- see the guard
        # in Invoke-Sync; that folder is the crew's, not ours.
        $dp = New-Profile -Name ("$label - design") -Direction 'push' `
            -SourcePath ([string]$Project.designSource) `
            -TargetType $type -DeviceName $model `
            -DestinationPath ($devRoot + '\' + ([string]$Collector.designSubPath).Trim('\')) `
            -Extensions @($Collector.designExtensions) `
            -ExcludeFolders @($Collector.excludeFolders) `
            -Prune ([bool]$Collector.prune)
        $dp | Add-Member -NotePropertyName deviceProjectRoot -NotePropertyValue ([string]$devRoot) -Force
        return (& $stamp $dp)
    }

    # collector -> OneDrive, additive. Every collector exports into the SAME dated
    # folder, so files must carry which unit they came from or two crews exporting
    # 2100-25-346.csv collide (and OneDrive makes conflict copies).
    #   prefix          -> TSC5-01_2100-25-346.csv in one flat month folder
    #   deviceSubfolder -> TSC5-01\2100-25-346.csv
    #   overwrite       -> the name the surveyor gave it, untouched
    # deviceName still has to be the MTP model name so the device can be found; the
    # per-collector label is separate, which is why collisionLabel exists.
    if (-not $Route) { $Route = @(Get-ExportRoutes $Project $Collector)[0] }
    # 'root' pulls from the project folder itself -- where Trimble Access keeps its
    # .job files -- so there is no subfolder to append.
    $src = $devRoot
    if ([string]$Route.from -ne 'root') {
        $sub = ([string]$Collector.exportSubPath).Trim('\')
        if ($sub) { $src = $devRoot + '\' + $sub }
    }
    $coll = [string]$Route.collision
    if (-not $coll) { $coll = 'prefix' }
    $p = New-Profile -Name ("$label - " + [string]$Route.name) -Direction 'pull' `
        -SourcePath $src `
        -TargetType $type -DeviceName $model `
        -DestinationPath ([string]$Route.root) `
        -CollisionMode $coll `
        -Extensions @($Route.extensions) `
        -ExcludeFolders @() -Prune $false
    $p | Add-Member -NotePropertyName collisionLabel -NotePropertyValue (Get-CollectorFolderName $Collector) -Force
    $df = [string]$Route.dateFrom
    if (-not $df) { $df = 'run' }
    $p | Add-Member -NotePropertyName dateFrom -NotePropertyValue $df -Force
    return (& $stamp $p)
}

# The stick is how the app itself reaches the tablet, so a stick carrying current
# designs but a stale app is a trap: the surveyor runs whatever version travelled with
# it. Keeping the two in step is therefore part of the sync, not a separate chore.
#
# Copied to the volume ROOT, alongside "Trimble Data", because SyncDataCollector.cmd
# resolves its own folder with %~dp0 and the app reads config.json / writes its log
# next to itself -- so the root is both the obvious place to double-click and the
# place those paths already point.
#
# config.json is deliberately NOT copied. It holds this site's network paths and
# collector serials, and the tablet needs its own anyway (its source is the stick,
# not S:). Shipping ours would both leak the layout and point the tablet at drives
# it cannot see.
$script:AppFiles = @('SyncDataCollector.ps1', 'SyncDataCollector.cmd')

function Copy-AppToVolume {
    param([string]$VolumeRoot, [scriptblock]$OnLog, [bool]$CheckOnly)
    $updated = 0; $current = 0
    foreach ($name in $script:AppFiles) {
        $src = Join-Path $ScriptDir $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            & $OnLog "App file missing here, not copied: $name" 'WARN'
            continue
        }
        $dst = Join-Path $VolumeRoot $name
        $s = Get-Item -LiteralPath $src
        $d = $null
        if (Test-Path -LiteralPath $dst -PathType Leaf) { $d = Get-Item -LiteralPath $dst }
        # Same "is it already there" rule the file sync uses: matching size, and the
        # copy on the stick not older than this one.
        if ($d -and ([long]$d.Length -eq [long]$s.Length) -and ($s.LastWriteTimeUtc -le $d.LastWriteTimeUtc.AddSeconds(2))) {
            $current++
            continue
        }
        if ($CheckOnly) {
            $why = if ($d) { 'out of date' } else { 'not on the stick' }
            & $OnLog "App would be updated ($why): $name" 'INFO'
            $updated++
            continue
        }
        # A stick that is full, write-protected or yanked must not cost the crew their
        # design files -- warn and carry on, the same way a failed leg does.
        try {
            Copy-FileFolder $src $dst $true
            & $OnLog "App updated on the stick: $name" 'INFO'
            $updated++
        }
        catch {
            & $OnLog "Could not copy $name to the stick :: $($_.Exception.Message)" 'WARN'
        }
    }
    return @{ Updated = $updated; Current = $current }
}

# The tablet's config, written BY this PC onto the stick, so the surveyor configures
# nothing: plug in, double-click, press Sync.
#
# It is DERIVED, never a copy of ours. On the tablet the stick plays the part S: plays
# here -- linework comes off it, exports go back onto it -- and the tablet's own disk
# is the collector. So the two sides swap round:
#
#            this PC                          the tablet
#   design   S:\02-DESIGN    -> stick         stick -> C:\Trimble Data\...\02-Design
#   export   stick           -> S:\07-...     C:\Trimble Data\...\Exports -> stick
#
# Every stick-side path uses {apphome}, so the tablet can mount it as any letter.
# Nothing site-specific travels: no network paths, no OneDrive, no hardware serials.
#
# The stick is shared between tablets, so the TABLET is what has to be identifiable in
# an export name -- not the stick, which is the same for everyone. The name is written
# as "%COMPUTERNAME%" and resolved on each tablet, so one generated config gives every
# machine its own prefix with nothing typed on a device that has no real keyboard.
# This PC therefore does NOT prefix again on the way into OneDrive (the stick's own
# collector is set to "overwrite"), or every file would read USB-01_T110-A_...
function New-TabletConfig {
    param($Project, $Collector, $Existing)

    $sub      = Get-DeviceProjectSubPath $Project
    $stickJob = if ($sub) { '{apphome}\' + $sub } else { '{apphome}' }
    $design   = ([string]$Collector.designSubPath).Trim('\')
    $export   = ([string]$Collector.exportSubPath).Trim('\')

    # Identity has to survive a regeneration or the tablet's sync-state and device
    # marker stop matching, and every file looks new again. Settings are ours to
    # overwrite; the id is not.
    $serial = ''
    if ($Existing) {
        $prior = @(@($Existing.collectors) | Where-Object { [string]$_.type -eq 'folder' }) | Select-Object -First 1
        if ($prior) { $serial = [string]$prior.serial }
    }
    if (-not $serial) { $serial = [guid]::NewGuid().ToString() }

    $tabletProject = New-Project -Name ([string]$Project.name) `
        -DesignSource ($stickJob + '\' + $design) `
        -ExportRoot   ($stickJob + '\' + $export) `
        -DeviceProjectPath ('C:\' + $sub)

    $tabletCollector = New-Collector -Serial $serial -Name '%COMPUTERNAME%' `
        -Model 'Tablet' -Type 'folder' `
        -DesignSubPath $design -ExportSubPath $export `
        -DesignExtensions @($Collector.designExtensions) `
        -ExportExtensions @($Collector.exportExtensions) `
        -ExcludeFolders @($Collector.excludeFolders) `
        -Prune ([bool]$Collector.prune) `
        -ExportCollision 'prefix'

    return [pscustomobject]@{
        _note         = 'Generated by Sync DataCollector on the office PC. Edits here are overwritten on the next sync to this stick.'
        activeProject = [string]$Project.name
        projects      = @($tabletProject)
        collectors    = @($tabletCollector)
        devices       = [pscustomobject]@{}
        mtp           = New-MtpSettings
    }
}

# Write it only when it actually differs, so a stick that is already correct is not
# rewritten on every sync (and the surveyor's file timestamp stays meaningful).
function Copy-TabletConfigToVolume {
    param([string]$VolumeRoot, $Project, $Collector, [scriptblock]$OnLog, [bool]$CheckOnly)
    $dst = Join-Path $VolumeRoot 'config.json'
    $existing = $null
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        try { $existing = Get-Content -LiteralPath $dst -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $want = (New-TabletConfig $Project $Collector $existing | ConvertTo-Json -Depth 6)
    $have = ''
    if ($existing) { try { $have = ($existing | ConvertTo-Json -Depth 6) } catch { } }
    if ($have -eq $want) {
        & $OnLog 'Tablet config on the stick is already current.' 'INFO'
        return $false
    }
    if ($CheckOnly) {
        $why = if ($existing) { 'out of date' } else { 'not on the stick' }
        & $OnLog "Tablet config would be written ($why): config.json" 'INFO'
        return $true
    }
    try {
        $want | Set-Content -LiteralPath $dst -Encoding UTF8
        & $OnLog 'Tablet config written to the stick (config.json).' 'INFO'
        return $true
    }
    catch {
        & $OnLog "Could not write the tablet config to the stick :: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# One collector, both legs. Design first so a crew heading out has current drawings;
# exports second so nothing they collected is left behind. A failed leg does NOT stop
# the other -- getting field data off the device matters more than either leg alone.
function Invoke-CollectorSync {
    param(
        $Project, $Collector,
        [scriptblock]$OnLog, [scriptblock]$OnProgress,
        [switch]$CheckOnly, [scriptblock]$OnChooseDevice,
        [scriptblock]$OnItem,       # param($viewRow) -- one file settled
        # Design-leg files on the collector the user has marked "keep" in the compare
        # view. Design only: the export leg never prunes, so nothing there is at risk.
        [string[]]$RescueDesign = @()
    )
    $label = Get-CollectorLabel $Collector
    $verb  = if ($CheckOnly) { 'CHECK' } else { 'SYNC' }
    & $OnLog "===== $verb $label  (project: $($Project.name)) =====" 'INFO'

    # A folder collector with its volume absent has no device root, so every leg path
    # would come out drive-less ("\02-Design") and land on whatever drive is current.
    # Refuse the write outright. A CHECK is still allowed through: with the stick out
    # it falls back to the last sync recorded here, which is the point of that path.
    if (Test-VolumeCollector $Collector) {
        $volRoot = Resolve-VolumeRoot ([string]$Collector.serial)
        if ($volRoot) { & $OnLog "USB target mounted at $volRoot (volume $(Get-VolumeSerial $Collector.serial))." 'INFO' }
        elseif ($CheckOnly) { & $OnLog "USB target (volume $(Get-VolumeSerial $Collector.serial)) is not plugged in - checking against the last sync recorded here." 'WARN' }
        else { throw ("$label is not plugged in: no volume with serial $(Get-VolumeSerial $Collector.serial) is mounted.") }

        # The app and its tablet-side config travel with the data, so the stick is a
        # complete, current kit. USB only: an MTP controller does not run this tool.
        if ($volRoot) {
            $app = Copy-AppToVolume $volRoot $OnLog ([bool]$CheckOnly)
            if ($app.Updated -eq 0) { & $OnLog "App on the stick is already current ($($app.Current) file(s))." 'INFO' }
            [void](Copy-TabletConfigToVolume $volRoot $Project $Collector $OnLog ([bool]$CheckOnly))
        }
    }

    # Design first so a crew heading out has current drawings, then one pull leg per
    # export route. Keys have to stay unique: the compare view groups rows by them.
    $legs = @( @{ Key = 'design'; Kind = 'design'; Route = $null
                  Title = 'Design  PC -> collector (mirrored)' } )
    foreach ($rt in @(Get-ExportRoutes $Project $Collector)) {
        # Under per-file dating there is no single destination to name, so leave the
        # date tokens unexpanded rather than printing today's folder -- expanding it
        # reads as "everything is going here", which is exactly what it is not.
        $shown = [string]$rt.root
        if ([string]$rt.dateFrom -ne 'file') { $shown = Expand-PathTokens $shown }
        else { $shown = (Expand-EnvVars $shown) + '   (dated per file)' }
        $legs += @{
            Key   = 'export:' + [string]$rt.name
            Kind  = 'export'
            Route = $rt
            Title = ('{0}  collector -> {1} (additive)' -f [string]$rt.name, $shown)
        }
    }
    $copied = 0; $pruned = 0; $kept = 0; $failed = 0; $legErrors = @(); $lines = @()
    $legPlans = @()

    # One engine row -> one compare-view row. The engine thinks in source and
    # destination, which flip between the legs; the view is always PC-on-the-left,
    # collector-on-the-right. On a pull the collector is the source, so sides swap.
    $toViewRow = {
        param([string]$LegKey, $Row)
        $pull = ($LegKey -ne 'design')
        [pscustomobject]@{
            Leg       = $LegKey
            Action    = [string]$Row.Action
            Reason    = [string]$Row.Reason
            Status    = [string]$Row.Status
            ToDevice  = (-not $pull)
            PcRel     = $(if ($pull) { [string]$Row.DestRel } else { [string]$Row.Rel })
            PcLength  = $(if ($pull) { [long]$Row.DstLength } else { [long]$Row.SrcLength })
            PcMtime   = $(if ($pull) { $Row.DstMtime } else { $Row.SrcMtime })
            DevRel    = $(if ($pull) { [string]$Row.Rel } else { [string]$Row.DestRel })
            DevLength = $(if ($pull) { [long]$Row.SrcLength } else { [long]$Row.DstLength })
            DevMtime  = $(if ($pull) { $Row.SrcMtime } else { $Row.DstMtime })
        }
    }

    # The whole of one leg's result, mapped the same way, so the final render and
    # the live ticks cannot disagree about which side a file belongs on.
    $toLegPlan = {
        param($Leg, $Result)
        $pull    = ([string]$Leg.Key -ne 'design')
        $srcRoot = [string]$Result.SourceRoot
        $dstRoot = [string]$Result.DestinationRoot
        $view = @()
        foreach ($row in @($Result.Plan)) { $view += (& $toViewRow $Leg.Key $row) }
        return [pscustomobject]@{
            Key        = $Leg.Key
            Title      = $Leg.Title
            Pull       = $pull
            PcRoot     = $(if ($pull) { $dstRoot } else { $srcRoot })
            DeviceRoot = $(if ($pull) { $srcRoot } else { $dstRoot })
            Rows       = @($view)
        }
    }

    foreach ($leg in $legs) {
        if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
        & $OnLog "--- $($leg.Title) ---" 'INFO'
        $p = New-LegProfile $Project $Collector ([string]$leg.Kind) $leg.Route
        # Engine rows arrive in engine terms; map each one before it reaches the UI.
        # GetNewClosure, and deliberately different names: Invoke-Sync has its own
        # $OnItem parameter, so a plain scriptblock would resolve $OnItem dynamically
        # to ITSELF once called from in there, and recurse until the app hangs.
        $legOnItem = $null
        if ($OnItem) {
            $outerOnItem = $OnItem
            $mapViewRow  = $toViewRow
            $thisLegKey  = [string]$leg.Key
            $legOnItem = { param($row) [void](& $outerOnItem (& $mapViewRow $thisLegKey $row)) }.GetNewClosure()
        }
        # Only the design leg prunes, so only it can have anything to rescue.
        $legRescue = @()
        if ([string]$leg.Key -eq 'design') { $legRescue = @($RescueDesign) }
        try {
            if ($CheckOnly) {
                $r = Invoke-SyncCheck -Profile $p -OnLog $OnLog -OnProgress $OnProgress `
                        -OnChooseDevice $OnChooseDevice -OnItem $legOnItem -Rescue $legRescue
                $lines += ("{0}: {1}" -f $leg.Key, $r.Summary)
                # An offline check never reached the collector, so it has no rows to show.
                if ($r.ContainsKey('Plan')) { $legPlans += (& $toLegPlan $leg $r) }
            }
            else {
                $r = Invoke-Sync -Profile $p -OnLog $OnLog -OnProgress $OnProgress `
                        -OnChooseDevice $OnChooseDevice -OnItem $legOnItem -Rescue $legRescue
                $legPlans += (& $toLegPlan $leg $r)
                $copied += [int]$r.Copied; $pruned += [int]$r.Pruned; $failed += [int]$r.Failed
                $kept += [int]$r.Kept
                $d = ''
                if ([int]$r.Pruned -gt 0) { $d = ", deleted $($r.Pruned)" }
                if ([int]$r.Kept -gt 0)   { $d += ", kept $($r.Kept)" }
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
        Collector = $label; Copied = $copied; Pruned = $pruned; Kept = $kept; Failed = $failed
        Lines = $lines; Errors = $legErrors; Summary = $summary; CheckOnly = [bool]$CheckOnly
        LegPlans = @($legPlans)
    }
}

# What is plugged in, split into collectors we know and ones we do not. An unknown
# serial is never matched to an existing collector -- that is the whole safety story
# for adding controllers later.
function Get-ConnectedCollectors {
    # MTP controllers and mounted USB sticks are both offerable targets, so both
    # kinds go in one list and everything downstream stays kind-agnostic.
    $devs = @()
    $devs += @(Get-MtpDevices)
    $devs += @(Get-VolumeDevices)
    $devs = @($devs | Where-Object { $_.Serial })
    $known = @(); $unknown = @()
    foreach ($d in $devs) {
        $c = Get-CollectorBySerial $d.Serial
        if ($c) { $known += [pscustomobject]@{ Device = $d; Collector = $c } }
        else    { $unknown += $d }
    }
    # A plain folder collector IS this machine -- a tablet running the app against its
    # own disk. There is nothing to plug in and nothing to enumerate, so it is always
    # present. Without this the tablet finds only the stick, fails to match it to the
    # generated collector, and reports "no collector connected" with Sync greyed out.
    foreach ($c in @($script:Config.collectors)) {
        if ([string]$c.type -ne 'folder') { continue }
        if (Test-VolumeCollector $c) { continue }
        $local = @{ Name = [string]$c.model; Serial = [string]$c.serial
                    Path = ''; Item = $null; Kind = 'folder'; Root = '' }
        $known += [pscustomobject]@{ Device = $local; Collector = $c }
        $devs  += $local
    }
    return @{ Known = @($known); Unknown = @($unknown); All = @($devs) }
}

# Turn a connected but unrecognised device into a collector entry, seeded from the
# active project's shape so it is usable immediately.
function Register-Collector {
    param($Device, [string]$FriendlyName)
    # A missing Kind means an MTP controller -- that is all this used to enumerate.
    $kind = [string]$Device['Kind']
    if (-not $kind) { $kind = 'mtp' }
    $c = New-Collector -Serial ([string]$Device.Serial) -Name $FriendlyName `
            -Model ([string]$Device.Name) -Type $kind
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
        [scriptblock]$OnChooseDevice, # param($candidates) -> one of them, when several match
        [scriptblock]$OnItem,       # param($row) -- one file settled, so the UI can tick it off
        # Destination-relative paths that prune would otherwise delete, which the user
        # has said to keep. Each is copied back to the source instead of being removed,
        # which also settles it for good: next run the source accounts for it.
        [string[]]$Rescue = @()
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

    # Per-file dating. A collector accumulates months of exports before anyone pulls
    # them, and dating the folder from the run would file a year and a half of work
    # under whatever month it happens to be today. Pull only: on a push the source
    # tree is the authority on where things live.
    $dateFrom = 'run'
    if ($Profile.PSObject.Properties['dateFrom'] -and $Profile.dateFrom) { $dateFrom = [string]$Profile.dateFrom }
    $perFileDate = ($direction -eq 'pull' -and $dateFrom -eq 'file')
    $datedTail = ''
    if ($perFileDate) {
        # Keep the fixed part as the destination root and fold the dated part into
        # each file's relative path instead. Everything downstream -- the no-overwrite
        # walk, the compare grid, the marker -- then works unchanged, and the grid
        # shows the dated folder each file is going to.
        $sp = Split-DatedRoot (Expand-EnvVars ([string]$Profile.destinationPath))
        $datedTail = [string]$sp.Tail
        if ($datedTail) { $dstPath = (Expand-PathTokens ([string]$sp.Base)).Trim().TrimEnd('\') }
        else { $perFileDate = $false }   # nothing dated in the template; nothing to do
    }
    # The scope for "have we pulled this before" is the DATED part only -- the month
    # folder -- not any fixed subfolder under it. That is what lets a file the office
    # moved into another company's folder still count as already pulled.
    $scopeTail = ''
    if ($perFileDate) {
        $segs = @($datedTail -split '\\')
        $last = -1
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($segs[$i] -match '(?i)\{(julian|year|month|date)\}') { $last = $i }
        }
        if ($last -ge 0) { $scopeTail = (@($segs[0..$last]) -join '\') }
    }
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
    # Prune deletes by PATH, not by file type: anything the source cannot account for
    # goes, whatever its extension. That is right for a folder the tool owns, and
    # catastrophic one level up -- the collector's project folder is where Trimble
    # Access keeps the crew's .job files, and mirroring onto it would delete the lot,
    # including today's. One blanked "Design subfolder" field is all that separates
    # the two, so refuse the run rather than trust the field.
    if ($prune) {
        $ownRoot = ''
        if ($Profile.PSObject.Properties['deviceProjectRoot']) {
            $ownRoot = ([string]$Profile.deviceProjectRoot).Trim().TrimEnd('\')
        }
        if ($ownRoot -and ($dstPath -ieq $ownRoot)) {
            throw ("Refusing to mirror onto '$dstPath': that is the project folder on the collector itself, " +
                   "not a subfolder this tool owns. Everything there the design source does not account for " +
                   "would be DELETED, including the crew's .job files. Set a design subfolder (e.g. 02-Design), " +
                   "or turn mirror/prune off for this collector.")
        }
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

            # A locked collector -- or one whose USB mode is charging-only -- still
            # enumerates as a device, with its WPD driver reporting OK, but exposes
            # no storage objects at all. Taken at face value that reads as "the
            # device is empty", which is the worst possible answer: a push calls all
            # 153 files new, and a pull reports the collector up to date having read
            # nothing off it. Refuse the leg instead, so no sync record is written.
            $storageCount = 0
            try {
                $devFolder = $dev.Item.GetFolder
                if ($devFolder) { $storageCount = [int]$devFolder.Items().Count }
            }
            catch { $storageCount = 0 }
            if ($storageCount -le 0) {
                throw ("'$deviceName' is connected but is exposing no storage, so it cannot be read. " +
                       "Unlock the collector's screen and set its USB connection to file transfer, then try again.")
            }
        }
        # A subst'd letter (S:) dies with the logon session, so the drive this leg
        # needs may simply be gone. Put it back before calling the folder missing.
        if ($srcKind -eq 'fs') { Confirm-PathDrive $srcPath $OnLog }
        if ($dstKind -eq 'fs') { Confirm-PathDrive $dstPath $OnLog }

        # Validate a filesystem source up front (MTP source absence is handled in enumeration).
        if ($srcKind -eq 'fs') {
            if (-not (Test-Path -LiteralPath $srcPath)) { throw "Source folder not found: '$srcPath'" }
            $srcPath = (Get-Item -LiteralPath $srcPath).FullName.TrimEnd('\')
        }

        # Per-device subfolder / prefix (pull only) needs a device name / label.
        if ($direction -eq 'pull' -and $collisionMode -in @('deviceSubfolder', 'prefix') -and [string]::IsNullOrWhiteSpace($collisionLabel)) {
            throw "Collision mode '$collisionMode' needs a device name / label (used to keep each collector's files separate)."
        }

        # A .jxl stores its companion folder name inside itself, so prefixing that
        # folder silently severs the job from its point cloud and photos. Warned, not
        # refused: the pull still gets the data across, and losing the run would be
        # worse than a renamed folder someone can put right.
        if ($direction -eq 'pull' -and $collisionMode -eq 'prefix' -and ($exts -contains '.jxl')) {
            & $OnLog "Export naming is 'prefix' and .jxl is in the types: a scan's '<name> Files' folder gets renamed, but the .jxl records that folder name internally, so the job will not find its point cloud/photos. Use 'deviceSubfolder' for collectors that export scans." 'WARN'
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
        $datedByName = 0; $datedByStamp = 0
        $outOfDate = New-Object System.Collections.ArrayList
        # Every compared file, in-sync ones included, so the compare view can show
        # both sides the way GoodSync does. Built here rather than re-derived later:
        # a second comparison pass could disagree with the one that actually runs.
        $plan = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($rec in $records) {
            if ($script:CancelRequested) { & $OnLog 'Cancelled by user.' 'WARN'; break }
            $i++
            $rel = $rec.Rel
            $destRel = Get-DestRel $rel $direction $collisionMode $collisionLabel
            # LastIndexOf, not Split-Path: Split-Path reads its input as a wildcard
            # pattern, and these filenames contain brackets.
            $li = ([string]$rel).LastIndexOf('\')
            $leaf = if ($li -ge 0) { ([string]$rel).Substring($li + 1) } else { [string]$rel }
            $scopeDir = ''
            if ($perFileDate) {
                # The julian in the name is what the surveyor called the day's work,
                # so it beats the timestamp -- which a copy or a restore can move.
                $when = Get-JulianFromName $leaf
                if ($when) { $datedByName++ }
                else {
                    $datedByStamp++
                    if ($rec.MtimeUtc) { $when = ([datetime]$rec.MtimeUtc).ToLocalTime() }
                    if (-not $when) { $when = Get-Date }
                }
                $dated = (Expand-PathTokens $datedTail $when).Trim('\')
                if ($dated) { $destRel = $dated + '\' + $destRel }
                if ($scopeTail) {
                    $scopeDir = $dstPath + '\' + (Expand-PathTokens $scopeTail $when).Trim('\')
                }
            }
            $dest = $dstPath + '\' + $destRel
            # Cleared each pass: a throw before the row is built must not report the
            # previous file's row as the one that failed.
            $planRow = $null
            try {
                $need = $false; $reason = ''
                $di = Target-GetInfo $ctx $dstKind $dest     # one live lookup (Length = -1 if absent)
                if ($di.Length -lt 0) { $need = $true; $reason = 'new' }
                elseif ([long]$rec.Length -ne $di.Length) { $need = $true; $reason = 'size changed' }
                elseif ($null -ne $di.Mtime -and $null -ne $rec.MtimeUtc -and $rec.MtimeUtc -gt $di.Mtime.AddSeconds(2)) { $need = $true; $reason = 'source newer' }

                # Nothing at the exact target -- but the office may have filed this
                # very file under a different company subfolder in the same month.
                # Pulling it again would put a second copy in ours, every sync.
                if ($need -and $di.Length -lt 0 -and $neverOverwrite -and $scopeDir) {
                    $filed = Test-AlreadyFiled $ctx $dstKind $scopeDir $leaf ([long]$rec.Length)
                    if ($filed) {
                        $need = $false
                        $reason = 'already filed at ' + ($filed -replace [regex]::Escape($dstPath + '\'), '')
                    }
                }

                # What the compare view shows on the destination side. Tracked
                # separately from $di because the no-overwrite walk below can move
                # us to a different "(n)" slot than the one we first looked at.
                $dstLen = [long]$di.Length; $dstMtime = $di.Mtime

                # Pulled field data is irreplaceable: never write over a different file
                # that is already there. Land alongside it under a "(n)" name instead.
                if ($need -and $neverOverwrite -and $di.Length -ge 0) {
                    $alt = Resolve-NoOverwriteDest $ctx $dstKind $dest ([long]$rec.Length) $rec.MtimeUtc
                    if ($alt.Skip) {
                        $need = $false
                        $destRel = $alt.Path.Substring($dstPath.Length).TrimStart('\')
                        $reason = 'already pulled'
                        # The slot only counts as "already pulled" when its size matches.
                        $dstLen = [long]$rec.Length; $dstMtime = $null
                    }
                    elseif ($alt.Path -ne $dest) {
                        $dest = $alt.Path
                        $destRel = $dest.Substring($dstPath.Length).TrimStart('\')
                        $reason = 'kept alongside existing'
                        $dstLen = -1; $dstMtime = $null      # the chosen slot is free
                    }
                }

                if ($need) { [void]$outOfDate.Add([pscustomobject]@{ Rel = $destRel; Reason = $reason }) }

                $planRow = [pscustomobject]@{
                    Direction = $direction
                    Rel       = $rel
                    DestRel   = $destRel
                    SrcLength = [long]$rec.Length
                    SrcMtime  = $rec.MtimeUtc
                    DstLength = $dstLen
                    DstMtime  = $dstMtime
                    Action    = $(if ($need) { 'copy' } else { 'same' })
                    Reason    = $reason
                    Status    = 'pending'
                }
                [void]$plan.Add($planRow)

                if ($CheckOnly) {
                    # Report only. Stay quiet about the files that are fine, so what
                    # actually needs syncing stands out in the log.
                    if ($need) { & $OnLog ("OUT OF DATE ($reason)  $destRel") 'COPY' }
                    else       { $skipped++ }
                }
                elseif ($need) {
                    Invoke-CopyWithRetry $ctx $copyMode $rec.Src $dest ([long]$rec.Length) $OnLog
                    $copied++
                    $planRow.Status = 'copied'
                    # The row was built from a comparison made before the write. The
                    # file is there now, and the copy verifies its size, so record it
                    # -- otherwise a finished copy still reads as "missing that side".
                    $planRow.DstLength = [long]$rec.Length
                    $planRow.DstMtime  = $rec.MtimeUtc
                    & $OnLog ("COPIED  ($reason)  $destRel") 'COPY'
                }
                else {
                    $skipped++
                    $planRow.Status = 'same'
                    & $OnLog ("skip           $destRel") 'SKIP'
                }
                if ($OnItem) { [void](& $OnItem $planRow) }
            }
            catch {
                $failed++
                if ($planRow) {
                    $planRow.Status = 'failed'
                    $planRow.Reason = $_.Exception.Message
                    if ($OnItem) { [void](& $OnItem $planRow) }
                }
                & $OnLog ("FAILED         $rel  ::  $($_.Exception.Message)") 'ERROR'
            }
            & $OnProgress $i $total
        }

        # Say which files got their folder from a julian in the name and which fell
        # back to a timestamp: a timestamp is only as good as whatever last touched
        # the file, so a high fallback count is worth someone's attention.
        if ($perFileDate -and ($datedByName + $datedByStamp) -gt 0) {
            & $OnLog ("Filed by date: $datedByName from the julian in the filename, $datedByStamp from the file timestamp.") 'INFO'
        }

        # ---- Prune: remove what the source does not account for -------------
        # $pf survives the block below so the return can report it; with prune off it
        # stays empty, which is the honest answer -- nothing would be deleted.
        $pruned = 0; $keptBack = 0; $pf = @(); $pruneSet = @{ Files = @(); Dirs = @() }
        if ($prune -and -not $script:CancelRequested) {
            & $OnLog 'Scanning the destination for files the source does not account for...' 'INFO'
            $pruneSet = Get-PruneSet $ctx $dstKind $dstPath $records $sel.Dirs $direction $collisionMode $collisionLabel
            $pf = @($pruneSet.Files); $pd = @($pruneSet.Dirs)
            # Say so rather than swallowing it: a device that enumerates unnamed items
            # is one whose listing should be treated with suspicion generally.
            if ([int]$pruneSet.Malformed -gt 0) {
                & $OnLog ("Ignored $($pruneSet.Malformed) unnamed item(s) the device reported - not deletion candidates.") 'WARN'
            }

            # Files the user marked "keep" in the compare view. Copying one back to the
            # source is what makes the decision stick: prune only ever removes what the
            # source cannot account for, so once a file is in the design folder it is
            # safe on this run and every one after it, on every collector. Split the
            # list before anything is deleted, so a rescue can never lose the race.
            $rescueSet = @{}
            foreach ($rp in @($Rescue)) {
                $k = ([string]$rp).Trim().TrimStart('\')
                if ($k) { $rescueSet[$k] = $true }
            }
            $rescued = @(); $doomed = @()
            foreach ($f in $pf) {
                if ($rescueSet.ContainsKey([string]$f.Rel)) { $rescued += $f } else { $doomed += $f }
            }
            $pf = @($doomed)

            # A kept file can sit in a folder the source does not account for, and
            # folder prune is recursive -- so leaving that folder in the list would
            # delete the very file just kept, seconds after keeping it. Spare the
            # whole ancestor chain. Only this run needs it: once the file is in the
            # source, the folder is accounted for like any other.
            if ($rescued.Count) {
                $spare = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($f in $rescued) {
                    $p = [string]$f.Rel
                    while ($true) {
                        $i = $p.LastIndexOf('\')
                        if ($i -lt 0) { break }
                        $p = $p.Substring(0, $i)
                        [void]$spare.Add($p)
                    }
                }
                $pd = @($pd | Where-Object { -not $spare.Contains([string]$_) })
            }

            # A rescue row deliberately keeps the delete row's identity -- blank source
            # side, same destination rel -- so the row the user clicked is the row that
            # updates, rather than a second one appearing underneath it.
            $backMode = "$dstKind`2$srcKind"
            foreach ($f in $rescued) {
                $rRow = [pscustomobject]@{
                    Direction = $direction
                    Rel       = ''
                    DestRel   = [string]$f.Rel
                    SrcLength = [long]-1
                    SrcMtime  = $null
                    DstLength = [long]$f.Length
                    DstMtime  = $null
                    Action    = 'rescue'
                    Reason    = 'kept'
                    Status    = 'pending'
                }
                [void]$plan.Add($rRow)
                if ($CheckOnly) {
                    & $OnLog ("WOULD KEEP     $($f.Rel)  ->  $srcPath") 'COPY'
                }
                else {
                    try {
                        # LastIndexOf, not Split-Path: Split-Path reads its input as a
                        # wildcard pattern, and design filenames do contain brackets.
                        $i = ([string]$f.Rel).LastIndexOf('\')
                        $backDir = $(if ($i -ge 0) { $srcPath + '\' + ([string]$f.Rel).Substring(0, $i) } else { $srcPath })
                        $back = $srcPath + '\' + [string]$f.Rel
                        Target-EnsureDir $ctx $srcKind $backDir
                        $from = $(if ($dstKind -eq 'mtp') { $f.Item } else { $dstPath + '\' + $f.Rel })
                        Invoke-CopyWithRetry $ctx $backMode $from $back ([long]$f.Length) $OnLog
                        $keptBack++
                        # SrcLength stays -1 on purpose: the row key is built from the
                        # source rel, so filling the left-hand side in mid-run would
                        # split this row in two. The next Check shows it properly
                        # paired, because by then the design folder really does have it.
                        $rRow.Status = 'rescued'
                        & $OnLog ("KEPT           $($f.Rel)  ->  $back") 'COPY'
                    }
                    catch {
                        $failed++
                        $rRow.Status = 'failed'
                        $rRow.Reason = $_.Exception.Message
                        & $OnLog ("KEEP FAILED    $($f.Rel)  ::  $($_.Exception.Message)") 'ERROR'
                    }
                }
                if ($OnItem) { [void](& $OnItem $rRow) }
            }

            # Destination-only rows: nothing on the source side, so the compare view
            # draws them with an empty left cell and a delete marker.
            $delRows = @{}
            foreach ($f in $pf) {
                $dRow = [pscustomobject]@{
                    Direction = $direction
                    Rel       = ''
                    DestRel   = [string]$f.Rel
                    SrcLength = [long]-1
                    SrcMtime  = $null
                    DstLength = [long]$f.Length
                    DstMtime  = $null
                    Action    = 'delete'
                    Reason    = 'not in source'
                    Status    = 'pending'
                }
                [void]$plan.Add($dRow)
                $delRows[[string]$f.Rel] = $dRow
                if ($OnItem) { [void](& $OnItem $dRow) }
            }
            if ($pf.Count -eq 0 -and $pd.Count -eq 0) {
                if ($rescued.Count) { & $OnLog "Nothing left to prune - all $($rescued.Count) extra file(s) were kept." 'INFO' }
                else                { & $OnLog 'Nothing to prune - the destination already matches the source.' 'INFO' }
            }
            elseif ($CheckOnly) {
                & $OnLog "Would DELETE $($pf.Count) file(s) and $($pd.Count) folder(s):" 'WARN'
                foreach ($f in $pf) { & $OnLog ("WOULD DELETE   $($f.Rel)") 'COPY' }
            }
            else {
                foreach ($f in $pf) {
                    $dRow = $delRows[[string]$f.Rel]
                    try {
                        Target-DeleteFile $ctx $dstKind ($dstPath + '\' + $f.Rel) $f.Item
                        $pruned++
                        if ($dRow) { $dRow.Status = 'deleted' }
                        & $OnLog ("DELETED        $($f.Rel)") 'COPY'
                    }
                    catch {
                        $failed++
                        if ($dRow) { $dRow.Status = 'failed'; $dRow.Reason = $_.Exception.Message }
                        & $OnLog ("DELETE FAILED  $($f.Rel)  ::  $($_.Exception.Message)") 'ERROR'
                    }
                    if ($OnItem -and $dRow) { [void](& $OnItem $dRow) }
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
            Kept      = $keptBack
            # After the split, deletion candidates are only the ones NOT marked keep,
            # so a check reports what a sync would really remove.
            PruneCandidates = @($pf)
            Plan      = @($plan)
            SourceRoot      = $srcPath
            DestinationRoot = $dstPath
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
# Laid out at 830 wide, then widened once every control is in place (see the
# startup block): the right-hand buttons are anchored, so letting the anchors do
# the widening keeps them flush without re-coordinating every Location by hand.
$form.Size = New-Object System.Drawing.Size(830, 915)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(740, 755)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:CurrentProject   = $null
$script:CurrentCollector = $null
$script:LastSeenSerials  = ''
$script:Loading          = $false
# Which collector the user chose at Detect, when more than one is connected.
# Held by serial rather than by object so it survives a config reload, and
# remembered across runs so a desk with a controller and the stick permanently
# plugged in does not need a Detect click on every launch.
$script:PinnedSerial     = [string](Get-Pref 'PinnedCollector' '')
# Has a Check been run that still describes what a Sync would do? Starts false, so
# a fresh launch always compares before it is allowed to write.
$script:CheckedOk        = $false
# Re-entrancy guard and last-laid-out size: several events land on one resize, and
# setting a column width can raise another.
$script:SizingColumns    = $false
$script:CompareLayoutSig = ''

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

# Deliberately its own button, not part of Sync. Sync pushes design out and pulls
# field data back; it does not destroy work on the collector. Tidying does, so it
# is a thing you ask for, on a day you mean it.
$btnTidy = New-Object System.Windows.Forms.Button
$btnTidy.Text = 'Tidy jobs...'; $btnTidy.Location = '406,512'; $btnTidy.Size = '110,38'
$form.Controls.Add($btnTidy)
# Set here, not up with the other tooltips: $tip is built before this button is,
# and SetToolTip on a control that does not exist yet throws at startup.
$tip.SetToolTip($btnTidy, 'Remove old job files from the collector - but only ones already backed up.' + [Environment]::NewLine +
    'Shows you exactly what would go, and what it is keeping, before anything happens.')

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '527,520'; $progress.Size = '273,22'; $progress.Anchor = 'Top,Left,Right'
$form.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready.'; $lblStatus.Location = '15,559'; $lblStatus.Size = '785,20'; $lblStatus.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblStatus)

# ---- Results: compare grid + log -----------------------------------------
# Two views of the same run. The grid answers "what is about to happen"; the log
# answers "what actually happened, and why did that one fail".
$tabsOut = New-Object System.Windows.Forms.TabControl
$tabsOut.Location = '15,585'; $tabsOut.Size = '785,270'
$tabsOut.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabsOut)

$tabCompare = New-Object System.Windows.Forms.TabPage
$tabCompare.Text = 'Compare'; $tabCompare.BackColor = 'White'
$tabsOut.TabPages.Add($tabCompare)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Log'; $tabLog.BackColor = 'White'
$tabsOut.TabPages.Add($tabLog)

# Header strip: which two folders the columns below are actually comparing.
# Positioned by Resize-CompareColumns so they stay over the columns they name;
# the group headers name the folders, these name the two sides.
$lblPcRoot = New-Object System.Windows.Forms.Label
$lblPcRoot.Location = '2,2'; $lblPcRoot.Size = '370,16'; $lblPcRoot.Text = 'This PC'
$lblPcRoot.TextAlign = 'MiddleLeft'; $lblPcRoot.ForeColor = 'DimGray'
$lblPcRoot.AutoEllipsis = $true
$tabCompare.Controls.Add($lblPcRoot)

$lblDevRoot = New-Object System.Windows.Forms.Label
$lblDevRoot.Location = '404,2'; $lblDevRoot.Size = '370,16'; $lblDevRoot.Text = 'Collector'
$lblDevRoot.TextAlign = 'MiddleLeft'; $lblDevRoot.ForeColor = 'DimGray'
$lblDevRoot.AutoEllipsis = $true
$tabCompare.Controls.Add($lblDevRoot)

# One grid, not two lists: the sides have to stay on the same row for the arrow
# between them to mean anything, and independent scrollbars would never manage it.
$lvCompare = New-Object System.Windows.Forms.ListView
$lvCompare.Location = '2,20'; $lvCompare.Size = '777,200'
$lvCompare.View = 'Details'; $lvCompare.FullRowSelect = $true; $lvCompare.GridLines = $false
$lvCompare.HideSelection = $false; $lvCompare.MultiSelect = $true
# Sized by Update-CompareLayout, not anchors: a TabPage is not laid out when its
# children are added, so anchor margins computed here come out negative.
$lvCompare.Font = New-Object System.Drawing.Font('Segoe UI', 9)
# Folder and file are separate columns because a truncated cell loses its TAIL,
# and the tail of a relative path is the filename -- the one part worth reading.
# Split, and the clipping lands on the folder, where the start still identifies it.
[void]$lvCompare.Columns.Add('Folder', 120, 'Left')
[void]$lvCompare.Columns.Add('File', 165, 'Left')
[void]$lvCompare.Columns.Add('Size', 62, 'Right')
[void]$lvCompare.Columns.Add('Modified', 100, 'Left')
[void]$lvCompare.Columns.Add('', 30, 'Center')          # the action arrow
[void]$lvCompare.Columns.Add('Folder', 120, 'Left')
[void]$lvCompare.Columns.Add('File', 165, 'Left')
[void]$lvCompare.Columns.Add('Size', 62, 'Right')
[void]$lvCompare.Columns.Add('Modified', 100, 'Left')
[void]$lvCompare.Columns.Add('What happens', 165, 'Left')
$tabCompare.Controls.Add($lvCompare)

$lblCompareHint = New-Object System.Windows.Forms.Label
$lblCompareHint.Location = '2,224'; $lblCompareHint.Size = '550,18'
$lblCompareHint.ForeColor = 'Gray'
$lblCompareHint.Text = 'Press Check to compare without writing anything.'
$tabCompare.Controls.Add($lblCompareHint)

$chkShowSame = New-Object System.Windows.Forms.CheckBox
$chkShowSame.Text = 'Show files already in sync'; $chkShowSame.Location = '560,222'
$chkShowSame.Size = '217,20'
$chkShowSame.ForeColor = 'DimGray'
$tabCompare.Controls.Add($chkShowSame)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = '2,2'; $txtLog.Size = '777,240'
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.BackColor = 'White'; $txtLog.BorderStyle = 'None'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Dock = 'Fill'
$tabLog.Controls.Add($txtLog)

# --------------------------------------------------------------------------
# UI logic
# --------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    $txtLog.AppendText($line + "`r`n")
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

# ---- Compare view ---------------------------------------------------------
# The arrows are built from code points rather than typed as literals: this file
# carries no BOM and is otherwise pure ASCII, so a literal glyph would be read
# back through the ANSI codepage and drawn as mojibake.
$script:GlyphToDevice = [string][char]0x2192    # right arrow
$script:GlyphToPc     = [string][char]0x2190    # left arrow
$script:GlyphSame     = [string][char]0x003D    # equals
$script:GlyphDelete   = [string][char]0x2717    # ballot X
$script:GlyphDone     = [string][char]0x2713    # check mark - this one is finished
$script:GlyphFailed   = [string][char]0x26A0    # warning sign

$script:ClrCopy   = [System.Drawing.Color]::FromArgb(0, 90, 170)
$script:ClrDelete = [System.Drawing.Color]::FromArgb(170, 0, 0)
$script:ClrSame   = [System.Drawing.Color]::FromArgb(130, 130, 130)
$script:ClrDone   = [System.Drawing.Color]::FromArgb(0, 130, 60)

$script:LastLegPlans   = @()
$script:CompareRowKeys = @{}    # row key -> ListViewItem, for updating in place
$script:CompareGroups  = @{}    # leg key -> ListViewGroup

# Identity of a row across a check and the sync that follows it, so pressing Sync
# ticks off the rows already on screen instead of appending a second copy.
function Get-RowKey {
    param($Row)
    return ('{0}|{1}|{2}' -f $Row.Leg, $Row.PcRel, $Row.DevRel)
}

# Files on the collector that prune would delete but the user has said to keep,
# by device-relative path. Design leg only -- the export leg never prunes, so
# nothing there is ever at risk. Cleared when the selected collector changes,
# because the paths mean nothing on a different device.
$script:RescueMarks = @{}

# Is this a row the user is allowed to change their mind about? Only a design-leg
# deletion that has not happened yet: once a file is gone, or copied, the decision
# is history and clicking it must do nothing.
function Test-RescueEligible {
    param($Row)
    if ($null -eq $Row) { return $false }
    if ([string]$Row.Leg -ne 'design') { return $false }
    $st = [string]$Row.Status
    if ($st -and $st -ne 'pending') { return $false }
    return ([string]$Row.Action -eq 'delete' -or [string]$Row.Action -eq 'rescue')
}

function Test-RescueMark {
    param($Row)
    if ([string]$Row.Leg -ne 'design') { return $false }
    $k = [string]$Row.DevRel
    if (-not $k) { return $false }
    return $script:RescueMarks.ContainsKey($k)
}

# Glyph, wording and colour for one row -- from its action, and from how far it
# has actually got. Shared by the initial render and the live updates so a row
# cannot end up looking like one thing and reading like another.
function Get-RowLook {
    param($Row)
    switch ([string]$Row.Status) {
        'failed'  { return @{ Glyph = $script:GlyphFailed; What = ('FAILED: ' + [string]$Row.Reason); Color = $script:ClrDelete } }
        'copied'  { return @{ Glyph = $script:GlyphDone;   What = 'Copied';  Color = $script:ClrDone } }
        'deleted' { return @{ Glyph = $script:GlyphDone;   What = 'Deleted'; Color = $script:ClrDone } }
        'rescued' { return @{ Glyph = $script:GlyphDone;   What = 'Kept - copied into the design folder'; Color = $script:ClrDone } }
    }
    # 'delete' and 'rescue' are the same decision seen from either side, and the mark
    # is what says which way it currently points. One branch, so the X and the arrow
    # can never disagree -- including when a click takes a rescue row back to a delete.
    if ([string]$Row.Action -eq 'delete' -or [string]$Row.Action -eq 'rescue') {
        if (Test-RescueMark $Row) {
            return @{ Glyph = $script:GlyphToPc; What = 'KEEP - copy into the design folder'; Color = $script:ClrCopy }
        }
        return @{ Glyph = $script:GlyphDelete; What = 'Delete from collector  (click to keep)'; Color = $script:ClrDelete }
    }
    if ([string]$Row.Action -eq 'copy') {
        return @{
            Glyph = $(if ($Row.ToDevice) { $script:GlyphToDevice } else { $script:GlyphToPc })
            What  = $(if ($Row.Reason) { 'Copy ({0})' -f $Row.Reason } else { 'Copy' })
            Color = $script:ClrCopy
        }
    }
    return @{
        Glyph = $script:GlyphSame
        What  = $(if ($Row.Reason) { [string]$Row.Reason } else { 'In sync' })
        Color = $script:ClrSame
    }
}

# Both ends of a row, in full. On a pull the two paths genuinely differ -- dated
# folder, company folder, collector prefix -- so showing only one leaves the other
# a guess, and the folder column is the first thing to clip on a narrow window.
function Get-RowTip {
    param($Row)
    $lines = @()
    if ([string]$Row.PcRel)  { $lines += 'PC:        ' + [string]$Row.PcRel }
    if ([string]$Row.DevRel) { $lines += 'Collector: ' + [string]$Row.DevRel }
    return ($lines -join [Environment]::NewLine)
}

# Split a relative path into its folder and its filename. LastIndexOf rather than
# Split-Path: this runs per row over a few hundred rows, and Split-Path treats its
# input as a wildcard pattern, which these paths are not.
function Split-RelPath {
    param([string]$Rel)
    if ([string]::IsNullOrEmpty($Rel)) { return @{ Dir = ''; Leaf = '' } }
    $i = $Rel.LastIndexOf('\')
    if ($i -lt 0) { return @{ Dir = ''; Leaf = $Rel } }
    return @{ Dir = $Rel.Substring(0, $i); Leaf = $Rel.Substring($i + 1) }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return '' }
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    $v = [double]$Bytes / 1024
    foreach ($unit in @('KB', 'MB', 'GB')) {
        if ($v -lt 1024) { return ('{0:N1} {1}' -f $v, $unit) }
        $v = $v / 1024
    }
    return ('{0:N1} TB' -f $v)
}

# Format-Local takes a [datetime], so an absent stamp has to be caught here --
# $null would arrive as DateTime.MinValue and print as the year 1.
function Format-RowTime {
    param($Utc)
    if ($null -eq $Utc) { return '' }
    try { return (Format-Local ([datetime]$Utc)) } catch { return '' }
}

# The two name columns absorb whatever width the window has spare; everything
# else is sized to its content and stays put. Also slides the two side captions
# so each still sits over the columns it names.
# Place the compare tab's children from the page's own client size. Anchors are
# no use here: a TabPage has not been laid out at the moment its children are
# added, so the margins they capture are wrong (and stretch the grid past the
# page). Driven from the page's Resize instead, which fires whenever it matters.
function Update-CompareLayout {
    $w = $tabCompare.ClientSize.Width
    $h = $tabCompare.ClientSize.Height
    if ($w -le 40 -or $h -le 60) { return }
    # One drag raises this from several places at once -- the page, the form, and a
    # tab switch afterwards. Do the work once per actual size.
    $sig = '{0}x{1}' -f $w, $h
    if ($sig -eq $script:CompareLayoutSig) { return }
    $script:CompareLayoutSig = $sig
    $lblPcRoot.SetBounds(2, 2, [Math]::Max(80, [int]($w / 2)), 16)
    $lvCompare.SetBounds(2, 20, ($w - 4), [Math]::Max(60, $h - 46))
    $lblCompareHint.SetBounds(2, ($h - 21), [Math]::Max(80, $w - 232), 18)
    $chkShowSame.SetBounds(($w - 223), ($h - 23), 217, 20)
    Resize-CompareColumns
}

# How wide each flexible column should be for a grid this wide. Pure arithmetic,
# separate from the control it is applied to, so the awkward cases -- a very narrow
# window, a very wide one -- can be checked without a window at all.
function Get-CompareColumnWidths {
    param([int]$GridWidth)
    # Size, Modified and the arrow are content-sized and never move. Everything else
    # shares what is left: the two folder/file pairs, and the what-happens text.
    $fixed = 62 + 100 + 30 + 62 + 100
    $spare = $GridWidth - $fixed
    # Below this the columns stop shrinking and the grid scrolls sideways instead --
    # past a point, narrower cells stop telling you anything.
    # Chosen so the whole grid still fits at the form's own minimum width -- a window
    # squeezed to its smallest should not also be scrolling sideways.
    $minSpare = 2 * (70 + 100) + 220
    if ($spare -lt $minSpare) { $spare = $minSpare }

    # What-happens has to fit its longest real sentence -- "Delete from collector
    # (click to keep)" -- or the one row that can destroy something is the one that
    # reads as truncated. It takes a share of the slack, capped: past ~340 it is just
    # trailing space, and the names are what deserve the width.
    # Floor, not [int]: PowerShell's [int] cast ROUNDS, so halving an odd number of
    # spare pixels rounded up and each side claimed one pixel more than existed --
    # enough to put a horizontal scrollbar under a grid that already fitted.
    $what = [int][Math]::Floor($spare * 0.22)
    if ($what -lt 220) { $what = 220 }
    if ($what -gt 340) { $what = 340 }

    $side = [int][Math]::Floor(($spare - $what) / 2)
    # The filename gets the larger share: a clipped folder still shows where it
    # starts, while a clipped filename is the thing you were trying to read. The
    # folder is capped too -- a dated path is short, and past that width the space
    # is better spent on names.
    $folder = [int][Math]::Floor($side * 0.42)
    if ($folder -lt 70)  { $folder = 70 }
    if ($folder -gt 260) { $folder = 260 }
    $file = $side - $folder
    if ($file -lt 100) { $file = 100 }
    return @{ Folder = $folder; File = $file; What = $what; Side = ($folder + $file + 62 + 100) }
}

function Resize-CompareColumns {
    # Setting a column width can itself add or remove the vertical scrollbar, which
    # fires Resize again. Guard, or a drag can put us in a loop.
    if ($script:SizingColumns) { return }
    $w = $lvCompare.ClientSize.Width
    if ($w -le 0) { return }
    $c = Get-CompareColumnWidths $w
    $folder = $c.Folder; $file = $c.File; $what = $c.What

    $script:SizingColumns = $true
    $lvCompare.BeginUpdate()
    try {
        $lvCompare.Columns[0].Width = $folder
        $lvCompare.Columns[1].Width = $file
        $lvCompare.Columns[5].Width = $folder
        $lvCompare.Columns[6].Width = $file
        $lvCompare.Columns[9].Width = $what
    }
    finally {
        $lvCompare.EndUpdate()
        $script:SizingColumns = $false
    }
    $sideW = $c.Side
    $lblPcRoot.Width = $sideW
    $lblDevRoot.Left = $lvCompare.Left + $sideW + 30
    $lblDevRoot.Width = [Math]::Max(80, $sideW)
}

# Paint one leg's rows into the grid. Left column is always this PC and right is
# always the collector, whichever way the leg happens to run.
# The one-line summary under the grid. Recomputed from the plans rather than
# accumulated while rendering, so toggling one row's keep/delete can refresh it
# without redrawing the whole grid and losing the user's place in it.
function Update-CompareHint {
    $gate = ''
    if (-not (Test-SyncAllowed)) { $gate = '   -   press Check before Sync.' }
    $plans = @($script:LastLegPlans)
    if ($plans.Count -eq 0) {
        $lblCompareHint.Text = 'Nothing compared yet. Press Check to compare without writing anything.'
        return
    }
    $toCopy = 0; $toDelete = 0; $toKeep = 0; $same = 0; $done = 0; $failedRows = 0
    foreach ($lp in $plans) {
        foreach ($r in @($lp.Rows)) {
            switch ([string]$r.Action) {
                'copy'   { $toCopy++ }
                'rescue' { if (Test-RescueMark $r) { $toKeep++ } else { $toDelete++ } }
                'delete' { if (Test-RescueMark $r) { $toKeep++ } else { $toDelete++ } }
                default  { $same++ }
            }
            switch ([string]$r.Status) {
                'copied'  { $done++ }
                'deleted' { $done++ }
                'rescued' { $done++ }
                'failed'  { $failedRows++ }
            }
        }
    }
    $tail = if ($chkShowSame.Checked) { "$same in sync" } else { "$same in sync (hidden)" }
    $bits = @()
    if ($done -gt 0 -or $failedRows -gt 0) {
        # A run has happened, so report what it did rather than what it intended.
        if ($done -gt 0)       { $bits += "$done done" }
        if ($failedRows -gt 0) { $bits += "$failedRows FAILED" }
    }
    else {
        if ($toCopy -gt 0)   { $bits += "$toCopy to copy" }
        if ($toKeep -gt 0)   { $bits += "$toKeep to KEEP" }
        if ($toDelete -gt 0) { $bits += "$toDelete to DELETE (click one to keep it)" }
        if ($bits.Count -eq 0) { $bits += 'nothing to do' }
    }
    $lblCompareHint.Text = ($bits -join ', ') + ",  $tail" + $gate
}

function Show-ComparePlan {
    param($LegPlans, [string]$DeviceLabel)

    # An empty array collapses to $null on the way out of a function, and @($null)
    # is a one-element array holding $null -- which would draw a phantom group with
    # no rows. Drop the nulls before anything counts or iterates.
    $plans = @(@($LegPlans) | Where-Object { $null -ne $_ })
    $script:LastLegPlans = $plans
    if ($DeviceLabel) { $lblDevRoot.Text = $DeviceLabel }
    $showSame = $chkShowSame.Checked

    $lvCompare.BeginUpdate()
    try {
        $lvCompare.Items.Clear()
        $lvCompare.Groups.Clear()
        $script:CompareRowKeys = @{}
        $script:CompareGroups  = @{}

        foreach ($lp in $plans) {
            # The two legs have different endpoints, so the folder pair belongs in
            # the group header -- one pair of column headers cannot name both.
            $head = '{0}      {1}  {2}  {3}' -f $lp.Title, $lp.PcRoot, $script:GlyphToDevice, $lp.DeviceRoot
            if ($lp.Pull) {
                $head = '{0}      {1}  {2}  {3}' -f $lp.Title, $lp.PcRoot, $script:GlyphToPc, $lp.DeviceRoot
            }
            $g = New-Object System.Windows.Forms.ListViewGroup($head)
            [void]$lvCompare.Groups.Add($g)
            $script:CompareGroups[[string]$lp.Key] = $g

            foreach ($r in @($lp.Rows)) {
                if ([string]$r.Action -eq 'same' -and -not $showSame) { continue }

                # The NAME is shown whenever we know it, even for a file that is not
                # there yet -- on a pull that name is where the file is going, and the
                # dated and company folders make it genuinely different from the
                # collector's own path, so blanking it hid the one thing worth seeing.
                # Size and modified stay blank until the file exists: that blank is
                # what still reads as "not on this side yet".
                $pcNamed  = ([string]$r.PcRel  -ne '')
                $devNamed = ([string]$r.DevRel -ne '')
                $pcHas  = ([long]$r.PcLength  -ge 0)
                $devHas = ([long]$r.DevLength -ge 0)

                # The arrow already says which way a file is going, so the text
                # spends its width on WHY instead of repeating the direction.
                $look  = Get-RowLook $r
                $glyph = $look.Glyph; $what = $look.What; $clr = $look.Color

                $pcP  = Split-RelPath ([string]$r.PcRel)
                $devP = Split-RelPath ([string]$r.DevRel)
                $it = New-Object System.Windows.Forms.ListViewItem($(if ($pcNamed) { $pcP.Dir } else { '' }))
                [void]$it.SubItems.Add($(if ($pcNamed) { $pcP.Leaf } else { '' }))
                [void]$it.SubItems.Add($(if ($pcHas) { Format-Size ([long]$r.PcLength) } else { '' }))
                [void]$it.SubItems.Add($(if ($pcHas) { Format-RowTime $r.PcMtime } else { '' }))
                [void]$it.SubItems.Add($glyph)
                [void]$it.SubItems.Add($(if ($devNamed) { $devP.Dir } else { '' }))
                [void]$it.SubItems.Add($(if ($devNamed) { $devP.Leaf } else { '' }))
                [void]$it.SubItems.Add($(if ($devHas) { Format-Size ([long]$r.DevLength) } else { '' }))
                [void]$it.SubItems.Add($(if ($devHas) { Format-RowTime $r.DevMtime } else { '' }))
                [void]$it.SubItems.Add($what)
                $it.ForeColor = $clr
                $it.Group = $g
                # Both paths in full: the two sides differ on a pull, and the folder
                # column is the first thing to get clipped when the window is narrow.
                $it.ToolTipText = Get-RowTip $r
                # The row travels with its item, so a click can act on it directly.
                $it.Tag = $r
                [void]$lvCompare.Items.Add($it)
                $script:CompareRowKeys[(Get-RowKey $r)] = $it
            }
        }
    }
    finally { $lvCompare.EndUpdate() }

    $lvCompare.ShowItemToolTips = $true
    Resize-CompareColumns
    Update-CompareHint
}

# One file has been settled mid-run: tick it off in place. If a check already put
# the row on screen we update that row, so pressing Sync walks the list you are
# looking at rather than building a second one underneath it.
function Update-CompareRow {
    param($Row)
    if ($null -eq $Row) { return }
    $key  = Get-RowKey $Row
    $look = Get-RowLook $Row
    $it = $null
    if ($script:CompareRowKeys.ContainsKey($key)) { $it = $script:CompareRowKeys[$key] }

    if ($null -eq $it) {
        # Nothing on screen for this file -- a cold Sync, or a file that only turned
        # up on this pass. In-sync rows still obey the filter; anything that is
        # actually happening is always shown.
        if ([string]$Row.Action -eq 'same' -and -not $chkShowSame.Checked) { return }
        $g = $null
        if ($script:CompareGroups.ContainsKey([string]$Row.Leg)) { $g = $script:CompareGroups[[string]$Row.Leg] }
        if ($null -eq $g) {
            $g = New-Object System.Windows.Forms.ListViewGroup([string]$Row.Leg)
            [void]$lvCompare.Groups.Add($g)
            $script:CompareGroups[[string]$Row.Leg] = $g
        }
        $pcNamed  = ([string]$Row.PcRel  -ne '')
        $devNamed = ([string]$Row.DevRel -ne '')
        $pcHas  = ([long]$Row.PcLength  -ge 0)
        $devHas = ([long]$Row.DevLength -ge 0)
        $pcP  = Split-RelPath ([string]$Row.PcRel)
        $devP = Split-RelPath ([string]$Row.DevRel)
        $it = New-Object System.Windows.Forms.ListViewItem($(if ($pcNamed) { $pcP.Dir } else { '' }))
        [void]$it.SubItems.Add($(if ($pcNamed) { $pcP.Leaf } else { '' }))
        [void]$it.SubItems.Add($(if ($pcHas) { Format-Size ([long]$Row.PcLength) } else { '' }))
        [void]$it.SubItems.Add($(if ($pcHas) { Format-RowTime $Row.PcMtime } else { '' }))
        [void]$it.SubItems.Add('')
        [void]$it.SubItems.Add($(if ($devNamed) { $devP.Dir } else { '' }))
        [void]$it.SubItems.Add($(if ($devNamed) { $devP.Leaf } else { '' }))
        [void]$it.SubItems.Add($(if ($devHas) { Format-Size ([long]$Row.DevLength) } else { '' }))
        [void]$it.SubItems.Add($(if ($devHas) { Format-RowTime $Row.DevMtime } else { '' }))
        [void]$it.SubItems.Add('')
        $it.ToolTipText = Get-RowTip $Row
        $it.Group = $g
        [void]$lvCompare.Items.Add($it)
        $script:CompareRowKeys[$key] = $it
    }
    # Always the latest row object: a check's row and the sync's row for the same
    # file are different objects, and the click handler must act on the live one.
    $it.Tag = $Row

    $it.SubItems[4].Text = $look.Glyph
    $it.SubItems[9].Text = $look.What
    $it.ForeColor = $look.Color
    try { $it.EnsureVisible() } catch {}
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
    # Keep marks are device-relative paths on one particular collector, so they mean
    # nothing on another. Dropping them on a switch is the safe way round: the worst
    # case is being asked about a file again, not silently keeping the wrong one.
    if ([string]$script:CurrentCollector.serial -ne [string]$C.serial) {
        $script:RescueMarks = @{}
        # A check vouches for one collector's plan, never the next one's.
        $script:CheckedOk = $false
    }
    $script:CurrentCollector = $C
    $has = ($null -ne $C)
    foreach ($ctl in @($txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl,$cboExportCollision,
                       $chkPrune,$btnNameDev,$btnResetDefaults)) {
        $ctl.Enabled = $has
    }
    Update-ActionButtons
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

function Set-PinnedCollector {
    param([string]$Serial)
    $s = ([string]$Serial).Trim()
    if ($s -eq [string]$script:PinnedSerial) { return }
    $script:PinnedSerial = $s
    Set-Pref 'PinnedCollector' $s
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
        Set-PinnedCollector ''
        $lblCollector.Text = 'No collector connected.  Plug one in over USB (File transfer / MTP), or insert a USB stick target.'
        $lblCollector.ForeColor = 'DimGray'
        Load-CollectorToUi $null
        return
    }
    if ($known.Count -eq 0 -and $unknown.Count -gt 0) {
        Set-PinnedCollector ''
        $s = ($unknown | ForEach-Object { "$($_.Name) ($($_.Serial))" }) -join ', '
        $lblCollector.Text = "Unrecognised: $s  -  press Detect to set it up."
        $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(180,90,0)
        Load-CollectorToUi $null
        return
    }
    $pick = $known[0]
    $also = ''
    if ($known.Count -gt 1) {
        # A controller and the USB stick are routinely plugged in together, so
        # "several connected" is normal, not an error. Detect asks which one and
        # pins it; honour that pin here or the 4-second poll would throw the answer
        # away moments later and leave Sync greyed out with no way to un-grey it.
        $pinned = @($known | Where-Object { [string]$_.Collector.serial -eq [string]$script:PinnedSerial })
        if ($pinned.Count -eq 0) {
            $lblCollector.Text = "$($known.Count) collectors connected - press Detect to choose."
            $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(180,90,0)
            Load-CollectorToUi $null
            return
        }
        $pick = $pinned[0]
        $also = "   ($($known.Count) connected - Detect to switch)"
    }
    Set-PinnedCollector ([string]$pick.Collector.serial)
    Load-CollectorToUi $pick.Collector
    $lbl = Get-CollectorLabel $pick.Collector
    $entries = @(@((Load-SyncState).entries) | Where-Object { [string]$_.deviceId -eq [string]$pick.Collector.serial })
    $when = 'never synced'
    if ($entries.Count) {
        $t = Parse-Utc ([string](@($entries | Sort-Object lastSyncUtc -Descending))[0].lastSyncUtc)
        if ($t) { $when = 'last synced ' + (Format-Local $t) }
    }
    $lblCollector.Text = "$lbl  -  $when$also"
    $lblCollector.ForeColor = [System.Drawing.Color]::FromArgb(0,110,0)
    if ($Announce) { Write-Log "Collector detected: $lbl ($when)." }
}

# Sync is gated behind Check. The design leg is mirrored, so a sync DELETES, and the
# compare view is the only place that plan can be read before it happens. Advanced
# mode lifts the gate -- someone who has opened the settings panel is not the person
# this is protecting.
function Test-SyncAllowed {
    if ([bool]$chkAdvanced.Checked) { return $true }
    return [bool]$script:CheckedOk
}

# A check only vouches for the collector and settings it actually ran against, so
# anything that changes the plan withdraws it.
function Reset-CheckGate {
    if ($script:Loading) { return }
    $script:CheckedOk = $false
    Update-ActionButtons
}

function Update-ActionButtons {
    $ready = (-not $script:IsSyncing) -and ($null -ne $script:CurrentCollector)
    $btnCheck.Enabled = $ready
    $btnSync.Enabled  = $ready -and (Test-SyncAllowed)
    # Tidy is not behind the Check gate: it does its own comparison and shows the
    # whole list before it touches anything, so a stale plan cannot reach it.
    $btnTidy.Enabled  = $ready
    if ($ready -and -not $btnSync.Enabled) {
        $tip.SetToolTip($btnSync, 'Press Check first. It reports exactly what both legs would do -' + [Environment]::NewLine +
            'including anything the design leg would DELETE - and writes nothing.' + [Environment]::NewLine +
            'Tick Advanced to sync without checking.')
    }
    else {
        $tip.SetToolTip($btnSync, 'Run both legs: push design files out, pull field data back.')
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsSyncing = $Busy
    $btnCancel.Enabled = $Busy
    foreach ($c in @($cboProject,$btnProjNew,$btnProjRename,$btnProjDelete,$btnSave,$btnDetect,$btnNameDev,
                     $txtDesignSrc,$btnDesignSrcBrowse,$txtExportRoot,$btnExportRootBrowse,$txtDevProj,
                     $txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl,$cboExportCollision,$chkPrune,
                     $btnResetDefaults,$chkShowSame)) {
        $c.Enabled = -not $Busy
    }
    Update-ActionButtons
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
    # Snapshot the keep list now: the run is re-entrant through DoEvents, so reading
    # the live hashtable mid-run could see a click that arrived after the split.
    $keepThese = @($script:RescueMarks.Keys)
    if ($keepThese.Count) {
        Write-Log ("Keeping $($keepThese.Count) file(s) the collector has that the design folder does not: " +
                   ($keepThese -join ', ')) 'WARN'
    }
    # A check rebuilds the plan from scratch, so start from an empty grid -- a stale
    # grid under a fresh error message is worse than no grid. A sync instead ticks
    # off the rows a check has already put on screen, so those are left in place.
    if ($CheckOnly) { Show-ComparePlan @() '' }
    $lblCompareHint.Text = "$verb..."
    # Switch now, not at the end: the point is to watch it happen.
    $tabsOut.SelectedTab = $tabCompare
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
    # Rows tick over as the run reaches them, rather than the whole grid landing
    # at the end -- on a 150-file push over MTP that is minutes of nothing.
    $onItem = {
        param($row)
        Update-CompareRow $row
        [System.Windows.Forms.Application]::DoEvents()
    }
    try {
        $r = if ($CheckOnly) {
            Invoke-CollectorSync -Project $script:CurrentProject -Collector $script:CurrentCollector `
                -OnLog $onLog -OnProgress $onProg -CheckOnly -OnChooseDevice ${function:Choose-DeviceDialog} `
                -OnItem $onItem -RescueDesign $keepThese
        } else {
            Invoke-CollectorSync -Project $script:CurrentProject -Collector $script:CurrentCollector `
                -OnLog $onLog -OnProgress $onProg -OnChooseDevice ${function:Choose-DeviceDialog} `
                -OnItem $onItem -RescueDesign $keepThese
        }
        $msg = [string]$r.Summary
        if ($script:CancelRequested) { $msg = 'Cancelled. ' + $msg }
        $lblStatus.Text = $msg
        Write-Log ('----- ' + $msg + ' -----')
        # A file that was actually kept is now in the design folder, so the mark has
        # done its job and must go. Left behind, it would silently rescue the file
        # again the day someone deliberately supersedes it -- turning a one-off
        # "keep this" into a standing veto on ever deleting it.
        foreach ($lp in @($r.LegPlans)) {
            foreach ($row in @($lp.Rows)) {
                if ([string]$row.Status -eq 'rescued') { $script:RescueMarks.Remove([string]$row.DevRel) }
            }
        }
        # A completed check is what unlocks Sync. A completed sync withdraws it, so
        # the next run is compared afresh rather than assumed from a plan the run
        # itself has just invalidated. Set before the render, so the hint agrees.
        $script:CheckedOk = [bool]$CheckOnly
        # Both a check and a real sync produce a plan; after a sync it reads as a
        # record of what was done, which is the same grid either way.
        # Rebuild from the finished plan: the live ticks were per-file, this is the
        # authoritative record, and it re-sorts everything back into leg order.
        Show-ComparePlan @($r.LegPlans) (Get-CollectorLabel $script:CurrentCollector)
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
        $tabsOut.Anchor = 'Top,Left,Right'
        foreach ($c in @($btnSync,$btnCheck,$btnCancel,$progress,$lblStatus,$tabsOut)) { $c.Top = $c.Top + $d }
        $minH = $form.MinimumSize.Height + $d
        $newH = $form.Height + $d
        if ($d -lt 0) {
            $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $minH)
            $form.Height = $newH
        } else {
            $form.Height = $newH
            $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $minH)
        }
        $tabsOut.Anchor = 'Top,Bottom,Left,Right'
        $form.ResumeLayout()
        $script:AdvCollapsed = $wantCollapsed
    }
}
# ---- Event handlers -------------------------------------------------------
$chkShowSame.Add_CheckedChanged({
    if ($script:IsSyncing) { return }
    Show-ComparePlan $script:LastLegPlans ''
})

# Change your mind about a deletion. Prune is how superseded drawings actually go
# away, so it has to stay on -- but a file someone copied onto the collector by
# hand is a real file, and being made to delete it to get a clean sync is no
# choice at all. Clicking its row keeps it instead: the sync copies it back into
# the design folder, which is also what stops it being flagged again next time.
function Toggle-RescueMark {
    param($Item)
    if ($script:IsSyncing) { return }
    if ($null -eq $Item -or $null -eq $Item.Tag) { return }
    $row = $Item.Tag
    if (-not (Test-RescueEligible $row)) { return }
    $k = [string]$row.DevRel
    if (-not $k) { return }
    if ($script:RescueMarks.ContainsKey($k)) {
        $script:RescueMarks.Remove($k)
        Write-Log "Back to deleting '$k' from the collector on the next sync."
    }
    else {
        $script:RescueMarks[$k] = $true
        Write-Log "Keeping '$k': the next sync copies it into the design folder instead of deleting it."
    }
    $look = Get-RowLook $row
    $Item.SubItems[4].Text = $look.Glyph
    $Item.SubItems[9].Text = $look.What
    $Item.ForeColor = $look.Color
    Update-CompareHint
}

# The arrow cell and the "What happens" cell are the two that describe the action,
# so both are the button. Anywhere else on the row still just selects it.
$lvCompare.Add_MouseUp({
    param($snd, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hit = $lvCompare.HitTest($e.X, $e.Y)
    if ($null -eq $hit -or $null -eq $hit.Item) { return }
    $col = -1
    if ($null -ne $hit.SubItem) { $col = $hit.Item.SubItems.IndexOf($hit.SubItem) }
    if ($col -ne 4 -and $col -ne 9) { return }
    Toggle-RescueMark $hit.Item
})

# Three ways in, because one alone is not reliable. The TabPage's own Resize is the
# direct signal; the form's catches maximise/restore, which does not always reach the
# page; and the tab switch catches a resize that happened while the Log tab was in
# front, when the Compare page was laid out for a window that no longer exists.
# Update-CompareLayout does nothing when the size has not actually changed, so the
# overlap costs nothing.
$tabCompare.Add_Resize({ Update-CompareLayout })
$form.Add_Resize({ Update-CompareLayout })
$tabsOut.Add_SelectedIndexChanged({ Update-CompareLayout })

$cboProject.Add_SelectedIndexChanged({
    if ($script:IsSyncing) { return }
    $name = [string]$cboProject.SelectedItem
    $p = @($script:Config.projects) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($p) {
        Load-ProjectToUi $p
        $script:Config.activeProject = $name
        Set-Pref 'LastProject' $name
        # Different project, different endpoints: the last check describes neither.
        $script:CheckedOk = $false
        Update-ActionButtons
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
                "No collectors found.`r`n`r`nFor a controller: connect it over USB, unlock it, and set USB mode to File transfer (MTP).`r`nFor a USB stick: insert it and make sure Windows has given it a drive letter.",
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
            # Pin before refreshing: Update-DetectedCollector re-picks from the pin,
            # so without this it would immediately undo the choice just made.
            Set-PinnedCollector ([string]$existing.serial)
            Load-CollectorToUi $existing
            Update-DetectedCollector $true
            return
        }
        # Unknown serial: set it up deliberately, never inherit another collector's config.
        if ([string]$pick['Kind'] -eq 'folder') {
            $mount = ([string]$pick.Root).TrimEnd('\')
            $r = [System.Windows.Forms.MessageBox]::Show(
                ("This USB stick is not set up yet.`r`n`r`nVolume: $($pick.Name)  ($mount)`r`nSerial: $(Get-VolumeSerial $pick.Serial)`r`n`r`n" +
                 "It will be treated as a collector: design files pushed onto it, exports pulled off it.`r`n" +
                 "The tool locks to the volume serial, not the drive letter, so it still works if Windows mounts it elsewhere.`r`n`r`nAdd it now?"),
                'New USB target', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $nm = Prompt-Text -Title 'Name this USB target' `
                    -Message "Short name (used as the export filename prefix, e.g. USB-01):" -Default ([string]$pick.Name)
        }
        else {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "This collector is not set up yet.`r`n`r`nModel:  $($pick.Name)`r`nSerial: $($pick.Serial)`r`n`r`nAdd it now?",
                'New collector', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $nm = Prompt-Text -Title 'Name this collector' `
                    -Message "Short name (used as the export filename prefix, e.g. TSC5-03):" -Default ''
        }
        if (-not $nm) { return }
        $c = Register-Collector $pick $nm
        try { Save-Config } catch {}
        Write-Log "Registered collector '$nm' (serial $($pick.Serial))."
        Set-PinnedCollector ([string]$c.serial)
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
# Each of these also changes what a sync would do, so it withdraws the last check.
foreach ($ctl in @($txtDesignSub,$txtExportSub,$txtDesignExt,$txtExportExt,$txtExcl)) {
    $ctl.Add_TextChanged({ Update-DefaultsIndicator; Reset-CheckGate })
}
$cboExportCollision.Add_SelectedIndexChanged({ Update-DefaultsIndicator; Reset-CheckGate })
$chkPrune.Add_CheckedChanged({ Update-DefaultsIndicator; Reset-CheckGate })
# The project paths decide both endpoints, so they invalidate a check just as surely.
foreach ($ctl in @($txtDesignSrc,$txtExportRoot,$txtDevProj)) {
    $ctl.Add_TextChanged({ Reset-CheckGate })
}

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

$btnTidy.Add_Click({
    if ($script:IsSyncing) { return }
    if (-not $script:CurrentCollector) { return }
    Commit-UiToProject
    Commit-UiToCollector
    $days = Get-JobRetentionDays $script:CurrentCollector
    Set-Busy $true
    $lblStatus.Text = 'Checking which jobs are safe to remove...'
    $tabsOut.SelectedTab = $tabLog
    $onLog = { param($m,$l) Write-Log $m $l; [System.Windows.Forms.Application]::DoEvents() }
    try {
        $label = Get-CollectorLabel $script:CurrentCollector
        Write-Log "===== TIDY JOBS  $label  (keeping the last $days day(s)) =====" 'INFO'
        $ctx = @{ DeviceName = [string]$script:CurrentCollector.model; Settings = $script:Config.mtp; FolderCache = @{} }
        if ([string]$script:CurrentCollector.type -eq 'mtp') {
            Ensure-MtpInterop
            $dev = Resolve-CollectorDevice ([string]$script:CurrentCollector.model) '' ${function:Choose-DeviceDialog}
            $ctx.DeviceItem = $dev.Item; $ctx.DeviceSerial = $dev.Serial
        }
        $plan = Get-JobCleanupPlan $ctx $script:CurrentProject $script:CurrentCollector $days $onLog
        $go   = @($plan.Rows | Where-Object { $_.Remove })
        $keep = @($plan.Rows | Where-Object { -not $_.Remove })

        foreach ($r in $keep) { Write-Log ("keep     $($r.Rel)  ::  $($r.Why)") 'SKIP' }
        foreach ($r in $go)   { Write-Log ("would remove  $($r.Rel)  ::  $($r.Why)") 'WARN' }

        if ($go.Count -eq 0) {
            $lblStatus.Text = "Nothing to tidy - all $($plan.Rows.Count) job(s) are being kept."
            [System.Windows.Forms.MessageBox]::Show(
                ("Nothing to remove.`r`n`r`nAll $($plan.Rows.Count) job file(s) on $label are being kept - " +
                 "either they are inside the last $days day(s), they have no date in the name, or no backup copy was found."),
                'Tidy jobs', 'OK', 'Information') | Out-Null
            return
        }
        # Name every file, both lists. A count alone is not something anyone can agree
        # to, and the kept list is what shows the rules actually working.
        $lines = @("Remove $($go.Count) job file(s) from $label ?", '',
                   "Each one is older than $days day(s) AND has a verified backup copy.", '')
        # Name the copy that vouches for each deletion, not just the count. A backup
        # is matched by name and size, and the name it was filed under has changed
        # over the years -- so the one thing worth being able to eyeball is exactly
        # which file is standing in for the one about to go.
        foreach ($r in ($go | Sort-Object Rel)) {
            $where = [string]$r.Backup
            if ($where -and $plan.BackupRoot) { $where = $where.Replace($plan.BackupRoot + '\', '') }
            $lines += ("   {0}`r`n        {1}  ->  saved as {2}" -f $r.Rel, $r.Why, $where)
        }
        if ($keep.Count) {
            $lines += ''
            $lines += "Keeping $($keep.Count):"
            foreach ($r in ($keep | Sort-Object Rel | Select-Object -First 12)) { $lines += ("   {0}   - {1}" -f $r.Rel, $r.Why) }
            if ($keep.Count -gt 12) { $lines += "   ... and $($keep.Count - 12) more (all listed in the Log tab)" }
        }
        $lines += ''
        $lines += "Backups were confirmed under $($plan.BackupRoot)."
        $lines += 'This cannot be undone on the collector.'
        $answer = [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'Tidy jobs', 'YesNo', 'Warning', 'Button2')
        if ($answer -ne 'Yes') { $lblStatus.Text = 'Tidy cancelled - nothing removed.'; Write-Log 'Tidy cancelled by user.' 'INFO'; return }

        $res = Invoke-JobCleanup $ctx $plan $onLog
        $msg = "Removed $($res.Removed) job file(s) from $label"
        if ($res.Failed -gt 0) { $msg += ", $($res.Failed) kept back (see the Log)" }
        $lblStatus.Text = $msg + '.'
        Write-Log ("----- $msg -----") 'INFO'
    }
    catch {
        $lblStatus.Text = 'Tidy failed: ' + $_.Exception.Message
        Write-Log ('TIDY FAILED: ' + $_.Exception.Message) 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Tidy jobs', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-Busy $false
        Update-DetectedCollector $false
    }
})

$chkAdvanced.Add_CheckedChanged({
    Set-AdvancedMode ([bool]$chkAdvanced.Checked)
    # Advanced lifts the check-before-sync gate, so the buttons and the hint under
    # the grid both have to catch up the moment it is ticked either way.
    Update-ActionButtons
    Update-CompareHint
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
        # Volumes count too, or inserting a USB target would go unnoticed until the
        # next restart -- Get-ConnectedCollectors offers both kinds, so both are polled.
        $sig = ((@(@(Get-MtpDevices) + @(Get-VolumeDevices)) | ForEach-Object { $_.Serial }) -join '|')
        if ($sig -ne $script:LastSeenSerials) {
            $script:LastSeenSerials = $sig
            Update-DetectedCollector $true
        }
    }
    catch {}
})
$devTimer.Start()

# S: (and anything else in driveMap) is a subst, so it does not survive a logout.
# Put it back before the first project loads: every path in config.json depends
# on it, and a crew that has to run a .bat first will eventually forget to.
Confirm-MappedDrives { param($m, $lvl) Write-Log $m $lvl }

$startProject = [string](Get-Pref 'LastProject' $script:Config.activeProject)
Refresh-ProjectList -SelectName $startProject
Write-Log 'Sync Data Collector ready.'
try { $script:LastSeenSerials = ((@(Get-MtpDevices) | ForEach-Object { $_.Serial }) -join '|') } catch {}
Update-DetectedCollector $true
# Now that every control is placed and anchored, widen the window to fit the
# compare grid. Doing it here rather than at construction means the anchors
# reposition the right-hand buttons for us.
$form.MinimumSize = New-Object System.Drawing.Size(960, $form.MinimumSize.Height)
$form.Width = 1120
Update-CompareLayout

$chkAdvanced.Checked = ([string](Get-Pref 'Advanced' '0') -eq '1')
Set-AdvancedMode ([bool]$chkAdvanced.Checked)

# Smoke-test hook: build the whole window, wire every handler, then stop without
# showing it. A parse check cannot catch a control referenced before it is created
# -- a tooltip set on a button declared further down, a handler attached to a
# control that does not exist yet -- and those only ever surface as a crash on
# somebody's first launch. This runs the same construction path and reports.
if ($env:SDC_SMOKETEST -eq '1') {
    Write-Host 'SMOKE OK: window built, handlers wired, nothing shown.'
    $form.Dispose()
    return
}
[void]$form.ShowDialog()
