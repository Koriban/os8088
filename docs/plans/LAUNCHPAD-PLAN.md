# PLAN — a LaunchPad for the dock strip (OS/2 Warp 3's shape)

**Status: a plan, nothing built.** Written 2026-10-30 against the dock as it
stands at `321eae08`.

## The authority

The design is **OS/2 Warp 3's LaunchPad**, read from the primary manual rather
than from memory: *User's Guide to OS/2 Warp Version 3*, IBM document
**S83G-8300-00**, First Edition October 1994, Part 2 "Exploring OS/2" —
`_LIBRARY/platforms/os2/users-guide-warp3/` (8 PDFs, 191pp; provenance in that
folder's README). Where this plan says "Warp 3 does X", Part 2 says it.

`docs/reports/WIDGET-CENSUS-2026-10-21.md` Part 2 is the secondary read — eight
launcher strips compared, the LaunchPad sourced to EDM2 and to Bubblepad (a
third-party replacement, useful for what the stock one was felt to lack). The
manual and the census agree on mechanism; the manual adds the first-party
detail the census had no source for (the four push buttons, the "Front Panel"
name, the default objects, the keyboard route).

## What the LaunchPad actually is

Not a taskbar. **A fixed strip of always-visible items, where some items have a
nested, temporarily-visible second tier.** Precisely:

| part | behaviour (Part 2) |
|---|---|
| **Front Panel** | the always-visible row of objects |
| **Push buttons, left** | Lockup, Find, Window List, Shut Down — four, fixed |
| **Objects, right** | each a **shadow** of something that lives elsewhere; "when you make a change to the shadow, the change also occurs in the original" |
| **Drawer** | a button attached to an object that has one. One click opens the drawer, one more launches what is inside. Drive A's drawer holds Drive C; OS/2 Window's holds DOS Window |
| **Adding** | drag an object onto the right side **with mouse button 2**; the pad **expands**; "a single, solid black bar" marks where it will land |
| **Defaults** | Drive A, OS/2 Window, Using OS/2, Shredder, and Printer *only if a printer was set up* |
| **Keyboard** | Alt+Tab to the LaunchPad, Enter to open; Left/Right Arrow to highlight, Enter to activate |

**The LaunchPad does not show what is running.** That is the Window List push
button's job — a list, on demand. This one sentence is the whole design
tension below, because os8088's strip is *nothing but* what is running.

## The one architectural fact the design turns on

**`dkv` is already a clean, complete seam, and the whole strip is replaceable
by a loaded module.**

`kernel/dock.inc` publishes a **14-slot far-pointer vector table** (`DKI_N equ
14`) and every dock operation the kernel performs is `DKCALL x` = `jmp far
[dkv + x]`:

```
DKI_GEOM  BAND  FORCE  PAINT  PX_HIT  CLICK  RCLICK
SLOT_RECT  FORCE_R  DROP  PASS  HOLE_ARM  HOLE_SUB  HOLE_WIN
```

Those fourteen cover every call the kernel makes into the dock — 18 call sites
across `wm.inc`, `ui.inc`, `fsx.inc` and `blank.inc`, all of them funnelling
through this table. A module takes the table over at `mod_fp` entry 0
(`dkx_hook`) and hands it back at entry 1 (`dkx_unhook`); §30.5 says the module
owns "advanced geometry, tile packing, hover/linger and clip-region
maintenance, drawing and input". The jump is a JUMP, so nothing is banked and
the mechanism costs **42 guest cycles** (the index-in-BP router it replaced was
227).

**This corrects the widget census.** Part 2's read-across says `DOCK_OPT` works
"by replacing individual operation landing pads inside the *same* strip … not
by replacing the whole dock with a different window", and concludes the
"driver unloads it, app replaces it" shape has no precedent here. Reading the
table says otherwise: paint, hit-test, click, right-click, geometry, the clip
hole, drop and force are all in it, which is the whole of a strip's behaviour.
The census's open question — *"is the basic dock's window-manager wiring
cleanly detachable"* — is **answered yes**, and that is what makes this plan
cheap.

## The design decision: faithful, or hybrid

Warp 3's LaunchPad launches and does not list. os8088's dock lists and does not
launch. A literal replacement therefore **removes** at-a-glance running state,
and takes two shipped behaviours with it: §29.6 `OSAPI_WM_MINIMIZE` (a package
sends its own window to the dock) and §30.4 (the tile is a toggle — clicking
the front window's tile minimizes it) are both wired to tiles.

| | A — faithful | B — hybrid Front Panel (**recommended**) |
|---|---|---|
| strip | four push buttons, then launcher objects with drawers | push buttons, launchers with drawers, **then the running tiles** |
| what's running | behind the Window List button, on demand | still on the glass, as now |
| §29.6 / §30.4 | must be re-homed or withdrawn | unchanged |
| fidelity | exact | the layout Windows 98 and every modern dock converged on |
| risk | a shipped behaviour removed for fidelity to a different OS | the strip gets busier; 640px is the budget |

**Take B.** The census already made this argument — "adding a second idea next
to the existing one, not replacing it" — and the manual does not contradict it:
Warp 3 could afford a pure launcher because OS/2 had a Window List *and* a
desktop full of objects. os8088 has neither. B also keeps §29.6 and §30.4
working, so no shipped contract is withdrawn to buy a look.

A stays reachable: the strip's composition is the module's, so a later
`[dock_cfg]` bit could offer the pure Front Panel to whoever wants it.

**640 pixels is the constraint that decides the counts.** `DOCK_STEP` is 28 and
the strip already fits `8 + 12*28 = 344` — so the launcher half has roughly
**ten slots at the bottom edge** before the tiles are squeezed, and a side
strip (`DOCK_SW` 32, `DOCK_SSTEP` 24) has fewer. §30.5.1 already says a side
strip that cannot hold every tile holds fewer; the launcher half inherits that
rule rather than inventing one.

## What is reused rather than invented

CLAUDE.md's first rule is to ask whether the OS already does it. It does, four
times, and each is most of a wave:

- **A shadow is a LINK** (§26.10, `apps/os88link.inc`, §26.10.7's parameter).
  The OS already has a one-construct reference to a package with an argument,
  already used by `\AUTOSTRT`. A LaunchPad item is a link; "change the shadow
  and the original changes" falls out because there is only one original.
- **An open drawer is a HOLE in the clip region** — which is *exactly*
  §30.6.1, already built and already in the table as `DKI_HOLE_ARM` /
  `HOLE_SUB` / `HOLE_WIN` for the auto-hiding strip. The drawer is a second
  user of a solved problem, not a new one.
- **The drawer's pixels are a save-under.** §11.96's raise cache and the menu
  bar's own save-under (`MENU_BCMAX`) are the precedent; a drawer is a menu
  that opens upward.
- **Hover and linger are already tuned** — `DOCK_HOVER_T` 5 ticks (0.27 s),
  `DOCK_LEAVE_T` 14 (0.77 s). A drawer that closes itself after a pick (CDE
  does; Warp 3's needs a click) can take these rather than guess.

## Where the cost lands

`kernsize[big]` at `321eae08`: **KERN_SIZE 97,280 of KERN_BUDGET 100,864 —
3,584 spare**, and the image rung is **482/512 (94%) accrued**. There is no
room for a resident launcher, and §2.8's test is passed anyway (the system
disk is already required to change dock settings, and `DOCK.DRV` is loaded for
any non-default dock today).

**So it is a module, and the resident delta must be near zero.** The precedent
is measured: `docs/reports/DOCK-RESIDENT-COST-2026-09-17.md` — the placement
feature is **486 resident bytes of which 112 are the mechanism**, the rest
being the window manager and menu bar learning the strip has a live rect. The
LaunchPad should add **no new resident sites at all**: it changes what the
fourteen slots do, not who calls them. Any resident growth is a design error
to find in review, not a budget request.

**`kern_small` gets nothing**, and that needs no argument: §30.5 already makes
the whole placement feature `kern_big`'s alone, every site `%ifdef DOCK_OPT`,
and the 128KB floor machine has a fixed bottom strip with no `DOCK.DRV` to
load. The LaunchPad inherits that boundary unchanged.

## Staging

Each wave is useful alone and gated by a measurement, per CLAUDE.md's waves.

### Wave 0 — the contract
A new SPEC.md **section 30.7** - the number is free, 30.6.1 being the last.
It is written as a PROPOSAL here and is deliberately never written in the
section-sign form, because the doc gate resolves every such citation against
a real heading - including one inside backticks - and a plan that cites its
own unwritten section fails `make`. This one did. Pin: the strip's composition,
the item record (a link plus an icon plus an optional drawer), where the list
is stored, the push buttons, the drawer's open/close rules, the drop protocol
and the insertion bar. Nothing is built until this is written — the project's
rule, and the one that `/port-to-os8088`'s LESSONS keeps re-learning.

**The storage question belongs here**: `SYSTEM/APPDATA/` (§19.9) is where an
application's state goes, and `SYSTEM.CFG`'s `DK` key is one byte and full.
A `LAUNCHPAD.DAT` of links beside `ASSOC.DAT` is the shape to argue first.

### Wave 1 — the Front Panel, no drawers
`dkx_hook` takes the table; the strip draws push buttons + launchers + the
existing tiles; clicking a launcher runs its link through `OSAPI_PKG_RUN`.
Drawers refused. **Gate:** `dockmodule` and `dockpos` still pass (the module
swap is the thing they already test), plus a new row for a launcher that
starts a package.

### Wave 2 — drawers
`DKI_HOLE_*` reused for the open drawer, save-under for its pixels, one click
opens and one more launches. **Gate:** the open drawer is a hole — a window
under it is not clipped away — which is §30.6.1's own assertion pointed at a
second caller. **Measure:** the open and the close in primitive calls, against
Part 5 of PERFORMANCE.md, because a drawer that repaints the strip is a
regression against a documented number.

### Wave 3 — adding and removing
Drag with button 2, the single solid black insertion bar, `DKI_DROP`.
**Gate:** a dropped item survives a restart (it is a link in a file), and the
bar lands where the drop does.

### Wave 4 — the push buttons
Window List first — it is the one that pays for itself under option B, and
§28's Task Manager already is the list. Find, Lockup and Shut Down map onto
things that exist or honestly do not; **a button with nothing behind it must
grey itself with the reason (§47, "grey a fact, never a guess")**, not be
drawn dead.

### Wave 5 — the look, on all three adapters
**Not optional and not last by accident.** §39.4 and §47: grey rounds to black
on 1bpp, so the drawer's panel, the insertion bar and a greyed push button are
each a separate decision on CGA and Hercules. `make test VIDEO=cga` / `herc`,
and look — the project's standing rule is that a drawing change is not done
until it has been seen on a 1bpp adapter.

## Files

- `kernel/dockmod.inc` — the module; the fourteen landing pads
- `kernel/dock.inc` — expected to change **only** if a basic body's contract
  moves. A diff here is the review's first question.
- `kernel/ctrl.inc` — the Dock page (§31.13) grows the LaunchPad's setting
- `SPEC.md` — a new section 30.7, and §30.5 (the module's ownership sentence
  widens)
- `tests/suite.py` + a `launchpad` row; `tests/launchpad.py`
- `docs/plans/LAUNCHPAD-PLAN.md` — this file

## Verification

- **The three existing dock rows are the regression floor**: `dockmark`,
  `dockmodule`, `dockpos`. They must pass untouched, because the mechanism
  they test is the one being reused.
- **A new row, mutation-proven.** This project's standing rule, and the
  reason it exists: take the arm out and the row must go red. A LaunchPad row
  that passes with the drawer never opening is this tree's commonest defect
  (`docs/reports/`, and the gate written this session for SPEC.md §68.16.1
  was vacuous **twice** before it was real).
- **`tools/kernsize.py` before and after, both kernels**, reported as
  per-section bytes plus the accrued figure — never "crossed no rung"
  (docs/KERNEL-MEMORY.md). The target is **zero** resident delta.
- **Primitive-call counts** for the drawer open/close, per PERFORMANCE.md
  Part 5. A redraw is priced by calls, not pixels.
- **All three adapters looked at**, per wave 5.

## Open questions, named rather than assumed

1. **Does `dkx_hook` really permit a strip of a different SHAPE**, or do the
   kernel's 18 call sites assume tile geometry anywhere outside the table?
   `DKI_SLOT_RECT` and `DKI_PX_HIT` suggest not, but this is the one claim
   this plan rests on that was read rather than tested. **Answer it in wave 1
   before building waves 2–5.**
2. **Where the list lives** (wave 0's storage question) — `LAUNCHPAD.DAT` is a
   proposal, not a decision.
3. **Does the drawer need its own window slot?** `MAX_WIN` is 12 and
   SPEC.md's own history has ~10 dialogs bricking a package's dialogs. If the
   drawer is a window, it is a window that opens and closes constantly. The
   save-under route avoids a slot entirely and is the one to cost first.
4. **Button 2 for the drop.** Warp 3 uses mouse button 2 to make a shadow;
   os8088 uses button 2 for context menus (§30.2's tile menu is a right-click).
   These collide on the strip. Decide in wave 3, and say so in the new section.
