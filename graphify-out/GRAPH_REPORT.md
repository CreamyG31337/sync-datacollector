# Graph Report - sync datacollector  (2026-09-04)

## Corpus Check
- 7 files · ~40,002 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 178 nodes · 413 edges · 10 communities (8 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `03727048`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Expand-EnvVars
- Load-Config
- Get-UiSettings
- Invoke-CollectorSync
- SyncDataCollector.ps1
- Sync DataCollector
- CLAUDE.md
- copilot-instructions.md
- Invoke-CollectorAction

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 24 edges
2. `Sync DataCollector` - 17 edges
3. `Invoke-SyncCheck()` - 15 edges
4. `Invoke-CollectorSync()` - 14 edges
5. `Get-JobCleanupPlan()` - 12 edges
6. `Load-Config()` - 11 edges
7. `Expand-EnvVars()` - 10 edges
8. `Update-SyncRecords()` - 10 edges
9. `Show-ComparePlan()` - 10 edges
10. `Update-DetectedCollector()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `New-LegProfile()` --calls--> `New-Profile()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 4_
- `New-DriveMap()` --calls--> `Get-DriveLetter()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 1_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 1_
- `Get-JobCleanupPlan()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_
- `Invoke-SyncCheck()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 5_

## Import Cycles
- None detected.

## Communities (10 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.12
Nodes (29): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-DeviceProjectSubPath() (+21 more)

### Community 1 - "Expand-EnvVars"
Cohesion: 0.36
Nodes (10): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots() (+2 more)

### Community 2 - "Load-Config"
Cohesion: 0.24
Nodes (14): ConvertFrom-LegacyProfiles(), Get-DefaultConfig(), Get-Defaults(), Get-JobRetentionDays(), Load-Config(), New-Collector(), New-CollectorDefaults(), New-DriveMap() (+6 more)

### Community 3 - "Get-UiSettings"
Cohesion: 0.43
Nodes (7): Apply-SettingsToUi(), Commit-UiToCollector(), Format-Settings(), Get-UiSettings(), Parse-Extensions(), Parse-FolderList(), Update-DefaultsIndicator()

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.21
Nodes (15): Copy-TabletConfigToVolume(), Expand-PathTokens(), Get-CollectorDeviceRoot(), Get-CollectorFolderName(), Get-ExportRoutes(), Get-JulianDate(), Get-MonthFolder(), Get-VolumeSerial() (+7 more)

### Community 5 - "SyncDataCollector.ps1"
Cohesion: 0.09
Nodes (31): Choose-DeviceDialog(), Format-DeviceChoice(), Format-Utc(), Get-CollectorBySerial(), Get-CompareColumnWidths(), Get-ConnectedCollectors(), Get-DeviceFriendlyName(), Get-DeviceLabel() (+23 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.06
Nodes (35): Check is required before Sync, Configuration reference, Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Exports are never destroyed, Features, Filing by when the work was done, not when you pulled it (+27 more)

### Community 13 - "Invoke-CollectorAction"
Cohesion: 0.15
Nodes (23): Commit-UiToProject(), Format-Local(), Format-RowTime(), Format-Size(), Get-CollectorLabel(), Get-RowKey(), Get-RowLook(), Get-RowTip() (+15 more)

## Knowledge Gaps
- **29 isolated node(s):** `graphify`, `graphify`, `Features`, `How MTP works here (and why it's reliable)`, `Requirements` (+24 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `graphify`, `graphify`, `Features` to the rest of the system?**
  _29 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Invoke-Sync` be split into smaller, more focused modules?**
  _Cohesion score 0.11822660098522167 - nodes in this community are weakly interconnected._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.09230769230769231 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.05555555555555555 - nodes in this community are weakly interconnected._
- **Should `Invoke-CollectorAction` be split into smaller, more focused modules?**
  _Cohesion score 0.14624505928853754 - nodes in this community are weakly interconnected._