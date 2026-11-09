# PLAN — the dock as a loadable program, and the desk's special folders

**Status: a plan, nothing built.** Written 2026-11-02.

Two features under SPEC.md §151's roof — "a shell owns the **furniture**" —
and they are separable: either can ship without the other. Part B is nearly
free and Part A is not.

---

# Part A — the dock as a loadable program

## A.1 What the dock costs today, measured

`tools/kernsize.py --modules`, 2026-11-02:

| file | `.text` | `.cold` | `.bss` | resident |
|---|---:|---:|---:|---:|
| `dock.inc` — the strip | **910** | — | 59 | **969** |
| `dockmod.inc` — `DOCK.DRV`, the placement/auto-hide runtime | — | — | — | **0** |

**969 bytes**, against `kern_big`'s **3,584 spare** of `KERN_BUDGET` — just
over a quarter of everything left.

And the constraint it relieves is the right one. `KERN_CODE_MAX` has
**18,974** free, so `.text` is not what is tight; `KERN_BUDGET` is, and
CLAUDE.md's rule is that `.cold` relieves the former and **a module relieves
both**. The dock is 910 bytes of *hot* `.text` — unlike the desk, which is 23
bytes of `.text` and 2,000 of `.cold` and therefore already cheap where it
matters.

## A.2 This reopens §151.7's question 4, and the owner is right

That question asked whether the stock dock should stay in the kernel, and
this plan's own answer was *"keep it resident until something argues
otherwise."* The argument is now made, and nothing about the measurement
changed — the 969 bytes were always there. **What changed is the
consistency**: once a dock is a thing you name in `SYSTEM.CFG` (§151.2), the
stock dock being the one that cannot be a file is an exception with no
reason behind it.

## A.3 Three shapes, and why it is a module

| | |
|---|---|
| **(a) `DOCK.DRV` always loaded** — the basic bodies move into the module, which is loaded at boot rather than on a settings change | **recommended** |
| (b) the dock becomes a `.O88` **package** | refused, below |
| (c) status quo — resident basic bodies, replaceable per §151 | the fallback if A.4 cannot be answered |

**(b) is refused on load order, not on taste.** A package is a task with a
window and a heap claim, launched by the loader; the dock is chrome *outside*
windows, drawn from the UI task under the gfx lock and reached by
`wm.inc`'s damage path before any package exists. The dock must answer
`DKI_PAINT` during the first `wm_paint_all`, which is before the loader has
run anything. A module is loaded by `mod_need` in the boot sequence and `dkv`
already exists to hook it — (b) would need a second mechanism to do what (a)
does with the one already built.

## A.4 THE TENSION, and it is the whole of Part A

§151.5 says, in terms:

> **The built-ins never leave the kernel.** They are what a slot holds at
> rest, so "no shell" is not a degraded mode: it is byte-identical to the
> system before this chapter.

**Making the stock dock a file contradicts that**, because then there is
nothing to fall back *to*. A machine whose `DOCK` file is missing or corrupt
gets no strip at all.

Three answers, in increasing cost:

1. **Accept it.** A machine with no dock file has no dock. The system disk is
   present at boot by construction (every module is read then), so the case
   is a damaged disk — and a damaged disk already costs the Control Panel,
   the formatter and the file copier (§2.8's module list).
2. **Keep a stub.** A few resident bytes that draw an empty strip and answer
   every slot harmlessly, so the machine is usable and says why. Costs back
   some of the 969.
3. **Keep the basic bodies** — option (c), no saving.

**Answer 1 is only safe after §30.7.6 lands**, and that is the sequencing
finding of this plan:

> **Today the dock is load-bearing for `OSAPI_WM_MINIMIZE`.** §29.6 puts a
> minimized window on a tile and a click on that tile is the only way back.
> A machine with no dock would have windows it cannot restore.
>
> **§30.7.6 moves minimize to the DESKTOP.** Once a minimized window is a
> desktop cell, the dock is no longer the only route back and becomes
> genuinely optional.

So **Part A is blocked on LaunchPad wave 1**, which is the iconize-to-desktop
wave. That is not a scheduling preference; shipping Part A first would ship a
machine that can lose a window.

## A.5 What it costs at boot

One more module read. `drv_boot` already reads the driver list with
`Loading Driver n/N` on the splash, and an `int 13h` is **~400 ms** on a
4.77 MHz floppy machine (PERFORMANCE.md: cost disk work in CALLS). The dock
image is small, so this is one or two calls — under a second on the slowest
machine in the project, and nothing on a hard disk.

**It must be read BEFORE the first paint**, which puts it with the drivers
rather than with the on-demand modules.

## A.6 Staging

- **A0 — the contract.** A SPEC section under §30: what the dock image is,
  when it is read, and which of A.4's three answers is taken. **Do not start
  until LaunchPad wave 1 has shipped.**
- **A1 — move the bodies.** `dock.inc`'s basic bodies into `dockmod.inc`;
  the boot loads it. **Gate:** every dock row (`dockmark`, `dockmodule`,
  `dockpos`) passes unchanged, and `kernsize` shows the 969 bytes gone.
- **A2 — the missing-file path.** Whichever of A.4 was chosen, and a gate
  that boots with the image deleted.
- **A3 — `kern_small`.** It has no `DOCK.DRV` and a fixed bottom strip
  (§30.5). Either it keeps its resident dock — two arms of one file — or it
  gains a module it has no room for. **Keep it resident there**; the saving
  is `kern_big`'s and the floor machine's strip is not the same code path.

---

# Part B — the desk's special folders

## B.1 What Warp 3 actually puts on the desktop

Read from the manual (IBM S83G-8300-00, Part 2 "Using the Desktop and Its
Objects" and Part 3), not from memory:

| object | the manual's words |
|---|---|
| **OS/2 System** | *"contains objects you can use to set up OS/2 the way you want it"* — and inside it: **System Setup**, **Productivity**, **Games**, **Command Prompts**, **Drives** |
| **Information** | *"online information, including Using OS/2 (the online tutorial), and the Master Help Index, and online books"* |
| **Templates** | *"object models (templates) … make it easy for you to create new objects for files, folders, programs"* |
| **LaunchPad** | §30.7 |
| **Shredder** | *"a quick way for you to delete files, objects, or folders"* |
| conditional | **Multimedia** (if an audio card), **Windows Programs** and **WIN-OS/2 Groups** (if Windows was found) |

The conditional ones matter as a *pattern*: **the installer places a folder
only when the machine has the thing it is for.**

## B.2 The mechanism already exists, and that is the headline

`OSAPI_DESK_ITEM` (slot `KERNEL_SEG:0x03F8`, §26.9.6) takes a 128-byte
record from a package — §26.8.1's row, byte for byte:

```
+0   1   the volume, 0 = A:
+1   1   the cell it would like, 0xFF = the first free
+2   1   the kind: 0 document, 1 package, 2 FOLDER
+4  45   the path BELOW THE ROOT, NUL
+49 13   the caption, NUL
+64 64   the 16x16 picture
```

**Kind 2 is a folder, the path is a path and not a cluster** (§26.8.1: *"this
system has no volume identity"*), the caption and the icon are the caller's,
and the item **persists** — §26.9.6's own words are that a row *"draws,
opens, moves, persists and is removed by every route"*, written through
`SYSTEM.CFG` on the UI task because a worker may not touch a file.

**So a special folder is a shortcut record with kind 2 and a known path, and
the common case needs no new mechanism at all.** There is room, too:
`DSL_SLOT` is **63 cells** and the shortcut table is a *growable heap claim*,
never `.bss`.

## B.3 What maps for free, and what does not

| Warp 3 | os8088 today | what Part B needs |
|---|---|---|
| **Productivity** | `APPS\` on every apps disk | a default item, kind 2 — **free** |
| **Games** | `GAMES\` | a default item — **free** |
| **Drives** | the desktop's drive icons (§26.1) | **already there**, and better: they are live |
| **Information** | `README.TXT`, and `tools/guide/manuals/` is a whole guide system with a page per program | a home on the disk, then an item |
| **Command Prompts** | `SYSTEM\DOS\` and `DOS.O88` | a default item |
| **System Setup** | the **Control Panel** (§31) — a WINDOW, not a directory | **the hard one, B.4** |
| **Templates** | nothing exists | out of scope here; it is a feature, not a folder |
| **Shredder** | nothing — there is no trash | out of scope; deleting is immediate (§18.99) |

## B.4 The hard one: a folder whose contents are not a directory

**System Setup's contents are not files.** They are the Control Panel's
pages, the formatter, the Task Manager — reached by code, not by a path.
`SYSTEM\` is a real directory but it is **hidden + system** (§19.6), which
means the file manager does not list it *by design*.

| | |
|---|---|
| **(c) a desktop item that OPENS the Control Panel** — kind 1, pointing at the thing that already is the settings UI | **recommended first** |
| (b) a VIRTUAL folder: a Disk window whose listing is synthesized rather than read | the real Warp 3 shape, and a much larger feature |
| (a) make `SYSTEM\` visible | refused: hidden + system is what stops `DISKOPS` and the installer treating it as user data (§52.10.12's species test) |

**(c) is honest about what it is.** Warp 3's System Setup is a folder because
every setting there is an *object*; os8088's settings are pages in one
window, and pretending otherwise would mean inventing objects to put in a
folder. A "System" item that opens the Control Panel is one record and
tells no lie.

**(b) is worth naming because it is the general facility**, and more than
this would use it: an Information folder of guide pages, a Templates folder,
a Shredder. The Disk window already synthesizes one entry — `OSAPI_FT_UP`,
the `..` (§19.5) — so the idea is not foreign, but a listing that is *wholly*
synthetic is a new kind of window and belongs in its own plan.

## B.5 Who places them, and when

**The desk shell's business, per §151.** The stock desk places a default set;
a replacement shell places whatever it likes. Two candidate moments:

1. **The installer** (§52.10), which already builds the volume's own
   `ASSOC.DAT` because *"a copied one is a lie"* (§52.10.14). Placing desktop
   items there matches the conditional pattern of B.1 — a Games folder only
   if `GAMES\` exists on this volume.
2. **First boot**, if the desk finds no items at all.

**Prefer the installer**, for §52.10.14's own reason: a desktop laid out for
the disk it is on is right, and one copied from another machine names paths
that may not exist. A first-boot placer cannot tell the difference between
"new machine" and "user deleted them all", and would put them back.

## B.6 Staging

- **B0 — the contract.** A SPEC section under §26: the default set, which
  are conditional on what the volume holds, who places them, and the
  statement that a user may delete any of them and they stay deleted.
- **B1 — the free ones.** Productivity (`APPS\`), Games (`GAMES\`),
  Command Prompts. Placed by the installer, conditional on the path
  existing. **Gate:** install to a volume with no `GAMES\` and no Games
  folder appears; delete one and it stays deleted across a reboot.
- **B2 — icons.** Each default folder wants its own 16×16 picture, and on
  1bpp it is a separate decision (§39.4).
- **B3 — the System item.** B.4's option (c).
- **B4 — Information.** Depends on `tools/guide/manuals/` having an on-disk
  form; today it is a host-side system.

## B.7 Why Part B is nearly free and Part A is not

Part B adds **no resident byte**: it is records in a file and an installer
that writes them, using a slot that already exists. Part A moves 969 bytes
out of the kernel and changes what happens when a file is missing. They are
in one plan because §151 made them both "furniture", not because they are
one piece of work.

---

## Open questions

1. **Which of A.4's three answers.** It decides whether Part A saves 969
   bytes or rather fewer, and it cannot be settled before LaunchPad wave 1
   shows what a dock-less machine is actually like.
2. **Does `kern_small` keep a resident dock?** A3 says yes; that makes
   `dock.inc` two arms of one file rather than one, which is a maintenance
   cost this tree has paid before and dislikes.
3. **Is a virtual folder (B.4's (b)) wanted at all**, or is the Control Panel
   the right answer for ever? Templates, Shredder and Information all want
   it; none of them is asked for yet.
4. **What a default item does when its path is gone** — a Games folder on a
   volume whose `GAMES\` was deleted. §26.8's shortcut already answers this
   for user-dragged items, and the default set should answer it the same way
   rather than inventing a second rule.
