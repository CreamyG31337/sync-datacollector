# Graph Report - sync datacollector  (2026-09-02)

## Corpus Check
- 9 files · ~29,686 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 154 nodes · 346 edges · 11 communities (8 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `8d3ecaef`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- SyncDataCollector.ps1
- Update-SyncRecords
- Invoke-SyncCheck
- Invoke-CollectorSync
- Invoke-CollectorAction
- Confirm-PathDrive
- graphify
- Sync DataCollector
- CLAUDE.md
- copilot-instructions.md

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 20 edges
2. `Sync DataCollector` - 16 edges
3. `Invoke-SyncCheck()` - 15 edges
4. `Invoke-CollectorSync()` - 11 edges
5. `Update-SyncRecords()` - 10 edges
6. `Invoke-CollectorAction()` - 10 edges
7. `Load-Config()` - 9 edges
8. `Resolve-MtpDir()` - 9 edges
9. `Update-DetectedCollector()` - 9 edges
10. `Show-ComparePlan()` - 8 edges

## Surprising Connections (you probably didn't know these)
- `New-LegProfile()` --calls--> `New-Profile()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 1 → community 4_
- `New-DriveMap()` --calls--> `Get-DriveLetter()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 1 → community 6_
- `Resolve-MtpDir()` --calls--> `Split-MtpPath()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 1 → community 0_
- `Expand-PathTokens()` --calls--> `Expand-EnvVars()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 3 → community 6_
- `Invoke-Sync()` --calls--> `Expand-PathTokens()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 3 → community 0_

## Import Cycles
- None detected.

## Communities (11 total, 3 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.16
Nodes (22): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory() (+14 more)

### Community 1 - "SyncDataCollector.ps1"
Cohesion: 0.12
Nodes (25): Apply-SettingsToUi(), Choose-DeviceDialog(), Commit-UiToCollector(), ConvertFrom-LegacyProfiles(), Format-DeviceChoice(), Format-Settings(), Get-DefaultConfig(), Get-Defaults() (+17 more)

### Community 2 - "Update-SyncRecords"
Cohesion: 0.31
Nodes (9): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Load-SyncState(), New-DeviceMarker(), Remove-SyncStateEntry(), Save-SyncState(), Set-SyncStateEntry() (+1 more)

### Community 3 - "Invoke-SyncCheck"
Cohesion: 0.22
Nodes (11): Expand-PathTokens(), Format-Local(), Get-JulianDate(), Get-MonthFolder(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck(), Parse-Utc() (+3 more)

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.18
Nodes (16): Copy-TabletConfigToVolume(), Get-CollectorBySerial(), Get-CollectorDeviceRoot(), Get-CollectorFolderName(), Get-ConnectedCollectors(), Get-MtpDeviceNames(), Get-MtpDevices(), Get-ShellApp() (+8 more)

### Community 5 - "Invoke-CollectorAction"
Cohesion: 0.19
Nodes (16): Commit-UiToProject(), Format-RowTime(), Format-Size(), Get-CollectorLabel(), Get-RowKey(), Get-RowLook(), Invoke-CollectorAction(), Load-CollectorToUi() (+8 more)

### Community 6 - "Confirm-PathDrive"
Cohesion: 0.36
Nodes (10): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots() (+2 more)

### Community 8 - "Sync DataCollector"
Cohesion: 0.07
Nodes (27): Configuration reference, Defaults, Everyday mode, and the Advanced tick-box, Exports are never destroyed, Features, How MTP works here (and why it's reliable), Keeping exports from different collectors apart, Keeping superseded designs off the collector (+19 more)

## Knowledge Gaps
- **25 isolated node(s):** `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, `graphify`, `graphify`, `Features`, `How MTP works here (and why it's reliable)` (+20 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, `graphify`, `graphify` to the rest of the system?**
  _25 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.11596638655462185 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.07142857142857142 - nodes in this community are weakly interconnected._