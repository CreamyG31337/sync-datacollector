# Graph Report - sync datacollector  (2026-10-06)

## Corpus Check
- 7 files · ~45,109 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 2, .cmd 1)

## Summary
- 189 nodes · 436 edges · 11 communities (9 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `7b65ddf8`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Projects and collectors
- SyncDataCollector.ps1
- Invoke-CollectorAction
- Invoke-CollectorSync
- Invoke-SyncCheck
- Expand-EnvVars
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
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 2_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 6_
- `Get-JobCleanupPlan()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_

## Import Cycles
- None detected.

## Communities (11 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.12
Nodes (29): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-DeviceProjectSubPath() (+21 more)

### Community 1 - "Projects and collectors"
Cohesion: 0.22
Nodes (9): Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Filing by when the work was done, not when you pulled it, Keeping exports from different collectors apart, More than one folder going out: survey control, Projects and collectors, The app rides along (+1 more)

### Community 2 - "SyncDataCollector.ps1"
Cohesion: 0.08
Nodes (30): Apply-SettingsToUi(), Choose-DeviceDialog(), Commit-UiToCollector(), Format-Settings(), Get-CollectorBySerial(), Get-CompareColumnWidths(), Get-ConnectedCollectors(), Get-ConsoleWindow() (+22 more)

### Community 3 - "Invoke-CollectorAction"
Cohesion: 0.14
Nodes (23): Commit-UiToProject(), Format-Local(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowLook(), Get-RowTip(), Invoke-CollectorAction() (+15 more)

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.22
Nodes (15): Copy-TabletConfigToVolume(), Ensure-ExportFolder(), Expand-PathTokens(), Get-CollectorDeviceRoot(), Get-CollectorFolderName(), Get-ExtraDesigns(), Get-JulianDate(), Get-MonthFolder() (+7 more)

### Community 5 - "Invoke-SyncCheck"
Cohesion: 0.19
Nodes (15): Format-DeviceChoice(), Format-Utc(), Get-CollectorLabel(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck() (+7 more)

### Community 6 - "Expand-EnvVars"
Cohesion: 0.36
Nodes (10): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots() (+2 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.07
Nodes (29): Check is required before Sync, Configuration reference, Exports are never destroyed, Features, Field data on the tablet, How MTP works here (and why it's reliable), Keeping a file the collector has and the design folder doesn't, Keeping superseded designs off the collector (+21 more)

### Community 9 - "Load-Config"
Cohesion: 0.24
Nodes (14): ConvertFrom-LegacyProfiles(), Get-DefaultConfig(), Get-ExportRoutes(), Load-Config(), New-Collector(), New-DriveMap(), New-ExportRoute(), New-ExtraDesign() (+6 more)

## Knowledge Gaps
- **32 isolated node(s):** `graphify`, `graphify`, `Main screen`, `Features`, `How MTP works here (and why it's reliable)` (+27 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 44 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Sync DataCollector` connect `Sync DataCollector` to `Projects and collectors`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Why does `Projects and collectors` connect `Projects and collectors` to `Sync DataCollector`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **What connects `graphify`, `graphify`, `Main screen` to the rest of the system?**
  _32 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Invoke-Sync` be split into smaller, more focused modules?**
  _Cohesion score 0.11822660098522167 - nodes in this community are weakly interconnected._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.08461538461538462 - nodes in this community are weakly interconnected._
- **Should `Invoke-CollectorAction` be split into smaller, more focused modules?**
  _Cohesion score 0.1422924901185771 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.06666666666666667 - nodes in this community are weakly interconnected._