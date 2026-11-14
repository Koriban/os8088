# BASIC/8088 — BASIC/nw as a native package

**The language is BASIC/8088**; `BASIC.O88` is the package file that carries
it and `BASIC/nw` is the TypeScript reference it is measured against.

**Status: wave 0 complete 2026-11-04 (0a frame, 0b console, 0c editor);
12,753 of 65,024 bytes, 19.6%.** Branch `basic-o88`. The diary is
`docs/HOW-BASIC-WAS-BUILT.md`; SPEC.md §150 is the contract.

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

**It is GFA's SHAPE that is wanted, not its substance** (SPEC §150). What is
being copied is that a BASIC can be an operating system's application
language: three tiers of reach with the raw one first, and an event loop the
programmer pumps in plain sight. What is not being copied is its keywords, its
type widths or its source — **if those were the goal, porting GFA itself would
be the honest course.** The substance is BASIC/nw's, and where the two
disagree BASIC/nw wins with no appeal to parity.

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

`docs/plans/BASIC-PORTING-NOTES.md` records how the two differ — chiefly that
GFA's `%` is a 4-byte integer where this one is 2, and its `!` a Boolean where
this is a float. **It is reference and not a requirement**: nothing here owes
a GFA listing a clean port.

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

### 0.3 The keyword gap, measured

**The two keyword lists are reconciled by a generator, not by hand** —
`basicnw/notes/gen-keyword-reconcile.py`, output
`basicnw/notes/KEYWORD-RECONCILE.md`. This is
`docs/plans/SHEET-MACRO-PLAN.md`'s shape for Excel 2.0's macro language and
for its reason: a count taken by hand goes stale the first time either side
moves. The count is for knowing the shape of the family, not for closing a
gap: the 218 names GFA has and this does not are **a menu, not a backlog**.

| | |
| --- | ---: |
| BASIC/nw reserved words | 134 |
| BASIC/nw built-ins | 64 |
| **BASIC/nw names in all** | **193** |
| GFA keyword-shaped nodes in the mirror | 275 |
| in both | 57 |
| **GFA only** | **218** |
| BASIC/nw only | 136 |

A floor rather than a census: the mirror carries one node per *documented*
command, so a keyword documented inside another's page is not counted.

**AND "A FLOOR" IS TOO SOFT A WORD FOR IT — the number is 53 of 136.** This
caveat was here from the first draft and it did not stop the error it
describes: wave 3's list was drawn from the `BASIC/nw only` side, which is
exactly the column the caveat says is unreliable, and `ERASE` came across as
a word GFA does not have. It has one: node [94], where `CLR` lives too —
which is why `CLR` was missing from that list altogether. `LSET` is a third,
inside node [164].

Measured by scanning each node's BODY for the syntax lines the manual puts
at its head and diffing against the title-derived set: **53 of the 136 words
filed as "in BASIC/nw and not in GFA" are GFA's**, among them `ELSE`, `END`,
`NEXT`, `RETURN`, `GOSUB`, `DATA`, `READ`, `RESTORE`, `UNTIL`, `WEND`,
`LOOP`, `CASE`, `EXIT` and `OPTION` — several of which this project has
already built AS GFA features while the table said they were not GFA's at
all. (The scan is a heuristic and a few of the 53 are noise, `MOD` and the
word `GFA` among them; the ones listed here are not.)

So the column is not a menu and not a backlog: **it is not evidence.** Read
the node before putting any word from it into a wave, and when the
generator is next touched, make it scan node bodies for `^KEYWORD ` syntax
lines rather than titles alone — at which point the count becomes one worth
quoting.

**And GFA is no longer the only comparison.** Five dialects' manuals are held
in `_LIBRARY/languages/basic/` and their keyword lists extracted into one
corpus by `basicnw/notes/gen-keyword-corpus.py`
(`keywords.tsv`, summarised in `KEYWORD-CORPUS.md`):

| | names | shares with BASIC/nw |
| --- | ---: | ---: |
| BASIC/nw | 187 | — |
| QuickBASIC 4.5 | 221 | **178** |
| GFA-BASIC 3 | 275 | 55 |
| BBC BASIC V | 168 | 69 |
| AMOS Professional | 745 | 90 |
| STOS | 125 | 30 |

**178 of QuickBASIC's 221 are shared, and the nine BASIC/nw has that it lacks
are exactly the documented divergences** — `EMIT`/`FETCH`/`STORE`,
`PROC`/`PROCEDURE`/`FUN`/`DEFINE`, `VIEWPRINT`. That is the strongest evidence
available that this language is where `quickbasic.md` says it is, and it is
measured rather than asserted.

AMOS is the outlier and the useful one: 745 names, **419 instructions against
211 functions**, plus two embedded sub-languages (47 `Interface Instruction`s,
10 `AMAL Instruction`s). Nothing of that shape belongs in §150, but it is the
richest catalogue in the set of *what a BASIC can be asked to do*.

**The 218 GFA-only names divide, and most are already answered:**

| | | |
| --- | ---: | --- |
| GEM bindings | 76 | no counterpart — one `OSAPI` verb replaces the lot (§0.4) |
| graphics | 33 | tier A, `BASIC-GUI-PLAN.md` wave G6 |
| windows, menus, events | 21 | tier A, waves G1–G4 |
| TOS and hardware | 12 | refused, SPEC §150.7 |
| the `MAT` sublanguage | 6 | declined — a library, not a language |
| **language-level** | **70** | **the real work, and the only group needing a decision each** |

So the answer to "must the lists be reconciled" is **yes, and it is already
two thirds done by decisions taken elsewhere in this plan.** What is left is
seventy names, and reading that list is a short afternoon rather than a
project: `REPEAT`, `EXIT IF`, `LOCAL`, `DEC`, `PRED`, `ROUND`, `RINSTR`,
`UPPER$`, `ON BREAK`, `QSORT`, `TRON`/`TRACE$`, `PRINT USING`, `DIR`,
`MKDIR`, `EXIST`, `SEEK`.

**The shared spellings are the dangerous ones, not the missing 218 — and the
sweep is done.** `basicnw/notes/GFA-CONFLICTS.md` reads all 55 against their
GFA pages: **12 are a different construct entirely, 15 differ in detail, 28
agree.** Nine of the twelve were not previously recorded, and two of those
outrank everything in `BASIC-PORTING-NOTES.md`:

- **`TYPE`** is a *function* in GFA (returns a variable's type code) and a
  *record declaration* here. One parser cannot have both; §150 should say
  which wins, and it is almost certainly the record, since `FIELD` and random
  access depend on it.
- **`STORE`** is GFA's "write a string array to a channel" — and BASIC/nw
  **invented** its own `STORE` as one of the four channel keywords. The clash
  is on a word this language chose, and it cannot be withdrawn without giving
  up the four-keyword design.

Also worth acting on: **`INP` is a channel read in GFA and a hardware port
here**, so §150.7's refusal should name the port explicitly or a GFA
programmer will read it as refusing their file I/O.

The older framing, kept because it is still true: A shared
spelling is not a shared meaning and a conflict is silent: three are known and
in `BASIC-PORTING-NOTES.md` — `VAR`, `RETURN`, and `GET`/`PUT` — and **the
other 54 are unchecked.** Each needs its GFA page read against
`statements.md` before it can be called compatible, and that, not the missing
names, is what the reconciliation is actually for.

### 0.3.1 Where GFA is a bigger language, and whether to follow

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
- **decide**: `INLINE`. It is §150.7's question wearing different clothes.

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
keeps them as dead space, or `MENU` here simply takes the array without them.
**With source compatibility not a requirement, this stops being a decision:
they go.** Six reserved strings exist to let an operating system fill them,
this one fills nothing there, and carrying them would be carrying GEM's
mechanism without GEM's purpose.

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
| get data out of, or into, your own buffer | **`FIELD buf, n AS f$, …`**, then the `CV*`/`MK*` pair | `FIELD` takes a buffer as well as a channel now (SPEC §150.16), so a kernel structure is read by **name** — `CVL(sz$)` rather than `CVL(MID$(ent$, 19, 4))`, and 19 is the kind of number that outlives the structure it describes |
| refer to a kernel object | **an opaque integer handle** | `OPENW 1` and tier B's `BX = win ptr` are handles to pass back, never to dereference |

**So I was wrong to call this an argument from necessity.** An earlier draft of
this section said tier C could not work without handing out an address, and
that an address is the first half of `PEEK`. It is not: `@` hands the address
to the *kernel*, inside one call, and the program is never given it. Tier C
needs neither `PEEK` nor `POKE` nor even `VARPTR`.

What would be left for an **address-taking** `PEEK` and `POKE` is therefore
exactly **memory that is not yours** — video RAM, kernel records, hardware.

**That question is closed, and not in the way this section first framed it**
(SPEC §150.7, §150.11). `POKE` is dropped with its name kept reserved. `PEEK`
is **kept**, and points somewhere else entirely: it reads the *running
program* rather than an address, so it is not in this group at all and never
was a pointer tool. Neither of the two takes an address, which is why the
three rows above are the whole of the pointer story.

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

1. ~~**double ↔ text.**~~ **THIS GAP DOES NOT EXIST**, and saying it did was
   an error in this plan. `fp_atof` (text → A, `SI` advanced, `CF=1` if there
   was no number) and `fp_ftoa` (A → a NUL string at `DS:DI`, `AX` significant
   digits, `%g` shape with trailing zeros trimmed) are both **in
   `apps/os88fp.inc`**, the shared include, at lines 2004 and 2223. What
   `apps/sheet/sheet.asm` holds is a pair of overlay *thunks* to them —
   `sh_x_fp_atof`, `sh_x_fp_ftoa` — which is what the grep behind the original
   claim actually found. Wave 1c used them as they are and extracted nothing.

   The lesson is the cheaper one: the grep that produced this gap searched for
   `fp_fmt|fp_tostr|fp_str|fp_parse|fp_fromstr` and the routines are called
   `ftoa` and `atof`. **A name you did not think of reads as a thing that is
   not there.**
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
walk, and it makes the inner loop a dispatch on one byte.

That dispatch was a **compare chain** in `bas_exec` for three waves while
this paragraph promised the table. Wave 2a built it: the opcode numbers are
the table's indices, the binaries are contiguous and share one `.binary`
entry so the operand prologue is not repeated per operator, and both tables
are size-checked at assembly time.

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

- **Refuse, permanently, with the new reason**: `POKE` `VARPTR` `DEF SEG`
  `OUT` `INP`. An 8086 has no MMU; a cooperative kernel cannot hand out
  arbitrary writes and keep its invariants. **Five** surfaces, and the only
  five where refusing is principled here. Every name stays reserved, and
  `INP`/`OUT` cost nothing by being refused — GFA used them for *channels*,
  which this language spells `INPUT$`/`CV*` and `EMIT`/`MK*` already, so the
  refusal message names `INPUT$` as well as the port.
- **Kept, and pointed elsewhere**: `PEEK` and `WAIT`. `WAIT` was the sixth of
  the group until §150.15 gave it the ordinary meaning of the word — `WAIT`
  yields once, `WAIT KEY` yields until a keystroke is waiting — which also
  answers the hole §150.8 leaves, a text-mode program having no `ON MENU` loop
  to yield in. **`SLEEP` waits for time, `WAIT` waits for the machine.** It was the seventh of that group
  until SPEC §150.11 gave the spelling a different job — reading the running
  program's own variables rather than an address. `PEEK(1047)` is still
  refused by name; `PEEK$("total")` is the language.
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

**Wave 0 — the seam.** §150 written. `BASIC.O88` is a window with a menu bar,
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

**Wave 2 — control flow and procedures. DONE.** `IF`/`ELSEIF`, `SELECT`
with ranges and lists, `FOR`/`NEXT`, `WHILE`/`WEND`, `DO`/`LOOP` both ends,
`REPEAT`/`UNTIL`, `EXIT IF`, labels and `GOTO`, `PROCEDURE`/`FUNCTION` with
`LOCAL`, recursion, values by value and **by reference** (`VAR`), `@proc`
and `~func`/`VOID`. SPEC.md §150.19-§150.27 are the contract and
`docs/HOW-BASIC-WAS-BUILT.md` the account; `basiclang` and `basiclang2` are
the rows.

Two corrections to this list, both from reading the oracle rather than
guessing. **`SELECT CASE` is QuickBASIC's spelling and not GFA's** — entry
228 is `SELECT x` / `CASE`/`DEFAULT`/`ENDSELECT`, with `SWITCH`,
`OTHERWISE` and `ENDSWITCH` as its own synonyms. And **`STATIC` is not
GFA's at all**: entry 239 has only `LOCAL`, the pairing here came from the
wider dialect survey, and its effect is this language's default anyway
(§150.26).

**Wave 3 — strings and arrays. MOSTLY DONE.** Gap 3 (the string heap) is
closed: SPEC.md §150.28 is the string model, §150.29 the eight built-ins a
program cannot be written without, §150.31 arrays numeric and string, and
§150.32 the compaction root an array element is. `DIM` with `a TO b`, two
dimensions, `OPTION BASE`, `LBOUND`/`UBOUND`.

**`CLR`, `ARRAYFILL` and `SWAP` are in** — SPEC.md §150.33 and §150.34, row
`basiclang3`. And reading the nodes for them corrected this list, which is
the third time that has happened in this chapter after `SELECT CASE` and
`STATIC`:

- **`REDIM` is in none of the reference's 542 command nodes.** It is
  QuickBASIC's word. The sentence above had it as GFA's and described what
  "the reference says" about it; the reference says nothing, because it does
  not have it.
- **`ERASE`'s description was RIGHT, with the wrong source attached.**
  "Clears in place" is exactly what `basicnw`'s `ERASE` does — a fresh array
  of the SAME dimensions, `interp.ts`'s `new QbArray(arr.dims, ...)` — and
  `basicnw`'s `REDIM` does lose the contents, taking new dimensions from
  runtime expressions. What was wrong is the phrase *"the reference says"*,
  written once the target was GFA. **This chapter has TWO authorities and
  used one word for both**: the Compendium, which the language is measured
  against, and `basicnw`, which its answers are compared with (§8). GFA's
  `ERASE` is a different statement with the same name — node [94] deletes
  whole arrays and releases their memory — and clearing in place is
  `ARRAYFILL`'s job there, node [73], which is also where the limit comes
  from: it cannot fill a string array. **So: never write "the reference"
  here. Write the Compendium, or write `basicnw`.**
- **`CLR` was missing from the list entirely**, though it is in the same
  node as `ERASE` — `CLR x,y` for scalars, with the reference's own note
  that arrays go to `ARRAYFILL` instead.
- **A whole-array `SWAP` moves no elements.** Node [95]: only the
  descriptors are exchanged, *"having the effect of also exchanging the
  dimensioning of the two arrays"*.

**`LSET`/`RSET` are in too** — SPEC.md §150.35, node [164], fixed-length
because *"only its length is significant"*.

**And `ERASE` is DECIDED, not deferred: refused by name** (§150.33). It
would do nothing a program could observe here. Its two documented effects
both rest on run-time allocation that this chapter does not do: the arena
is handed out while compiling, so freed bytes have no later `DIM` to go to,
and a second `DIM` of one name is refused at compile time — with `DIM`
taking a CONSTANT where the reference takes an `iexp`, so there is no
computed size to re-dimension to anyway.

So the thing `ERASE` was standing in for is **`DIM` of an EXPRESSION**:
runtime-sized arrays, the arena allocated and the bounds checked at run
time. That is one coherent piece of work and it is what makes `ERASE`,
re-`DIM` and a data-driven program size possible at all; it is now the open
item, in `ERASE`'s place.

Still open, in this order: **`DIM` of an expression** (above), **a third
dimension** (the reference allows seven, product under 65535, and this
record's size is a power of two for the indexer's sake — so the third costs
it the shift), **`DIM?()`** for the element count, and **`TYPE` records with
their dotted names** plus **`BYTE`/`WORD`**, which want the type system
§150.4 describes and nothing yet builds. The other 56 built-ins are wave
5's, in the overlay.

**Wave 4 — the event loop and tier A windows.** The wave that makes it GFA.
`OPENW`/`CLOSEW`/`CLEARW`/`TITLEW`/`TOPW`/`FULLW`, `MENU` from a string array,
`ALERT`, `FILESELECT` on the existing chooser, `MOUSE`/`MOUSEX`/`MOUSEY`/
`MOUSEK`, and `ON MENU` with `ON MENU GOSUB`/`BUTTON`/`KEY`/`MESSAGE`. A BASIC
program now owns real OS windows and dispatches real events. **Exit: a GUI
application written in BASIC, with a menu bar, that responds to clicks.**

**ITS PREREQUISITE IS SETTLED FIRST, AND IT IS NOT WHAT §0.1 SETTLED.**
SPEC.md §150.36 is the other half of the event loop: §0.1 above says what a
yield LOOKS like in the language, and §150.36 says how the interpreter can
yield at all — which, in the context `RUN` executes in today, it cannot.
Three measured facts decided it:

- **`RUN` is an `AM_ONCMD` item, so a program runs on the UI TASK UNDER THE
  GFX LOCK** (SPEC.md §12.2, and `basic.asm` says so above `bas_oncmd`).
  `OSAPI_TASK_YIELD` there gives up the slice still holding the lock — and
  worse, the events `ON MENU` exists to dispatch are delivered BY the UI
  task, which is the one stuck inside `bas_exec`. No yield from that handler
  can ever produce one.
- **`OSAPI_WM_WAKE` is the resume signal.** It posts an `EVT_WAKE` the UI
  task pops IN ORDER with the mouse and key events, so a wake posted at
  `ON MENU` arrives behind the clicks already queued: the handlers run on
  what was waiting, and the program resumes behind them.
- **The interpreter is ALREADY resumable, for two words.** Nothing rides the
  host stack across an op boundary — `OP_CALL` stores a `bas_ops`-relative
  offset in a bss frame rather than pushing a return — so the whole machine
  at a `.next` is the op cursor and the value-stack pointer. Checked in the
  shipped code, not assumed.

So `ON MENU` RETURNS out of the handler rather than yielding inside it, and
a wake brings it back; `ALERT` and `FILESELECT` use the same seam, which is
also what makes `os88ui_ask`'s asynchronous completion fit a statement that
appears to block. **And it makes one rule for every opcode from here on: no
op may leave state on the host stack across a `.next`.** An op that did
would make the interpreter unwakeable, and the symptom would be a program
that hangs rather than an opcode that looks wrong.

**Slice 1 is IN** — the suspend/resume seam, bare `ON MENU`, row
`basiclang4`, +226 bytes. The seam is proven by removing the wake post: the
answer after the loop vanishes AND the window stays responsive, which is
the whole point of returning rather than yielding. **Slice 2 is IN too** — `ALERT`, SPEC.md §150.37, +2,287 bytes (the dialog
and the button control it needs were not compiled into this package at
all). It proves the seam carries DATA where slice 1 proved only control: a
completion made to report 9 instead of 0 is caught on one console line.
Still to come, in this order: `OPENW` and the window verbs, then `MENU`
from a string array — which is the one with no
existing kernel facility behind it, `OS88_MENUSET` being an assembly-time
macro with a five-menu cap where a BASIC program builds its bar at run time.

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
specification for this language** (SPEC §150.9).

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
2. ~~**`PEEK`, `POKE` and `INLINE`**~~ — **decided, except `INLINE`.**

   **`POKE` is dropped, its name kept reserved** (SPEC §150.7): refused by
   name with its reason, not freed as a variable and not quietly absent.
   §150.7's permanent group is **six** now — `POKE`, `VARPTR`, `DEF SEG`,
   `OUT`, `INP`, `WAIT`.

   **`PEEK` is kept and points somewhere else** (SPEC §150.11). It no longer
   reads an address; it reads the *running program* — a variable, a constant,
   an array element, a record field — and gives back the value.
   `PEEK$(name$)` renders any type as text, `PEEK(name$)` answers for the
   four numeric ones, `PEEK?(name$)` says whether a name exists and is in
   scope. It reads and never writes, which with `POKE` gone is a deliberate
   asymmetry rather than an omission, and `PEEK(1047)` — the old meaning,
   which real QuickBASIC contains — is refused by name so ported code is told
   what changed at the line that changed. It costs a symbol table in the
   running program, emitted **only** when one of the three is used; the same
   table is what an editor's variable watch needs.

   The reasoning is kept because it reversed twice before landing. They were
   never the pointer tools (§0.5), so there was no necessity argument; and
   measured against real QuickBASIC, `gorilla.bas` uses them on **seven lines
   of 1,135**, both blocks forcing the BIOS NumLock flag on and back — which
   is precisely what a cooperative system should refuse, one application
   reaching past its window to change what every other application shares.

   **`INLINE` is the part still open.** Inline assembly is about wanting a
   fast inner loop, not about reaching foreign memory, and it has its own
   answer independent of this group.

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
