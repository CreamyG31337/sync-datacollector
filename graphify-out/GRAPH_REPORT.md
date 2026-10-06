# Graph Report - sync datacollector  (2026-10-06)

## Corpus Check
- 7 files · ~44,634 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 2, .cmd 1)

## Summary
- 188 nodes · 435 edges · 11 communities (9 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `be13fa9d`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Get-Defaults
- SyncDataCollector.ps1
- Invoke-CollectorAction
- Invoke-CollectorSync
- Invoke-SyncCheck
- Confirm-PathDrive
- Sync DataCollector
- Load-Config
- CLAUDE.md
- copilot-instructions.md

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 24 edges
2. `Sync DataCollector` - 18 edges
3. `Invoke-CollectorSync()` - 16 edges
4. `Invoke-SyncCheck()` - 15 edges
5. `Load-Config()` - 12 edges
6. `Get-JobCleanupPlan()` - 12 edges
7. `Update-SyncRecords()` - 11 edges
8. `Expand-EnvVars()` - 10 edges
9. `Show-ComparePlan()` - 10 edges
10. `Update-DetectedCollector()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `New-LegProfile()` --calls--> `New-Profile()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 4_
- `New-DriveMap()` --calls--> `Get-DriveLetter()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 6_
- `Get-DefaultConfig()` --calls--> `New-CollectorDefaults()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 1_
- `Resolve-MtpDir()` --calls--> `Split-MtpPath()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 0_
- `Invoke-Sync()` --calls--> `Split-DatedRoot()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_

## Import Cycles
- None detected.

## Communities (11 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.15
Nodes (23): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory() (+15 more)

### Community 1 - "Get-Defaults"
Cohesion: 0.25
Nodes (11): Apply-SettingsToUi(), Commit-UiToCollector(), Format-Settings(), Get-Defaults(), Get-JobRetentionDays(), Get-UiSettings(), New-CollectorDefaults(), Parse-Extensions() (+3 more)

### Community 2 - "SyncDataCollector.ps1"
Cohesion: 0.09
Nodes (24): Choose-DeviceDialog(), Format-DeviceChoice(), Get-CollectorBySerial(), Get-CompareColumnWidths(), Get-ConnectedCollectors(), Get-ConsoleWindow(), Get-DeviceProjectSubPath(), Get-JulianFromName() (+16 more)

### Community 3 - "Invoke-CollectorAction"
Cohesion: 0.14
Nodes (23): Commit-UiToProject(), Format-Local(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowLook(), Get-RowTip(), Invoke-CollectorAction() (+15 more)

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.23
Nodes (18): Ensure-ExportFolder(), Expand-EnvVars(), Expand-PathTokens(), Get-CollectorDeviceRoot(), Get-CollectorFolderName(), Get-CollectorLabel(), Get-ExportRoutes(), Get-JobCleanupPlan() (+10 more)

### Community 5 - "Invoke-SyncCheck"
Cohesion: 0.23
Nodes (13): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck(), Load-SyncState(), New-DeviceMarker() (+5 more)

### Community 6 - "Confirm-PathDrive"
Cohesion: 0.36
Nodes (9): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots(), Get-SubstTarget() (+1 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.05
Nodes (38): Check is required before Sync, Configuration reference, Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Exports are never destroyed, Features, Field data on the tablet (+30 more)

### Community 9 - "Load-Config"
Cohesion: 0.22
Nodes (15): ConvertFrom-LegacyProfiles(), Copy-TabletConfigToVolume(), Get-DefaultConfig(), Get-ExtraDesigns(), Load-Config(), New-Collector(), New-DriveMap(), New-ExportRoute() (+7 more)

## Knowledge Gaps
- **32 isolated node(s):** `graphify`, `graphify`, `Main screen`, `Features`, `How MTP works here (and why it's reliable)` (+27 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 43 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `graphify`, `graphify`, `Main screen` to the rest of the system?**
  _32 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.09090909090909091 - nodes in this community are weakly interconnected._
- **Should `Invoke-CollectorAction` be split into smaller, more focused modules?**
  _Cohesion score 0.1422924901185771 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.05128205128205128 - nodes in this community are weakly interconnected._