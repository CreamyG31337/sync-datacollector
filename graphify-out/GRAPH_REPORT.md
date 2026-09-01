# Graph Report - sync datacollector  (2026-08-31)

## Corpus Check
- 9 files · ~25,848 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 141 nodes · 308 edges · 11 communities (8 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `81b3b9f5`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- SyncDataCollector.ps1
- Load-Config
- Invoke-CollectorAction
- Invoke-SyncCheck
- Confirm-PathDrive
- Update-SyncRecords
- graphify
- Sync DataCollector
- CLAUDE.md
- copilot-instructions.md

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 20 edges
2. `Sync DataCollector` - 16 edges
3. `Invoke-SyncCheck()` - 15 edges
4. `Update-SyncRecords()` - 10 edges
5. `Invoke-CollectorAction()` - 10 edges
6. `Load-Config()` - 9 edges
7. `Resolve-MtpDir()` - 9 edges
8. `Update-DetectedCollector()` - 9 edges
9. `Show-ComparePlan()` - 8 edges
10. `Get-DefaultConfig()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `New-LegProfile()` --calls--> `New-Profile()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 3_
- `New-DriveMap()` --calls--> `Get-DriveLetter()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 5_
- `Load-Config()` --calls--> `New-Collector()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 1_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 5_
- `Invoke-Sync()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_

## Import Cycles
- None detected.

## Communities (11 total, 3 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.14
Nodes (24): Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory(), Get-MtpInfo() (+16 more)

### Community 1 - "SyncDataCollector.ps1"
Cohesion: 0.14
Nodes (14): Choose-DeviceDialog(), Format-DeviceChoice(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowLook(), New-Collector(), Register-Collector() (+6 more)

### Community 2 - "Load-Config"
Cohesion: 0.21
Nodes (16): Commit-UiToCollector(), ConvertFrom-LegacyProfiles(), Format-Settings(), Get-DefaultConfig(), Get-Defaults(), Get-UiSettings(), Load-Config(), New-CollectorDefaults() (+8 more)

### Community 3 - "Invoke-CollectorAction"
Cohesion: 0.20
Nodes (14): Apply-SettingsToUi(), Commit-UiToProject(), Format-Local(), Get-CollectorBySerial(), Get-CollectorFolderName(), Get-CollectorLabel(), Get-ConnectedCollectors(), Invoke-CollectorAction() (+6 more)

### Community 4 - "Invoke-SyncCheck"
Cohesion: 0.21
Nodes (13): Expand-PathTokens(), Get-JulianDate(), Get-MonthFolder(), Get-MtpDeviceNames(), Get-MtpDevices(), Get-ShellApp(), Get-SyncStateEntries(), Get-SyncStateEntry() (+5 more)

### Community 5 - "Confirm-PathDrive"
Cohesion: 0.36
Nodes (10): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots() (+2 more)

### Community 6 - "Update-SyncRecords"
Cohesion: 0.31
Nodes (9): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Load-SyncState(), New-DeviceMarker(), Remove-SyncStateEntry(), Save-SyncState(), Set-SyncStateEntry() (+1 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.08
Nodes (23): Configuration reference, Defaults, Everyday mode, and the Advanced tick-box, Exports are never destroyed, Features, How MTP works here (and why it's reliable), Keeping exports from different collectors apart, Keeping superseded designs off the collector (+15 more)

## Knowledge Gaps
- **23 isolated node(s):** `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, `graphify`, `graphify`, `Features`, `How MTP works here (and why it's reliable)` (+18 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Invoke-Sync()` connect `Invoke-Sync` to `SyncDataCollector.ps1`, `Invoke-CollectorAction`, `Invoke-SyncCheck`, `Confirm-PathDrive`, `Update-SyncRecords`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **What connects `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, `graphify`, `graphify` to the rest of the system?**
  _23 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Invoke-Sync` be split into smaller, more focused modules?**
  _Cohesion score 0.14130434782608695 - nodes in this community are weakly interconnected._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.13768115942028986 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.08333333333333333 - nodes in this community are weakly interconnected._