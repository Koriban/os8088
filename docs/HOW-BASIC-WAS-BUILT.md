# How BASIC was built

The diary for SPEC.md §126 and `docs/plans/BASIC-PLAN.md`. Written as the work
happens, for later reuse: decisions, constraints, discoveries, pictures and
measured results, with observations kept apart from intentions.

## Before wave 0: four documents and no code

The language exists already. BASIC/nw is a complete QuickBASIC-4.5-line
implementation in TypeScript — lexer, parser, analyser, compiler, interpreter,
64 built-ins, five types, 370 passing tests — written to be a **plot device**
in a game, where the fiction was a sealed machine the player could not escape.
Pulling it out of that game and into `~/Src/Prj_8086/basicnw/` came first, and
the audit of what the fiction had cost it came with it: 43 real QuickBASIC
spellings refused, of which **26 defend nothing this OS lacks**.

Then the owner set the target: **GFA-BASIC on the Atari ST**. Not a BASIC that
runs — a BASIC that OS/8088 applications are written in, GUI or text. That one
sentence reordered everything, because GFA's value was never its keyword count
but its three tiers of access to the machine, and a binding project that builds
those in the wrong order stalls.

Four documents came out of it before any code: SPEC.md §126 (the contract, 14
subsections), `BASIC-PLAN.md` (the language), `BASIC-BINDINGS-PLAN.md` (tiers
B and C — the OS/8088 answer to GEM's call layer), `BASIC-GUI-PLAN.md` (tier A,
the keywords) and `BASIC-PORTING-NOTES.md` (what GFA source needs changed).

Three things in them are worth repeating here because they were not obvious
going in.

**The C route is closed, and not on taste.** §73 exists for exactly this kind
of program — "slower and larger in exchange for being writable" — but SmallerC
has no `long`, no `float` and no `double`, so **three of BASIC's five types
cannot be expressed at all**; `nasm -f bin` refuses an external reference, so
there is no second translation unit; and the measured ceiling is ~9,700 lines.
Assembly it is.

**Most of the machine already exists.** `apps/os88con.inc` is an 80×25 console
of character/attribute pairs with a CP437 face, already used by Telnet — so
BASIC's entire screen half is written. `os88text.inc` is the editor and
`os88fp.inc` the arithmetic, with an 8087 path gated per call.

**`VDISYS` is not a system call.** It is GEM's ABI with a BASIC keyword in
front of it, and GFA needed six trap verbs and eight parameter arrays because
GEM and TOS have six trap interfaces. None of that survives, and the news is
good: this OS passes in registers over one flat space of 194 slots, so the
whole of tier C collapses to one verb. **Tier C gets smaller, not larger.**

## Wave 0 — the seam

**What it is for.** §126.6 splits the interpreter across `BASIC.O88` and
`BASIC.OVL` on the arithmetic that it cannot fit beside sixty-four built-ins,
an editor and a console in one 63.5KB segment. That arithmetic is worth nothing
until the empty frame has been measured, so wave 0 builds the frame and
measures it: the window, two panes, the menu bar, the command path, and no
language at all.

**Measured: 804 bytes of image, 4 of bss.** `APP_MAX_SIZE` is `0xFE00`
(65,024), so the frame costs 1.2% of the budget before anything of the language
exists. `make basic` prints it.

**Three defects, and only one of them was found by a tool.**

The first was found by *reading what I had just written*: `bas_paint` pushed
`SI` then `DI`, and then used `pop si` to recover the window pointer — which
pops the caller's `DI`. It assembled perfectly. The fix was to hold the window
pointer in `BP` for the paint's duration, which is safe as a plain register
hold even though `SS ≠ DS` here, because only `[bp+disp]` addresses the stack
segment.

The second was a **comment that described code I had not written**. The bss
word holding the status-line pointer is loader-zeroed, and the window is shown
before any command can run, so the first paint draws through a null — and the
source carried a confident comment saying `bas_paint` read a zero as "Ready".
It did not. Writing the sentence had felt like implementing it.

The third is the one that matters, because **nothing but looking would ever
have found it**:

> `OSAPI_GFX_FRAME` draws in `[gfx_color]`, which is global state and not an
> argument. `bas_repaint` sets it to `CWHITE` for its fill, and `bas_paint`
> then drew both pane frames without setting it back.

The package assembled, packaged, loaded, opened a window, drew its menu bar and
both captions and its status line — and had no panes in it. White frames on a
white fill. A values-only check would have passed it; the picture is the only
thing that says otherwise, which is CLAUDE.md's point about chrome in one
screenshot.

**What it looks like.** The window opens with its menu bar reading
chip / BASIC / File / Run, a framed **Program** pane above and a framed
**Output** pane below reading `Ready` — the status line's null-guard path, on
the glass. Picking Run → Run writes

```
No interpreter yet - wave 0 is the seam (SPEC.md 126)
```

into the output pane, which is the smallest thing that proves a menu pick
reaching a handler reaching a repaint without pretending to be an interpreter.

**Registered as `building`.** `apps/RETIRED.txt` carries the line, because
CLAUDE.md's invariant is that everything in `apps/` ships and this must not —
a program on a disk that cannot run a program is worse than its absence. The
line is a deadline in PLAN's sense: it comes out when wave 2 lands and the
thing can evaluate an expression and `PRINT` it.

The first attempt exempted it in `tests/unit/t_livefull.py`'s `LOCAL_EXEMPT`
instead, which `t_retired.py` immediately failed — correctly. That file's own
comment says the registry is reached *through* `apps/RETIRED.txt` rather than
through a second copy of the list, and two lists is exactly what I had made.

## Wave 0b — the console pane is real

`apps/os88con.inc` (§70.8) became the output pane. It is an 80x25 buffer of
(character, IBM attribute) pairs in text VRAM's own layout, with a dirty-row
bitmap and a composer that writes eight bytes a cell and calls nothing, and
`%define CON_TTY` adds the teletype half — `con_write`, `con_say`, `con_open` —
whose LF scrolls and whose CR does not move the row, because that is the ROM's
behaviour and not ANSI's NEL. That teletype is what `PRINT` is going to be.

**Measured: 4,638 bytes of image and 4,817 of bss**, against wave 0a's 804 and
4. So the console costs about 3.8KB of code and 4.8KB of storage — the 4,000
of it is the cell buffer, which is fixed and does not reflow. Running total:
**9,455 of 65,024, or 14.5% of the budget**, with no language in it yet.

**The include's own header pre-announced the trap I would otherwise have hit.**
Until `con_font` runs, the glyph table's ASCII 32..127 is a blank hole, so a
console whose carrier forgot it *holds all the right characters and draws every
letter as nothing* — the buffer reads perfectly and the screen is empty. The
file says so, in capitals, and says that a carrier calling `con_open` gets the
face for free and cannot forget. I called `con_open`.

Two defects it did not pre-announce, both found by looking.

**`con_vtop` is not zero, and that is the contract's one real trap.** `con_row`
tests `cmp bx, [con_vtop] / jb .done` and has **no lower bound at all**, so
`[con_vrows]` does not bound the drawing — a `con_vtop` of 0 draws all
twenty-five rows whatever the pane is, over the frame, over the window's own
bottom edge and onto the desktop. Which is exactly what it did. The answer is
in `telnet.asm`: `con_vtop = CON_ROWS - vrows`, so a short window is a viewport
onto the **bottom** of the buffer, which is what a teletype wants.

**And fixing it made the pane go blank, which was the fix working.** With the
viewport on rows 17..24 and `con_open` parking the cursor at (0,0), a fresh
console writes its first lines where nobody is looking, and the pane stays
black until eighteen lines have scrolled past. So `bas_conreset` opens the
console and then puts the cursor on the first *visible* row. Everything after
that is the teletype's own business.

**What it looks like.** Three banner lines on open, and each Run or Stop
appends one more, scrolling:

```
BASIC for os8088 - SPEC.md 126
Wave 0b: the console pane is real.
Ready
No interpreter yet - wave 0 is the seam.
Nothing to stop.
No interpreter yet - wave 0 is the seam.
```

## Next

Wave 0c is `os88text.inc` (§83) as the editor, measured as it lands, because
the three numbers together are what §126.6's overlay seam is cut against.
