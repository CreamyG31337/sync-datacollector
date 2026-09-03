# Sync DataCollector

A lightweight Windows GUI for **one-way file sync between a PC and survey data collectors**,
in **both directions**:

- **Push** design files (`.csv`, `.dxf`, LandXML `.xml`, Trimble `.ttm` surfaces, `.rxl`
  alignments, …) onto a collector before you head out.
- **Pull** field-collected data (jobs, scans, exports) *off* a collector onto a USB stick or
  a cloud-synced folder — keeping each collector's work separate so nothing collides.

It handles the two ways collectors actually connect:

- **MTP over USB** — collectors that mount as a "portable device" (no drive letter),
  which normal tools like `robocopy` / `Copy-Item` **cannot** reach.
- **Plain folder** — a USB stick, a network share, or the collector's own internal
  disk (useful when IT policy blocks the collector from connecting to the PC directly,
  so you stage to a USB stick and pull from it on the collector).

No install, no build step, **no third-party libraries**: a single PowerShell script +
WinForms GUI that runs on stock Windows (PowerShell 5.1 + .NET Framework 4.x).

> Not affiliated with, or endorsed by, any hardware manufacturer. "MTP" is a generic
> protocol; this tool works with any MTP-class device.

---

## Features

- **Push and pull share one engine** — the same comparison, retry and verification logic drives
  both legs; only the direction and the safety rules differ.
- **A collector is the unit of configuration** — plug one in, and the app identifies it by
  **hardware serial** and locks to that collector's setup. Nothing to pick from a dropdown,
  and an unrecognised controller is never given another one's settings.
- **See what will happen before it happens** — **Check** fills a side-by-side compare grid:
  this PC on the left, the collector on the right, an arrow per file showing which way it
  moves and why. Both legs share the grid, so one glance covers the whole run. Preview and
  run are built from the same comparison pass, so they cannot disagree.
- **One button, two one-way legs** — *design* mirrors the project's drawings onto the
  collector; *export* pulls its field data into OneDrive. Not a two-way merge.
- **Everyday mode by default** — the window shows the project, which collector is plugged in,
  and **Sync**. Setup (paths, file types, naming, renaming things) sits behind an **Advanced**
  tick-box that starts off and is remembered per machine.
- **One baseline every collector shares, and nothing in the GUI can rewrite it** — the settings
  a collector uses live once under `defaults`. A newly detected collector is seeded from them,
  **Reset to defaults** puts one back on them, and the panel says whether you are looking at the
  baseline or a one-off tweak. Editing a collector changes that collector only; the baseline is
  changed by editing `config.json`, so no amount of clicking turns one person's experiment into
  everyone's default.
- **Projects are separate from collectors** — one active project supplies the design source,
  the export root and the on-device folder; every collector follows it.
- **`S:` maps itself** — the design tree lives in OneDrive, but every path calls it `S:`, which
  is a `subst` that dies with the logon session. The app re-creates it from `driveMap` at
  startup and before any leg that needs it, resolving `%OneDriveCommercial%` and friends so one
  shared `config.json` fits every crew member's profile. A letter that already works is never
  touched, and a letter held by a real disk is never taken over.
- **Mirrors your folder tree** under the destination (subfolders preserved).
- **Total-station scans stay whole** — when a `.jxl` is synced, its companion `<name> Files`
  folder (point cloud, photos, database — any file type, incl. empty subfolders) travels with it.
- **Per-collector separation on pull** — exported files are prefixed with the collector that
  produced them (`TSC5-01_2100-25-346.csv`), so two crews exporting the same filename into one
  shared folder never collide. A per-collector subfolder is available instead.
- **Exports are never destroyed** — a pull never overwrites: a clashing name lands beside the
  original as `name (2).ext`, and prune is refused outright on a pull.
- **Knows one collector from another** — units are identified by **hardware serial** read from
  the USB descriptor, not by the model name they all share, and you can give each a friendly
  name. Two identical models connected at once makes it ask, never guess.
- **Dated path tokens** — `{year}` (`2026`), `{month}` (`8-AUG`), `{julian}` (`26-236`) and
  `{date}` (`2026-08-24`) expand in any path, so `…\BACKUP\{year}\{month}` files each pull into
  the right dated folder on its own. Today's values are shown in the app.
- **Superseded designs stay off the collector** — folder names listed in `excludeFolders`
  (default `SUPERSEDED`) are skipped at any depth, so obsolete drawings never reach the field.
- **Copies only new or changed files** — compares size and modified-time; re-syncs are fast.
- **Live check every run** — it re-reads what's actually on the target each time; it never
  trusts a cached list/manifest.
- **"Out of date" awareness** — a **Check** button says what needs syncing *without copying
  anything*. With the collector connected the answer is exact; with it unplugged the app
  falls back to what the last sync recorded and still tells you whether the design folder
  has moved on since. See below.
- **Additive by default; mirroring on request** — nothing is deleted unless a collector opts
  into **prune** on its design leg, which makes the tool *own* that folder. Never on exports.
- **Per-machine preferences in the registry** — the app folder (and its shared `config.json`)
  can live on OneDrive and run from several PCs/collectors; each machine remembers its own
  last project in `HKCU\Software\SyncDataCollector` instead of churning the shared file.
- **Reliable MTP** — see below.

---

## How MTP works here (and why it's reliable)

Most MTP/WPD automation libraries open the device with `IPortableDevice`, which on some
real collectors (e.g. the Trimble TSC5) **hangs indefinitely** — freezing both the app and
File Explorer. This tool avoids that entirely: it drives MTP through the **Windows Shell
namespace** — the exact mechanism File Explorer uses — plus **`IFileOperation`** for the
actual transfers. Concretely:

- **Navigate / list / create folders / read size+date** via `Shell.Application`.
- **Copy / overwrite / delete** via `IFileOperation` — silent, synchronous (no progress
  dialogs, no "replace?" or "delete?" prompts), and it **coexists with an open Explorer
  window** on the device.
- **Size verification** after each upload; **retries** on transient failures.
- MTP devices report modified-times in **UTC**; the tool accounts for that so unchanged
  files are correctly skipped on re-sync.

All of this uses only built-in Windows components — nothing to download or install.

---

## Requirements

- Windows 10/11 (or a Windows data collector) with **PowerShell 5.1** and
  **.NET Framework 4.x** — both present on a default modern Windows.
- For **MTP** targets: the collector connected over USB, unlocked, and set to
  **File transfer (MTP)** mode. Nothing else to install.

---

## Quick start

1. **Get a config.** Copy `config.example.json` to `config.json`:
   ```powershell
   Copy-Item config.example.json config.json
   ```
   (`config.json` is git-ignored so your real network paths and project names never
   get committed.)
   Then point `driveMap` at your team folder so the app can create `S:` itself, rather than
   everyone keeping a personal "map S drive" `.bat` — see
   [The `S:` drive maps itself](#the-s-drive-maps-itself).
2. **Run it.** Double-click **`SyncDataCollector.cmd`**.
3. **Tick "Advanced"** — steps 4 and 5 are one-time setup, and the panels they describe are
   hidden until you do. Untick it afterwards; day to day nobody needs them.
4. **Set up the project** (once) — the paths every collector shares:
   - **Design source** — where the drawings live, e.g. `S:\02-DESIGN`.
   - **Export root** — where pulled field data is filed. Supports `{year}` `{month}`
     `{julian}` `{date}`, so `…\07-DATALOGGER BACKUP\{year}\{month}` files into
     `2026\8-AUG` on its own.
   - **Project on device** — the project folder on the collector, e.g.
     `Internal shared storage\Trimble Data\Projects\2100 - EXAMPLE SITE`.
5. **Plug in a collector.** It is detected by serial within a few seconds. The first time a
   controller is seen, press **Detect** and give it a short name — this becomes the export
   filename prefix, so pick it before the first export (already-exported files keep the old
   prefix). Its settings are copied from the defaults, so usually there is nothing more to do.
   What they mean:
   - **Design folder** / **Export folder** — subfolders under the project folder on the device.
   - **Design types** — defaults `.csv, .dxf, .xml, .ttm, .rxl`. `.xml` is only synced when it is
     really **LandXML** (root `<LandXML>`), so unrelated project XML is skipped.
   - **Export types** — defaults `.job, .jxl, .csv, .dxf, .rxl, .xml`. Include `.jxl` to pull
     scans with their `<name> Files` folder.
   - **Skip folders** — folder names ignored at any depth, defaults `SUPERSEDED`.
   - **Export naming** — how files from different collectors are kept apart. See below.
   - **Mirror** — whether the design folder is owned by the tool. See below.
6. If you changed anything, press **Save settings** — nothing is written to `config.json` until
   you do. (To change what *every* collector starts from, edit the `defaults` block in
   `config.json`; see below.)
7. Press **Sync this collector**. Both legs run: design down, then exports up.

Press **Check** any time for what both legs *would* do — it writes nothing and deletes nothing.

A rolling `sync-log.txt` is written next to the app for later troubleshooting.

---

## The stick round trip (devices that can't do MTP)

Some devices can't be MTP collectors at all. A Windows tablet is the usual case: MTP is a
*peripheral-side* protocol, and Windows only ships the host half — there is no responder to
turn on, and adding one would mean a USB gadget-mode driver. The answer is not to fight that,
but to let a **USB stick carry everything**, in a four-leg round trip:

| | Runs on | Source → Destination |
|---|---|---|
| 1. design out | office PC | `S:\02-DESIGN` → stick |
| 2. design in | tablet | stick → `C:\Trimble Data\…` |
| 3. exports out | tablet | `C:\Trimble Data\…\Exports` → stick |
| 4. exports in | office PC | stick → `S:\07-DATALOGGER BACKUP\{year}\{month}` |

Legs 1 and 4 are one press of **Sync** against the stick's collector entry on the office PC.
Legs 2 and 3 are one press on the tablet. **On the tablet the stick simply plays the part `S:`
plays in the office** — linework comes off it, field data goes back onto it — and the tablet's
own disk is the collector.

### The stick is a self-contained kit

Nobody sets the tablet up by hand. Every sync to a USB target also writes, to the volume root:

- **the app itself** (`SyncDataCollector.ps1`, `SyncDataCollector.cmd`), so the tablet always
  runs the current version rather than whatever shipped months ago;
- **a generated `config.json`** for the tablet, derived from this PC's project and the stick's
  own settings.

The surveyor plugs the stick in, double-clicks `SyncDataCollector.cmd`, and presses **Sync**.

That generated config is **derived, never a copy of ours**. Its stick-side paths use
`{apphome}`, so the tablet can mount the stick as any drive letter; its collector is the
tablet's local `C:\Trimble Data\…`; and it carries no network paths, no OneDrive, and no
hardware serials. This matters when the surveyor is a third party: nothing about the company's
storage layout travels, and the tablet never signs in to anything. Editing it on the tablet is
pointless — the next sync from the office overwrites it — but the collector's generated id is
preserved across regenerations, so sync-state and the device marker keep matching.

### Telling tablets apart

One stick can serve several tablets, so the thing that has to be identifiable in an export
filename is the **tablet**, not the stick — the stick is the same for everyone. The generated
config therefore names the collector `%COMPUTERNAME%`, which each tablet resolves to itself:
one config file, a distinct export prefix per machine, and nothing to type on a device with no
real keyboard. Exports reach the stick already prefixed, e.g. `T110-A_26-245.jxl`.

The office PC consequently does **not** prefix again on leg 4 — the stick's collector is set to
`exportCollision: "overwrite"` — or every file would read `USB-01_T110-A_26-245.jxl`. Despite
the name, `overwrite` only means "do not disambiguate by device"; a pull still never destroys
field data, landing a genuine clash as `name (2).ext`.

Two limits worth knowing. The prefix is whatever Windows calls the tablet, so a machine named
`DESKTOP-A1B2C3` produces exactly that in your export folder — rename the tablet if the name
should mean something. And because the generated config carries one collector id, tablets
sharing a stick share that id: each tablet keeps its own local marker, but the `sync-state.json`
on the stick records only the most recent tablet, so "last synced" is per-stick, not per-tablet.

---

## Pulling field data off collectors (reverse sync)

Set a profile's **Direction** to `pull`. Now the **collector is the source** and a **USB stick
or cloud-synced folder is the destination** (there's no NAS needed — any filesystem path works,
including a OneDrive/Drive/SharePoint local folder the cloud client syncs up). Two ways to run it:

- **On a PC with the collector on USB** → `Collector type = mtp`; pull straight off the device.
- **On the Windows collector itself** (e.g. a T110) → `Collector type = folder`; pull its local
  export folder to the USB stick. (TBC only exports into a *folder*, not the drive root — point
  the source at that export folder.)

Key pull behaviors:

- **Per-device subfolders** (`collisionMode: deviceSubfolder`, the default) — files land under
  `…\<destination>\<deviceName>\…`. The **Device name** doubles as the folder label, so two
  collectors that both exported `26-203….jxl` stay separate and nothing is lost.
- **`{julian}` in the destination** — e.g. `E:\FieldData\{julian}` files today's pull into
  `E:\FieldData\26-204\<device>\…`, so a whole day's work lands in one dated place.
- **Scans travel whole** — a total-station scan is a `.jxl` **plus** a `<name> Files` folder
  holding the point cloud / photos / scan database. Include `.jxl` in the file types and the
  companion folder is pulled in full (every file, any extension, including nested and empty
  subfolders) automatically.

Example pull profile:
```
Direction:      pull
Collector type: mtp            (or "folder" when running on the collector)
Device name:    TSC5           (also the per-device subfolder label)
Source:         Internal shared storage\Trimble Data\Projects\MyJob\Export
Destination:    E:\FieldData\{julian}
File types:     .job, .jxl, .csv, .dxf, .rxl, .xml
```

---

## Projects and collectors

The unit of configuration is a **collector**, keyed by its hardware serial — or, for a USB
stick, its volume serial. Plug one in and the app locks to that collector's setup — there is no
profile to remember to select, and an unrecognised serial is **refused rather than matched to
something else**, which is what makes adding a fourth controller safe.

Orthogonal to that is the **project**: the design source, the export root, and where the
project lives on the device. One project is active at a time and every collector follows it.
A site may keep the same project for years, but the two axes are genuinely independent, so
they are modelled separately.

A run is **two one-way legs, never a merge**:

| Leg | Direction | Behaviour |
|---|---|---|
| **design** | project design folder → collector | Mirrored: exclusions apply, and prune deletes anything the source does not have. |
| **export** | collector export folder → OneDrive | Additive: never prunes, and **never overwrites**. |

A failing leg does not stop the other — getting field data off a device matters more than
either leg on its own, so the export still runs if the design push fails.

### USB sticks as collectors

A USB stick can be a collector in its own right (`type: "folder"`). Both legs work exactly as
they do for a controller — design pushed onto it, exports pulled off it, same file types, same
skip folders, same export naming — but over plain filesystem copies rather than MTP, which is
considerably faster.

Insert the stick and press **Detect**; it is offered alongside any connected controllers as
`<volume label> [USB D:]`. Name it as you would a controller, since that name still becomes the
export filename prefix.

The stick is keyed on its **volume serial, not its drive letter**. Windows hands removable
media whatever letter happens to be free, so today's `D:` really can be tomorrow's `E:` — and a
mirrored design push aimed at "whatever is on `D:`" is exactly the accident worth engineering
out. Each sync locates the volume by serial and uses wherever it is mounted right now; if that
volume is not present the run is refused outright rather than falling back to a letter. A
**Check** still works with the stick unplugged, answering from the last sync recorded on this
PC, which is the point of that fallback.

Two consequences worth knowing: re-formatting a stick changes its volume serial, so it has to
be added again; and a stick with no volume serial at all is not offered, because there would be
nothing stable to lock onto.

#### The app rides along

Every sync to a USB target also copies **the app itself** to the volume root —
`SyncDataCollector.ps1` and `SyncDataCollector.cmd`, and only when they differ from what is
already there. The stick is how the tool reaches a tablet in the first place, so a stick
carrying current designs alongside a months-old app is a trap: whoever runs it in the field
gets whatever version travelled with it.

The root is the right place for them because `SyncDataCollector.cmd` resolves its own folder
with `%~dp0`, and the app reads `config.json` and writes its log next to itself. So the stick
ends up self-contained: app at the root, data under `Trimble Data\`, double-click and go.

`config.json` is **deliberately not copied**. It holds this site's network paths and collector
serials, and a tablet needs its own anyway — its design source is the stick, not `S:`. Copying
ours would both hand out the site layout and point the tablet at drives it cannot reach.

This applies to USB targets only. MTP controllers do not run this app, so nothing is copied to
them. A **Check** reports what would be updated without writing, and a stick that is full or
write-protected logs a warning rather than failing the run — design files matter more.

### Everyday mode, and the Advanced tick-box

Almost every run is the same three facts: which project, which collector is plugged in, and
*go*. That is all the window shows by default — nobody renaming a device or retyping a network
path is doing the normal thing, and settings that are visible are settings that get changed by
accident.

**Advanced** reveals the rest: project New/Rename/Delete and Save, the collector Rename button,
the project paths, and the per-collector settings. It starts off, and each machine remembers
its own choice in the registry alongside `LastProject`. **Detect** stays visible in both modes,
because "which controller is this?" is an everyday question and an unrecognised serial has to
be set up from somewhere.

Nothing is hidden from a sync: the collapsed window runs exactly the same two legs with exactly
the same settings.

### Defaults

Every collector is set up the same way in practice, so the settings live once in `config.json`
under `defaults` rather than being retyped per unit:

- A newly detected collector is **seeded from the defaults**, so setting up a fourth controller
  is a name and nothing else.
- **Reset to defaults** puts a collector back on the baseline, dropping anything set just for
  it. It shows what it is about to apply and asks first, and touches that collector only —
  not the other collectors, not the project paths, and not the defaults.
- The panel says which of the two you are looking at — *Matches the defaults* or *Customised —
  differs from defaults* — updated as you type, so a one-off tweak made months ago stays
  visible instead of quietly becoming the house style.

**There is deliberately no button that writes the baseline.** The GUI can edit one collector;
it cannot make those edits everyone's default. Changing the baseline means opening `config.json`
and editing the `defaults` block — a small speed bump that is the whole point, because the
person tweaking a setting to get one controller working is rarely the person deciding site
policy. Note the limit of that: `config.json` is a plain file, usually on a shared drive, so
this stops an accidental click, not someone determined with Notepad. If you need it genuinely
locked down, put the app folder somewhere users have read-only NTFS rights.

Changing the defaults does **not** disturb collectors already set up — they keep what they
have, and adopt the new baseline when you press Reset on them.

Project paths are per-project by nature and are deliberately **not** part of the defaults.

If `config.json` has no `defaults` block, the built-in values are used and written on the next
save. A partial block is fine — stated keys win, the rest fall back — and a stated empty list
(`"excludeFolders": []`) is honoured as a real choice rather than refilled.

### Keeping exports from different collectors apart

Every collector exports into the *same* dated folder, so files must say where they came from.
**Export naming** controls how:

| Mode | Result |
|---|---|
| `prefix` (default) | `TSC5-01_2100-25-346.csv` — one flat month folder, provenance in the name. |
| `deviceSubfolder` | `TSC5-01\2100-25-346.csv` — a folder per collector. |
| `overwrite` | No separation. Only sensible with a single collector. |

`prefix` prefixes the **first path segment**, not the filename — for a flat export folder those
are the same thing.

> **`prefix` is not safe for scans.** A `.jxl` records its companion folder name **explicitly
> inside the file** — e.g. `2100-25-CONTROL Files/AR-01.JPG`. Renaming that folder to
> `TSC5-02_2100-25-CONTROL Files` breaks the link: the point cloud and photos are on disk, but
> the job can no longer find them, and nothing about the copy looks wrong. Prefixing the `.jxl`
> itself is harmless, since the stored path is relative to whatever folder the `.jxl` sits in —
> it is the **folder** that must keep its name.
>
> Use `deviceSubfolder` on any collector that exports scans. It separates crews by folder and
> leaves every name untouched, which is why it is the default. A run that combines `prefix`
> with `.jxl` in the export types logs a warning.

There is a second, independent limit: a companion folder is matched **by name**, as
`<jxl basename> Files`. A `.jxl` that references a folder named after something else — an
aggregate "dumpall" export is the usual case — will not have that folder pulled, because
nothing pairs them. The media simply does not travel, silently.

### Exports are never destroyed

Field data cannot be re-collected, so a pull will not overwrite. If a name is taken by a
*different* file, the new one lands beside it as `name (2).ext`. Re-running does not spawn
`(3)`, `(4)`, … — the next pull recognises its own earlier copy and skips. Prune is refused
outright on a pull, and logs the refusal.

---

## Keeping superseded designs off the collector

Design folders usually keep a `SUPERSEDED` subfolder of drawings that have been replaced.
Those must not reach a collector — staking out from an obsolete design is exactly the
mistake this prevents.

**Skip folders** (`excludeFolders`) is a list of folder *names*, matched **at any depth**
and **case-insensitively**, so one entry covers every copy of it in the tree:

```
Skip folders:  SUPERSEDED
```

```
S:\02-DESIGN\9.0 TOWER CRANE\SUPERSEDED\TC-1.dxf          <- skipped
S:\02-DESIGN\5.0 BRIDGE\MCB\superseded\26-111 MCB FDN.dxf <- skipped (case ignored)
S:\02-DESIGN\9.0 TOWER CRANE\2100 - TC PLATES.dxf         <- synced
```

Names may contain spaces (`OLD DRAWINGS`), so the list splits on **commas/semicolons only**,
never on whitespace. An empty list excludes nothing. Exclusions beat everything else,
including `.jxl` companion folders. Each run logs which folders are excluded and how many
files that skipped, so it is never silent:

```
Excluding folder(s): SUPERSEDED
Found 151 matching file(s) (excluded 10 in excluded folder(s)).
```

> **Upgrading:** a profile saved before this feature existed has no `excludeFolders` field.
> That's read as "never chose" and defaults to `SUPERSEDED` rather than inheriting the old
> behaviour — the safe default matters more here than strict backwards compatibility. Set it
> to `[]` if you really do want superseded files pushed.

On its own, an exclusion only stops *future* syncs from copying those files — anything already
on a collector stays there. Turn on **prune** below to have the tool clear it out.

---

## Mirror mode: letting the tool own the destination folder

By default nothing at the destination is ever deleted. Tick **Mirror: DELETE files at the
destination that are not in the source** (`prune`) and the destination becomes an exact mirror
of the filtered source: after the copy pass, anything the source does not account for is
removed, and folders left empty go with it.

This is the one irreversible thing the tool does, so:

- **Off by default**, per profile, and never enabled by an upgrade.
- **Push only.** On a pull the destination accumulates field data from several collectors and
  earlier days that no source can account for — pruning it would destroy exactly the work you
  just collected. A pull profile with `prune` set logs a warning and ignores it.
- **The marker is never pruned.** Deleting it would strip the collector of its identity.
- **Excluded folders count as "not claimed"**, so `excludeFolders` + `prune` together is what
  actually clears superseded designs off a collector that already has them.
- **Check previews it** — press **Check** and the exact delete list is printed, with nothing
  removed:
  ```
  Up to date - 151 file(s) checked on TSC5 [6a03f199], none out of date.
  10 extra file(s) on the device would be DELETED by a sync.
  ```
- **Every deletion is logged by name** to `sync-log.txt`, and the run banner warns up front:
  ```
  Prune ON - files at the destination that the source does not account for will be DELETED.
  DELETED        9.0 TOWER CRANE\SUPERSEDED\TC-1.dxf
  DELETED FOLDER 9.0 TOWER CRANE\SUPERSEDED
  ----- Done. Copied 0, deleted 10, skipped 151, failed 0 (of 151). -----
  ```

There is deliberately **no extra confirmation dialog** on each sync: the option is opt-in, red
in the UI, off by default, and previewable with **Check**. A prompt on every run would train
you to click through it.

---

## Knowing when a collector is out of date

The question "has anyone changed the design files since I last loaded collector X?" gets
asked with the collector on the bench *and* with it out in the field, so **Check** answers
it both ways. It never writes anything — not a file, not a folder, not a marker.

**Collector connected** → the exact answer. Check runs the same comparison a sync runs
(size, then modified-time) against what is really on the device, and lists what differs:

```
OUT OF DATE (source newer)  GENERAL ARRANGEMENT\260109-RSSSC-LINEWORK.dxf
OUT OF DATE (new)           UTILITIES\260319TEST_.xml
----- NEEDS SYNC - 2 of 159 file(s) out of date on TSC5. -----
```

**Collector not connected** → the useful answer. The app scans the source once and scores
**every collector it has ever synced under that profile**, so it names which units are behind:

```
  TSC5 [6a03f199] - NEEDS SYNC (last sync 2026-08-24 13:07 : 3 changed)
  TSC5 [a41b0e77] - up to date as of 2026-08-24 13:09
----- NEEDS SYNC - 1 of 2 tracked collector(s) behind:
      TSC5 [6a03f199] (last sync 2026-08-24 13:07: 3 changed). -----
```

This is a strong hint, not a guarantee — it describes the *source*, and can't know whether
someone deleted files on the collector in the meantime. It says "Probably up to date …
Connect it to be sure" rather than claiming certainty. Changes made within ~2 seconds of a
sync fall inside the timestamp tolerance and aren't flagged.

The collector banner at the top of the window shows the same thing at a glance the moment a
controller is plugged in (`TSC5-02 (JAJ000000002) - last synced 2026-08-24 14:35`), read from
the local record, so it appears instantly — no scanning.

### The compare view

Check and Sync both fill the **Compare** tab: one row per file, this PC on the left, the
collector on the right, and the arrow between them showing which way it is about to move.
Folder and filename are separate columns, because a truncated cell loses its tail and the
tail of a path is the filename -- split, and the clipping lands on the folder instead.

```
This PC                                              TSC5-01 (JAJ000000001)
Folder          File            Size   Modified        Folder      File          What happens
  Design  PC -> collector (mirrored)    S:\02-DESIGN  ->  \2100 - EXAMPLE SITE\02-Design
Hoist House(HH) 26-243 HH.dxf   240 KB 08-31 17:22 ->                            Copy (new)
6.0 UTILITIES   Pull Boxes.dxf   85 KB 08-31 17:22 ->  6.0 UTIL..  Pull Boxes    Copy (source newer)
5.0 BRIDGE...   Boundary.dxf    1.4 MB 08-31 17:22  =  5.0 BRI..   Boundary.dxf  In sync
                                                    X  Hoist Ho..  26-111 HH.dxf Delete from collector
  Export  collector -> OneDrive (additive)    ...\07-DATALOGGER BACKUP\2026\08  <-  \...\Exports
                                                   <-  Exports     2100-25-346   Copy (new)
```

Both legs share the one grid, grouped by leg, because they run in opposite directions:
design files travel out to the collector (`->`) and field data comes back (`<-`). An empty
cell means the file is not on that side yet, which is what makes "new here, missing there"
readable without reading a word of it.

The export rows repay a second look. The collector holds `2100-25-346.csv`, but it lands on
the PC as `TSC5-01_2100-25-346.csv`. Each side is shown under the name it actually has, so
[collision naming](#keeping-exports-from-different-collectors-apart) is something you can
see rather than something you work out afterwards.

Files already in sync are hidden by default -- tick **Show files already in sync** to see
them. The summary line under the grid counts them either way.

**Rows tick over as the sync reaches them.** A file that has been written turns green with a
check mark and reads `Copied`; a pruned one reads `Deleted`; a failure turns red and carries
the reason. On a 150-file push over MTP that is the difference between watching progress and
watching nothing. Run Check first and Sync ticks off the rows already on screen rather than
building a second list underneath them.

The grid is a report, not a picker: **Sync this collector** always runs the whole plan. What
it does guarantee is that the preview and the run agree, because both are built from the
same comparison pass rather than from two passes that could drift apart.

The **Log** tab keeps the full commentary -- every `COPIED`, `DELETED` and `FAILED` line with
its reason -- and still writes to `sync-log.txt` next to the app.

### Several collectors, one device name

MTP reports a **model** name, so every TSC5 in the yard shows up as `TSC5`. The name alone
cannot tell two units apart — which matters the moment you own more than one.

**The hardware serial does.** Windows puts the USB device descriptor in the Shell path the
tool already walks, and the serial is right there:

```
::{20D04FE0-...}\\\?\usb#vid_099e&pid_0261#jaj000000001#{6ac27878-...}
                                           ^^^^^^^^^^^^  -> JAJ000000001
```

No WMI, no extra dependency, still pure Shell. The serial beats a generated id on every count:
it identifies a unit **before it has ever been synced**, it **survives the device being wiped**,
and it matches the sticker on the machine.

Records are kept **per profile per serial**, so one profile drives a whole fleet and every
collector carries its own last-sync record.

**Naming your units.** `TSC5 (JAJ000000001)` is unambiguous but not memorable, so give each
serial a friendly name — press **Detect…** and it offers to name any unit it doesn't know:

```json
"devices": { "JAJ000000001": "Crew A", "JAJ000000002": "TSC5-02" }
```

That lives in `config.json` (shared), so every machine calls the same collector the same thing,
and it shows up everywhere: `Crew A (JAJ000000001)`.

**Two of the same model connected at once.** The tool resolves the device *item* it was given
rather than looking one up by name, so it can never drift onto the wrong unit mid-sync. If two
collectors share the profile's name, it **stops and asks which** — it will not guess:

```
More than one 'TSC5' is connected (JAJ000000001, JAJ000000002).
Disconnect all but one, or choose which to use.
```

**Upgrading.** A collector already carrying a GUID-based marker is promoted to its serial on
the next sync, and the stale record is retired so one unit never appears twice:

```
Device identity upgraded to hardware serial JAJ000000001 (was 6a03f199-36e3-49eb-94db-7a1273d4da8e).
```

**Where there is no serial:** a `folder` target (a USB stick) has none, so the marker keeps a
generated GUID there, shown truncated (`STICK (ee3d7fa8)`). On **pull** the marker lives on the
USB/cloud destination rather than on the collector — the tool never writes to a collector it is
pulling field data from — so pull profiles still identify by name.

### What gets written, and where

| File | Where | Purpose |
|---|---|---|
| `_SyncDataCollector.json` | destination root, i.e. **on the collector / USB stick** | Identity marker: a stable `deviceId` plus a note of the last sync written to it. |
| `sync-state.json` | next to the app (git-ignored) | What *this install* last synced, **one record per profile per collector**: when, file counts, newest source timestamp. |

The `deviceId` is a GUID generated once and then preserved across syncs, so a USB stick is
still recognisable after Windows gives it a different drive letter. The marker is **never
itself synced** — copying it onward would hand a second device the same identity — so it is
skipped even if you add `.json` to a profile's file types.

Both records are best-effort: if the marker can't be written (a read-only or full device),
the sync still succeeds and logs a warning, and offline checks fall back to the local record.
A cancelled sync deliberately leaves the previous records alone, since it doesn't describe
what's on the target.

---

## The `S:` drive maps itself

Every path in `config.json` calls the team folder `S:`. That letter is not a real disk — it is a
`subst` onto the OneDrive-synced team folder, which is exactly what keeps the shared config free
of anybody's `C:\Users\<name>\…`. But a `subst` lives and dies with the **logon session**: after
a reboot `S:` is simply gone, every run fails with `Source folder not found: 'S:\02-DESIGN'`, and
somebody has to remember to double-click a per-user `.bat` first.

So the app maps it itself, from `driveMap`:

```json
"driveMap": [
  {
    "letter": "S",
    "targets": [
      "%OneDriveCommercial%\\Teams - Surveying",
      "%USERPROFILE%\\OneDrive - Company\\Teams - Surveying"
    ]
  }
]
```

- **Targets are tried in order and `%ENVVAR%` is expanded**, so one entry covers the whole crew:
  `%OneDriveCommercial%` is *that* user's OneDrive root on *that* machine. If none of them exist,
  the app looks for the same folder **name** under every OneDrive root in the profile — which
  covers a tenant folder spelled differently on somebody's PC.
- It runs **at startup**, and again **before any leg** whose path needs the letter, so a drive
  that disappears mid-session is back by the next **Sync**.

What it will not do:

- **touch a letter that already resolves**, whatever it points at — map `S:` somewhere on
  purpose and it stays mapped there;
- **take over a letter held by a real disk or a network drive**, even one that is not ready;
- **guess** — if no target folder exists it says so in the log and maps nothing.

Only a *stale* `subst` — still mapped, but its folder is gone — is dropped, and only to re-point
it at a folder that does exist.

One wrinkle worth knowing: `subst` is per logon session **and per elevation level**. A drive
mapped by a normal process is invisible to an elevated one and vice versa, which is why every run
re-checks the letter instead of assuming an earlier run set it up (and why mapping `S:` from an
admin prompt will not help this app). Paths in `config.json` expand `%ENVVAR%` too, so an export
root can be written `%OneDriveCommercial%\…` where a drive letter is not wanted at all.

---

## Configuration reference

`config.json` (see `config.example.json`):

| Field | Meaning |
|---|---|
| `activeProject` | Which project is currently selected. |
| `projects[].name` | Display name in the dropdown. |
| `projects[].designSource` | Where the drawings live on the PC, e.g. `S:\02-DESIGN`. Supports the same tokens as `exportRoot`. |
| `projects[].exportRoot` | Where pulled field data is filed. Supports `{year}` `{month}` `{julian}` `{date}` `{apphome}`, and `%ENVVAR%`. `{apphome}` is the folder the app is running from — use it when the app runs off a USB stick, so no drive letter is baked in. |
| `projects[].deviceProjectPath` | The project folder **on the collector**. For MTP the first segment is the device storage. For a `"folder"` collector that first segment is replaced by wherever the volume is currently mounted, so one project path serves both kinds. |
| `driveMap[].letter` | A drive letter the app creates with `subst` when it is missing, e.g. `S`. Leave `driveMap` out entirely and it never maps anything. |
| `driveMap[].targets` | Folders that letter may point at, **best first**. `%ENVVAR%` is expanded — prefer `%OneDriveCommercial%\…` to `C:\Users\<name>\…`, or the config only works for whoever wrote it. |
| `defaults.*` | The baseline new collectors are seeded from, and what **Reset to defaults** applies. Same seven fields as `collectors[]` below, minus the identity ones (`serial`, `name`, `model`, `type`). **Edit here only** — the GUI never writes this. Omit it and the built-in values are used; a partial block falls back key by key. |
| `collectors[].serial` | Hardware serial — the key. Read from the USB descriptor; never guessed. For a `"folder"` USB target it is `VOL-<volume serial>` (e.g. `VOL-00000000`), read from the volume itself. |
| `collectors[].name` | Short name you assign. **Becomes the export filename prefix**, so settle it before the first export. |
| `collectors[].model` | MTP model name as shown under "This PC" (e.g. `TSC5`). Several units share this, which is why `serial` is the key. For a USB target it is the volume label. |
| `collectors[].type` | `"mtp"` (over USB), or `"folder"` for a plain filesystem target — a USB stick, or a Windows tablet running this app locally. |
| `collectors[].designSubPath` | Design subfolder under `deviceProjectPath`, e.g. `02-Design`. |
| `collectors[].exportSubPath` | Export subfolder under `deviceProjectPath`, e.g. `Exports`. |
| `collectors[].designExtensions` | Types pushed. `.xml` is content-checked and only sent when it is LandXML. |
| `collectors[].exportExtensions` | Types pulled. Include `.jxl` to bring scans with their `<name> Files` folder. |
| `collectors[].excludeFolders` | Folder **names** skipped at any depth, case-insensitive. Defaults `[ "SUPERSEDED" ]`; `[]` excludes nothing. |
| `collectors[].prune` | Design leg only. `true` makes the collector's design folder an exact mirror, deleting what the source lacks. Defaults `true`. |
| `collectors[].exportCollision` | `"prefix"` (default), `"deviceSubfolder"`, or `"overwrite"`. |
| `mtp.retries` | Extra attempts per file after the first (default 2). |
| `mtp.verifyAfterUpload` | Re-read the on-device size and confirm it matches (default true). |

Values under `collectors[]` **override** `defaults` for that collector; they are written out in
full rather than left blank, so the file always says exactly what a given unit will do.

Per-machine settings (not in `config.json`) live in `HKCU\Software\SyncDataCollector` —
`LastProject` and `Advanced`, so a shared copy on OneDrive doesn't fight over either.

> **Upgrading from the old profile-based config:** on first load, `profiles` are read once to
> derive a project (design source, on-device project folder, export root) and the file gains
> `projects` / `collectors`. The old `profiles` array is **left in place, ignored** — delete it
> by hand once you're happy. Collectors are not invented: plug each one in and press **Detect**.

---

## Troubleshooting

- **"MTP device not found"** — connect the collector, unlock it, and set the USB mode to
  **File transfer (MTP)**. Then click **Detect…**; the name may differ from what you typed.
  (It's fine if the device is also open in a File Explorer window — the tool coexists with it.)
- **Nothing happens when I double-click the .cmd / "running scripts is disabled"** — the
  launcher already passes `-ExecutionPolicy Bypass`. On a locked-down device (AppLocker /
  AllSigned), IT may need to allow the script's location or sign it.
- **"Source folder not found: `S:\02-DESIGN`"** — `S:` is not mapped and the app could not map
  it either. The log line above says why: no `driveMap` entry for `S`, none of its `targets`
  exist on this machine (has OneDrive finished setting this profile up?), or the letter is held
  by something else. Stopgap, in a **normal** (non-admin) prompt — an admin one maps a drive
  this app cannot see: `subst S: "%OneDriveCommercial%\Teams - …"`.
- **The device briefly disappears from "This PC"** — MTP devices occasionally drop off for a
  moment; just run **Sync now** again.
- **Cloud-backed source (OneDrive/SharePoint "Files On-Demand")** — the first sync may be
  slow while files hydrate from the cloud; this is transparent.

---

## Roadmap

- **Scheduling / watch-folder** — auto-sync on a timer or when the source changes.
- **Killable background worker** — run the transfer in a separate process the GUI can hard-kill,
  for a mid-file cancel/timeout on flaky MTP.

---

## License

Released under the **MIT License** — see [LICENSE](LICENSE). Uses only built-in Windows
APIs (Shell namespace + `IFileOperation`); no bundled third-party binaries.
