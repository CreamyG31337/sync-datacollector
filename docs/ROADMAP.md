# Roadmap

Open work, most important first. Written 2026-10-09.

---

## 0. Before anything else

- [ ] **Commit the work from 2026-10-09.** It is in the working tree, not committed:
  - `.ttm` surfaces pulled back via a `Surfaces` route (`from: root`).
  - Root routes read only the project folder's own files, not its subfolders.
  - Compare-view and log labels name the real sides (`USB stick` / `This tablet` / `This PC` /
    `Collector`), via `Get-SideNames`.
  - Duplicate detection inside scan folders matches on the path from `<name> Files\` down
    (`Test-AlreadyFiled` `$Tail`), so a new scan keeps its `trwlayer.lay` / `Database.dmt` /
    `trwdb.db1`.
- [ ] **Look at the new labels in the real app**, on this PC with the stick plugged in, and on
  the tablet. They were only checked outside the GUI.
- [ ] **Run the first tablet round trip** (see "The round trip this week" below).

---

## 1. Stick as courier, not archive

### The problem

Nothing ever removes anything from the stick, so it grows without limit. A scan is
30–620 MB (the six on S: average ~300 MB). Today the stick has 100 GB free of 116 GB, so this
is months away, not days, but it is unbounded.

Deleting from the stick by hand does **not** fix it. The tablet decides what to send by
comparing itself against the stick (`Invoke-Sync`, tablet leg), so anything missing from the
stick gets sent again on the next tablet sync: the whole backlog, every time the stick is
cleared.

### The design

The stick holds only what is in transit. Two halves:

**Office side (stick → S:), in `Invoke-CollectorSync` for a volume collector:**

1. After a pull leg, take every stick file that is now **confirmed on S:**. That means one of:
   - copied this run and verified (size matches after copy), or
   - skipped because it is already there: `already pulled`, or `already filed at …` from
     `Test-AlreadyFiled`.
2. Append each one to a **delivered ledger** on the stick (format below).
3. Then delete those files from the stick (`Target-DeleteFile`), along with any scan folders
   that end up empty.

**Tablet side (tablet → stick), in the tablet's pull legs:**

4. Before copying, read the ledger. Skip any file whose `tablet + path + size + mtime`
   matches a ledger entry, and report it as `already delivered to the office`.
5. A file that changed since delivery (different size or mtime) is sent again. This is what a
   `.job` the crew keeps working in needs, and the office's superseding `.job` route handles
   it as now.

### Ledger

- File: `<stick root>\delivered.json`, next to `config.json` / `sync-state.json`.
- One entry per delivered file:
  `{ tablet, route, rel, length, mtimeUtc, deliveredUtc, filedAt }`
  - `tablet`: the collector label the tablet used (`%COMPUTERNAME%`, e.g. `DESKTOP-MENK28V`),
    because several tablets can share one stick.
  - `rel`: the path **as it sits on the tablet**, relative to that route's source. That is
    what the tablet compares against. It is not the stick path: the stick path carries the
    tablet prefix or subfolder.
  - `filedAt`: where it went on S:. For people reading the file; the tablet doesn't use it.
- Written atomically: temp file + rename, as `Copy-FileFolder` already does for folder
  targets. A half-written ledger must never be read as "nothing delivered" while the stick is
  already emptied.

### Rules that must hold

- **Delete from the stick only after S: has the file.** Never on a check, never on a failed
  or cancelled leg, never for a file whose copy failed.
- **The ledger is written before the stick files are deleted.** If the run dies in between,
  the worst case is a file still on the stick that is also in the ledger. The next office
  sync finds it already on S: and removes it. The reverse order could lose track of a file.
- **An unreadable or corrupt ledger means "send everything".** That fails toward too many
  copies, never too few.
- **Nothing is deleted from the tablet.** Clearing the tablet is section 2.
- **Check shows the plan.** The compare view lists stick removals the way it lists mirror
  deletions today (`WOULD DELETE`), labelled so it is obvious they are delivered files, e.g.
  `delivered - remove from stick`.
- Applies only to a **volume (USB stick) collector**. MTP controllers are unaffected: their
  pulls stay additive and never delete.

### Where the code goes

| Piece | Where |
|---|---|
| Collect "confirmed on S:" rows per leg | `Invoke-Sync` result: rows with action COPIED (verified), or reason `already pulled` / `already filed at …` |
| Ledger read/write | new functions near `Read-DeviceMarker` / `Update-SyncRecords` |
| Delete delivered files from the stick | `Invoke-CollectorSync`, after the export legs, volume collector only, not on `-CheckOnly` |
| Tablet skips delivered files | `Invoke-Sync` record loop, before the `new` / `size changed` decision; gated on a profile flag set in `New-LegProfile` when the destination is the stick |
| Tablet needs the ledger path | `New-TabletConfig` / `New-TabletExportRoutes`: `{apphome}\delivered.json` |
| Compare view rows | `Show-ComparePlan` |
| Docs | README: "The stick round trip" and "Field data on the tablet" |

### Tests to run

- Fake stick in `%TEMP%` (keep paths short: the 260-character limit bit on 2026-10-09).
  Real S: data can't be copied because OneDrive files are online-only; create stand-ins of the
  exact size with `[IO.File]::Create` + `SetLength`.
- Office leg: a file already on S: is added to the ledger and removed from the stick; a new
  file is copied, added, removed; a failed copy stays on the stick and is not in the ledger.
- Tablet leg: a ledger entry suppresses the copy; a changed `.job` (different size) is still
  sent; a deleted or corrupt ledger sends everything.
- Two tablet names on one stick: entries don't cross over.
- Cancel halfway through the office leg: nothing is deleted that isn't in the ledger.

---

## 2. Tidy scans off the tablet

The tablet keeps every scan forever, so its disk fills even once the stick doesn't. Model it
on **Tidy jobs** (`Get-JobCleanupPlan`, README "Tidying old jobs off the collector"): a button
you press on purpose, never part of Sync.

- [ ] A scan (`.jxl` + its `<name> Files` folder, as one unit) is removable only when **all**
  of these hold:
  - it is older than the retention window (`jobRetentionDays` or a separate setting),
  - it has a date in its name,
  - the delivered ledger shows it reached S: with the same size.
- [ ] Shows the list first, with the reason each one is kept or removed.
- [ ] Depends on section 1 (the ledger is the tablet's only evidence that S: has the file; the
  tablet cannot see S:).

---

## 3. Smaller items

- [ ] **`.ttm` exported into `Exports`** is not picked up: the `Surfaces` route reads only the
  project folder itself. If crews export surfaces, add `.ttm` to an `export` route.
- [ ] **Scans missing from S:**: 26-260-JEJ-TS-WEST HH ABUT SCAN and
  26-261-JEJ-TS-HH WEST ABUT SCAN exist on the tablet but nowhere on S:. They should arrive with
  the first round trip; confirm they do.
- [ ] **New tablet files land in a per-tablet subfolder** on S:
  (`05-QC SURVEY DATA\2026\09-SEP\FDC\DESKTOP-MENK28V\…`), because the stick keeps them under
  `Exports\<tablet>\`. Decide whether that's wanted, or whether the QC route should flatten
  that folder away. Flattening a scan is safe as long as the `.jxl` and its `<name> Files`
  folder move together.
- [ ] **Rename the tablet.** Its Windows name, `DESKTOP-MENK28V`, is what appears on S:.

---

## The round trip this week (before section 1 exists)

1. On this PC, with the stick plugged in, **Sync USB-01**. This puts the current app and the
   tablet config on the stick.
2. On the tablet, press **Sync** (not Check). The first run copies the tablet's whole
   backlog to the stick (~2–3 GB, mostly scan photos), so it is slow. It copies; nothing is
   removed from the tablet.
3. Back on this PC, press **Check** for USB-01 first. Expect the scans already on S: (26-203,
   26-246, 26-247, 26-253, 26-255, 26-274) to show `already filed at …`. Anything showing
   `new` that you know is on S: has a different size there, probably re-exported. Look before
   syncing.
4. Sync. From now on the stick keeps this backlog; that's expected until section 1 is built.
