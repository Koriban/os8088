# PLAN — a LaunchPad for the dock strip (OS/2 Warp 3's shape)

**Status: wave 0 DONE (the contract, SPEC.md §30.7); waves 1-6 not built.**
Written 2026-10-30 against the dock as it stands at `321eae08`.

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

## The decision: the LaunchPad launches, the Desktop holds what is minimized

**Settled by the owner, 2026-10-30: a window iconizes to the DESKTOP, not to
the LaunchPad.** The LaunchPad is a launcher and holds no running state. An
earlier draft of this plan recommended the opposite - a hybrid strip carrying
launchers *and* the running tiles - and that recommendation is withdrawn.

**It is also what Warp 3 does**, which the draft had not checked. Part 3,
"Cleaning Up Your Desktop", gives a window two minimize destinations, chosen
per object in Settings -> Window tab -> Minimize button:

> **Minimizing an Object to the Desktop** - "Some frequently used objects
> might be easier to re-access if they are minimized to the desktop instead
> of the Minimized Window Viewer."
>
> **Minimizing an Object to the Minimized Window Viewer** - "Most objects by
> default are set up to minimize to the Minimized Window Viewer."

So the destination is a real OS/2 setting and the Desktop arm is the one being
taken. Nothing here is a departure from the source design.

### What that costs, named

| today | under the LaunchPad |
|---|---|
| §29.6 `OSAPI_WM_MINIMIZE`: "the tile inverts, the window hides, and a click on the tile brings it back" | the window hides and an icon appears in a free desktop cell; a click on the icon brings it back |
| §30.4 the tile is a toggle - clicking the front window's tile minimizes it | **withdrawn with the tiles** |
| the strip is the at-a-glance list of what is running | the Desktop is, and the **Window List push button** is the complete list |

**The slot's signature does not move**, so this is not an ABI change under
§20.2.0.1: 0x0413 still takes `BX` = a window of yours with the gfx lock held,
and still means "minimize me". What moves is where it lands. §29.6's prose,
§30.4 and §46.5.3's worked example are all rewritten in wave 0, and so is
every package comment that says "to the dock".

**The Window List button stops being optional.** With no tiles, it is the only
route to a window that is hidden rather than iconized - and the manual's own
note is that the Window List legitimately holds more titles than the viewer
does, "because hidden windows are also displayed in the Window List". It moves
from wave 4 to wave 1.

**`OSAPI_WM_HIDE` stays the trap §29.6 already calls it**, and more so: with
no tile to draw, a plain hide now leaves an instance with *no* on-screen
handle at all. The Window List is what keeps that recoverable, which is the
second reason it moves early.

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
- **A free desktop cell is already allocated for you.** `kernel/desk.inc` has
  the whole placement problem solved: `desk_free` answers the first free cell,
  `desk_owner` says what is shown in one, `desk_reflow` re-packs them,
  `desk_zone_rect`/`desk_cell_rect` give the pixels, and **`desk_cmark` posts
  a repaint without drawing** - which is exactly what an iconize needs,
  because §29.6 runs with the gfx lock HELD. The geometry is `DESK_ZSTEP` 60
  for the 32-row icon and **`DESK_ZSTEP_S` 34 for §26.4's 14-row one**, which
  is the size a minimized window probably wants; columns flow leftwards at
  `DESK_COLW` 44.
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
**The order is forced by the decision above**: the moment the strip stops
drawing tiles, minimize has nowhere to land - so the Desktop destination is
built and shipped BEFORE the tiles go, not after. Every wave boundary here is
a working system.

### Wave 0 — the contract — **DONE, 2026-10-31**
**SPEC.md §30.7 is written**, marked `Status: PINNED, nothing shipped`, in
eight subsections: the strip's composition (§30.7.1), the item record and its
file (§30.7.2), drawers (§30.7.3), the drop and the insertion bar (§30.7.4),
the push buttons (§30.7.5), iconizing to the Desktop (§30.7.6) and the cost
(§30.7.7).

Three questions this plan left open were **decided** in it:

- **Storage is `SYSTEM/APPDATA/LAUNCHPAD.DAT`** (§19.9), not `SYSTEM.CFG` -
  that file's `DK` key is one byte and full, and a list of links is not a
  setting.
- **The drop is button 1, not Warp 3's button 2**, because button 2 on the
  strip is already §30.2's context menu. Recorded in §30.7.4 as a deliberate
  departure; a right-click on a launcher offers Remove.
- **A drawer takes no window slot** - save-under, §11.96's shape - because
  `MAX_WIN` is 12 and a drawer opens and closes constantly.

Still open and left to wave 1 on purpose: **what happens when `desk_free`
finds no cell.** §30.7.6 names the Minimized Window Viewer as Warp 3's own
answer and does not pin it.

**§29.6 and §30.4 are NOT rewritten yet**, deliberately: they describe what
the shipped kernel does, and rewriting them now would make SPEC lie until
wave 1 lands. §30.7.6 says so in place. The same goes for §46.5.3's worked
example and the Control Panel's Dock page (§31.13).

### Wave 1 — iconize to the Desktop, with the strip untouched
`OSAPI_WM_MINIMIZE` takes a free cell (`desk_free`), draws the instance's own
icon there, marks it with `desk_cmark` rather than drawing under the held
lock, and a click on the cell restores. **The dock still draws its tiles** -
this wave changes only where a minimize LANDS, so the machine is usable
throughout and the change is reviewable on its own.

**Gate:** a new row - minimize, assert the cell is owned and the window
hidden, click, assert restored - mutation-proven by removing the restore arm.
`dockmark` must still pass, because the tiles are still there.

### Wave 2 — the Front Panel takes the table
`dkx_hook`; the strip draws push buttons + launchers; clicking a launcher runs
its link through `OSAPI_PKG_RUN`. **The tiles go here, and §30.4 goes with
them** - safe only because wave 1 already moved minimize. **The Window List
push button ships in this wave, not later**: with no tiles it is the only
route to a hidden window.
**Gate:** `dockmodule` and `dockpos` still pass (the module swap is what they
already test), plus a launcher that starts a package, plus the Window List
reaching a hidden instance.

### Wave 3 — drawers
`DKI_HOLE_*` reused for the open drawer, save-under for its pixels, one click
opens and one more launches. **Gate:** the open drawer is a hole - a window
under it is not clipped away - which is §30.6.1's own assertion pointed at a
second caller. **Measure:** the open and the close in primitive calls, against
Part 5 of PERFORMANCE.md, because a drawer that repaints the strip is a
regression against a documented number.

### Wave 4 — adding and removing
Drag with button 2, the single solid black insertion bar, `DKI_DROP`.
**Gate:** a dropped item survives a restart (it is a link in a file), and the
bar lands where the drop does.

### Wave 5 — the remaining push buttons
Find, Lockup and Shut Down map onto things that exist or honestly do not;
**a button with nothing behind it must grey itself with the reason (§47,
"grey a fact, never a guess")**, not be drawn dead.

### Wave 6 — the look, on all three adapters
**Not optional and not last by accident.** §39.4 and §47: grey rounds to black
on 1bpp, so the drawer's panel, the insertion bar, a greyed push button and
**the minimized icon's caption** are each a separate decision on CGA and
Hercules. `make test VIDEO=cga` / `herc`, and look - the project's standing
rule is that a drawing change is not done until it has been seen on a 1bpp
adapter.

## Files

- `kernel/dockmod.inc` — the module; the fourteen landing pads
- `kernel/dock.inc` — expected to change **only** if a basic body's contract
  moves. A diff here is the review's first question.
- `kernel/desk.inc` — the cell a minimized window takes, and its restore
- `kernel/inst.inc` — `inst_minimize`, whose destination moves (§29.6)
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

1. ~~**Does `dkx_hook` really permit a strip of a different SHAPE?**~~
   **ANSWERED 2026-11-01, yes — audited, and it cost the plan a claim.**
   Every dock symbol the kernel names outside `dock.inc`/`dockmod.inc` was
   checked. The fourteen slots cover the strip completely, including the one
   that looks like a bypass: `inst_tile_rect` near-jumps to `dock_slot_rect`,
   which is itself `DKCALL DKI_SLOT_RECT` on `kern_big`. What sits outside
   the table is state the module publishes (`dock_cfg`, `dock_side`,
   `dock_thk`, `dock_px1`/`px2`, `dock_up`), two kernel helpers that read it
   (`dock_live_hit`, `dock_px_rect`), and three lifetime entries
   (`dock_apply`, `dock_reflow`, `dock_init`) — all shape-agnostic. SPEC.md
   §30.7.7 carries the table.

   **But "zero resident delta" was wrong and is withdrawn.** The audit found
   `inst_tile_rect` changes MEANING rather than implementation: it answers
   where an instance's TILE is, for §11.99's zoom, and under the LaunchPad
   the window goes to a desktop cell instead. The module answers
   `DKI_SLOT_RECT` with the cell's rect — and needs a door onto
   `kernel/desk.inc` that does not exist. With Lockup's saver door that is
   **two `cw_` wrappers, about eight bytes**, now named in §30.7.7.1 instead
   of being discovered in wave 2.
2. **Where the list lives** (wave 0's storage question) — `LAUNCHPAD.DAT` is a
   proposal, not a decision.
3. **Does the drawer need its own window slot?** `MAX_WIN` is 12 and
   SPEC.md's own history has ~10 dialogs bricking a package's dialogs. If the
   drawer is a window, it is a window that opens and closes constantly. The
   save-under route avoids a slot entirely and is the one to cost first.
4. **Button 2 for the drop.** Warp 3 uses mouse button 2 to make a shadow;
   os8088 uses button 2 for context menus (§30.2's tile menu is a right-click).
   These collide on the strip. Decide in wave 4, and say so in the new section.
5. **What happens when the Desktop has no free cell?** `desk_free` can fail,
   and a minimize that silently does nothing is the worst outcome. §30.5.1's
   precedent for the strip is "a side strip that cannot hold every tile holds
   fewer", which does not transfer. **OS/2's own answer is the Minimized
   Window Viewer**, and Part 3 documents it as the DEFAULT destination with
   the Desktop as the per-object alternative - so a Viewer is both the
   authentic and the cheap fallback, and the Window List button is most of
   one already. Decide in wave 1; it is that wave's only real design risk.
6. **Where on the Desktop.** Cells flow LEFTWARDS from the top right
   (`DESK_ZY0` 32, `DESK_COLW` 44) and the drive icons are already there,
   while the strip sits at the bottom. "Under the LaunchPad" reads naturally
   as *under the LaunchPad design* rather than spatially below the strip -
   which is as well, since below a bottom strip is off-screen. **If a
   dedicated band is wanted** (minimized windows in their own row rather than
   sharing the drive icons' pool) that is a layout decision for wave 1 and
   changes `desk_free`'s caller, not `desk_free`.
7. **Which icon?** A package carries one (`OS88_HEADER ... icon=yes`), so the
   instance's own icon is the obvious answer; what a package with no icon
   gets is not.
