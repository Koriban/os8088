# BASIC.O88 — BASIC/nw as a native package

**Status: wave 0 built 2026-11-04.** Branch `basic-o88`. The diary is
`docs/HOW-BASIC-WAS-BUILT.md`; SPEC.md §126 is the contract.

BASIC/nw is a QuickBASIC 4.5-line structured BASIC with a complete
implementation in TypeScript at `~/Src/Prj_8086/basicnw/` — a lexer, parser,
analyser, compiler and interpreter, 64 built-in functions, five types, and 370
passing tests. It was written to be a **plot device** in a game: the player
wrote BASIC inside the fiction of a sealed machine. This plan brings the
language here, where the machine is not sealed.

Read `basicnw/notes/REFUSAL-AUDIT.md` first. It is the reason this is tractable:
of the 43 spellings BASIC/nw refuses, 26 refuse nothing this OS lacks.

## 0. The target: GFA-BASIC on the Atari ST

**The goal is not a BASIC that runs. It is a BASIC you can write OS/8088
applications in** — GUI or text — which is what GFA-BASIC was on the ST.

That target is specific enough to measure against, and the measuring stick is
the GFA-BASIC 3 manual itself, **held locally** at
`_LIBRARY/languages/basic/gfa-basic/` — *The GFA-Basic Compendium* v2.98, all
542 command nodes, as `gfabasic.txt` (grep-able) and `gfabasic.html` (one
offline page, linked), **and `manuals/`, ten scanned manuals** of which seven
have `text/` sidecars. The primary English authority among them is the 558-page
*V3 Interpreter User Manual* (OCR). Use the Compendium for a signature and the
User Manual for everything it states without explaining. Read the node and the
page for a command before building it; do not
quote this summary of it, and do not go back to the website — its `robots.txt`
asks automated clients to leave the viewer alone, which is why the mirror was
made from the `.hyp` container instead.

What it shows is a language of some 900 index entries, whose GUI surface
divides into **three tiers** — and that division, not the
keyword count, is the thing to copy:

| tier | GFA | here |
| --- | --- | --- |
| **A. BASIC-native verbs** | `OPENW CLOSEW CLEARW FULLW TOPW TITLEW INFOW`, `MENU`, `ALERT`, `FILESELECT`, `ON MENU …`, `MOUSE MOUSEX MOUSEY MOUSEK`, and the whole drawing set (`PLOT DRAW LINE BOX PBOX RBOX PRBOX CIRCLE PCIRCLE ELLIPSE PELLIPSE CURVE POLYLINE POLYFILL FILL TEXT GET PUT`) | the layer to build. Short, memorable, and the only layer most programs ever touch |
| **B. named system bindings** | `WIND_CREATE WIND_OPEN WIND_GET WIND_SET FORM_DO FORM_ALERT OBJC_DRAW RSRC_LOAD EVNT_MULTI GRAF_RUBBERBOX SHEL_* SCRP_* V_OPNVWK …` — one BASIC word per AES/VDI call | one BASIC word per kernel slot, named after it. 194 slots, so this tier is generated, not hand-written |
| **C. the raw gateway** | `GEMSYS`, `VDISYS`, `BIOS`, `XBIOS`, `GEMDOS`, `LINE-A`, with `CONTRL GINTIN GINTOUT ADDRIN ADDROUT` as the parameter arrays | one `OSAPI` verb taking a slot number and registers. The escape hatch that stops tier B from ever being a blocker |

**GFA source does not port unchanged, and
`docs/plans/BASIC-PORTING-NOTES.md` says what to change** — chiefly that GFA's
`%` is a 4-byte integer and this one is 2 bytes, which is loud, and that its
`!` is a Boolean where this is a float, which is not.

**Tier A — the keyword set a GUI or text application is actually written in —
is designed in `docs/plans/BASIC-GUI-PLAN.md`.** Tiers B and C are designed in
`docs/plans/BASIC-BINDINGS-PLAN.md` — what
each GEM construct was *for* and what answers that need here, the `OSAPI`
gateway, the generated binding table and its gate, and the dialog gap.

Tier C is what made GFA-BASIC usable for real work in 1986: anything the
language had not wrapped yet, you could still reach. **Build tier C first**,
because from that day on every missing feature is an inconvenience rather than
a wall, and tiers A and B become conveniences layered over something already
complete.

### 0.1 The event loop is the answer to the hard question

GFA's idiom is this, and it is the whole design:

```
GOSUB build_menu_bar
ON MENU GOSUB menu_handler
DO
  ON MENU
LOOP
```

`ON MENU` pumps one round of events and dispatches to the handlers the program
registered. Without it in a loop, no handler ever runs.

This settles what the SPEC chapter left open. A cooperative OS needs the
interpreter to yield, and the question was whether that happens invisibly every
N ops or not at all. GFA answers: **it happens at `ON MENU`, and the programmer
writes it.** The yield is a language feature, in plain sight, in the program
text. A text-mode program that never calls `ON MENU` never yields and does not
need to; a GUI program yields every pass of its own main loop.

### 0.2 What this adds that a port does not

BASIC/nw has **none** of tiers A, B or C — it was a sealed language by design.
So this project is a port *and* an addition, and the addition is the larger
half. What comes from the reference is the language: the lexer, the five
stages, the operator set, the control flow, the 64 built-ins, and 370 tests
that say what all of it means. What does not exist anywhere yet is every line
that connects BASIC to this operating system.

### 0.3 Where GFA is a bigger language, and whether to follow

GFA has eight numeric types to BASIC/nw's four (`BIT BYTE WORD INT LONG
SINGLE DOUBLE FLOAT`, with `CARD` for unsigned), a matrix sublanguage
(`MAT MUL`, `MAT INV`, `MAT DET`, twenty more), inline assembly (`INLINE`),
timers (`AFTER`, `EVERY`), `ON BREAK`, sprites, and `$`-prefixed compiler
directives. Positions, to be revisited rather than assumed:

- **follow**: `BYTE` and `WORD` (an API binding needs them), `AFTER`/`EVERY`
  (the OS has a tick), `ON BREAK`, `TRIM$`, `UPPER$`, `RINSTR`, `INC`/`DEC`,
  `SUCC`/`PRED`, `DIV`/`MOD` as words, `@proc` and `~func` call syntax,
  `REPEAT`/`UNTIL`, `SWITCH`, `EXIT IF`, `LOCAL`.
- **decline**: the `MAT` sublanguage (a library, not a language), `SPRITE`
  (the OS composites differently), `LINE-A` (no analogue).
- **decide**: `INLINE`. It is §126.7's question wearing different clothes.

### 0.4 GFA's tiers B and C are GEM-shaped; what they map to here

`GEMSYS`, `VDISYS`, `XBIOS`, `BIOS`, `GEMDOS` and `LINE-A` are not general
concepts — each is one of GEM/TOS's six trap interfaces, and the seven arrays
`CONTRL GINTIN GINTOUT ADDRIN ADDROUT PTSIN PTSOUT` exist because filling
arrays and trapping **is** the AES/VDI calling convention. None of that
survives the move, and the news is good: this OS passes arguments in registers
with CF for failure, over **one flat space of 194 slots** with no AES/VDI
split.

So the whole of GFA's tier C collapses:

| GFA | here |
| --- | --- |
| `GEMSYS n`, `VDISYS n`, `GCONTRL`, `XBIOS`, `BIOS`, `GEMDOS`, `LINE-A` | **one** verb — a slot number and register values |
| `CONTRL`, `GINTIN`, `GINTOUT`, `ADDRIN`, `ADDROUT`, `PTSIN`, `PTSOUT`, `WORK_OUT` | nothing. Registers replace all eight |

Tier B maps closely, because the window manager was built from the same ideas:

| GFA / GEM | here |
| --- | --- |
| `WIND_CREATE` `WIND_OPEN` `WIND_CLOSE` `WIND_DELETE` `WIND_SET` `WIND_GET` | `OSAPI_WM_CREATE` 0x0076, `WM_SHOW` 0x007C, `WM_HIDE` 0x0082, `WM_DESTROY` 0x02BC, `WM_TITLE` 0x01D3, `WM_GEOM` 0x0174, and ~25 more `WM_*` |
| `WIND_UPDATE`, clipping | `WM_CLIP_SET` 0x013D, `CLIP_CLEAR` 0x0145, `CLIP_TEST` 0x014D |
| `MENU_BAR`, `MENU_ICHECK`, `MENU_IENABLE`, `MENU_TEXT` | `OSAPI_MENU_SET` 0x011E, `MENU_OWNER` 0x0229 |
| `SCRP_READ` / `SCRP_WRITE` | `OSAPI_CLIP_GET` 0x026E / `CLIP_PUT` 0x0268 / `CLIP_SIZE` 0x0274 |
| `GRAF_MKSTATE`, `GRAF_MOUSE` | the mouse and cursor slots, `WM_CURSOR` 0x02E5 |
| `SHEL_READ` / `SHEL_WRITE` / `SHEL_FIND` | the loader slots |
| `V_OPNWK` `V_OPNVWK` `V_CLSVWK` `V_CLRWK` `V_UPDWK` | **nothing, and nothing needed.** There is no workstation to open: a window has a surface. About ten keywords simply vanish |

**The one real gap is dialogs.** GEM's are declarative object trees loaded from
a `.RSC` file, and roughly forty of GFA's keywords serve that model —
`RSRC_LOAD` `RSRC_GADDR` `RSRC_OBFIX`, `FORM_DO` `FORM_CENTER` `FORM_DIAL`
`FORM_BUTTON` `FORM_KEYBD`, `OBJC_DRAW` `OBJC_FIND` `OBJC_ADD` `OBJC_EDIT`
`OBJC_CHANGE`, `OB_*`, `TEDINFO`, `ICONBLK`, `BITBLK`, `APPLBLK`, `PARMBLK`.
Here there is no resource file and no object tree: `apps/os88ui.inc` (§13, §75)
provides buttons, check boxes, radio dots, scroll bars, group boxes, a standard
alert, an About card and a drop-down, each **built in code and opted into with
a `%define`**. So this is the one place where tier A must be *designed* rather
than mapped — BASIC verbs that construct a dialog by calls. `ALERT` and
`FILESELECT` come free (the alert and the chooser both exist); `FORM_DO` has no
counterpart and should not acquire a fake one.

**And one place where this OS is tighter than GEM.** `OSAPI_MENU_SET` caps the
bar at five menus, which both SHEET and Word outgrew and answered with their
own in-window bars. Tier A's `MENU` therefore either accepts that cap or
replicates that pattern, and which is a wave 4 decision rather than an
implementation detail.

`MENU m$()`'s array layout is in the User Manual's chapter 9, and it carries
one thing that does not port. Position, not any separator, assigns meaning:
`m$(0)` is the first menu's heading, `m$(1)` its first entry, `m$(2)` a line
of minus signs, **`m$(3)`-`m$(8)` six reserved slots for desk accessories**,
and `m$(9)` an empty string ending that menu; every later menu is a heading,
its entries, then an empty string, with one more empty string ending the bar.
An entry starting with a minus sign is shown greyed and unselectable, and
`MENU x,y` sets a tick or greys an item by that same index. **There are no
desk accessories here**, so slots 3-8 have nothing behind them: either tier A
keeps them as dead space for source compatibility, or `MENU` here is
documented as taking the array without them. A wave 4 decision, and the first
place where GFA source will not port unchanged.

### 0.5 The pointer tools are not `PEEK` and `POKE`

Many slots take a far pointer: `OSAPI_FILE_READ` wants `ES:BX = buffer`,
`OSAPI_FILE_PATH` wants `ES:DI` and a size, and `OSAPI_FILE_FIND_RAW` fills a
directory entry in which `+18` is a size field. A BASIC string is a handle into
a claim that can move, so none of this can work by holding an address in a
variable. Three different needs hide behind the word *pointer*, and separating
them is what keeps the language safe:

| the need | the tool | |
| --- | --- | --- |
| give the kernel a buffer | **`@obj`** | pin-and-pass: the interpreter computes the address, pins the object, makes the call, unpins. The **program never sees a number** |
| get data out of, or into, your own buffer | **`CVI` `CVL` `CVS` `CVD` / `MKI$` `MKL$` `MKS$` `MKD$`**, and `FIELD` for named fields | already in the language, for random-access records — which is the *identical* problem. `CVL(MID$(ent$, 19, 4))` reads that `+18` size field |
| refer to a kernel object | **an opaque integer handle** | `OPENW 1` and tier B's `BX = win ptr` are handles to pass back, never to dereference |

**So I was wrong to call this an argument from necessity.** An earlier draft of
this section said tier C could not work without handing out an address, and
that an address is the first half of `PEEK`. It is not: `@` hands the address
to the *kernel*, inside one call, and the program is never given it. Tier C
needs neither `PEEK` nor `POKE` nor even `VARPTR`.

What is left for `PEEK` and `POKE` is therefore exactly **memory that is not
yours** — video RAM, kernel records, hardware — which is precisely the group
§126.7 refuses on principle. The case for allowing them rests on GFA parity
and on wanting to write system software in BASIC. It does not rest on
necessity, and §9's second question should be decided on that weaker footing.

The kernel's own warning in `apps/os88api.inc` is the reason to keep the line
sharp: *"never draw from a rect you cached on an earlier pass. A rect in bss is
valid until the next thing that can move the window, which is any moment your
code is not running."* A language whose pointer story is `PEEK` invites exactly
the cached address that sentence forbids; a language whose pointer story is
`@` cannot express it.

## 1. The decision that shapes everything: assembly, not C

§73 allows a package written in C, *"slower and larger in exchange for being
writable"*, which is the obvious way to bring a 10,000-line interpreter over.
It cannot be used here, and the reason is not taste:

| | |
| --- | --- |
| **no `long`** | BASIC's `&` is a 32-bit integer. Every `CLNG`, `MKL$`, `CVL` and `&H` literal needs one |
| **no `float`, no `double`** | BASIC's `!` and `#`. §73 does not merely lack them — `os88.h` `#define`s the words to an identifier that cannot compile, because a `float` global silently assembles to `resb 2` and `sizeof(float)` comes out 2 |
| **one translation unit** | `nasm -f bin` refuses an external reference, so there is no linker and no second file |
| **~9,700 lines** | the measured ceiling before SmallerC stops with `Identifier table exhausted`, naming no file and no line |

Three of the five BASIC types cannot be expressed, and the interpreter is
larger than the compiler can hold. So: **8086 assembly, against
`apps/os88fp.inc` for the numerics.**

That is less daunting than it sounds, because most of the machine is already
built.

## 2. What already exists

Every entry point below was read out of the file, not guessed.

| need | what serves it | verified |
| --- | --- | --- |
| `PRINT`, `CLS`, `LOCATE`, `COLOR`, `POS`, `CSRLIN`, `WIDTH` | **`apps/os88con.inc`** (§70.8, §96.32) — an 80×25 console of (character, IBM attribute) pairs in text-VRAM layout, a dirty-row bitmap, CP437 face, and a composer that writes eight bytes a cell and calls nothing | `con_putc` `con_clear` `con_rows_owed` `con_scrollpaint` `con_pen` `con_font` `con_celloff` `con_nextrow` `con_fillcells`, `CON_COLS 80` `CON_ROWS 25` |
| the program editor | **`apps/os88text.inc`** (§83) — multi-line, Enter inserts a newline. No wrap, no selection, no undo | the file is 25,298 bytes and §83 is its contract |
| `!` `#` arithmetic, `SQR` `LOG` `EXP` `SIN` `COS` `TAN` `ATN` `^` | **`apps/os88fp.inc`** (§84) — IEEE-754 double in software with an 8087 path probed at boot and gated per call (§84.6) | `fp_add` `fp_sub` `fp_mul` `fp_div` `fp_cmpab` `fp_sqrt` `fp_trunc` `fp_floor` `fp_round` `fp_ln` `fp_exp` `fp_pow` `fp_sin` `fp_cos` `fp_tan` `fp_atan` `fp_i2a` `fp_a2i` `fp_init` |
| channel I/O at an offset | `OSAPI_FILE_READ_AT` **0x028C**, `OSAPI_FILE_WRITE_AT` **0x043D**, `FILE_READ_SEQ` 0x0455, `FILE_WRITE_SEQ` 0x0461, `FILE_APPEND` 0x0286 | INDEX |
| `KILL`, `NAME`, `FILES` | `FILE_DELETE` 0x010F, `FILE_RENAME` **0x0115**, `FILE_FIND_RAW` **0x03D9** | INDEX |
| `INKEY$` | `OSAPI_KEY_DOWN` **0x02FC** | INDEX |
| `SOUND`, `PLAY` | `OSAPI_SND_TONE` **0x00D3**, `SND_PLAY` 0x00DB, `SND_FM` 0x00E3, `SND_CAPS` 0x00CD | INDEX |
| the graphics statements, later | `GFX_PIXEL` 0x0020, `HLINE` 0x0028, `VLINE` 0x0030, `FILL` 0x0038, `FRAME` 0x0040, `SAVE` 0x03DC, `BLITP` 0x03A4 | INDEX |

§84.3 says `os88fp.inc` declares no storage and §84.8 says what a package does
not call it need not carry, so the numeric layer is pay-as-you-go.

**`os88con.inc` is the find that makes this a project rather than an
ambition.** BASIC's entire screen half — the thing a BASIC *is*, to a user —
already exists, is already used by Telnet (§70), and already speaks IBM
attributes, which is what `COLOR` sets.

## 3. The three real gaps

Nothing above covers these, and each is a wave of its own.

1. **double ↔ text.** `os88fp.inc` has no parser and no formatter; the only
   ones in the tree are inside `apps/sheet/sheet.asm`. BASIC needs both in
   four places (`VAL`, `STR$`, a numeric literal, and `PRINT` of a non-integer)
   and `PRINT USING` needs a third mode. **Extract SHEET's pair into a shared
   include rather than writing a second one** — two formatters that disagree
   about `1e16` is a defect this project has met before, in other clothes.
2. **32-bit integer multiply and divide**, for `&`. No helper exists; the 8086
   has `mul`/`div` at 16 bits only. Needed by `CLNG`, `&` arithmetic, `MKL$`,
   and array indexing past 65,535 elements (which `DIM` can ask for).
3. **A string heap.** `$` is a dynamic string; QuickBASIC's own answer was a
   descriptor table plus compaction. The app gets a heap claim (`docs/HEAP-CLAIMS.md`),
   so this is an allocator inside our own claim, with the one hard constraint
   that **a claim can move** — so a string is a handle, never a far pointer
   held across a call that might compact.

## 4. Architecture

The TypeScript is five stages, and the port keeps all five, because that is
what makes it checkable stage by stage against a reference that already works:

```
source text
  -> lexer      tokens                 (lexer.ts)
  -> parser     AST                    (parser.ts, ast.ts)
  -> analyse    warnings, no transform (analyse.ts)
  -> compile    a flat op array        (compile.ts)  "one op = one step"
  -> interp     walks the ops          (interp.ts)
```

`compile.ts`'s own comment says the flat op array *"gives the K-line budget a
natural unit (one op = one step)"*. The budget is fiction and goes, but the flat
array stays: a linear op stream is far friendlier to 8086 assembly than a tree
walk, and it means the inner loop is one `jmp [table + bx]`.

**The split.** `APP_MAX_SIZE equ 0xFE00` — 65,024 bytes of image + bss, and a
module is one segment, so 65,536 is a wall and not a setting (SHEET learned
this; see `SHEET-MACRO-PLAN.md` §2). The interpreter will not fit beside 64
built-ins, an editor and a console. Therefore:

| | holds | why there |
| --- | --- | --- |
| `BASIC.O88` resident | the window, menus, `os88text.inc` editor, `os88con.inc` console, lexer, the op interpreter, the string heap | the inner loop and the UI |
| `BASIC.OVL` | the 64 built-ins, `PRINT USING`, the double formatter, the parser and compiler | called once per `RUN`, or rarely per op |

Precedent for the pattern: `CHART.OVL` (§81.62), `MACRO.OVL` (§81.94),
`SCRIBE.OVL`. The known trap is recorded — an overlay dispatcher that clobbers
an argument register, and a `%define` placed after the `%ifdef`s — so read
`docs/plans/completed/SCRIBE-OVL-PLAN.md` before cutting the seam.

## 5. The five types on this machine

| BASIC | width | how |
| --- | --- | --- |
| `%` INTEGER | 2 | native. `ax` |
| `&` LONG | 4 | `dx:ax`, with gap 2's mul/div |
| `!` SINGLE | 4 | **held as a double, stored as 4 bytes.** QuickBASIC's `!` is a 32-bit float; `os88fp.inc` is 64-bit only, so arithmetic widens and `CSNG` rounds on store. This is a stated simplification, in §84.2's tradition, and `MKS$` must still emit the real 4-byte IEEE single because the audit found `MKS$`/`CVS` round-trip exactly |
| `#` DOUBLE | 8 | `os88fp.inc` register A/B |
| `$` STRING | handle | gap 3's heap |

**The trap, already paid for once:** `os88fp.inc` has a two-register model
(A and B) and the helpers clobber A. SHEET's `sh_acc_*` wrappers hit exactly
this — *build the constant first, load the value last* — and it cost two wrong
answers (`NOW` twice the serial, `RAND` a constant 1). Any `bas_acc_*` wrapper
here inherits that hazard on day one.

## 6. Where the refusal line goes

From the audit, unchanged in substance: **a user program may not, because the
kernel owns it** — not *the machine cannot*.

- **Refuse, permanently, with the new reason**: `POKE` `PEEK` `VARPTR`
  `DEF SEG` `OUT` `INP` `WAIT`. An 8086 has no MMU; a cooperative kernel
  cannot hand out arbitrary writes and keep its invariants. Seven surfaces,
  and the only seven where refusing is principled here.
- **Refuse while true, revisit by name**: `LPRINT` (until PRINT-PLAN lands),
  `LOCK` (until multiuser), `ENVIRON`/`ENVIRON$` (no env API exists),
  `STRIG` `PEN` (no hardware), `PALETTE` (per adapter — real on VGA/EGA,
  meaningless on Hercules).
- **Implement**: everything else, in wave order below.

Every refusal keeps BASIC/nw's best property, which the audit confirms is real:
a refused spelling is reported **by name, with a reason**, never as a syntax
error and never as a type mismatch blamed on the author.

## 7. Waves

Reordered for the §0 target. The old order built a language and reached the OS
at the end; this one reaches the OS in wave 1 and is a usable tool from wave 4.

**Wave 0 — the seam.** §126 written. `BASIC.O88` is a window with a menu bar,
an `os88text.inc` editor, an `os88con.inc` output pane and a `RUN` that does
nothing. Proves the UI, the overlay seam and the size budget before any
language work. Exit: it builds, opens, types, and `make` reports image+bss.

**Wave 1 — expressions, `PRINT`, and tier C.** Lexer, the expression parser,
the op stream, `%` and `#` arithmetic on `os88fp.inc`, `PRINT` to the console,
`LET`. Gap 1 (double↔text) lands here. **And `OSAPI`** — the raw gateway, which
is perhaps two hundred bytes and from which every other OS facility becomes
reachable by hand. A BASIC program that can evaluate an expression and call a
kernel slot is already more useful than one that can do the whole language and
nothing else.

**Wave 2 — control flow and procedures.** `IF`/`ELSEIF`, `SELECT CASE`,
`FOR`/`NEXT`, `WHILE`/`WEND`, `DO`/`LOOP` both ends, `REPEAT`/`UNTIL`,
`EXIT IF`, `GOTO`/`GOSUB`, `PROCEDURE`/`FUNCTION` with `LOCAL` and `STATIC`,
recursion, `@proc` and `~func`.

**Wave 3 — strings and arrays.** Gap 3 (the string heap). `DIM` with `a TO b`
and `OPTION BASE`, `REDIM`, `ERASE`, `SWAP`, `LSET`/`RSET`, `TYPE` records,
dotted names, the string built-ins, `BYTE` and `WORD`.

**Wave 4 — the event loop and tier A windows.** The wave that makes it GFA.
`OPENW`/`CLOSEW`/`CLEARW`/`TITLEW`/`TOPW`/`FULLW`, `MENU` from a string array,
`ALERT`, `FILESELECT` on the existing chooser, `MOUSE`/`MOUSEX`/`MOUSEY`/
`MOUSEK`, and `ON MENU` with `ON MENU GOSUB`/`BUTTON`/`KEY`/`MESSAGE`. A BASIC
program now owns real OS windows and dispatches real events. **Exit: a GUI
application written in BASIC, with a menu bar, that responds to clicks.**

**Wave 5 — the built-in library, in the overlay.** All 64 of the reference's,
plus `PRINT USING`. Gap 2 (32-bit mul/div) lands here for `CLNG`/`MKL$`/`CVL`.

**Wave 6 — graphics, tier A.** `PLOT`, `DRAW`, `LINE`, `BOX`, `PBOX`, `RBOX`,
`CIRCLE`, `PCIRCLE`, `ELLIPSE`, `POLYLINE`, `POLYFILL`, `FILL`, `TEXT`,
`GET`/`PUT`, `GRAPHMODE`, `DEFLINE`, `DEFFILL`, `DEFTEXT`, `CLIP`. The audit's
point stands — decide what a drawing surface *is* here before writing `PSET`,
since a BASIC window already has one and there are no mode numbers to set.

**Wave 7 — files, honestly.** Channels on `FILE_READ_AT`/`WRITE_AT`, never a
whole-file string: `OPEN`/`CLOSE`, the four channel keywords and the `#` forms,
`FOR RANDOM` with `FIELD`/`GET`/`PUT`, `EOF`/`LOF`/`INPUT$`, then the five
file surfaces the audit calls SCOPE.

**Wave 8 — errors, input, and the rest of the console.** `ON ERROR GOSUB`,
`RESUME` in three forms, `ERROR n`, `ERR`/`ERL`/`ERR$`, the error table.
`INPUT`/`LINE INPUT`, `INKEY$` on `KEY_DOWN`, `DATA`/`READ`/`RESTORE`,
`SOUND` on `SND_TONE`, `AFTER`/`EVERY` on the tick, `ON BREAK`.

**Wave 9 — tier B, generated.** One BASIC word per kernel slot, emitted from
the same source `tools/os88index.py` already reads, so the binding table cannot
drift from the kernel. 194 slots; the generator is the deliverable, not the
table.

**What finished means.** Not `gorilla.bas`. BASIC/nw is in the QuickBASIC 4.5
*line* and departs from it on purpose — the four channel keywords,
`DEF PROC`/`DEF FUN`, fixed `RND`/`TIMER`, IEEE-754 `MKS$`, no immediate mode —
so accepting QuickBASIC source is a courtesy and **no QuickBASIC program is a
specification for this language** (SPEC §126.9).

`reference/gorillas/gorilla.bas` is a **sample**, and a useful one: 1,135 lines
of real-world QuickBASIC is good evidence about what programs of this kind
actually reach for, which is how §9's second question used it. It is evidence,
not a bar.

The bar is a **GUI or text application written in this language**, exercising
tier A: a window, a menu bar, a repaint, a dialog, with the lock and clip
discipline held by the interpreter and none of it visible in the program.
`docs/plans/BASIC-GUI-PLAN.md` §7 is that program.

## 8. Testing: a differential oracle, not a golden file

The TypeScript engine is a working implementation of this exact language with
370 passing tests. That makes it the oracle: **run the same `.BAS` in both and
compare the output**, rather than hand-writing expected text that encodes
whatever the assembly happened to do first.

- the host side is `basicnw/dist-cli/basicnw.mjs <prog.bas>`, which already
  reads and writes real files;
- the guest side reads output off the screen with `tests/glass.py`, which
  recovers exact cell text through the kernel's own glyphs;
- `basicnw/notes/probe-refusals.ts` is the model for the refusal half: assert
  that each refused spelling is refused **by name**. The audit found only 13 of
  43 surfaces had any assertion at all, so the guest suite should start better
  than the host's did.

Three standing hazards in this repo apply directly, and all three have bitten
before: a values-only gate is blind to the chrome, so assert the window and not
just the numbers; a skip is not a pass; and a mutation run leaves its own
artefacts, so re-run the good build before believing a green row. For anything
that looks correct but will not show, write the live value into the pixel
buffer and read it back off a BMP export.

## 9. Open questions

1. ~~**Does `RUN` block?**~~ **Answered by §0.1:** the yield is `ON MENU`,
   written by the programmer. A GUI program pumps its own loop; a text program
   that never calls it never yields and does not need to.
2. **`PEEK`, `POKE` and `INLINE` — the one real conflict with the target.**
   §126.7 refuses the memory and port group on principle, and GFA-BASIC had
   all of it, because on a single-tasking ST the programmer owned the machine.
   Here they do not. But an assembly package can already poke anything, so
   refusing it in BASIC protects the *BASIC programmer from an accident*, not
   the OS from harm.

   **Recommendation, after measuring: refuse them, and keep §126.7 as it
   stands.** Two findings moved this, and the second is decisive.

   First, they are not the pointer tools — §0.5. `@`, the `MK*`/`CV*` pair and
   opaque handles cover every pointer need, and tier C needs none of these
   three. There is no necessity argument.

   Second, **real QuickBASIC barely uses them.** `reference/gorillas/
   gorilla.bas` is a sample and not a target (§7), but as evidence about
   ordinary practice it is worth having: 1,135 lines, and its entire low-level
   footprint is **7 lines in two blocks**, both doing one cosmetic thing: `DEF SEG = 0`, `PEEK(1047)`, `POKE 1047, KeyFlags OR 32` to
   force NumLock on at startup, and the same to restore it at exit. No
   `BLOAD`, no `BSAVE`, no `CALL ABSOLUTE`, no `SHELL`. The five `INKEY$` calls
   are a separate refusal that `OSAPI_KEY_DOWN` answers in one call, and the
   six `CALL`s are its own procedures.

   And forcing the machine's global NumLock state is a thing a cooperative
   multitasking OS arguably *should* refuse: it is one application reaching
   past its window to change something every other application shares. So the
   measured cost of refusing the whole group is that the target program loses
   a keyboard LED, and the correct fix for even that is a kernel slot rather
   than a poke.

   **The extension path is already better than `POKE`.** If a BASIC program
   ever genuinely needs something out of kernel memory, the answer is a slot
   that exposes it safely — and tier C can call any slot the day it exists.
   "Add a slot" is a reviewable change to a published contract; "allow `POKE`"
   is a permanent hole.

   **`INLINE` is a separate question and should not be decided here.** Inline
   assembly is about wanting a fast inner loop, not about touching foreign
   memory, and it has its own answer (or refusal) independent of this group.

   **And it is a weaker case than §0.5 first claimed.** `PEEK` and `POKE` are
   not the pointer tools — `@`, the `MK*`/`CV*` pair and opaque handles are,
   and tier C needs none of these three. So this is not a capability the
   bindings require; it is one that GFA parity and system programming in BASIC
   would like. Declining it costs those two things and nothing else.

   I had proposed copying GFA's `$`-prefixed directives for this, GFA having
   used them for exactly this class of choice. **The manual says not to.**
   `$` there "is treated by the Interpreter like a REM" — it is a *compiler*
   instruction the interpreter ignores — and the manual states plainly that
   "any incorrect compiler commands will be silently ignored. There is no easy
   way to detect incorrect compiler commands." Both halves are wrong here: the
   declaration has to take effect *under interpretation*, which is the only
   place this language runs, and a misspelled `$SYS` silently ignored would
   surface as a refusal on the first `POKE` — a diagnostic pointing at the
   wrong line, which is the exact failure §126.7 exists to prevent. So: a real
   statement the interpreter acts on, and an unknown directive is an error,
   not a comment.
3. **Do BASIC programs become standalone packages?** GFA had a compiler
   emitting a `.PRG` that ran without the interpreter. The equivalent here is
   a `.O88`, which means code generation rather than interpretation — a much
   larger project. Assumed out of scope until the interpreter hosts real GUI
   apps, since that is a prerequisite either way; worth confirming that
   "create apps" means *runs under BASIC.O88* for now.
4. **`!` as a narrowed double** — stated above as a simplification. Worth
   confirming against §84.2 before wave 1 rather than after.
5. **One window or two?** Editor and output as panes of one window, or a
   separate output window that a `RUN` raises. QuickBASIC used one screen and
   F5; two windows is more this OS's idiom — and once wave 4 lands, a program
   opens its own windows anyway, so this is only about the default console.
6. **Does the editor want `os88text.inc` as-is?** No selection and no undo is
   thin for a program editor. Decide whether wave 0 accepts that or grows §83.
