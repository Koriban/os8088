# BASIC.O88 — BASIC/nw as a native package

**Status: planned 2026-11-04. Nothing built.** Branch `basic-o88`.

BASIC/nw is a QuickBASIC 4.5-line structured BASIC with a complete
implementation in TypeScript at `~/Src/Prj_8086/basicnw/` — a lexer, parser,
analyser, compiler and interpreter, 64 built-in functions, five types, and 370
passing tests. It was written to be a **plot device** in a game: the player
wrote BASIC inside the fiction of a sealed machine. This plan brings the
language here, where the machine is not sealed.

Read `basicnw/notes/REFUSAL-AUDIT.md` first. It is the reason this is tractable:
of the 43 spellings BASIC/nw refuses, 26 refuse nothing this OS lacks.

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

**Wave 0 — the seam.** The SPEC chapter written (it takes the next free number, 126); `BASIC.O88` is a window with a
menu bar, an `os88text.inc` editor pane and an `os88con.inc` output pane, and a
`RUN` that does nothing. Proves the UI, the overlay seam and the size budget
before any language work. Exit: it builds, opens, types, and `make` reports the
image+bss figure.

**Wave 1 — expressions and `PRINT`.** Lexer, the expression half of the
parser, the op stream, `%` and `#` arithmetic on `os88fp.inc`, `PRINT` to the
console, `LET`. Gap 1 (double↔text) lands here because `PRINT 1.5` needs it.
Exit: the differential oracle (§8) agrees with the TypeScript on a set of
expression programs.

**Wave 2 — control flow and procedures.** `IF`/`ELSEIF`, `SELECT CASE` with
lists, `TO` ranges and `IS`, `FOR`/`NEXT` with `STEP`, `WHILE`/`WEND`,
`DO`/`LOOP` both ends, `EXIT`, `GOTO`/`GOSUB`, `DEF PROC`/`DEF FUN` with
`SHARED` and `STATIC`, recursion.

**Wave 3 — strings and arrays.** Gap 3 (the heap). `DIM` including
`a TO b` and `OPTION BASE`, `REDIM`, `ERASE`, `SWAP`, `LSET`/`RSET`,
`TYPE`/records, dotted names, the string built-ins.

**Wave 4 — the built-in library, in the overlay.** All 64. Gap 2 (32-bit
mul/div) lands here for `CLNG`/`MKL$`/`CVL`. `PRINT USING`.

**Wave 5 — files, honestly.** Channels on `FILE_READ_AT`/`WRITE_AT` from the
start, never a whole-file string: `OPEN`/`CLOSE`, the four channel keywords
(`EMIT` `STORE` `FETCH` `FETCH LINE`) and the `#` forms, `FOR RANDOM` with
`FIELD`/`GET`/`PUT`, `EOF` `LOF` `INPUT$`, and then the five file surfaces the
audit calls SCOPE: `OPEN FOR BINARY`, `BLOAD`, `BSAVE`, `NAME`, `FILES`.

**Wave 6 — errors and the rest of the console.** `ON ERROR GOTO`, `RESUME`
in its three forms, `ERROR n`, `ERR`/`ERL`, the error table from `errors.md`.
`INPUT`/`LINE INPUT`, `INKEY$` on `KEY_DOWN`, `DATA`/`READ`/`RESTORE`,
`SOUND` on `SND_TONE`.

**Wave 7 — graphics, as one decision.** The audit's point: `SCREEN` is the
question and the other twelve surfaces follow from how it is answered. A BASIC
window already has a surface, so there are no mode numbers to set; decide what
`SCREEN n` *means* here before implementing `PSET`.

**The end state is in the tree already.** `reference/gorillas/gorilla.bas` is
1,135 lines of real QuickBASIC that the Gorillas app was hand-ported from, and
it uses 106 graphics, sound and memory statements. Running it is the honest
finish line for wave 7 — and it is worth noticing that today's refusal set
would reject that file 106 times while sitting in the same repository as the
native port of it.

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

1. **Does `RUN` block?** A BASIC program is a loop; this is a cooperative OS.
   Either the interpreter runs N ops per `W_IDLE` (responsive, and `SLEEP`/
   `INPUT` become natural yields) or it owns the machine until `END`. The op
   stream makes the first cheap, and it is almost certainly right — but it
   decides the shape of every statement that waits.
2. **`!` as a narrowed double** — stated above as a simplification. Worth
   confirming against §84.2 before wave 1 rather than after.
3. **One window or two?** Editor and output as panes of one window, or a
   separate output window that a `RUN` raises. QuickBASIC used one screen and
   F5; two windows is more this OS's idiom.
4. **Does the editor want `os88text.inc` as-is?** No selection and no undo is
   thin for a program editor. Decide whether wave 0 accepts that or grows §83.
