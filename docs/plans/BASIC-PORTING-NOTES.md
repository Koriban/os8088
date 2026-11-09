# Porting GFA-BASIC source to BASIC.O88

**Status: reference, 2026-11-04. NOT a requirement.** Branch `basic-o88`.

**GFA compatibility is not a goal** (SPEC §150): what is wanted from GFA is
its shape — a BASIC that an operating system's applications are written in —
and not its substance. If its substance were the goal, porting GFA itself
would be the honest course.

So this file is **what to expect if you ever hand-port a GFA listing**, and
nothing in it obliges BASIC/8088 to do anything. Its real value is the second
one: it is the clearest statement anywhere of how far the two languages
actually are apart, which is worth knowing before borrowing an idea from one
into the other. Companion to `BASIC-PLAN.md`, `BASIC-GUI-PLAN.md` and SPEC
§150.

Everything below was checked against the manuals in
`_LIBRARY/languages/basic/gfa-basic/` and, where it concerns BASIC/nw, by
running the reference implementation. Re-check it; do not quote it.

## 1. The type suffixes mean different things — fix these first

This is the hazard. GFA-BASIC 3's own table (*V3 Interpreter User Manual*,
"Variable Types") against BASIC/nw's (`language.md`, "Types"):

| suffix | GFA 3 | | BASIC/nw |
| --- | --- | --- | --- |
| `!` | **Boolean**, 1 byte, only 0 or −1 | → | **SINGLE**, a 4-byte float |
| `\|` | **Byte**, 1 byte | → | **nothing** — not a suffix here |
| `&` | **Word**, 2 bytes | → | **LONG**, 4 bytes |
| `%` | **Integer, 4 bytes** | → | **INTEGER, 2 bytes** |
| `#` | Float, 8 bytes | → | DOUBLE, 8 bytes — the one that agrees |
| `$` | String | → | String |

**`%` and `&` have swapped sizes.** That is the whole problem in one line.

- **`a%` is the killer.** GFA's `%` holds ±2147483647; BASIC/nw's holds
  ±32767. A GFA loop counter, a pixel product, a file length or a score in
  `a%` is fine there and **fails here**: `LET a% = 100000` stops the program
  with error 6, `Overflow`, on that line. At least it is loud. **Port `%` to
  `&`**, and only keep `%` where the value provably fits in 16 bits.
- **`&` the other way is harmless but not identical.** GFA's 2-byte word
  becomes a 4-byte long, so anything relying on 16-bit wraparound stops
  wrapping.
- **`!` is the quiet one.** GFA's `!` is a Boolean normalising any non-zero
  assignment to −1; here it is a float. `done! = TRUE` and `IF done!` both
  behave, because this language also uses −1 and 0 and treats non-zero as
  true — so the port *appears* to work. But `flag! = 5` is −1 in GFA and
  **5.0** here, and `flag! = 0.5` is −1 there and a true-ish 0.5 here.
  **Port `!` flags to `%`.**
- **`|` is a syntax error here.** There is no byte type. Port to `%`.

Nothing warns you about any of this except the `%` overflow, so do this pass
before the program runs, not after.

## 2. Parameters: the marking is inverted, and GFA's is sticky

GFA defaults to **by value** and marks by-reference with `VAR`. BASIC/nw
defaults to **by reference** and marks by-value with `BYVAL`. Worse, GFA's
marker is sticky: *"If the command VAR is found in the parameter list ... all
of the variables that follow will be treated as VAR-parameters"*, and it *"must
always appear as the last elements of a parameter list"*.

```basic
' GFA
PROCEDURE sum(x, y, VAR z)      ' x,y by value; z by reference
  z = x + y
RETURN

' BASIC.O88 — every parameter before the VAR needs BYVAL
DEF PROC sum(BYVAL x, BYVAL y, z)
    LET z = x + y
END PROC
```

Verified against the reference, with GFA's own two examples from the `VAR`
page: `sum 13,12,a` then `sum 7,9,b` prints **25 and 16**, as the manual says,
and the whole-array case works the same way —
`DEF PROC mean(BYVAL lo%, BYVAL hi%, arr%(), m)` receives `nums%()` by
reference with no keyword, because that is the default.

**Getting this wrong fails silently**: drop the `BYVAL`s and the callee gains
write access to arguments the GFA original protected. Nothing errors; a value
changes behind the caller's back.

One thing BASIC/nw can express that GFA cannot: the marking is **per
parameter**, not a sticky tail, so `DEF PROC p(BYVAL a, b, BYVAL c, d)` is
legal and means exactly what it reads.

### 2.1 `VAR` is taken, and means something else here

`VAR` is **not** a reserved word in BASIC/nw, and the name has been claimed for
BASIC.O88's **declaration** keyword — `VAR count AS INTEGER`, SPEC §150.13 —
which is the sense Pascal and most languages since have used it in, and which
reads better than `DIM`-ing a scalar.

So GFA's parameter `VAR` cannot share the word. A parser could tell them apart,
one being a statement and the other sitting inside a parameter list, but a
reader could not, and that is reason enough.

**A `VAR` in a parameter list is refused by name**, with the fix: mark the
parameters before it `BYVAL` and delete the `VAR`. Nothing is lost in the
translation, because by-reference is already the default here — only the
*marking* changes, per §2's table and worked example.

## 3. Procedure syntax

| GFA | BASIC.O88 |
| --- | --- |
| `PROCEDURE p(...)` … `RETURN` | `DEF PROC p(...)` … `END PROC` |
| `FUNCTION f(...)` … `RETURN x` … `ENDFUNC` | `DEF FUN f(...)` … `END FUN` |
| `@p(...)` or `p(...)` | `p ...` |
| `~f(...)` — call and discard | assign and ignore, or `VOID` if adopted |

**GFA's `RETURN` closes a procedure; here `RETURN` is `GOSUB`'s partner.** A
GFA procedure body ending in `RETURN` will not merely mis-parse — if it parses,
it is a `RETURN` with no `GOSUB`, which is a runtime error somewhere else
entirely. Replace every procedure-closing `RETURN` with `END PROC`.

`SUB`/`FUNCTION` are accepted as QuickBASIC means them, so a listing using
those needs no change.

## 4. Channel I/O needs no change

BASIC/nw gives file I/O its own four keywords — `EMIT`, `STORE`, `FETCH`,
`FETCH LINE` — but **the `#` forms still parse**. `PRINT #1`, `INPUT #1`,
`WRITE #1` and `LINE INPUT #1` all work, so GFA and QuickBASIC file code comes
across untouched. Converting to the four keywords is a readability choice, not
a port step. Using a channel keyword *without* a `#` is an error that names the
screen statement you wanted.

## 5. What is refused, and what that costs

Six spellings are refused permanently — `POKE`, `VARPTR`, `DEF SEG`, `OUT`,
`INP`, `WAIT` (SPEC §150.7) — because an 8086 has no MMU and a cooperative
kernel cannot hand out arbitrary writes. `PEEK` keeps its name for
introspection instead (§150.11), so **`PEEK(address)` is refused by name** and
a program that reads memory has to be rethought rather than translated.

`INLINE` is undecided. `PALETTE` is refused per adapter, being real on VGA and
EGA and meaningless on Hercules. `LPRINT` and `LOCK` are refused while they
remain true. Everything else in GFA's absent list — graphics, sound, keyboard
polling, file enumeration, rename — is implemented or planned, and
`basicnw/notes/REFUSAL-AUDIT.md` has the full 43 with reasons.

## 6. GEM calls

`GEMSYS`, `VDISYS`, `XBIOS`, `BIOS`, `GEMDOS` and `LINE-A` do not exist, and
neither do `CONTRL`, `GINTIN`, `GINTOUT`, `ADDRIN`, `ADDROUT`, `PTSIN`,
`PTSOUT` or `WORK_OUT`. They are GEM's ABI, not a general idea. All of it
collapses into one `OSAPI` verb taking a slot number and register values, with
`REG()` as the register file and `REG(R_CF)` for the carry flag that is this
OS's uniform failure channel. `BASIC-BINDINGS-PLAN.md` §2 has the construct-by-
construct mapping; the short version is that `WIND_*` becomes `WM_*`,
`SCRP_READ`/`WRITE` becomes `CLIP_GET`/`PUT`, and `V_OPNVWK` and its relatives
map to nothing because a window already has a surface.

The dialog family — `RSRC_LOAD`, `FORM_DO`, `OBJC_*`, `TEDINFO`, `ICONBLK` —
has no counterpart. Dialogs are built by calls here (`DLG NEW`, `DLG BUTTON`,
`DLG RUN`; SPEC §150.12), so a resource-driven dialog is rewritten rather than
ported.

## 7. Menus

`MENU m$()` keeps GFA's array, with one deletion: **`m$(3)` to `m$(8)` are
GEM's six desk-accessory slots and must be removed.** There are no accessories
here — the kernel owns that part of the bar and an application registers an
About handler instead — so the first menu is read like every other, items until
an empty string. `MENU m$()` recognises the GEM shape and refuses it by name
with that fix, rather than rendering six placeholder entries.

Also: **five menus per application** (`MENU_APPMAX`), and item text caps at 24
glyphs (`MENU_MAXCH`, derived from `MENU_MAXW` 208px). The kernel drops a sixth
menu silently, so `MENU` counts and refuses it first.

## 8. The order to do it in

1. **Suffixes** (§1). `%` → `&` wherever the value can exceed 32767; `!` flags
   → `%`; `|` → `%`. Everything else depends on the program having the right
   types.
2. **Procedure headers and closers** (§2, §3). `BYVAL` on every parameter
   before a `VAR`, then delete the `VAR` — which the compiler will demand of
   you, since `VAR` in a parameter list is refused by name (§2.1). The
   procedure-closing `RETURN` → `END PROC` change is the one that fails
   quietly, so do it by inspection rather than by waiting for an error.
3. **Menus** (§7). Delete `m$(3)`–`m$(8)`; check the menu count and item
   widths.
4. **GEM calls** (§6). `WIND_*`/`SCRP_*` to their `WM_*`/`CLIP_*` equivalents,
   or `OSAPI` for anything unwrapped.
5. **Dialogs** (§6). Rewritten, not ported.
6. **Refusals** (§5). Whatever is left will say so by name, with a reason, at
   the line that has it — which is the point of refusing by name and the only
   part of this list the language does for you.
