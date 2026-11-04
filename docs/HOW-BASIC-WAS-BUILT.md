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

## Wave 0c — the editor, and the number wave 0 existed for

`apps/os88text.inc` (§83) is the program pane: a multi-line box with a caret
that moves between lines, a vertical scroll, and deliberately **no word wrap,
no selection and no undo** — its header is explicit that it is a cell note or
a comment field and *not* Note Pad. For a BASIC listing that is the right
trade: lines are short, and the one thing it must not do is reflow them.

Unlike the console it **declares no storage at all** — every routine takes
`SI` = a block the caller owns, so a window may have two. The block's rect is
`TX_X1..TX_Y2`, inclusive and in **screen** coordinates, which is `gfx_frame`'s
convention, "so the drawn control and the clickable control read the same four
words and cannot drift". Set every paint, for the console's reason.

**The dispatch contract is where the work was**, and `os88ui.inc` states it
plainly in a comment about something else entirely:

> entered with SI = BX = the window and a clip region ARMED over it
> (**nothing armed one for a click, a key or a menu pick**, §11.3)

So `W_PAINT` arrives with a clip and the other three do not. A key handler
that draws arms its own — and does not undo it, because the region dies at the
kernel's own `gfx_unlock`.

And `W_ONCLICK` carries a second rule in capitals: **give SI back as you got
it.** `ui_task` arms the mouse release to whatever `SI` holds *after* the
handler returns (§13.7), so a handler that comes back with `SI` pointing at a
text block has named that as the window. `bas_onclick` keeps the window in
`BP` across its body for exactly that reason.

**It works**: typing `print 42`, Enter, `end` puts two lines in the box with
the caret after the second, Enter being consumed as a newline — which is the
one place this control differs from `os88line.inc`, where Enter is the
caller's submit.

### The three numbers

This is what wave 0 was for. `APP_MAX_SIZE` is `0xFE00` = **65,024** bytes of
image plus bss in one segment.

| | image | bss | total | of budget |
|---|---:|---:|---:|---:|
| 0a the frame | 804 | 4 | 808 | 1.2% |
| 0b + the console | 4,638 | 4,817 | 9,455 | 14.5% |
| 0c + the editor | 5,868 | 6,885 | **12,753** | **19.6%** |

**The shell of the thing costs a fifth of the segment, and 52,271 bytes are
left for the language.** Out of that the numerics still have to come —
`os88fp.inc` is pay-as-you-go but SHEET measured a double at about 2,800 bytes
of code — so call it **~49KB for the lexer, the parser, the compiler, the op
interpreter, the string heap and sixty-four built-ins**.

That is the arithmetic §126.6's overlay split was asserted on before anyone had
measured it, and it holds: it does not fit, and the split is not optional. What
the numbers add is *where* to cut. The resident side has to carry the window,
the editor, the console, the lexer and the op interpreter — the inner loop and
everything a keystroke touches — and that looks like 25–30KB. The parser, the
compiler, the double formatter, `PRINT USING` and the built-in library go to
`BASIC.OVL`, which gets a segment of its own.

## Wave 1a — it is a language now

Scanner, compiler and interpreter, in `apps/basic/baslang.inc`: `PRINT` of an
integer expression with `+ - *` and `\`, parentheses, unary minus, `REM`, `'`
and `END`. The compiler emits **postfix into a flat op stream** and the
interpreter is a stack machine, which is §126.5's shape and the reason for it —
on an 8086 the inner loop is one dispatch where a tree walk would be a
recursive descent through far pointers at run time.

**Cost: 1,386 bytes of image** over wave 0c. Running total **14,701 of 65,024,
22.6%**.

**`/` is refused by name and `\` is not.** BASIC's `/` is floating-point
division even between two integers, so an integer `/` here would be a wrong
answer wearing a right one's clothes. `\` is integer division in every BASIC
of this line and is exactly what this wave can do.

### The oracle earned its keep before the thing ever booted

Running the test program through the reference implementation first gave two
corrections that would otherwise have shipped:

- **`PRINT 1000*1000` is `1000000`.** The reference widens past 16 bits, where
  a 16-bit multiply would have silently answered 16960. So overflow is
  **refused by name** — `imul` sets `OF` exactly when the upper half is not the
  sign extension, so the test is free — and the message says the wider
  arithmetic arrives in wave 1c.
- **A number prints with a trailing space as well as a leading one.**
  QuickBASIC separates numbers that way; ` 42 ` is what the reference emits,
  trailing space and all.

### And two defects that only running it found

**`.mul` fell through into `.idiv`.** Adding the overflow check replaced a
block that had ended `jmp .store`, and the replacement dropped it. So
`2+3*4` computed `3*4 = 12`, fell into the divide and made it `12\4 = 3`, and
answered **5**. It assembled; it ran; only the number was wrong. This is the
repository's own recorded lesson about cutting an instruction and leaving the
fall-through, met from the other side.

**The op stream was never terminated.** `bas_opn` resets per statement but
`bas_ops` keeps its bytes, so execution ran on into whatever the previous line
had left — invisible while the array was still zeroed bss, and then an
underflow blamed on the wrong line as soon as a second statement was shorter
than the first. Both symptoms, one missing `OP_END`.

**How it was found** is worth keeping: staring at the source produced three
wrong theories. One temporary line — printing the compiled op *count* beside
the answer — gave `13 | 5`, which says the compiler emitted all thirteen bytes
correctly and the interpreter is at fault, and that halved the search in one
run. It is behind `%ifdef BAS_DIAG` now.

**Verified against the oracle**, on the glass:

| | guest | reference |
|---|---|---|
| `print 2+3*4` | ` 14 ` | ` 14 ` |
| `print 7\2` | ` 3 ` | ` 3 ` |
| `print -5` | `-5 ` | `-5 ` |
| `print 1000*1000` | refused, line 4 | ` 1000000 ` |

## Wave 1b — a BASIC program calls the operating system

Tier C, the whole of it: one verb and one small array.

```basic
OSAPI slot [, ax [, bx [, cx [, dx [, si [, di]]]]]]
REG(0..7)        ' AX BX CX DX SI DI ES CF, after the call
```

GFA needed six trap verbs and eight parameter arrays because filling arrays
and trapping *is* the AES/VDI calling convention. This OS passes in registers
over one flat space of 194 slots, so the whole thing collapses to this — which
is `BASIC-BINDINGS-PLAN.md` §2's claim, now built and measured.

**The enabling fact** is that `KERNEL_SEG equ 0x0060` is fixed at build time,
so a *dynamic* slot number is reachable by an indirect far call through a
constructed pointer. That is one instruction, and it is the one instruction
worth checking rather than trusting: `call far [bas_fp]` assembles to
`FF 1E ...`, whose ModRM reg field is 3 — `FF /3`, a far indirect call. Had
NASM taken it as `FF /2` it would have been a *near* call to a kernel offset
inside our own segment, which assembles cleanly and crashes.

**`REG(7)` is the carry flag and it is why the array exists.** Failure on this
OS is CF, uniformly, so it is captured with `pushf` as the very first
instruction after the call — before anything can disturb it — and published as
0 or 1. A binding layer that dropped it would turn every refused call into a
silently wrong answer.

**`SI` and `DI` are the interpreter's own** op-stream cursor and value-stack
pointer, so both are saved across the call. The API cell preserves everything
it does not document, but it cannot preserve what we hand it on purpose.

**Measured: 480 bytes of image.** The plan guessed "perhaps two hundred", so
it is more than twice the estimate — the difference is `REG()` and the
variadic argument parsing, neither of which the guess accounted for. Running
total **15,201 of 65,024, 23.4%**.

**Proved on the glass, three ways**, because one reading proves nothing:

```
 2424     GET_TICKS - a LATER tick than an earlier run's 1252, so the call
 2424     reaches the kernel's counter rather than returning a constant
 0        CF, clear
13267     SRAND 1234, then RAND
12584     RAND again - DIFFERENT, so each call really executes
```

The seed reaching the kernel proves inputs travel; two different draws prove
the second call is not a cached first; and a tick count that advances between
runs proves the whole thing is not a constant. Any one of those alone would
have been consistent with a gateway that never fired.

## Next

Wave 1c: **the numerics** — the `OSAPI` gateway, which is
perhaps two hundred bytes and from which every kernel facility becomes
reachable by hand. `BASIC-BINDINGS-PLAN.md` §7 is the order and the reason.
