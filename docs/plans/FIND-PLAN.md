# PLAN — FIND.O88, a flat view of a volume

**Status: a plan, nothing built.** Written 2026-10-31.

**It stores nothing.** No index, no cache, no settings, no window geometry —
not one byte on any disk. That is the main decision and §3 is the arithmetic
behind it. The "find database" this started as does not exist and should not.

## 1. What Find is for

SPEC.md §30.7.5 records that the LaunchPad's Find button has nothing behind
it: §27.10 is Note Pad's Find and Replace, §81.71 is SHEET's, and §54.4.2's
volume sweep finds a PROGRAM for the loader and is not user-facing. This plan
is that missing feature.

**It is a flattener, not a search engine**, and the measurement says why.
Counted 2026-10-31 on the images this tree builds:

| volume | files | folders | depth |
|---|---:|---:|---:|
| 360KB system floppy | 39 | 7 | 4 |
| 1.44MB apps floppy | 65 | 9 | 4 |
| 1.5GB CF partition | 174 | 22 | 3 |
| **live USB — the largest volume this OS has** | **482** | **41** | 4 |

Nothing here is a big disk. The problem is that 482 files are spread over 41
folders and **the Disk window shows one folder at a time, by design** (§19).
So the jobs are:

1. *"Which folder is `SALES.SLK` in?"* — a name fragment across a volume.
2. *"Every `.SLK` on this disk"* — an extension filter. Nothing gives this.
3. *"What is actually on this disk?"* — a flat list of a volume, which no
   window in the system can show.
4. **The LaunchPad's Find button** — locate a program and launch it.
5. Across volumes: four CF partitions plus two floppies is six places.

**Not** content search — hopeless on an 8088 — and **not** for a floppy-only
XT, where 39 files in 7 folders are already visible by scrolling. That is
what decides where it ships (§6).

## 2. The one fact that makes it cheap

**`OSAPI_FILE_GOTO_Q` (`0x029E`) costs nothing inside a volume.** Its own
words: *"Inside the volume you are already on it is a WORD — no I/O at all —
and crossing to another one keeps the BPB and the FAT window and skips the
directory scan, the sort and the icon harvest."*

The expensive slot is plain `OSAPI_FILE_GOTO` (`0x01C7`), a REMOUNT that
scans, sorts and harvests icons — because it exists to *show* a folder. A
sweep never wants that. `OSAPI_FILE_GOTO_QM` (`0x035C`) is the same free stand
with the instance moved with it, so the next file cell resolves there.

So a recursive descent is free, and the sweep's whole cost is **reading each
directory's clusters** through `OSAPI_FILE_FIND` (`0x0283`: CX = ordinal,
ES:DI = a 24-byte record, CF=1 + `FERR_NOENT` at the end, types `OSAPI_FT_FILE`
/ `_PKG` / `_DIR` / `_UP`). The FAT is resident — `dskw_dfree` counts free
clusters *"across the resident FAT snapshot; no disk I/O"* — so chain-walking
is free too.

## 3. Why there is no index

A full sweep, counted as directory-cluster reads:

| volume | reads | at 400 ms (XT floppy) | at 20 ms (IDE/CF) |
|---|---:|---:|---:|
| 360KB system floppy | 15 | 6.0 s | 0.30 s |
| 1.44MB apps floppy | 25 | 10.0 s | 0.50 s |
| 1.5GB CF partition | 23 | — | 0.46 s |
| live USB | 51 | — | **1.02 s** |

**The 1.5GB partition sweeps in fewer reads than a 1.44MB floppy**, because a
32KB cluster holds 1,024 directory entries. Sweep cost tracks FOLDERS, not
files.

**And the pairing is favourable, which is the real argument**: many folders
implies a hard disk, where a read is ~20 ms; a slow floppy implies few
folders. The worst case is not "41 folders at 400 ms" because that volume
cannot be a floppy — it does not fit on one.

An index would buy back about one second and cost a file format, a writer, a
staleness story, bytes on every volume, and **§52.10.14's hazard**: a
per-volume cache carrying folder clusters, copied, is *"not a wasted read but
a wrong answer that outlives the install."* A find index has exactly that
shape. The index is refused.

**Nor is anything else stored.** Caching the last search term would cost ~2
`int 13h` to read — about 800 ms on a floppy, **5% of a whole 360KB sweep** —
to save typing six characters. Window geometry: no package in the tree
persists it. 47 of 75 packages store nothing at all, so this is the norm and
not an eccentricity.

**What storing nothing buys on this system specifically:** it runs on a
read-only volume (a CD cannot be written, §80.3) against a read-only volume,
which is exactly where the 482-file library lives; and there is nothing to
version, go stale, or corrupt.

**The icons are free anyway.** `ASSOC.DAT` (§54.7) already caches each
package's icon and its associations per volume, maintained by the mount. Find
shows a proper icon beside every result and launches by association without
storing a byte of its own.

## 4. The constraint that shapes the code

**The sweep runs on the UI task and must be chunked.** Two rules force it:

- **A worker may not touch a file** (§20.6 rule 7), so the sweep cannot be
  moved off the UI task the way a long computation would be.
- The file slots are *"UI-task/window-callback context like every other one,
  **and a deep tree is a long freeze**"* — the SDK's own warning beside
  `OSAPI_FILE_GOTO`.

So the sweep does a bounded slice per pass and hands control back, the shape
`wd_hchunk` uses for Word's row count (§27.7.2.2) and the file manager's
chunked copy for a long copy (§18.4.4). **How the slice is bounded — a folder
at a time, or N records — is wave 1's measurement**, not a guess here.

**And Find draws its own progress.** §12.8's file-operation progress widget is
`fprog.inc`, kernel-internal: there is no `OSAPI_FPROG` and a package cannot
reach it. A line of text with the folder being scanned and a Stop button is
the whole requirement, and Stop must work *during* the sweep, which is what
chunking buys.

## 5. The application

`apps/find/find.asm`, prefix `fn_`. An ordinary package: a window, no heap
claim beyond its results, no driver, no kernel change of any kind.

- **The field** — a name fragment, matched case-insensitively against the 8.3
  name. An extension filter is the same field with a leading `.`.
- **The scope** — this volume, or all mounted volumes. Volumes are indices
  `0..DVOL_MAX-1` (8 on `kern_big`, 4 on `kern_small`, `kernel/disk.inc`),
  asked with `OSAPI_VOL_KIND` (`0x0190`); `OSAPI_FILE_HERE` (`0x01C1`, no disk
  I/O) says where the instance stands before the sweep so it can be put back.
- **The results** — a flat list: icon, name, and the folder path it was found
  in, which is the column that does the actual work.
- **Opening one** — by association, the same route a double-click in the Disk
  window takes; a `.O88` runs, a document opens its program.
- **The results are not saved.** Closing the window forgets them, which is
  what the question deserves.

## 6. Where it ships

**Not on the 360KB curated apps selection** (§24.6.1: being on that disk is a
decision with a date on it, and 39 files in 7 folders do not need finding).

`util360.img` is its 360KB home, beside the other utilities; the 720KB, 1.2MB
and 1.44MB apps disks and the live media carry it as an ordinary package. The
live media is the one volume whose premise is completeness (§80.6) and the one
with 482 files in 41 folders — it is the machine this is for.

## 7. Staging

### Wave 0 — the contract
A SPEC chapter of its own, numbered when written. It is short, because there
is no file format to pin: the window, the match rule, the scope rule, the
chunking contract and the refusal to store anything.

### Wave 1 — the sweep, with no window
One volume, chunked, counting what it finds. **Gate:** the count matches an
independent host-side walk of the same image — the host reads the FAT with its
own code, which is the shape `tests/unit/t_image.py` already uses so that a
writer and a reader cannot cancel each other's defects. **Measure** the slice
cost here and pick its bound.

### Wave 2 — the window, the field and the flat list
Name matching, results with icons from `ASSOC.DAT`, the folder column.
**Gate:** a known file in a known folder is found from the root.

### Wave 3 — scope, filters and opening a result
All-volumes, the extension filter, open by association.

### Wave 4 — the LaunchPad's Find button
§30.7.5 greys it with a reason until this exists; this is what ungreys it.

### Wave 5 — the look, on all three adapters
§39.4 and §47: grey rounds to black on 1bpp, so the Stop button's greyed
state, the progress line and the list's selection are each their own decision
on CGA and Hercules.

## 8. Verification

- A **host-side independent walk** as wave 1's gate, per above.
- **Mutation, per this tree's standing rule** — break the descent so it never
  leaves the root and the gate must go red. A find gate that passes while
  finding only the root is this project's commonest defect shape.
- **No `tools/kernsize.py` entry is expected to move at all**: this is a
  package and touches no kernel byte. A kernel delta is a design error.
- **All three adapters looked at**, per wave 5.

## 9. Open questions

1. **How the slice is bounded** — a folder per pass is simplest; N records is
   smoother. Wave 1 measures and decides.
2. **A volume that is not mounted** — does an all-volumes sweep mount it, or
   skip it and say so? Skipping and saying so is the cheaper answer and
   matches §47's "grey a fact".
3. **A result whose volume has since been swapped.** §54.4.2's rule is that a
   cluster means nothing on a disk that has been swapped and the NAME is
   re-checked on arrival. Opening a result must do the same; it is the only
   place this stateless design can still be wrong.
4. **How many results to hold.** They are in the package's own memory and a
   482-file volume is the ceiling; a cap with an honest "more than N" line is
   likely cheaper than a growing claim.
