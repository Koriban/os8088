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

## Wave 1c — the numerics, and a gap that was never there

The value stack holds **doubles** now, not 16-bit words, on `apps/os88fp.inc`
(§84). `/` works, `3.14159` is a literal, and wave 1a's two refusals — `/`
itself and the integer-overflow one — are gone because the thing they stood in
for has arrived.

A literal is converted **once, by `fp_atof` at compile time**, and the eight
bytes ride in the op stream. Keeping the text and converting on every
execution would have put a decimal parse inside every `FOR` loop.

**Cost: 4,050 bytes of image**, in line with SHEET's measured ~2,800 for a
double plus `fp_ftoa`'s 454. Running total **19,453 of 65,024, 29.9%**
(11,784 image + 7,669 bss).

This line read **19,421** until the audit below re-measured it: the bss half
was hand-summed as 7,637 and `bas_fpbuf`'s 32 bytes were left out of it. The
figure to quote is `os88pkg`'s own, off the built `.o88`, which is where
every number above came from and where this one did not.

### Gap 1 did not exist

`BASIC-PLAN.md` listed "double ↔ text" as one of three real gaps, said the
only pair in the tree was private to `apps/sheet/sheet.asm`, and planned a
wave around extracting it. **That was wrong.** `fp_atof` and `fp_ftoa` are in
`apps/os88fp.inc` itself, at lines 2004 and 2223, with better contracts than
anything that extraction would have produced — `fp_atof` accumulates digits
into a 64-bit integer and converts once, so `0.1` comes back as the nearest
double to 0.1 rather than the nearest double to nine rounded multiplications.

What SHEET holds is `sh_x_fp_atof` and `sh_x_fp_ftoa`: two overlay *thunks*.
The grep behind the original claim searched for
`fp_fmt|fp_tostr|fp_str|fp_parse|fp_fromstr`, matched SHEET's thunk names and
nothing in the include — because the routines are called **ftoa** and **atof**.
*A name you did not think of reads as a thing that is not there.* The plan and
§126 are corrected.

### Two defects, one caught by reading and one by running

**`rep movsb` would have written into the kernel.** Pushing a literal copies
eight bytes from the op stream to the value stack, and the obvious instruction
is a string move — which writes to **ES:DI**, and `ES` is `KERNEL_SEG` on
entry to any callback. Four `mov`s by hand instead, both halves DS-relative.
Caught before running, by the one rule in `apps/os88api.inc` worth keeping in
the front of your mind.

**The formatter overwrote its own scratch.** `bas_sayfp` passed `DI = fp_dig`
as `fp_ftoa`'s output buffer — and `fp_dig` is `fp_ftoa`'s *internal* digit
string, which `apps/fptest` labels in as many words. The integer part came out
right and every fractional digit came out as a full stop: `3.5` printed as
`3..` and `3.14159` as `3......`. §84.3 says the caller declares the scratch,
and I declared it correctly and then also used one of its fields as mine.

### Matched against the oracle, on the glass

| | guest | reference |
|---|---|---|
| `print 7/2` | ` 3.5 ` | ` 3.5 ` |
| `print 1/3` | ` .3333333 ` | ` .3333333 ` |
| `print 2+3*4` | ` 14 ` | ` 14 ` |
| `print 1000*1000` | ` 1000000 ` | ` 1000000 ` |
| `print 3.14159` | ` 3.14159 ` | ` 3.14159 ` |

Two formatting rules came from reading the reference rather than guessing:
**seven significant digits**, because a bare literal is a SINGLE and SINGLE
arithmetic stays SINGLE; and **no leading zero** — BASIC prints `.3333333`,
not `0.3333333`, which `fp_ftoa` does not know and `bas_sayfp` trims.

One simplification stated rather than hidden: this computes in double and
prints seven digits, where §126.4 requires a SINGLE to **narrow to 32 bits on
every store**. There is no store yet — wave 1c has no variables — so the two
agree on every value a program can currently produce. The narrowing is owed
when `!` variables arrive.

## The audit, 2026-11-04

Before wave 2, a read of everything written so far. The headline is one
defect that produced **silently wrong numbers**, and the reason it survived
four waves is worth more than the fix.

### The value stack was paying for words after it held doubles

`BAS_BSS_OWN` — the number `OS88_BSS` reserves — was a hand-written sum, one
term per field of a chain laid out thirty lines below it. One term read
`BAS_STK_MAX*2`. Wave 1c widened an evaluation-stack slot from a word to the
eight bytes a double needs, moved `BAS_SLOT` to 8, and changed `bas_exec`'s
own bound check to `BAS_STK_MAX*BAS_SLOT` — and did not change the sum or the
`bas_numbuf equ bas_stk + BAS_STK_MAX*2` beneath it. So the stack **reserved
four slots and the interpreter permitted sixteen**, because the check counted
in slots and the reservation counted in words.

The fifth slot was `bas_numbuf`, the sixth `bas_reg`, the seventh `bas_fp`
and os88fp.inc's register-A scratch — `fp_as`, `fp_ae`, the mantissa words
that every arithmetic op reads.

**It takes a right-nested expression to reach them.** `1+2*3*4` holds only
three operands: `+` and `*` are left-associative here and the interpreter
folds each pair the moment it has both. `1+(2+(3+(4+5)))` holds five, and
`1+(2+(3+(4+(5+(6+(7+8))))))` holds eight. The A/B, same kernel, same disk
layout, the same thirty-three keystrokes typed into the editor:

| build | `PRINT 1+(2+(3+(4+(5+(6+(7+8))))))` |
| --- | --- |
| with the fix | ` 36` |
| the layout as it shipped | `-2.668453E+307` |

A wrong answer that looks like an answer, which is the one thing §126.7's
discipline exists to prevent, in the layer that discipline is about.

**The fix is not the `*BAS_SLOT`.** The chain is laid out twice now: once as
pure constants (`BAS_B_*`) from which `BAS_BSS_OWN` is **derived**, and once
as the labels, each `os88_image_end + its constant`. A derived total cannot
drift from the fields it pays for, where an assertion only reports that it
has — and the old sum was *also* 10 bytes too **large** in two other terms,
which is exactly the slack that let a 96-byte shortfall assemble and run.

### A false premise I nearly left in the fix

The house idiom for an unchecked `OS88_BSS` literal is two `times` lines that
go negative on a mismatch. I wrote them, and they fired on this very
shortfall. Then the build broke with `label changed during code generation`
against innocent labels at the end of another file, five bytes adrift. I
concluded the idiom could not be used here, because `os88_image_end` is a
label that moves between nasm's passes; and then that the constants chain had
to sit after the includes rather than beside `BAS_PROG_MAX`, because a
49-deep chain of forward `equ`s needs a nasm pass per level. Both were
plausible, both went into the source comment as fact, and **both are false** —
tested afterwards, the `times` pair assembles clean and the chain assembles
in either position.

The real cause was one line of my own. The cut that removed `bas_number` was
bounded by the next *comment header* instead of the next proc, and took the
live `bas_word` with it. nasm said so plainly — `error: symbol 'bas_word' not
defined` — in the **first** line of its output, under 105 convergence
warnings, and I was reading `tail -6`. An undefined symbol makes nasm size
the call differently per pass, which is what the convergence complaint had
been reporting all along.

Two lessons, and the second is the one that cost the round. Bound a deletion
by the thing that follows it, not by the next header that looks like a
boundary. And when a build emits a hundred warnings, `tail` is the wrong end
of it: the error that matters is usually the first. Writing a cause into a
comment before testing it is how this file got `[bas_status]`.

### A keystroke drew the editor over the About card

`bas_onclick` lets the card take a click. `bas_onkey` had no such test and
drew the text box straight over it. The card now takes the keystroke too.

### What was dead, and what was a lie

`bas_number` (42 lines, superseded by `fp_atof` at wave 1c), `bas_emitw`,
`bas_e_slash`, `bas_e_over` with the `.over` label that was its only caller,
and `bas_s_norun` — **256 bytes of image**, none of it reachable.

The text was worse than the code. The **About card** still read *"SPEC.md 126
— wave 0, the seam"* and the **startup banner** *"Wave 0b: the console pane
is real"*, four waves after both stopped being true, on the two surfaces a
user actually reads. `baslang.inc`'s header stated *"`/` IS REFUSED BY NAME"*
beside an `OP_DIV` that implements it, and *"PRINT of an INTEGER
expression"* over a file that had held doubles since 1c. `bas_oncmd`'s `.run`
was commented *"wave 0 has no interpreter, and says so rather than
pretending"* directly above `call bas_run`. And a comment on the bss chain
explained how `[bas_status]` is zeroed by the loader and read by `bas_paint`:
**there has never been a `bas_status`**, in any wave. Nothing but the comment
said there was, which is how it lasted.

The banner's wave line was deleted rather than corrected. It is a line that
has to be edited every wave, and it was not.

### Three claims the documents made and the code did not

- **The indexed jump.** §126.5, `BASIC-PLAN.md` and `baslang.inc`'s own
  header all promised `jmp [table + bx]`. `bas_exec` has always been a
  compare chain — twelve ops, the five binary ones grouped behind the
  operand-unpack prologue they share, which is also what makes the table
  awkward rather than obvious. Honest at twelve, and `OP_ADD`/`OP_MUL`, which
  every expression runs, sit at the back behind seven compares. All three now
  say so, and §126.5 owes the table to wave 2.
- **`BASIC.OVL`.** §126.6 described the split in the present tense. There is
  no overlay; the package is 19,283 of 65,024 and the wall is not in sight.
  The section now says what it fixes is *where* the cut goes.
- **"Fills the slot's own registers."** `BASIC-BINDINGS-PLAN.md` §3 said the
  convenience form of `OSAPI` does that. It fills `AX, BX, CX, DX, SI, DI`
  positionally — `bas_c_stmt`'s own comment says so correctly — so
  `OSAPI_GFX_HLINE`, which takes `AX, BX, **DX**`, gets `y` in CX and draws
  at whatever `DX` held. Served correctly for slots that use the registers in
  order, wrong for the rest: the shape of defect that looks like it works.
  The plan now documents the real rule and owes the per-slot list to tier B.

One finding was **retracted**. §126.8's *"one verb taking a slot number"*
looked like a divergence from a gateway that far-calls a raw offset, until
§20.1 settled it: *a slot is a pinned address*, and this project calls
`0x0068` a slot number. The code matches the contract.

### What the audit could not lean on, and the half of it now closed

**BASIC had no test rows at all.** It is `building` in `apps/RETIRED.txt`,
which exempts it from the registry gate, so nothing in `tests/suite.py`
touched it. The stack defect is exactly what one row would have caught, and
the A/B above was that row written by hand and thrown away.

**`fpscratch` is the first one** (`tests/unit/t_fpscratch.py`, fast tier,
0.2s). It holds the layout half — the part that was actually wrong — and it
turned out to be worth more than BASIC alone. `os88fp.inc` declares no
storage (SPEC.md 84.3) and **four** packages write its `fp_*` scratch chain
out by hand: SHEET, CHART, FPTEST and BASIC/8088. Nothing compared the four
hands. A carrier that sizes a field short is silent — every name resolves,
nasm is happy, and the include writes past the field into whatever that
carrier put next, which is precisely the route the stack defect took.

So the gate is **agreement, not a table copied into the test**, which would
only be a fifth hand to go stale: for every field two carriers both declare,
the size must match, while a carrier may still omit what 84.8 lets it drop
(CHART drops eleven). It found one deviation immediately — BASIC gave
`fp_hw` two bytes where the include's own "the caller owes" block says `db`
and the other three give it one. Harmless over-allocation, one byte back,
but it was the only place in the tree where a carrier disagreed. Beside that
it holds BASIC's own chain: the stack reserving whole slots, `BAS_BSS_OWN`
still derived from the chain top, `bas_exec`'s bound named in symbols rather
than a literal, and no two fields sharing an address.

**It is mutation-tested, and two of the mutations are this chapter.** Putting
`BAS_STK_MAX*2` back reports the stack 96 bytes short; sizing `fp_hw` at two
again reports the carriers disagreeing; replacing the bound with `128`
reports it unnamed. The row also caught *itself*: its first version read each
carrier alone, so `BAS_STK_MAX` and `BAS_SLOT` — which live in other files —
resolved to zero and the stack check read `0 == 0`, fifty green checks
testing nothing. Every constant a comparison depends on is now asserted
non-zero first, and removing the include-gathering is the fourth mutation.

**The other half is still owed and is currently blocked.** Running a BASIC
program and comparing the answer needs the emulator, which needs a system
disk, which cannot be built while upstream's `doswtail` gate is red (see the
merge of 1a146f1d). That row — the one that would have printed 36 against
-2.668453E+307 without a human driving QEMU — comes with wave 2.

### Sizes

Measured, not quoted: **11,528 image + 7,755 bss = 19,283 of 65,024,
29.7%**, from 11,784 + 7,669 = 19,453. The dead code paid for the stack:
−256 image, +86 bss, −170 net.

## Wave 2a — scalar variables, and three bugs only the glass found

Wave 2 is `IF`, `SELECT CASE`, `FOR`, `WHILE`, `DO`, `REPEAT`, `GOSUB` and
procedures, and not one of them works without a variable to loop on or
compare. So this is the floor: `x = 7`, `y = x * 6`, `PRINT y`, and the
answer on the console is **42**.

The design is in SPEC.md 126.17. The one choice worth repeating here is that
**an entry does not hold the name** — it holds an offset into the program
text and a length. A fixed-width name field would quietly make two long
names one variable; comparing against the program's own text cannot. It also
costs nothing: the index is resolved at compile time and rides in the op
stream as one byte, so the interpreter indexes rather than searching.

### Three bugs, and the glass found all three

**`mul` clobbers DX.** `bas_varfind` held the table's count in DX and
computed each entry's address with `mov ax, BAS_VAR_SZ / mul bx` — which
writes DX:AX. The scan's own bound would have been gone after the first
entry and every name created fresh. Caught by reading it back before
building; `bas_varat` does `(i*4) + (i*8)` with shifts instead, and the
interpreter's two call sites wanted BX and CX kept anyway.

**The table outlived the text it points into.** The comment on `bas_varfind`
said "bas_run clears it, so nothing survives into the next RUN". It said so
because that is what I designed; I never wrote the line. Run
`x = 7 / y = x * 6 / PRINT y`, retype the program as `PRINT n / N = 3 /
PRINT n + N`, run again — and `y`'s entry, offset 6 and one character long,
spells `n` in the new text. `PRINT n` answered **42** where it owed 0:

| | `PRINT n` after a previous run |
| --- | --- |
| as written | ` 42` — the old `y`, through a stale text pointer |
| with the reset | ` 0` |

and `PRINT n + N` gives ` 6`, so the case-insensitivity holds too. **A
comment describing code I had not written** is this chapter's own lesson
arriving one section later, and the only thing that caught it was typing two
programs in a row instead of one.

**`File > New` cleared the console and not the program** — which reads as
New having done nothing, since the program is the thing on screen. Fixing
that uncovered the third: New is the one path in `bas_oncmd` without a
`push si` around its body, and `bas_conreset` ends `mov si, bas_s_banner`.
So `.redraw` handed `bas_abdismiss` and `bas_repaint` the banner's address
instead of the window's, and **the repaint drew nothing while every byte of
state was already correct** — New cleared the program and the screen kept
showing it. `.run` and `.stop` both bracket SI; New did not, back when
nothing it touched was on screen. That is docs' own "sh_repaint needs SI"
rule, one package along.

### Verified, and how

On the glass, because none of the three was visible any other way: `42` for
the arithmetic, `0` then `6` for the default and the case-folding, and an
empty editor and console after New. The machine is QEMU on the **pre-merge**
system disk — upstream's `doswtail` gate is red, so no current system disk
can be built — which is sound here because `PKG_FMT` did not move across the
merge and BASIC names no slot the older kernel lacks. The package had to be
packed UNCOMPRESSED to load: the merge brought an `E8` filter into
`os88pkg.py` that the older kernel's decompressor does not know.

`fpscratch` still passes 50/50 and no symbol is dead. **12,129 image + 7,950
bss = 20,079 of 65,024, 30.9%.**

### Owed from here

The op dispatch is still a compare chain and wave 2 has just added two more
ops to it; SPEC.md 126.5 owes the indexed jump, and it should land before
the control-flow ops rather than after, as its own verified step. And the
row that runs a program and compares the answer — which would have caught
all three of the above without a human driving QEMU — still waits on a
system disk.

## Next

The rest of wave 2: **control flow and procedures** — the `OSAPI` gateway, which is
perhaps two hundred bytes and from which every kernel facility becomes
reachable by hand. `BASIC-BINDINGS-PLAN.md` §7 is the order and the reason.
A registered test row comes with it.
