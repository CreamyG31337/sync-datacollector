# Graph Report - sync datacollector  (2026-10-09)

## Corpus Check
- 7 files · ~47,054 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 2, .cmd 1)

## Summary
- 193 nodes · 446 edges · 11 communities (9 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `3870c7e7`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Projects and collectors
- SyncDataCollector.ps1
- Show-ComparePlan
- Invoke-CollectorSync
- Invoke-SyncCheck
- Get-JobCleanupPlan
- Sync DataCollector
- Load-Config
- CLAUDE.md
- copilot-instructions.md

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 24 edges
2. `Sync DataCollector` - 19 edges
3. `Invoke-CollectorSync()` - 17 edges
4. `Invoke-SyncCheck()` - 15 edges
5. `Load-Config()` - 12 edges
6. `Get-JobCleanupPlan()` - 12 edges
7. `Update-SyncRecords()` - 11 edges
8. `Show-ComparePlan()` - 11 edges
9. `Expand-EnvVars()` - 10 edges
10. `Update-DetectedCollector()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `New-LegProfile()` --calls--> `New-Profile()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 4_
- `New-DriveMap()` --calls--> `Get-DriveLetter()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 6_
- `Get-DefaultConfig()` --calls--> `New-CollectorDefaults()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 2_
- `Invoke-Sync()` --calls--> `Split-DatedRoot()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 6 → community 0_
- `Invoke-CollectorSync()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 6 → community 4_

## Import Cycles
- None detected.

## Communities (11 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.12
Nodes (27): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-DeviceProjectSubPath() (+19 more)

### Community 1 - "Projects and collectors"
Cohesion: 0.22
Nodes (9): Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Filing by when the work was done, not when you pulled it, Keeping exports from different collectors apart, More than one folder going out: survey control, Projects and collectors, The app rides along (+1 more)

### Community 2 - "SyncDataCollector.ps1"
Cohesion: 0.09
Nodes (28): Apply-SettingsToUi(), Choose-DeviceDialog(), Commit-UiToCollector(), Format-DeviceChoice(), Format-Settings(), Get-CompareColumnWidths(), Get-ConsoleWindow(), Get-Defaults() (+20 more)

### Community 3 - "Show-ComparePlan"
Cohesion: 0.22
Nodes (14): Format-Local(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowLook(), Get-RowTip(), Show-ComparePlan(), Split-RelPath() (+6 more)

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.17
Nodes (22): Commit-UiToProject(), Ensure-ExportFolder(), Get-CollectorBySerial(), Get-CollectorDeviceRoot(), Get-CollectorLabel(), Get-ConnectedCollectors(), Get-ExportRoutes(), Get-SideNames() (+14 more)

### Community 5 - "Invoke-SyncCheck"
Cohesion: 0.17
Nodes (16): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck(), Load-SyncState(), New-DeviceMarker() (+8 more)

### Community 6 - "Get-JobCleanupPlan"
Cohesion: 0.20
Nodes (17): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Expand-PathTokens(), Get-CollectorFolderName(), Get-DriveLetter() (+9 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.06
Nodes (30): Check is required before Sync, Configuration reference, Exports are never destroyed, Features, Field data on the tablet, How MTP works here (and why it's reliable), Keeping a file the collector has and the design folder doesn't, Keeping superseded designs off the collector (+22 more)

### Community 9 - "Load-Config"
Cohesion: 0.22
Nodes (15): ConvertFrom-LegacyProfiles(), Copy-TabletConfigToVolume(), Get-DefaultConfig(), Get-ExtraDesigns(), Load-Config(), New-Collector(), New-DriveMap(), New-ExportRoute() (+7 more)

## Knowledge Gaps
- **33 isolated node(s):** `graphify`, `graphify`, `Main screen`, `Features`, `How MTP works here (and why it's reliable)` (+28 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 45 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Sync DataCollector` connect `Sync DataCollector` to `Projects and collectors`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Why does `Projects and collectors` connect `Projects and collectors` to `Sync DataCollector`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **What connects `graphify`, `graphify`, `Main screen` to the rest of the system?**
  _33 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Invoke-Sync` be split into smaller, more focused modules?**
  _Cohesion score 0.11965811965811966 - nodes in this community are weakly interconnected._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.08819345661450925 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.06451612903225806 - nodes in this community are weakly interconnected._