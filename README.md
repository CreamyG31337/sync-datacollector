# Sync DataCollector

A lightweight Windows GUI for **one-way file sync from a PC to survey data collectors** —
push your design files (`.csv`, `.dxf`, LandXML `.xml`, Trimble `.ttm` surfaces, …) onto a
field data collector before you head out.

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

- **Named profiles** — one install drives several jobs (a collector over MTP, staging to
  a USB stick, pulling from USB on the collector). Pick a profile, press **Sync now**.
- **Mirrors your folder tree** under the destination (subfolders preserved).
- **Copies only new or changed files** — compares size and modified-time; re-syncs are fast.
- **Live check every run** — it re-reads what's actually on the target each time; it never
  trusts a cached list/manifest.
- **One-way and additive** — never deletes anything on the collector.
- **Configurable** source, target, device name, and file types per profile.
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
2. **Run it.** Double-click **`SyncDataCollector.cmd`**.
3. In the GUI, pick or edit a **profile**:
   - **Source folder** — where your design files live (Browse…).
   - **Target type** — `folder` (USB / local path) or `mtp` (device over USB).
   - **Device name** (mtp only) — click **Detect…** to list connected MTP devices and pick yours.
   - **Destination** — the folder to create/fill on the target. For `mtp`, the first
     segment is the device storage, e.g. `Internal shared storage\Projects\MyJob\Design`.
   - **File types** — comma-separated, defaults to `.csv, .dxf, .xml, .ttm`. `.xml`
     files are only synced if they are actually **LandXML** (root `<LandXML>`), so
     unrelated project/config XML is skipped automatically.
4. Click **Save** to persist the profile, then **Sync now**. Watch the log; the status line
   shows `Copied N, skipped M, failed K`.

A rolling `sync-log.txt` is written next to the app for later troubleshooting.

---

## The two-leg USB workflow (collectors that can't connect to the PC)

When IT policy stops the collector from talking to the PC directly, sync in two hops using
the **same app** with two profiles:

**Leg A — on the office PC** (`folder` target → the USB stick):
```
Source:      S:\Design\...            (your network design folder)
Target type: folder
Destination: E:\...\Design            (the USB stick's drive letter)
```

**Leg B — on the collector** (`folder` target → the collector's internal disk):
```
Source:      E:\...\Design            (the USB stick)
Target type: folder
Destination: C:\...\Design            (a folder on the collector)
```

Copy this whole app folder onto the USB stick (or install it on the collector) so the same
tool runs on both ends.

---

## Configuration reference

`config.json` (see `config.example.json`):

| Field | Meaning |
|---|---|
| `lastProfile` | Profile selected on launch. |
| `profiles[].name` | Display name in the dropdown. |
| `profiles[].sourcePath` | Folder to copy **from** (always a normal path). |
| `profiles[].targetType` | `"folder"` or `"mtp"`. |
| `profiles[].deviceName` | MTP device name as shown under "This PC" (mtp only). Use **Detect…** if unsure. |
| `profiles[].destinationPath` | Target folder. For `mtp`, first segment is the device storage, e.g. `Internal shared storage\Projects\...\Design`. |
| `profiles[].extensions` | File types to sync, e.g. `[".csv", ".dxf", ".xml", ".ttm"]`. `.xml` is content-checked and only synced when it is LandXML. |
| `mtp.retries` | Extra attempts per file after the first (default 2). |
| `mtp.verifyAfterUpload` | Re-read the on-device size and confirm it matches (default true). |

---

## Troubleshooting

- **"MTP device not found"** — connect the collector, unlock it, and set the USB mode to
  **File transfer (MTP)**. Then click **Detect…**; the name may differ from what you typed.
  (It's fine if the device is also open in a File Explorer window — the tool coexists with it.)
- **Nothing happens when I double-click the .cmd / "running scripts is disabled"** — the
  launcher already passes `-ExecutionPolicy Bypass`. On a locked-down device (AppLocker /
  AllSigned), IT may need to allow the script's location or sign it.
- **The device briefly disappears from "This PC"** — MTP devices occasionally drop off for a
  moment; just run **Sync now** again.
- **Cloud-backed source (OneDrive/SharePoint "Files On-Demand")** — the first sync may be
  slow while files hydrate from the cloud; this is transparent.

---

## Roadmap

- **"Out of date" awareness** — track which design files have changed since the last sync
  to a given collector and warn *"collector X needs a re-sync"*. Requires a small
  identity marker on each collector so the app knows which device it's looking at.
- **Reverse sync (field data → network)** — pull collected data off collectors back to the
  network. Same engine, opposite direction. Needs **filename-collision handling** (two
  crews can export the same filename with different contents): options are per-device
  target subfolders, filename prefixing by device, or auto-rename on collision.
- **Mirror/prune option** — optionally delete target files that no longer exist in the source.
- **Scheduling / watch-folder** — auto-sync on a timer or when the source changes.
- **More file types / per-profile filters** beyond `.csv` / `.dxf`.

---

## License

Released under the **MIT License** — see [LICENSE](LICENSE). Uses only built-in Windows
APIs (Shell namespace + `IFileOperation`); no bundled third-party binaries.
