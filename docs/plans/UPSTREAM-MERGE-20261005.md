# PLAN — merging upstream `jggonz/os8088` 6212352..277313a into `forkmain`

`docs/UPSTREAM.md` is the authority on the cycle and binds this file. What is
here is the measurement for *this* merge and the order to do it in; where the
two disagree, UPSTREAM.md wins.

## The shape of it

| | |
|---|---|
| merge base | `6212352` (2026-09-26) — upstream's own head at our last merge |
| upstream head | `277313a` (2026-10-03) |
| upstream commits to take | **25** |
| files upstream touched | **635** |
| files we touched since the base | **168** |
| **files BOTH touched** | **27** |
| our commits since the base | 263 (29 of them this session's VBE work) |

The last upstream merge is already in `forkmain`, so the base is clean and the
merge is exactly those 25 commits. **Nothing has to be rebased or replayed.**

**Count the overlap per COMMIT, not off the compare endpoint.** GitHub's
`compare` API caps `files` at 300 and reports no truncation flag — it returned
exactly 300 here, which read as the whole diff and was not. Unioning each
commit's own file list gives 635, and the overlap 8 → **27**. A plan built on
the capped figure would have been wrong about the one thing it exists to size.

## What we gain

**Six applications, all additive** — new directories that cannot conflict:
Gorillas (with AdLib/SB music), 1942, Excitebike, DrMarco, REDLINE (a
CPU/graphics lab), MIDIRack (OPL2/OPL3, SB synth and wavetable, PC speaker,
MPU-401 out).

**Kernel and system work**, which is where the cost is:

- **FAT16 volumes to 2GB.** `HP_MAXSEC equ 65535` becomes `HP_MAXHI equ
  0x003F` with `HDM_MBIG` = *'Partition is over 2GB'*. The volume layer counts
  sectors in a dword, and `0x06`/`0x0E` are written rather than merely
  tolerated.
- Video Player; Installer keeps your files; desktop shortcuts with no static
  kernel growth; PC-speaker sound with no card; streaming writes; sets split
  across floppies; a floppy page with low-level format; **both kernels
  smaller**; `blit1` 30% faster.
- Two skills: `native-game-port`, `vga-face`.

**It settles a decision taken earlier today.** `tools/os88cf.py` lays four
32MB partitions because *this* fork caps a volume at 65,535 sectors. After the
merge a 484MB CF card is **one partition**, and that tool is either re-pointed
or retired (stage 6).

## What it costs — the 27, ranked by risk

1. **`SPEC.md`** — ours is +9,785/−65. UPSTREAM.md records *sixteen* conflicts
   in one past merge. Mechanical, not hard, but it must not be eyeballed.
2. **`kernel/vga12.inc`** — upstream's `blit1` work against our `VBROW` /
   `VBHOME` insertions in the three edge-column fills and the save-under pair.
   Ours is +54/−17 and additive.
3. **`kernel/viddet.inc`** — our +168 of VBE geometry (`vid_tab_vbe`, the
   `VBROW` macros, `gfx_rowbase_calc`'s bank select) against their size work.
4. **`Makefile`, `tests/suite.py`** — both sides added targets and rows.
   Add/add, mechanical.
5. **SHEET's pinned region.** The fork pins SHEET's heap region where upstream
   makes its region movable, because the overlay banks CS and holds far frames
   across file calls. **Every upstream heap change has to be re-judged against
   that**, and `kernel/memory.inc` is in the 27.
6. **`kern_small`.** Upstream made both kernels smaller; we fixed a kern_small
   break today that `make` could not see. The gate is `make test-full`.

**Two findings that make this cheaper than the file count suggests:**

- **Only two upstream commits touch the renderer at all** — `48178e4` and
  `343cb17`. Everything else in the 25 is applications and tooling.
- **"One Desktop" does not remove the multi-display machinery.**
  `vid_ctx_capture`, `vid_disp_init`, `vid_dual_ok` and `vid_ctx_rect` all
  survive upstream with the same symbol counts, so §39.29.11's fix is not
  built on ground that has moved.

**Upstream still has the bug we fixed today.** Its `vid_disp_init` refusal arm
is structurally identical to our pre-fix version — `cmp byte [vid_ndisp], 1 /
je .jout` — so display 0's context is never recaptured on a single-adapter
mode switch there either. Our hunk lands in untouched code, and it is worth
offering back.

## MEASURED: a trial merge conflicts in 8 files, 15 hunks

Run in a throwaway worktree off `forkmain`, `git merge --no-commit --no-ff
origin/main`:

| file | hunks | |
|---|---:|---|
| `Makefile` | 6 | both sides added targets |
| `docs/INDEX.md` | 2 | **generated** — regenerate with `tools/os88index.py`, never hand-merge |
| `kernel/vga12.inc` | 2 | see below |
| `kernel/viddet.inc` | 1 | see below |
| `tests/suite.py` | 1 | both sides added rows |
| `tests/unit/t_registry.py` | 1 | |
| `tests/unit/t_smallreq.py` | 1 | |
| `tools/os88ovlchk.py` | 1 | |

**`SPEC.md` merged CLEANLY**, and so did `CLAUDE.md`, `kernel/wm.inc`,
`kernel/kernel.asm`, `kernel/ctrl.inc` and — the one that mattered —
`kernel/vidsel.inc`, which carries §39.29.11's fix. The risk ranking below was
built before this was measured and over-weighted `SPEC.md`; the measurement
stands, the ranking does not.

**Both `vga12.inc` hunks are the same edit twice** (`vga_solid_rect`'s `.lcol`
and `.rcol`) and both resolve by taking BOTH sides:

```nasm
    xchg [es:di], al    ; THEIRS: latch load and masked write in ONE
                        ; instruction - Set/Reset supplies all four planes, so
                        ; the byte written is don't-care (font.inc's idiom)
    VBROW di            ; OURS: the banked row advance. Their `add di,
                        ; ROW_BYTES` is the fixed-stride form 39.29 replaced,
                        ; and taking it would silently un-fix 1024 wide
```

**`viddet.inc`'s single hunk** is five lines of `vid_colour_q`: we added the
`cmp al, VID_VBE` arm, they moved the `je .colour` inside the `%ifdef` so it
is not a jump onto the next instruction. Keep ours and adopt their placement —
both changes are right and neither needs the other's text.

## The order

### Stage 0 — a fetch that finishes
Everything else needs real objects. Two `git fetch origin` runs were killed at
2 and 4.7 minutes before one was left to run unbounded; the repo now carries
four games' art and audio. If it stalls again, `--filter=blob:none` for the
graph and blobs on demand. **Never `--depth`**: UPSTREAM.md Rule 0 is that git
answers ancestry questions confidently and *wrongly* on a shallow clone.

### Stage 1 — land our side first
Push `forkmain` before merging, so there is a clean point to come back to, and
settle `tests/sheetxl2.py` now — the WIP swept into `c2f47e9` is still there,
nothing is pushed, and extracting it renumbers every build from that commit.
Doing it after a merge is strictly worse.

### Stage 2 — merge in a worktree, never in place
```sh
git worktree add ../os8088-merge-20261005 -b merge-upstream-20261005 forkmain
cd ../os8088-merge-20261005 && git merge origin/main
```
The previous merge used this shape and is already in `forkmain`.

### Stage 3 — resolve, by UPSTREAM.md's rules
Defaults that have held: **ours** for what the branch deliberately changed;
**theirs** for what it merely lacks; **theirs for differences with no reason
behind them**, because gratuitous divergence re-conflicts at every future
merge. For `SPEC.md` run the scripted check in UPSTREAM.md — it prints every
non-blank line upstream added that is not on our side, and each is either
something to bring across or a paragraph we rewrote on purpose.

**Never blanket `git checkout --ours`.** It silently drops what upstream has
and the branch lacks; a whole CLAUDE.md paragraph was lost that way once.

### Stage 4 — the three checks a clean merge still fails
```sh
grep -oE '^#+ [0-9.]+' SPEC.md | sort | uniq -d   # duplicate headings: checkdocs
                                                  # resolves to the FIRST match and is happy
git ls-files build | wc -l                        # must be 0
ls kernel/taskmgr.inc                             # must NOT exist
```

### Stage 5 — gates, in this order
`make test-full` (**not** `make`: the fast tier does not build `kern_small`,
which is how a break survived eight commits today) → `tests/curtrail.py` →
**`make VBEDIAG=1` and `make vbebox`**.

That last pair is new and is the point: no previous merge could tell whether
it had broken the renderer's banking, because nothing here could enter the
mode. A merge that silently breaks it would otherwise reach the Satellite
before anything caught it.

### Stage 6 — re-decide what the merge changes
- `tools/os88cf.py` and `cfimg` against the 2GB ceiling: one partition, not
  four. Re-point or retire.
- SHEET's pinned region against their heap changes (risk 5).
- Whether `vid_disp_init`'s fix goes back to upstream as its own PR.

## What this plan does not cover

Pushing to `fork` or opening a PR to `main`. UPSTREAM.md owns the PR cycle and
its requirements (SPEC.md sections gate merges upstream), and nothing here is
pushed yet.
