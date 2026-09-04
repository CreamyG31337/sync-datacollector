# Graph Report - sync datacollector  (2026-09-03)

## Corpus Check
- 7 files · ~39,403 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 177 nodes · 412 edges · 10 communities (8 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `c205bcaf`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Expand-EnvVars
- Load-Config
- Get-UiSettings
- Invoke-SyncCheck
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
- `Resolve-MtpDir()` --calls--> `Split-MtpPath()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 0_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 1_
- `Get-JobCleanupPlan()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_

## Import Cycles
- None detected.

## Communities (10 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.13
Nodes (27): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory() (+19 more)

### Community 1 - "Expand-EnvVars"
Cohesion: 0.31
Nodes (11): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-CollectorFolderName(), Get-DriveLetter(), Get-DriveMapEntry() (+3 more)

### Community 2 - "Load-Config"
Cohesion: 0.20
Nodes (16): ConvertFrom-LegacyProfiles(), Get-DefaultConfig(), Get-Defaults(), Get-DeviceProjectSubPath(), Get-JobRetentionDays(), Load-Config(), New-Collector(), New-CollectorDefaults() (+8 more)

### Community 3 - "Get-UiSettings"
Cohesion: 0.43
Nodes (7): Apply-SettingsToUi(), Commit-UiToCollector(), Format-Settings(), Get-UiSettings(), Parse-Extensions(), Parse-FolderList(), Update-DefaultsIndicator()

### Community 4 - "Invoke-SyncCheck"
Cohesion: 0.18
Nodes (19): Copy-TabletConfigToVolume(), Expand-PathTokens(), Get-CollectorDeviceRoot(), Get-CollectorLabel(), Get-DeviceLabel(), Get-ExportRoutes(), Get-JulianDate(), Get-MonthFolder() (+11 more)

### Community 5 - "SyncDataCollector.ps1"
Cohesion: 0.10
Nodes (26): Choose-DeviceDialog(), Format-DeviceChoice(), Format-Utc(), Get-CollectorBySerial(), Get-CompareColumnWidths(), Get-ConnectedCollectors(), Get-DeviceFriendlyName(), Get-MtpDeviceNames() (+18 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.06
Nodes (34): Check is required before Sync, Configuration reference, Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Exports are never destroyed, Features, Filing by when the work was done, not when you pulled it (+26 more)

### Community 13 - "Invoke-CollectorAction"
Cohesion: 0.14
Nodes (23): Commit-UiToProject(), Format-Local(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowLook(), Get-RowTip(), Invoke-CollectorAction() (+15 more)

## Knowledge Gaps
- **29 isolated node(s):** `graphify`, `graphify`, `Features`, `How MTP works here (and why it's reliable)`, `Requirements` (+24 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `graphify`, `graphify`, `Features` to the rest of the system?**
  _29 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Invoke-Sync` be split into smaller, more focused modules?**
  _Cohesion score 0.13105413105413105 - nodes in this community are weakly interconnected._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.0957983193277311 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.05714285714285714 - nodes in this community are weakly interconnected._
- **Should `Invoke-CollectorAction` be split into smaller, more focused modules?**
  _Cohesion score 0.1422924901185771 - nodes in this community are weakly interconnected._