# Graph Report - sync datacollector  (2026-10-06)

## Corpus Check
- 7 files · ~43,658 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 2, .cmd 1)

## Summary
- 185 nodes · 428 edges · 12 communities (10 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4f01a9b0`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Resolve-MtpDir
- Get-Defaults
- SyncDataCollector.ps1
- Projects and collectors
- Invoke-CollectorSync
- Invoke-SyncCheck
- Expand-EnvVars
- Invoke-Sync
- Sync DataCollector
- Load-Config
- CLAUDE.md
- copilot-instructions.md

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 24 edges
2. `Sync DataCollector` - 18 edges
3. `Invoke-SyncCheck()` - 15 edges
4. `Invoke-CollectorSync()` - 15 edges
5. `Get-JobCleanupPlan()` - 12 edges
6. `Load-Config()` - 11 edges
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
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 0_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 7 → community 6_

## Import Cycles
- None detected.

## Communities (12 total, 2 thin omitted)

### Community 0 - "Resolve-MtpDir"
Cohesion: 0.21
Nodes (14): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-MtpInfo(), Invoke-CopyWithRetry() (+6 more)

### Community 1 - "Get-Defaults"
Cohesion: 0.25
Nodes (11): Apply-SettingsToUi(), Commit-UiToCollector(), Format-Settings(), Get-Defaults(), Get-JobRetentionDays(), Get-UiSettings(), New-CollectorDefaults(), Parse-Extensions() (+3 more)

### Community 2 - "SyncDataCollector.ps1"
Cohesion: 0.08
Nodes (35): Choose-DeviceDialog(), Format-DeviceChoice(), Format-Local(), Format-RowTime(), Format-Size(), Get-CompareColumnWidths(), Get-ConsoleWindow(), Get-MtpDeviceNames() (+27 more)

### Community 3 - "Projects and collectors"
Cohesion: 0.25
Nodes (8): Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Filing by when the work was done, not when you pulled it, Keeping exports from different collectors apart, Projects and collectors, The app rides along, USB sticks as collectors

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.22
Nodes (17): Commit-UiToProject(), Ensure-ExportFolder(), Get-CollectorBySerial(), Get-CollectorDeviceRoot(), Get-CollectorLabel(), Get-ConnectedCollectors(), Get-ExportRoutes(), Get-VolumeDevices() (+9 more)

### Community 5 - "Invoke-SyncCheck"
Cohesion: 0.21
Nodes (14): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck(), Load-SyncState(), New-DeviceMarker() (+6 more)

### Community 6 - "Expand-EnvVars"
Cohesion: 0.31
Nodes (11): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-CollectorFolderName(), Get-DriveLetter(), Get-DriveMapEntry() (+3 more)

### Community 7 - "Invoke-Sync"
Cohesion: 0.19
Nodes (17): Expand-PathTokens(), Get-DestRel(), Get-FsInventory(), Get-JobCleanupPlan(), Get-JulianDate(), Get-JulianFromName(), Get-MonthFolder(), Get-MtpInventory() (+9 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.07
Nodes (29): Check is required before Sync, Configuration reference, Exports are never destroyed, Features, Field data on the tablet, How MTP works here (and why it's reliable), Keeping a file the collector has and the design folder doesn't, Keeping superseded designs off the collector (+21 more)

### Community 9 - "Load-Config"
Cohesion: 0.21
Nodes (15): ConvertFrom-LegacyProfiles(), Copy-TabletConfigToVolume(), Get-DefaultConfig(), Get-DeviceProjectSubPath(), Load-Config(), New-Collector(), New-DriveMap(), New-ExportRoute() (+7 more)

## Knowledge Gaps
- **31 isolated node(s):** `graphify`, `graphify`, `Main screen`, `Features`, `How MTP works here (and why it's reliable)` (+26 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 42 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Sync DataCollector` connect `Sync DataCollector` to `Projects and collectors`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Why does `Projects and collectors` connect `Projects and collectors` to `Sync DataCollector`?**
  _High betweenness centrality (0.014) - this node is a cross-community bridge._
- **What connects `graphify`, `graphify`, `Main screen` to the rest of the system?**
  _31 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.08456659619450317 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.06666666666666667 - nodes in this community are weakly interconnected._