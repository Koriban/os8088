# BASIC's system bindings — the OS/8088 answer to GEM's call layer

**Status: planned 2026-11-04. Nothing built.** Branch `basic-o88`. This is
the tier B and tier C half of `BASIC-PLAN.md`; SPEC §126 is the contract.

## 1. The problem, stated precisely

GFA-BASIC reached the Atari's operating system through six verbs — `GEMSYS`,
`VDISYS`, `BIOS`, `XBIOS`, `GEMDOS`, `LINE-A` — plus eight parameter arrays,
`CONTRL GINTIN GINTOUT ADDRIN ADDROUT PTSIN PTSOUT WORK_OUT`.

**None of that is a general idea about operating systems.** There are six verbs
because GEM and TOS have six trap interfaces. There are eight arrays because
*filling arrays and trapping* is literally the AES/VDI calling convention:
`VDISYS [opcode [,c_int,c_pts [,subopc]]]` sets `CONTRL[0]`, the counts, and
traps. `VDISYS` is not a system call, it is GEM's ABI with a BASIC keyword in
front of it.

Copying the vocabulary would import an ABI this OS does not have. The task is
to find what each of those constructs was *for*, and answer that need in this
OS's own terms — which turn out to be simpler in every case but one.

## 2. What is accident and what is substance

| GEM construct | why it existed | here |
| --- | --- | --- |
| six trap verbs | six separate interfaces, each with its own trap number | **one**: a flat space of 194 slots, no AES/VDI split |
| `CONTRL`/`GINTIN`/`GINTOUT`/`ADDRIN`/`ADDROUT`/`PTSIN`/`PTSOUT`/`WORK_OUT` | the arrays *are* the argument-passing mechanism | **none**: arguments go in registers |
| `opcode`, `subopc` | selects the call within an interface | the slot number is the selector |
| `c_int`, `c_pts` | the callee cannot know how many arguments you put in an array | **nothing to count**: a register either carries an argument or does not |
| `GRAF_HANDLE`, `APPL_INIT`/`APPL_EXIT`, `V_OPNVWK`/`V_OPNWK` | you must open the libraries and get a workstation handle before drawing | **nothing, and nothing needed**: a package is already a running package and a window already has a surface |
| `WIND_UPDATE` + walking a rectangle list | GEM hands you visible rectangles to clip against, one at a time | **`WM_CLIP_SET` 0x013D**, one call, `CF=1` when not one pixel is visible |
| `EVNT_MULTI` | one call that waits for any of several event classes | the `W_*` message dispatch the window manager already does |
| no error convention | each call reports differently | **`CF`**: the OS's uniform failure channel, and a thing GEM had no equivalent of |
| `.RSC` files, object trees, `FORM_DO`, `OBJC_*`, `TEDINFO`, `ICONBLK` | dialogs are data, loaded from a resource file and walked by the AES | **the one real gap — see §6** |

Of GFA's roughly 150 AES/VDI binding keywords, the great majority answer a need
that either does not arise here or is answered by a single existing slot. That
is the finding this plan rests on: **tier C gets smaller, not larger.**

## 3. Tier C — the gateway

One verb, named for what the kernel calls its own calls, so the BASIC word and
the SPEC word match:

```
OSAPI slot                       ' registers taken from and left in REG()
OSAPI slot, a [, b [, c [, d]]]  ' convenience: fills the slot's own registers
x% = OSAPI(slot [, a ...])       ' function form; the result is AX
```

and a register file as an array, which is the one piece of GFA's design worth
keeping, because it is what makes the gateway total rather than merely
convenient:

```
REG(R_AX) REG(R_BX) REG(R_CX) REG(R_DX) REG(R_SI) REG(R_DI) REG(R_ES) REG(R_CF)
```

`REG()` is `GINTIN`/`GINTOUT` collapsed into one array, in the same spirit:
written before the call, read after it. Three notes on it.

**`REG(R_CF)` has no GEM counterpart and is the important one.** Failure in
this OS is the carry flag, uniformly. A binding layer that drops it would turn
every refused call into a silently wrong answer, which is the single worst
thing this layer could do.

**The convenience form is only possible because the arity is tiny.** Measured
across all 194 slots: 76 take one input register, 50 take two, 7 take three, 6
take four, and the rest take none. **Four is the maximum in the whole API**, so
a positional form covers everything without becoming a parameter soup.

**Pointers need a pinning construct, which GFA did not need.** 34 of the 194
slots take a buffer or a pointer — `OSAPI_FILE_READ` wants `ES:BX`,
`OSAPI_FILE_PATH` wants `ES:DI` and a size. On a flat 68000 with no compaction,
`VARPTR` was enough. Here a BASIC string is a handle into a claim that can
move, so an address handed over as a number is a bug waiting for the next
compaction. The gateway therefore takes the *object*, not its address, and
pins it for exactly the duration of the call:

```
OSAPI OSAPI_FILE_PATH, @buf$, LEN(buf$)
```

`@` is the pin-and-pass operator. `VARPTR` may still exist for reading an
address, but it is not how a buffer reaches a kernel call, and the distinction
is worth keeping sharp: `VARPTR` returns a number that was true once, `@`
passes a pointer that is true for the length of one call.

## 4. Tier B — one word per slot, generated

`OSAPI_WM_CREATE` becomes `WM_CREATE`: the prefix drops, nothing else changes,
and a reader of SPEC can find the BASIC word and a reader of the BASIC program
can find the SPEC section. GFA's `WIND_CREATE` by a different route.

**It is generated, and the numbers say that is realistic.** `apps/os88api.inc`
already carries each slot's register contract as a trailing comment, in a
convention consistent enough to parse:

```nasm
%define OSAPI_GFX_PIXEL     KERNEL_SEG:0x0020   ; CX=x, DX=y
%define OSAPI_GFX_FILL      KERNEL_SEG:0x0038   ; AX=x1, BX=y1, CX=x2, DX=y2
%define OSAPI_WM_CREATE     KERNEL_SEG:0x0076   ; SI=template; out BX = win ptr, CF on full
```

Measured, all 194 slots:

| | |
| --- | --- |
| have a trailing comment | **194 of 194** |
| comment names its input registers, parseably | **139** |
| comment says in so many words that there are none | 2 |
| neither | **53** |

The 53 are not 53 hard cases. Reading them, they fall into three groups:

- **about twenty take no inputs at all** — `GFX_LOCK`, `GFX_UNLOCK`,
  `TASK_YIELD`, `GET_TICKS`, `RAND`, `MOUSE`, `CLK_GET`, `VIDEO`. The comment
  describes the effect instead of saying "no inputs", so a parser that reads
  *no `REG=` before `out`* as **none** rather than as **unknown** collects them
  for free;
- **a handful use the other arrow** — `SET_COLOR` is `AL -> [gfx_color]`,
  `SRAND` is `AX -> [osapi_seed]`. One more pattern in the parser;
- **roughly twenty-eight are genuinely multi-verb** — `SND_PLAY`, `SND_FM`,
  `SND_STREAM`, `FSX_SPK`, `FILE_COPY`, `VOL_STAT`, where a register's meaning
  depends on a verb selector and the contract runs to paragraphs.

So **about 166 of 194 bind mechanically**, and the remaining ~28 get
hand-written descriptors. That is the whole of the curation debt, it is
enumerable today, and it is small enough to finish.

**Reuse the existing parser, do not write a second one.** `tools/os88index.py`
already reads `os88api.inc` and already joins continuation-comment lines
(`tools/os88index.py:407`). A second parser of the same comments would
eventually disagree with the first, and this project has paid for that class of
defect before. The slot reader becomes shared, and both the index and the
bindings are generated from it.

**The gate is the point of generating at all.** The generator must **fail the
build** when a slot has neither a parseable contract nor a descriptor. A kernel
slot added without a BASIC binding is then a build error rather than a silent
absence, which is the only way a 194-entry table stays true for longer than a
month. `make checkdocs` already enforces exactly this shape of invariant for
`docs/INDEX.md`, so the precedent and the habit both exist.

## 5. Tier A — the verbs people actually write

Hand-written, over tier B, and short enough to memorise. **The keyword set,
the event model and the paint discipline are designed in
`docs/plans/BASIC-GUI-PLAN.md`** — this section only states where tier A sits.
The window, menu and alert verbs map onto `WM_*`, `MENU_SET` and the standard
alert almost directly; `BASIC-PLAN.md` §0.4 has that correspondence.

Two things in tier A are **not** mappings and must be designed:

**The menu array.** `MENU m$()` assigns meaning by position, and positions 3
through 8 are six reserved slots for *desk accessories* — a GEM concept with
nothing behind it here, and **with GFA source compatibility ruled out as a
requirement (SPEC §126) this is no longer a decision: they go.** Six reserved
strings exist so that an operating system can fill them; this one fills
nothing there, and keeping them would be keeping GEM's mechanism without GEM's
purpose — which is what §8 below forbids.

**`OSAPI_MENU_SET` caps the bar at five menus**, which SHEET and Word both
outgrew by drawing their own in-window bars. Tier A's `MENU` either accepts the
cap or replicates that pattern.

## 6. The one real gap: dialogs

Everything else in this plan shrinks. This does not.

A GEM dialog is **data**: a tree of objects in a `.RSC` file, loaded with
`RSRC_LOAD`, located with `RSRC_GADDR`, drawn with `OBJC_DRAW` and run with
`FORM_DO`, which owns the interaction loop and returns the object the user
pressed. About forty of GFA's keywords serve that model, and `TEDINFO`,
`ICONBLK`, `BITBLK` and `PARMBLK` are its record layouts.

OS/8088 has no resource file and no object tree. `apps/os88ui.inc` (§13, §75)
provides buttons, check boxes, radio dots, scroll bars, group boxes, a standard
alert, an About card and a drop-down — each **built in code** and opted into
with a `%define`, which is a compile-time decision a BASIC program cannot make.

So there is a real choice here, and it is the one piece of design this plan
cannot shortcut:

1. **Dialog as calls.** BASIC verbs that build a dialog imperatively and run
   it, over whatever `os88ui.inc` widgets the interpreter links in once.
   Honest, simple, no new file format; but every BASIC dialog costs resident
   bytes in the interpreter rather than in the program, and nothing GFA-shaped
   ports.
2. **Dialog as data, defined in BASIC.** A `DIALOG`/`END DIALOG` block that the
   compiler turns into a table the interpreter walks — the object tree
   reinvented, in the language instead of in a file. Closest to `FORM_DO` in
   feel; costs a layout engine.
3. **A resource format.** The heaviest, and it buys a thing nobody has asked
   for: dialogs editable without the program.

**Decided: 1, with 2 kept possible.** A dialog built by calls can be wrapped
in a `DIALOG` block later without changing the widgets underneath, whereas
starting at 2 means designing a layout engine before anything can show a
button. `DIALOG` is reserved from the start and means nothing yet, so the block
can arrive without breaking a program; the call API is `DLG` with the verb
after it. SPEC §126.12 is the contract and `BASIC-GUI-PLAN.md` §6 the summary.

**`FORM_DO` must not acquire a counterpart that pretends to be it** — a verb
that looks like `FORM_DO` and takes a tree this OS cannot represent would be
worse than its absence.

## 7. Waves

Numbered to sit inside `BASIC-PLAN.md`'s own ordering.

**B0 — the shared slot reader.** Lift `os88api.inc` parsing out of
`tools/os88index.py` into a module both it and the binding generator import.
`make checkdocs` must still pass unchanged, byte for byte, which is the proof
the lift changed nothing.

**B1 — `OSAPI`, `REG()` and `@`** (with `BASIC-PLAN.md` wave 1). The gateway,
the register file, the carry flag, and pin-and-pass. Perhaps two hundred bytes,
and from here every kernel facility is reachable by hand.

**B2 — the generator and its gate.** Parse, classify, emit the tier B table and
a generated reference page; fail the build on a slot with no contract and no
descriptor. Exit: the ~28 descriptors written, 194 of 194 covered.

**B3 — tier A windows, menus and alerts** (with `BASIC-PLAN.md` wave 4).

**B4 — dialogs**, by §6's decision.

**B5 — tier A graphics** (with `BASIC-PLAN.md` wave 6).

## 8. What must not happen

- **A second parser of `os88api.inc`.** Two readers of one comment convention
  drift, and the drift shows up as a binding that passes the wrong register.
- **A binding table maintained by hand.** 194 entries, a kernel that gains
  slots, and no gate is a table that is wrong within a month.
- **A `VARPTR` that reaches a kernel call.** An address held across anything
  that can compact is a bug with a long fuse; `@` exists so that the safe thing
  is also the short thing.
- **Dropping `CF`.** A refused call that reports success is the worst defect
  this layer can have, and it would be invisible in every test that only checks
  values.
- **A fake `FORM_DO`.** See §6.
- **GEM's vocabulary for this OS's concepts.** `VDISYS` names GEM's ABI. There
  is no virtual workstation to open here, no rectangle list to walk and no
  `opcode` to select — and a binding layer that keeps those words would teach
  every reader of a BASIC program something false about the machine underneath.
