# Graph Report - sync datacollector  (2026-10-06)

## Corpus Check
- 7 files · ~46,228 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 2, .cmd 1)

## Summary
- 192 nodes · 440 edges · 16 communities (14 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `1acf968a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Invoke-Sync
- Projects and collectors
- SyncDataCollector.ps1
- Show-ComparePlan
- Invoke-CollectorSync
- Invoke-SyncCheck
- Confirm-PathDrive
- Get-UiSettings
- Sync DataCollector
- Load-Config
- Get-ConnectedCollectors
- CLAUDE.md
- copilot-instructions.md
- Invoke-CollectorAction
- Get-RowLook
- Load-CollectorToUi

## God Nodes (most connected - your core abstractions)
1. `Invoke-Sync()` - 24 edges
2. `Sync DataCollector` - 19 edges
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
- `Resolve-MtpDir()` --calls--> `Split-MtpPath()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 9 → community 0_
- `Invoke-Sync()` --calls--> `Get-JulianFromName()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 2 → community 0_
- `Invoke-Sync()` --calls--> `Split-DatedRoot()`  [EXTRACTED]
  SyncDataCollector.ps1 → SyncDataCollector.ps1  _Bridges community 4 → community 0_

## Import Cycles
- None detected.

## Communities (16 total, 2 thin omitted)

### Community 0 - "Invoke-Sync"
Cohesion: 0.15
Nodes (23): Copy-AppToVolume(), Copy-FileFolder(), Copy-FileMtp(), Copy-FileMtpDownload(), Ensure-MtpInterop(), Find-ShellChild(), Get-DestRel(), Get-FsInventory() (+15 more)

### Community 1 - "Projects and collectors"
Cohesion: 0.22
Nodes (9): Defaults, Everyday mode, and the Advanced tick-box, Export routes: filing different file types in different places, Filing by when the work was done, not when you pulled it, Keeping exports from different collectors apart, More than one folder going out: survey control, Projects and collectors, The app rides along (+1 more)

### Community 2 - "SyncDataCollector.ps1"
Cohesion: 0.13
Nodes (10): Get-CompareColumnWidths(), Get-ConsoleWindow(), Get-JulianFromName(), Hide-ConsoleWindow(), Invoke-Git(), Invoke-SelfUpdate(), Resize-CompareColumns(), Show-ConsoleWindow() (+2 more)

### Community 3 - "Show-ComparePlan"
Cohesion: 0.39
Nodes (8): Format-Local(), Format-RowTime(), Format-Size(), Get-RowKey(), Get-RowTip(), Show-ComparePlan(), Split-RelPath(), Update-CompareRow()

### Community 4 - "Invoke-CollectorSync"
Cohesion: 0.23
Nodes (18): Ensure-ExportFolder(), Expand-EnvVars(), Expand-PathTokens(), Get-CollectorDeviceRoot(), Get-CollectorFolderName(), Get-CollectorLabel(), Get-ExportRoutes(), Get-JobCleanupPlan() (+10 more)

### Community 5 - "Invoke-SyncCheck"
Cohesion: 0.15
Nodes (18): Choose-DeviceDialog(), Format-DeviceChoice(), Format-Utc(), Get-DeviceFriendlyName(), Get-DeviceLabel(), Get-SyncStateEntries(), Get-SyncStateEntry(), Invoke-SyncCheck() (+10 more)

### Community 6 - "Confirm-PathDrive"
Cohesion: 0.36
Nodes (9): Confirm-MappedDrive(), Confirm-MappedDrives(), Confirm-PathDrive(), Ensure-MappedDrive(), Get-DriveLetter(), Get-DriveMapEntry(), Get-OneDriveRoots(), Get-SubstTarget() (+1 more)

### Community 7 - "Get-UiSettings"
Cohesion: 0.43
Nodes (7): Apply-SettingsToUi(), Commit-UiToCollector(), Format-Settings(), Get-UiSettings(), Parse-Extensions(), Parse-FolderList(), Update-DefaultsIndicator()

### Community 8 - "Sync DataCollector"
Cohesion: 0.06
Nodes (30): Check is required before Sync, Configuration reference, Exports are never destroyed, Features, Field data on the tablet, How MTP works here (and why it's reliable), Keeping a file the collector has and the design folder doesn't, Keeping superseded designs off the collector (+22 more)

### Community 9 - "Load-Config"
Cohesion: 0.15
Nodes (21): ConvertFrom-LegacyProfiles(), Copy-TabletConfigToVolume(), Get-DefaultConfig(), Get-Defaults(), Get-DeviceProjectSubPath(), Get-ExtraDesigns(), Get-JobRetentionDays(), Load-Config() (+13 more)

### Community 10 - "Get-ConnectedCollectors"
Cohesion: 0.29
Nodes (7): Get-CollectorBySerial(), Get-ConnectedCollectors(), Get-MtpDeviceNames(), Get-MtpDevices(), Get-ShellApp(), Get-VolumeDevices(), Resolve-CollectorDevice()

### Community 13 - "Invoke-CollectorAction"
Cohesion: 0.33
Nodes (6): Commit-UiToProject(), Invoke-CollectorAction(), Parse-Utc(), Set-PinnedCollector(), Set-Pref(), Update-DetectedCollector()

### Community 14 - "Get-RowLook"
Cohesion: 0.40
Nodes (6): Get-RowLook(), Test-RescueEligible(), Test-RescueMark(), Toggle-RescueMark(), Update-CompareHint(), Write-Log()

### Community 15 - "Load-CollectorToUi"
Cohesion: 0.50
Nodes (5): Load-CollectorToUi(), Reset-CheckGate(), Set-Busy(), Test-SyncAllowed(), Update-ActionButtons()

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
- **Should `SyncDataCollector.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.13157894736842105 - nodes in this community are weakly interconnected._
- **Should `Sync DataCollector` be split into smaller, more focused modules?**
  _Cohesion score 0.06451612903225806 - nodes in this community are weakly interconnected._
- **Should `Load-Config` be split into smaller, more focused modules?**
  _Cohesion score 0.14761904761904762 - nodes in this community are weakly interconnected._