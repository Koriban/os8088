# PLAN — replaceable DOCK and DESK shells

**Status: wave 0 DONE — the contract is SPEC.md §151. Waves 1-5 not built.**
Written 2026-11-01 at the owner's request.

**Two independent shells, each named in `SYSTEM.CFG`, each replaceable at
startup.** Not one abstraction over both — the dock and the desktop get their
own, so either can be swapped without the other.

## 1. The precedent, which is exact

Windows 3.1's `SYSTEM.INI` carried one line:

```
[boot]
shell=progman.exe
```

Point it somewhere else and you got **Calmira** (a Windows 95 shell on 3.1),
**Central Point Desktop**, or **MS Bob**. Windows NT and XP kept the idea in
the registry's `Shell=explorer.exe`, which is what **GeoShell** replaced.

**What those replaced, and what they did not**, is the boundary this plan
takes: Calmira replaced Program Manager and File Manager. It did not replace
`USER.EXE`. The window manager, the menus, the drawing and the file system
stayed Windows'. A shell owned the **furniture** — what launches things, what
shows what is running, what sits on the background — and nothing else.

Here that is exactly the dock and the desktop, and `kernel/wm.inc` is
`USER.EXE`.

## 2. What exists, measured

| | abstraction today | external surface |
|---|---|---|
| `dock.inc` (1,334 lines) | **`dkv`, 14 far slots**, whole table taken at `dkx_hook` | everything funnels through it (audited, SPEC.md §30.7.7) |
| `desk.inc` (2,364 lines) | **none at all** | ~20 symbols called directly from `wm.inc`, `ui.inc`, `instance.inc`, `ctrl.inc` |

`DESK.DRV` is a false friend: `kernel/deskmod.inc` is the **Sticky Apps desk
layer** (`OSAPI_WM_DESK`'s MAKE/DRAG/RELEASE, prefix `dkd_`), carved out
because a size pass left `.cold` on a rung boundary. It is not a seam.

**And the name is welded shut on both.** `kernel/mod.inc` holds
`mod_f_dock: db 'DOCK.DRV', 0` as a literal in `.text`, and `mod_tab` is a
fixed array of `dw 0, mod_f_<name>`. The dock is already swappable; what it
cannot do is be pointed at a *different file*.

## 3. The design

### 3.1 The `SH` record — one line, two slots

`SYSTEM.CFG` is already key/ver/len/data with a **length byte** (§51.5), so a
record can carry a filename and the container does not change. A new key:

```
'SH'  ver 1   len n   <dock shell name>,0 <desk shell name>,0
```

Either name empty means *the built-in*. The record absent entirely means the
same, so **every disk ever written stays valid** and this costs a machine
that does not use it one skipped key (§51.5 rule 1).

The two name buffers replace the literals in `mod.inc`. `mod_tab`'s row
already points at a buffer rather than inlining the text, so the row shape
does not change — only whether something may write into what it points at.

### 3.2 `dsv` — the desk's own table

The desk gets a vector table of its own, `dkv`'s shape and not shared with
it: `DSI_*` byte offsets, `jmp far [dsv + x]`, a slot at rest holding
`KERNEL_SEG:<basic body>`, and `mod_fp` entries 0 and 1 as hook and unhook.
The dock's measured mechanism is **42 guest cycles** and 112 bytes; the
desk's will be of that order and is wave 1's first measurement.

**The slot set is derived in wave 0, not guessed here.** The external surface
sorts the way the dock's did — operations, published state, and lifetime —
and only the first group becomes slots:

| group | examples |
|---|---|
| **operations → slots** | `desk_click`, `desk_select`, `desk_open`, `desk_reflow`, `desk_zone_rect`, `desk_caprect`, `desk_zone_redraw`, `desk_dmg_zones_x`, `desk_cmark`, `desk_rowcalc_x`, `desk_drop_x`, `desk_key_x` |
| **published state** | `desk_zslot`, `desk_sel`, `desk_zh1`, `desk_zdirty`, `desk_icons` |
| **lifetime** | `desk_init` |

### 3.3 The fallback rule, which is the safety property

**A named shell that will not load does not brick the machine.** Windows
3.1's famous failure is `shell=` pointing at something broken: you get a bare
screen and the only way back is booting DOS and editing `SYSTEM.INI`.

Here the rule is: **the hook is attempted, and the built-in stands if it
fails.** Absent file, bad header, refused `dkx_hook`/`dsx_hook` — each leaves
the basic bodies in the table and raises a toast naming the file. A machine
whose shell is missing boots to the stock dock and desktop and tells the user
why, and that is a property of the design rather than a recovery procedure.

The recovery procedure exists anyway and is the same one §79.11 relies on:
`SYSTEM.CFG` is readable from any other machine.

### 3.4 What a shell may NOT replace

The window manager (`wm.inc`), the menu bar, the clip region and damage
machinery, the file system, the loader. A shell owns the strip and the
background — Calmira's boundary exactly. **`kern_small` gets none of it**:
§30.5 already makes the dock's module `kern_big`'s alone, and the desk's
follows it.

## 4. What this does to the LaunchPad

**It makes LAUNCHPAD the first replacement shell rather than the new dock**,
and that is strictly better. `docs/plans/LAUNCHPAD-PLAN.md` and SPEC.md
§30.7 currently read as though the strip is being changed; under this plan
the stock strip stays, and the LaunchPad is a dock shell you point `SH` at.
You can go back by clearing one record.

It also gives the mechanism its first real customer, which is the test of
whether the abstraction is right: an abstraction with one implementation is
a guess.

## 5. Where the cost lands

| | |
|---|---|
| **DOCK** | near zero — it has the table. The name buffer and the `SH` reader are the whole of it |
| **DESK** | the table and its hook, ~112 bytes by the dock's measurement, plus the basic bodies staying where they are |
| **the two `cw_` doors already named** | §30.7.7.1: `cw_ss_start` and `cw_desk_zone_rect`, about eight bytes |
| **the `SH` reader** | `.cold` — it runs once at boot — plus two name buffers |

Against `kern_big`'s **3,584 spare**. The desk table is the only part that is
not small, and **it is the part a feature is paying for**: the dock's own
`dkv` was justified by placement and auto-hide, not by elegance, and this one
is justified by a shell the owner intends to run.

## 6. Staging

### Wave 0 — the contract — **DONE, 2026-11-01**
**SPEC.md §151**, in seven sections: the model and its boundary (§151.1), the
`SH` record and its three states (§151.2), `dkv` (§151.3), `dsv` with the
slot list DERIVED (§151.4), the fallback (§151.5), the cost (§151.6), and
why a second implementation is what proves the table (§151.7).

**The derivation corrected §2 of this plan.** Counting the desk's external
surface properly — comments stripped, and the three desk files (`desk.inc`,
`desksc.inc`, `deskmod.inc`) treated as ONE layer rather than as consumers of
each other — gives **thirteen operations, one lifetime entry and five state
words**. That is the dock's shape almost exactly. A first pass had said 84
symbols and "far more entangled than the dock", and it was wrong on both
counts: inflated by comment text naming routines that no longer exist (a
`.text` thunk removed in a size pass is still named in the comment recording
its removal), and by counting `desksc.inc`'s use of `desk.inc` as external.

### Wave 1 — `dsv`, with no shell to load
The desk's table, its basic bodies, `dsx_hook`/`dsx_unhook`, hooked by
nothing. **Gate:** every desk row still passes with the table in place and
every slot at rest — the kernel's own behaviour must be byte-identical, which
is the same bar `BAND=1` and the other A/B knobs are held to. **Measure** the
mechanism against the dock's 42 cycles.

### Wave 2 — the `SH` record and the name buffers
`SYSTEM.CFG` carries the two names; the boot reads them; `mod_tab` points at
the buffers. **Gate:** a machine with no `SH` behaves exactly as today, and a
machine with an `SH` naming a missing file boots to the stock shells with a
toast.

### Wave 3 — the LaunchPad as the first dock shell
`LAUNCHPAD.DRV` named by `SH`, the stock strip untouched behind it.

### Wave 4 — a desk shell, to prove `dsv` with two implementations
Until something other than the built-in answers `dsv`, the table is a guess.
The cheapest honest second implementation decides this wave's content.

### Wave 5 — the look, on all three adapters
§39.4 and §47, as every drawing wave here ends.

## 7. Open questions

1. **Does `dsv` need `DSI_*` at all, or does the desk want fewer, coarser
   slots?** The dock's fourteen mirror what the kernel calls; the desk's
   twenty might collapse. Wave 0 decides, and fewer is better.
2. **Two files or one?** A single shell image answering both tables is
   simpler to ship and harder to mix. The `SH` record has two slots either
   way; whether one file may fill both is a wave 2 decision.
3. **What a shell is allowed to claim.** `DOCK.DRV` is a pinned module claim;
   a third-party shell is a bigger one, and §2.8's drop rule
   (`tests/moddrop.txt`) applies to it exactly as to every other module.
4. **Does the stock dock stay in the kernel, or become a shell too?** Making
   it a shell is cleaner and costs a disk read at every boot; keeping it
   resident costs bytes and is what §30.5 already decided for the basic
   bodies. Keep it resident until something argues otherwise.
