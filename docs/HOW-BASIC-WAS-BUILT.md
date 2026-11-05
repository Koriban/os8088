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

## Wave 2b — the indexed jump, and the first `\` this language ever ran

SPEC.md 126.5 promised `jmp [table + bx]` for three waves and `bas_exec` was
a run of compares the whole time; wave 2a added two more ops to it. So the
table came before the control-flow ops rather than after, as its own step.

The shape that makes it work: **the opcode numbers ARE the indices**, so they
were renumbered contiguous with the five binaries last and together. A table
sending each binary straight to its body would have to repeat the shared
operand prologue five times, so instead all five point at one `.binary` entry
which runs the prologue once and then indexes a second five-entry table by
the same opcode — an add and no compare. Both tables are size-checked against
`OP_N` and `OP_BIN_N` by `times` pairs, so a new op without a row is a build
error. It came out **29 bytes smaller** than the chain.

The assertion earned itself immediately, on something I would not have
guessed: I drew an ASCII brace up the right margin of the table's comments,
and **nasm continues a line on a trailing backslash even inside a comment**,
so two `dw` rows merged and the table was 13 long. The build failed on the
pair rather than on a jump into the word after the table.

### `PRINT 10\3` had never been executed

Verifying the table meant running every op, which is how `\` got its first
run since wave 1c shipped it. It refused: *"outside an INTEGER"* for `10\3`.

The cause is three lines in this file's own `fp_b2i_bas`. **`fp_push_a` banks
A on the CALLER'S STACK** — six words — and `fp_b2i_bas` had a `pushf`
between the bank and the unbank. So `fp_pop_a`'s first `pop` took the FLAGS
word as A's sign pair, restored the whole of A one word shifted, and the
`popf` afterwards popped A's last mantissa word as flags. **The depth
balances**, which is why nothing caught it: what is wrong is the data, and a
carry flag that is now a mantissa bit. The value and the carry ride in
registers now, saved before the bank — `sbb dx, dx` / `add dx, dx` — and
nothing is pushed in between.

The A/B, same kernel and the same keystrokes, against the previous commit
rebuilt from git:

| `PRINT 10\3` | |
| --- | --- |
| wave 2a and every wave before it | *Error: outside an INTEGER* |
| with the fix | ` 3` |

Verified on the glass across the whole operator set: `13`, `7`, `30`,
`3.333333`, `3`, `-10` for `a+b`, `a-b`, `a*b`, `a/b`, `a\b` and `-a` with
`a=10, b=3`.

### Fixed: the console blanked when it scrolled

Running six `PRINT`s in one program overflows the eight-row pane, and the
console goes **empty** — and stays empty through a full `W_PAINT`, so it is
the buffer and not the pixels. It reproduces with nothing but `PRINT -10`
run ten times, so it is not about variables, the table or `\`.

**It was pre-existing**: the same ten runs blank the console on the previous
commit's build too, and the merge touched neither `con_scrollup` nor
`con_scroll1`.

**And the viewport was a red herring.** I had it half-reasoned that BASIC
being a viewport user — `con_vtop` 17 of 25 — was the likely cause, which
would have sent me editing a shared include on a guess. A **memory dump**
settled it in one step instead: `pmemsave` the guest's low megabyte, find
the banner as (character, attribute) cells, and walk the rows. All ten lines
were in the buffer, at rows 12..23, with the viewport on 17..24 — **seven of
them squarely inside it.** The buffer was perfect. Nothing was being drawn.

The cause is one line of contract BASIC never kept. `con_rows_owed` opens

    cmp word [con_scrl], 0
    jne .owed                   ; ...and draws NOTHING

because a scroll leaves the glass owing a blit, and while that debt stands a
mark names a buffer row that is no longer the row of glass it used to be
(SPEC.md 96.54.14). Every carrier therefore owes one of two calls before it:
`con_scrollpaint` to SPEND the debt on the incremental path, or
`con_takescroll` to DROP it when a full repaint is about to draw every row
from the buffer anyway. Telnet carries both. **BASIC called neither**, so the
first time output passed the bottom of the eight-row pane `[con_scrl]` went
non-zero and stayed there, and from that moment every repaint filled the
pane white and put nothing back.

`bas_paint` now does `con_takescroll` first — telnet.asm's own wording at
the same call is that *the debt is dropped, not spent*, because spending it
would blit the pane up N and mark only the N rows it vacated.

| ten runs of `PRINT -10` | the pane |
| --- | --- |
| before | blank from the sixth run on |
| after | the last seven lines, scrolling |

and the program that found it now reads ` 13`, ` 7`, ` 30`, ` 3.333333`,
` 3`, `-10` with the console scrolled.

**The shared include gained the rule, not the fix.** os88con.inc's header
advertised `con_rows_owed` as "draw what is owed, and clear it" and said
nothing about the debt; it now carries the two-call contract, names both
paths and says what the failure looks like — *a carrier that calls neither
works perfectly until its first scroll and never draws again*. That is the
whole of what a future carrier needs, and no shared code changed.

**12,109 image + 7,950 bss = 20,059 of 65,024, 30.8%.**

## Wave 2c — comparisons, and the one-line `IF`

Wave 2's floor, the way variables were 2a's: there were no comparison
operators at all and no truth convention, so `IF` could not exist and
neither could `WHILE` or `UNTIL`.

`= <> < > <= >=`, binding looser than all arithmetic, answering **-1 for
true and 0 for false** — an ordinary number, so `PRINT 1 < 2` prints -1.
SPEC.md 126.18 is the contract. Three details worth keeping:

- the six comparisons are **one body**, not six. They are binaries like any
  other, and `.binary` leaves the opcode in BX, so the operator is still in
  hand at the handler: `fp_cmpab` answers -1/0/1, the result's sign picks a
  bit, the operator picks a mask from a six-byte table, and the AND of them
  is the answer;
- the condition is tested with **`fp_iszero`, never `fp_a2i`** — converting
  first would truncate and make `IF 0.5 THEN` false, a number that is not
  zero answering as though it were;
- `IF` compiles its arm by **re-entering the statement compiler**, so
  `IF a THEN IF b THEN PRINT 1` nests with no extra code. That reentrancy
  is also what exposed the one real bug below.

**The block `IF` is not here, deliberately.** Its arms are other LINES, and
`bas_run` compiles and runs one statement at a time. Compiling the whole
program first is the change the loops need anyway, so it belongs with them
rather than being half-done here. The one-line form introduces `OP_JF` and
`OP_JMP` and the backpatching the rest will reuse.

### The bug, and the two mutations

Making the statement compiler reentrant broke it immediately: `bas_word`
reads from the cursor and skips nothing, and `bas_run` only skipped spaces
before the TOP-LEVEL call. So the moment `IF` compiled its arm by calling
the compiler again, the cursor sat on the space before `PRINT` and the arm
came back *"not a statement this wave knows"* — reported against the IF's
own line, which is what made it look like `IF` was unrecognised. The entry
point skips for itself now, which is what being reentrant means.

Mutated, because the row is what makes this wave different from the last
three: giving `OP_LT` the mask that means *greater* reports `PRINT 1 < 2`
answering 0 and every IF arm inverting — the 99, 98 and 97 in the row's
program are values no correct run prints, and they appear. And one mutation
**passed**: deleting the cursor restore in `.ifnoelse` changes nothing,
because `bas_word` does not move the cursor when it finds no word and
`bas_skipsp` does not cross a newline, so after an arm the ELSE probe always
lands on the line's end. Those two instructions are unreachable in today's
grammar; the comment there says so rather than letting them read as
load-bearing.

`tests/basiclang.py` is 30 lines and 23 answers now, 104s. Its buffer anchor
had to change with this wave: it found the console by BASIC's banner as
cells, and 23 answers scroll the banner off the 25-row buffer. It finds the
buffer by its SHAPE instead — one attribute byte across 25 rows of printable
cells, which nothing the program prints can take away.

**12,612 image + 7,950 bss = 20,562 of 65,024, 31.6%.**

## Wave 2d — the whole program is compiled, and the first loops

The change the loops needed, and the reason they could not exist before:
**the interpreter compiled and ran one STATEMENT at a time**, resetting the
op stream per line. Nothing can jump backwards over statements that no
longer exist. So `bas_run` compiles the lot and then runs it, and `WHILE`,
`FOR` and eventually the block `IF` all follow from that one paragraph
(SPEC.md 126.19).

Two things came with it that are contract rather than detail. The op stream
must now hold the whole program (4KB, and one too big is refused by name).
And **the line number has to ride in the stream** — `OP_LINE`, three bytes a
statement — because `[bas_line]` at run time is otherwise the last line
*compiled*: a division by zero on line 3 of a thirty-line program would have
been reported against line 30, and 126.7's rule that a refusal names its
line would have quietly stopped being true.

`WHILE`/`WEND` tests at the top. `FOR`/`NEXT` evaluates its limit **once**,
into a variable no program can name (an entry of length zero, which
`bas_word` can never produce), because re-testing `b` each time round
differs from every BASIC of this line the moment the body assigns to
something `b` mentions. The increment is emitted BEFORE the test and jumped
over on entry — so the step is code, nothing has to remember it, and `NEXT`
is four instructions. `STEP` takes a signed literal and that is stated, not
overlooked: the test is `<=` up and `>=` down, so the direction must be
known while the loop compiles.

`CLS` arrived as a side effect worth having on its own. The row's program
had grown past the 25-row console buffer and the first answers were
scrolling away before they could be read — every BASIC has `CLS`, and it is
`bas_conreset` without the banner.

### What the row cost, and what it caught

Nothing in 2d failed on the glass the first time, which is a first for this
chapter — `FOR` printed 10, 4 and 0 on its first run. The work went into the
row instead, and that is the honest story of this wave:

- **the anchor broke twice.** It found the console by BASIC's banner as
  cells; 2c's answers scrolled the banner off. "One attribute byte across 25
  rows" looked structural enough to be safe and was not — after `CLS` no
  such region was in the dump at all, and the row could only say it had not
  found one. It now prints a **sentinel** as its first line: a number no
  answer is, at the top of a freshly cleared buffer, written by the very
  console being looked for.
- **the buffer is 25 rows and the cursor takes one**, so 24 answers is the
  ceiling. Rather than delete older coverage every time a wave adds cases,
  the program runs in **two self-contained parts** with a read between.
- **clearing between parts by backspacing was 900 confirmed keys**, and the
  BIOS buffer cannot take them: `the ROM had not stored the press after 10
  guest seconds`, once per key, for minutes. `File > New` does it in one
  gesture.

Mutated: testing a negative `STEP` with `<=` reports the `STEP -3` loop
running zero times, 0 where it owes 4.

**13,877 image + 11,610 bss = 25,487 of 65,024, 39.2%** — the op stream's
4KB is most of the bss growth. The row is 158s over two parts.

## Wave 2d, second half — the block `IF` and the bottom-tested loops

The block `IF` is what 2d's architectural change was actually for, and it
cost almost nothing once that was done: it shares everything with the
one-line form up to the forward jump, and differs only in who closes it. A
statement after `THEN` closes it on the line; an empty rest of line hands
that job to `ELSE` or `ENDIF`, lines later. Before whole-program
compilation there was no later line to hand anything to.

`REPEAT`/`UNTIL` and `DO`/`LOOP [UNTIL]` are **one loop with two
spellings** — the first is this line's, the second QuickBASIC's — and they
share every instruction. Only the keyword that may close them differs, so a
`DO` cannot be closed by a bare `UNTIL`. Both test at the bottom, which is
the whole of what distinguishes them from `WHILE`, and the row says so
directly: `f = 7 / REPEAT / f = f + 1 / UNTIL f > 0` leaves `f` at 8,
because the condition was already true and the body ran anyway. Neither
opens a forward jump, so neither has anything to patch — `UNTIL` jumps back
on FALSE, which is `OP_JF`'s own sense and needs no negation.

All of it passed on the first run, as 2d's first half did. Mutated:
stopping `ENDIF` from patching its forward jump kills the run immediately
after part three's sentinel, the unpatched jump landing at offset 0.

The row grew a **third part** rather than evicting older coverage — the
console holds 24 answers and wave 2a's would otherwise have had to go.

**14,201 image + 11,610 bss = 25,811 of 65,024, 39.7%.**

## `EXIT IF`, and a register I clobbered

`EXIT IF <cond>` leaves the innermost **loop**, which is not the innermost
block: written inside a block `IF` inside a `WHILE` it must leave the
`WHILE`, so the stack is searched downwards. A loop may hold several exits
and none knows where the end is yet, so each jump's placeholder carries the
offset of the one before it — the pending exits are a **list in the op
stream**, costing no table, and the loop's closer walks it.

Widening the block entry to sixteen bytes to hold that chain's head is what
broke it. `bas_blkat` turns an index into an address, and I wrote the
multiply as `mov cl, 4 / shl ax, cl` — **but CX is `bas_blkpush`'s patch-slot
argument**, so every block pushed got a corrupted forward jump. On a loop
that is a jump to nowhere: part two of the row hung, and part three then
read a console the hung program had left behind, so the failure arrived as
*part three's answers are part two's again*. Four `shl ax, 1` instead.

It is the third register-clobber of this chapter — `mul` taking DX in
`bas_varfind`, SI in `bas_new`'s repaint, now CL here — and all three were
a helper quietly using a register its caller was still holding. The row
caught this one in a single run.

## `ELSEIF`, which the chain had already paid for

`EXIT IF`'s pending-jump list turned out to be the expensive half of
`ELSEIF` as well, and it was already built. An arm has two jumps: the
false-jump at its head, whose destination the NEXT LINE names, and the
finished-jump at its foot, whose destination nobody knows until `ENDIF`.
The first wants one slot that each arm hands on; the second wants a list,
and the list is the one the loops walk.

That left `ELSE` carrying a patch slot of its own for no reason, so it was
rewritten onto the chain too — a deletion in the middle of a feature, which
is the shape worth noticing: the new construct made the old one simpler
instead of sitting beside it. `ENDIF` now patches the last arm's false-jump
if it has one and walks the chain either way, and an `ELSE` arm says it has
none by leaving the slot at **0** — offset 0 in the op stream is the
program's first opcode and can never be a placeholder, so zero is a free
sentinel rather than a second field.

234 bytes, and the row's fourth part reads all four shapes: the middle arm
taken, the first arm taken with two true `ELSEIF`s below it that must not
run, the `ELSE` reached when nothing matches, and a chain with no `ELSE` at
all skipped entirely with the line after it still running. The last case is
an `ELSEIF` chain inside a `FOR`, where the arms' jumps and the loop's share
one op stream and must not cross: `t` sums to 112 over four iterations.

## `SELECT`, and reading the oracle before guessing

I nearly wrote QuickBASIC's `SELECT CASE x` / `CASE ELSE` / `END SELECT`
from memory. The plan's own wave list says "SELECT CASE", which is where
that would have come from, and GFA's manual — held at
`_LIBRARY/languages/basic/gfa-basic/gfabasic.txt`, entry 228 — says
something different: `SELECT x` with no `CASE` after it, `DEFAULT` rather
than `CASE ELSE`, `ENDSELECT` as one word, and three pairs of synonyms
(`SWITCH`, `OTHERWISE`, `ENDSWITCH`) that the interpreter itself normalised.
Ten minutes of reading, and the difference is every line of a real GFA
listing.

It also showed what the shape is *for*: ranges and lists, `CASE 2 TO 4` and
`CASE 5,6`, which is most of why a `SELECT` beats an `ELSEIF` chain.

**It needed no new opcode.** The subject goes in the hidden variable `FOR`
keeps its limit in; a test is `LOAD subject`, the value, and one of the
comparisons that were already there. What it needed was a THIRD kind of
pending jump: a list has several ways into one body, and the body's address
is not known until the last value is parsed — so another chain in the op
stream, this one local to a single `CASE` line and never seen by
`ENDSELECT`.

The sharp edge was the range. `<a> TO <b>` is two tests, there being no
`AND` yet, and the lower end's failure must jump to the **next alternative**
rather than out of the arm — `CASE 1, 5 TO 9, 20` is one arm with four tests
and three ways in, and a lower end that fails still owes `20` its turn. That
is one `jc`'s worth of difference and nothing would have shown it but a list
with a range in the middle.

759 bytes and two of bss. The build also turned up a dead `QCHAR` table in
the row itself — a keystroke map that duplicated `os88qemu`'s and had never
been used — which went.

## Labels, `GOTO`, and declining to copy the oracle

GFA's manual is the authority for this chapter, and here it documents a
defect: *"If the label used with GOTO is undefined the compiler will not
issue an error message. Instead the compiler writes a bad binary where GOTO
is translated into JMP 0."* A program that silently jumps to its own top
instead of being refused is the worst thing to hand someone on a machine
with no debugger, so this is the one place the oracle is deliberately not
followed. Everything else about labels is GFA's, including the rule that a
label may **begin with a digit** and hold `.` and `_` — which is why the
probe for one is not `bas_word` and why the **colon**, not the name, is what
identifies it.

The interesting part was the legality rule. GFA's table forbids jumping out
of a `FOR` or a procedure and allows a jump *within* the same loop, and the
reason is run-time state: a loop holds a variable and a limit, a procedure
will hold a return address, and a block `IF` holds nothing at all — so a
jump between the two arms of one `IF` is harmless and allowed, and the rule
is about loops, not blocks. I nearly implemented it as a **depth** count,
which would have let a jump from one `FOR` into a sibling `FOR` through:
both are depth 1. The loop's own top offset is unique per loop, so that is
the identity recorded at the label, at every `GOTO`, and in a pending
forward reference.

A forward reference is the normal case rather than the exception, so the
pending table carries everything its refusal will need — including the
**line**, because resolution happens where the program's text ends and
`[bas_line]` has long since moved on. Without that the refusal names the
last line of the program.

Writing the row's refusal cases turned up two more things. The error
sentence read `Error at line  3 : ...`, and the cause was not the missing
space I first assumed: `bas_sayint` was padding the number the way
QuickBASIC's `PRINT` pads one, a sign space before and a separator after.
That padding was copied from `bas_sayfp`, which does the same thing *and
needs to* — and `bas_sayint`'s only caller in the whole package is the
refusal line, where it reads as a typo. Four waves of refusals carried it,
because no row had ever read an error message. And a part that tests a
compile-time refusal **cannot print the row's sentinel**: the whole program
is compiled before any of it runs, so a refused program prints nothing at
all, not even its own `CLS`. Those parts read the buffer at the address an
earlier part found, which is sound because the console is in the package's
bss and the package does not move while its window is open.

855 bytes and 212 of bss (16 labels, 8 pending references).

## Procedures, where the frame turned out to be two words

The design question was what a frame has to hold, and the answer is smaller
than it looks: the return offset, and **where this frame's saved variables
begin**. There is one save stack for the whole program and each frame knows
its own mark, so `RETURN` is a run of pops down to it — and recursion needs
nothing further, being only what a stack of frames already is. `GOSUB down`
calling itself four deep works because the thing that makes it work was
already there.

`LOCAL` is the same mechanism seen from the other end. GFA's manual says a
local is visible to *"any variables in all subroutines called by this
procedure"* — dynamic scope, stated plainly — and saving the old value on
entry and restoring it at `RETURN` is exactly that, for free. A procedure's
local `z` is what the procedure it calls sees, and the caller's `z` is back
when it returns. I would not have chosen dynamic scope; the oracle did, and
it is cheaper than the alternative.

Three spellings of one call, because GFA has three (`GOSUB name`, `@name`,
and the bare name), and `@` needed its own door: it is not a character a
word may hold, so `bas_word` never sees it and the call is read where the
"this is not a word at all" path already was, beside `'` for `REM`. The bare
name is only read as a call when nothing follows it, which keeps `PRIN 3`
the refusal it was rather than a call to a procedure called `PRIN`.

**Control cannot fall into a body**: each procedure is preceded by a jump
over its own `RETURN`, so a main program that runs off its end steps over
every procedure and reaches the `END` the compiler appends. Three bytes
each, and a whole class of question goes away.

Two defects caught by reading it back before the first run, both the same
shape as this chapter's earlier ones. `PROCEDURE` pushed the name in CX,
emitted the jump-over, put the slot in CX, then **popped CX** — handing
`bas_blkpush` the name's length as the forward slot to patch. And
`bas_dosave` indexed with `[si + cx]`, which an 8086 cannot address at all:
BX is the only register that may be added to SI or DI, which is why
`.vload` and `.vstore` count in it.

The third thing was a gap rather than a defect. `GOTO`'s legality rule asks
"which loop is this line in", and a line inside a procedure is in no loop —
so a `GOTO` from a procedure into the main program was allowed, which GFA
forbids as firmly as jumping out of a `FOR`. Outside a loop the answer is
now the procedure's own number with the top bit set: an op offset cannot
reach `0x8000`, so the two kinds of answer cannot collide, and §126.22's one
word still carries the whole rule.

And the row's expectations had to learn execution order. Every part until now
had its `PRINT`s run in source order; a procedure's body is written *below*
the call that runs it, so an expectation belongs to the line that RUNS —
`GOSUB hide` is what prints the `0`, not the `PRINT x` inside `hide`.

## Values handed over, and a record that outgrew its own indexer

A parameter is a `LOCAL` that arrives with a value in it — GFA's manual
says the parameter list is *"always local"* as a note in passing — so the
prologue is one `OP_LOCAL` and one `OP_STORE` each and there is no new
mechanism at all. It runs **backwards**: the caller pushes left to right, so
the last parameter is on top, which is the whole reason the names are
collected before any of the prologue is emitted.

The defect was in the table, not the feature. Recording how many values a
call hands over took the pending-call record from 8 bytes to 10, and
`bas_calat` still turned an index into an address with **three shifts** —
so entry 1's first word landed on entry 0's last, and the first call in the
program was refused for handing over the wrong number of values. Every
symptom pointed at the counting code, which was correct.

Three shifts *are* a record size, and nothing in the file tied them to the
constant. They do now: every one of the six indexers carries the project's
`times A-B db 0` pair against the size it assumes, and changing
`BAS_CAL_SZ` to 12 fails the build at that line. The save stack's two
copies of the arithmetic became one `bas_savat` on the way, which is where
the duplication would have bitten next.

## `FUNCTION`, and an opcode that had been pinned before it was written

§126.23 promised four opcodes and three were enough. `OP_RETV` was going to
pop the value, restore the frame and push the value back — and `OP_RET`
touches the value stack **not at all**, so a function's value is simply
still there when the caller's expression continues. The frame mechanism was
already exactly right for a value-returning call. Worth writing down
because the fourth opcode had been pinned in the contract a wave before
anyone tried to use it, and the contract now says so.

`RETURN exp` does not close the body, several are allowed, and `ENDFUNC`
closes it — which fell out of the block stack without argument: a `RETURN`
inside a block `IF` inside a `FUNCTION` pops nothing, so the `IF` is still
open and `ENDFUNC` with one open is refused by the check that was already
there.

The part worth the care was the **kind**. Calling a procedure in an
expression leaves the value stack one slot short, and calling a function as
a statement leaves one slot too many; both go wrong somewhere else entirely,
which is the shape of the first defect this chapter ever had
(`-2.668453E+307` for an expression whose answer was 36). So the kind is
recorded with the name and checked at the call — and, for a call to a
procedure defined further down, carried in the pending record and checked
where the name resolves, with two different sentences because "it returns
nothing" and "its value has nowhere to go" are different facts.

`@name` means both things depending on where it is: a procedure call as a
statement, a function call inside an expression. That reading is not a
choice made here — it is what GFA's entries 237 and 240 say between them.

A body that falls off its end answers **0**. GFA's manual offers only
"expect unpredictable results if you reach this point", which is the second
place this chapter declines to follow its oracle.

### The bug that arrived as a wrong message

The kind check worked and said the wrong sentence: calling a function as a
statement reported *that is a PROCEDURE and returns no value*. I spent a
while reading the two branches, which were right.

`bas_err` **returns**. That makes `jmp bas_err` correct for a statement body
— the `ret` lands in `bas_c_stmt`'s own caller, which is where a refused
statement belongs — and wrong for a helper that another routine *calls*:
`jmp bas_kinderr` from a routine holding six pushed registers printed the
refusal correctly and then returned **into the saved registers**. The
package was wedged from that moment, so the next program typed into the
editor never ran, and the row read the *previous* program's console. Hence a
right sentence in the wrong place, looking like a wording bug.

`tests/unit/t_basrefuse.py` holds it now, and what it is *not* is the
interesting part. The tempting check — track the push depth at every
`jmp bas_err` — is **unsound**: a linear walk crosses the pop runs of blocks
it never flows through, and the version I wrote first caught this defect in
`bas_callemit` and missed the identical one in `bas_calfix`. A gate that
catches one of two is worse than one that says plainly what it covers. So
the row holds the sound part instead: a helper that is ever `call`ed must
never be `jmp`ed to, with the three legitimate tail-call targets listed and
judged, and the docstring saying it is a ratchet on names rather than a
proof.

## `VAR`, and a forward call corrected one byte at a time

Call by reference had one real problem and it was not the referencing. A
call is compiled **before** its procedure is seen — procedures live below
their callers — so the call site cannot know which of its arguments are by
reference, and the two cases need different code: a value parameter wants
the variable's *contents* pushed and a `VAR` parameter wants its *index*.

The way out is that both are **one opcode and one index byte**. A bare
variable argument is emitted as `OP_LOAD idx`, and where that opcode byte
went is remembered — in the pending record when the procedure is unknown.
Resolving the name rewrites the byte to `OP_VREF`, which pushes the index
instead of the value. Nothing moves, there is no second pass over the
stream, and the four slots are the only new storage.

Recognising "a bare variable" needed no parser change either, which was the
nicest part: compile the argument, then ask what it **emitted**. Two bytes
whose first is `OP_LOAD` is a variable and nothing else can produce that
shape. A `VAR` position handed anything else is refused by name — there is
nothing for it to point at.

The referencing itself is a 16-byte **alias table**, identity except where a
parameter points at the caller's variable, which `OP_LOAD` and `OP_STORE`
resolve through in one byte-read each. It is saved and restored beside the
value in each save record, so `OP_LOCAL` resets it and recursion through a
`VAR` parameter costs nothing extra. True reference semantics rather than
copy-in-copy-out, which would differ observably the moment a callee's callee
also reads the caller's variable — easy to do under §126.23's dynamic scope,
and the row has that case.

The first run of it got `25` and `16` — GFA's own entry-238 example and its
own answers — and failed the next two cases: a reference **passed on** to a
second procedure, and a reference carried down a recursion. One cause.
`OP_VREF` was pushing the parameter's own index, so the inner procedure
aliased the *middle* procedure's parameter rather than the caller's
variable: the chain was one link long. It pushes what the name already
resolves to now, which both fixes it and keeps the table exactly one deep,
so `OP_LOAD` and `OP_STORE` still resolve with a single byte-read and never
a loop.

Both cases were in the row because I wrote them deliberately, not because
anything suggested them — a reference that reaches one level is correct for
every example in the manual's entry.

### A name could not contain a digit, for eight waves

The row's `outer2` was refused as *"not a statement this wave knows"*.
`bas_word` took **letters only** — it has since wave 1 — so the dispatch had
read `outer`, found `2` where it wanted `(`, and said the only thing it
could. Every variable in every test until now had been a single letter or a
plain word, so nothing had ever asked.

A digit is legal after the first character and not as it, because
`bas_c_fact` tells a name from a number by the first character alone: a word
that could begin with a digit would swallow every literal in the language.
`_` joined it at the same time.

The same read also found an inconsistency worth fixing while it was open.
A procedure's name was read with the **label** scanner at its definition and
with `bas_word` at a bare call, so `a.b` would have been one name in the
definition and another at the call site. Labels keep the loose spelling —
`.`, `_` and a leading digit, which is GFA's entry 249 — and a procedure's
name is an identifier at the definition and at all four call spellings.

`STATIC` turns out not to be GFA's at all: entry 239 has no such keyword,
and the plan's wave list had paired it with `LOCAL` from the wider survey.
Its effect is this language's default anyway — a variable a procedure does
not declare `LOCAL` is the global one.

## Next

`~name(...)`, `ON GOSUB`, then wave 3's strings with `LOCAL`/`STATIC` and recursion,
which close wave 2. Procedures want a call stack and a frame convention
pinned in SPEC.md before any of it is written — the `OSAPI` gateway, which is
perhaps two hundred bytes and from which every kernel facility becomes
reachable by hand. `BASIC-BINDINGS-PLAN.md` §7 is the order and the reason.
A registered test row comes with it.
