# Graph Report - sync datacollector  (2026-08-25)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 104 nodes · 258 edges · 8 communities (7 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `21e6c779`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Community 0
- Community 1
- Community 2
- Community 3
- Community 4
- Community 5
- Community 6
- Community 7

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 20 edges
2. `Invoke-SyncCheck()` - 15 edges
3. `Update-SyncRecords()` - 10 edges
4. `Resolve-MtpDir()` - 9 edges
5. `Load-Config()` - 9 edges
6. `Update-DetectedCollector()` - 9 edges
7. `Get-DefaultConfig()` - 7 edges
8. `Invoke-CollectorAction()` - 7 edges
9. `Expand-PathTokens()` - 7 edges
10. `Confirm-PathDrive()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Write-DeviceMarker()` --calls--> `Copy-FileMtp()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 0 → community 6_
- `Invoke-SyncCheck()` --calls--> `Get-FsInventory()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 0 → community 4_
- `Invoke-CollectorSync()` --calls--> `Invoke-Sync()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 0 → community 3_
- `Invoke-Sync()` --calls--> `Confirm-PathDrive()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 0 → community 5_
- `Invoke-Sync()` --calls--> `Select-SyncSet()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 0 → community 1_

## Import Cycles
- None detected.

## Communities (8 total, 1 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.17
Nodes (21): Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory(), Get-MtpInfo() (+13 more)

### Community 1 - "Community 1"
Cohesion: 0.13
Nodes (9): Choose-DeviceDialog(), Format-DeviceChoice(), Get-CollectorBySerial(), Get-ConnectedCollectors(), New-Collector(), Register-Collector(), Select-FromList(), Select-SyncSet() (+1 more)

### Community 2 - "Community 2"
Cohesion: 0.19
Nodes (17): Apply-SettingsToUi(), Commit-UiToCollector(), ConvertFrom-LegacyProfiles(), Format-Settings(), Get-DefaultConfig(), Get-Defaults(), Get-UiSettings(), Load-Config() (+9 more)

### Community 3 - "Community 3"
Cohesion: 0.23
Nodes (12): Commit-UiToProject(), Format-Local(), Get-CollectorFolderName(), Get-CollectorLabel(), Invoke-CollectorAction(), Invoke-CollectorSync(), Load-CollectorToUi(), New-LegProfile() (+4 more)

### Community 4 - "Community 4"
Cohesion: 0.23
Nodes (12): Expand-PathTokens(), Get-JulianDate(), Get-MonthFolder(), Get-MtpDeviceNames(), Get-MtpDevices(), Get-ShellApp(), Get-SyncStateEntries(), Get-SyncStateEntry() (+4 more)

### Community 5 - "Community 5"
Cohesion: 0.36
Nodes (10): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Expand-EnvVars(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots() (+2 more)

### Community 6 - "Community 6"
Cohesion: 0.27
Nodes (10): Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Load-SyncState(), New-DeviceMarker(), Remove-SyncStateEntry(), Save-SyncState(), Set-SyncStateEntry() (+2 more)

## Knowledge Gaps
- **1 isolated node(s):** `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Invoke-Sync()` connect `Community 0` to `Community 1`, `Community 3`, `Community 4`, `Community 5`, `Community 6`?**
  _High betweenness centrality (0.014) - this node is a cross-community bridge._
- **Why does `Invoke-SyncCheck()` connect `Community 4` to `Community 0`, `Community 1`, `Community 3`, `Community 5`, `Community 6`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **Why does `Update-SyncRecords()` connect `Community 6` to `Community 0`, `Community 1`?**
  _High betweenness centrality (0.003) - this node is a cross-community bridge._
- **What connects `C:\Users\user\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe` to the rest of the system?**
  _1 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.13450292397660818 - nodes in this community are weakly interconnected._