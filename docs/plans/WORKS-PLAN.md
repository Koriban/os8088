# An integrated works — AppleWorks' shape, not ClarisWorks'

**The decision this plans:** a works suite built as **separate packages sharing
a Desktop and a typed clipboard of their own**, not as one program and not by
typing the system clipboard. Architecture C of three, chosen by the owner.

Nothing is built. This is the record of what the choice costs and what it
rules out, written first because the two cheap mistakes here are both
architectural and neither is visible once code exists.

---

## 1. The number that decides the architecture

**SHEET is 61,866 resident** — image 52,535 plus bss 9,331 — against
`APP_MAX_SIZE` = `0xFE00` = **65,024**. Three thousand spare, with
charting and the macro engine *already* pushed out into `CHART.OVL` and
`MACRO.OVL`.

So **one package holding a spreadsheet and a word processor is arithmetically
impossible**, and that is settled before any design argument. It also rules
out the shape most people picture when they hear "integrated".

Measured 2026-10-21 from the package header (`image_unwrap`, `+8`, `+10`).
**Re-measure it; do not quote this.**

---

## 2. Four of the five modules already exist

| works module | what exists today |
|---|---|
| spreadsheet | **SHEET** (§81) — formulas, macros, four sheets |
| charts | **CHART.OVL** (§82, §84), in that same package |
| word processor | **WORD** (§68), **CWORD** (§73.12), **SCRIBE**, **TEXPAD**, **NOTEPAD** |
| draw / paint | **PAINT** (§42), **ARTFUL**, **PIXEL** |
| communications | **TELNET** (§70), the browser (§71) |
| **database** | **no.** §81.65 is Excel's `DSUM`/`DCOUNT` over a cell range with criteria rows — a function family, not a record database with forms and reports |

**So the work is not the modules. It is the integration**, plus one new
program.

---

## 3. The target is AppleWorks 1.0, and that is a cost decision

AppleWorks (1984, 128 KB Apple //e) was **three modes sharing a Desktop** — a
list of open files — **and a clipboard that moved data between them**. There
were **no embedded frames**: you could not put a live spreadsheet range inside
a letter. ClarisWorks added frames in 1991 on a Mac with megabytes.

**Frames are the expensive half of "integrated" and they are not in this
plan.** A frame needs a container document, a layout that reflows around a
foreign rectangle, a renderer for each embedded type, and a rule for what a
stale embed shows. On a 4.77 MHz 8086 that is a different project, and
AppleWorks shipped a product people used for a decade without it.

---

## 4. The clipboard — and the first draft of this plan had it WRONG

The obvious first move is "give the kernel a typed clipboard". **It is wrong,
and `kernel/clip.inc` says why in its own header** — text-only is recorded
there as *"a decision rather than a first step"*:

> A typed clipboard needs a format registry, a negotiation between the putter
> and the getter, and a rule for what happens when neither side understands
> the other — and the thing every app here actually wants to hand another app
> is a run of characters. Paint's bitmap clipboard stays Paint's own
> (SPEC.md 42), because a picture pasted into Note Pad has no meaning to
> negotiate about.

That reasoning is still right **for the apps that exist**, and a suite does
not make it wrong — it makes it inapplicable *within the suite*. The
precedent is already in the tree and named in that very paragraph: **Paint
owns a richer clipboard of its own** (`pt_clip_need`).

**So the suite gets its own typed clipboard, and `OSAPI_CLIP_*` is not
touched.** No kernel change, no format registry in the kernel, no ABI
question, and the system clipboard goes on doing what it is good at — a cell
range copied as tab-separated text still pastes into Note Pad, which is a
feature and not a consolation.

### 4.1 Where a clipboard shared by SEPARATE packages lives

Paint's is a heap claim inside one package; the suite's has to cross package
boundaries. Three ways, and the cheapest is also the most faithful:

| | | |
|---|---|---|
| **a file** in `SYSTEM/APPDATA/` (§19.9) | nothing new at all | a disk write per copy — ~400 ms an `int 13h` on the target |
| a heap claim with a shared owner tag | fast | `MEM_K_*` tags are the KERNEL's; a package cannot find another package's claim |
| a `.DRV` publishing verbs (§51) | idiomatic — it is how ETHER and EMS publish surfaces | a new `DRVC_*` class number, **which is ABI** (§20.2.0.1) |

**Take the file.** AppleWorks' own Desktop and clipboard were disk-backed and
nobody minded, the cost lands on an explicit Copy rather than on typing, and
it needs no new mechanism whatever. If the write ever measures badly the
driver is still there to move to — and moving to it is a change to the suite,
not to the kernel.

---

## 5. What gets built

### Story 1 — the typed clipboard file, and ONE pair that uses it
`SYSTEM/APPDATA/WORKS/CLIP.DAT`: a small header (a type tag, a length, a
producer) and a payload. **Two formats in this story and no more** — a cell
range (SYLK, which SHEET already writes) and plain text — and exactly one
producer and one consumer wired to it, so the format is proved by use before
a second module depends on it.

### Story 2 — the Desktop
`SYSTEM/APPDATA/WORKS/DESKTOP.DAT`: the list of open documents, their types,
and which was last active. A launcher reads it and opens the right package
through `OSAPI_PKG_RUN` — the call The Wire already uses for the desktop zone,
so this is a second caller rather than a new mechanism (§92).

### Story 3 — the record database
**The one genuinely new program.** Records, fields, a form view, a list view,
and a report. Its own package, so it never competes with SHEET for bytes. Its
file format is this suite's, not Excel's — §81.65 stays what it is.

### Story 4 — the suite's own look
A shared menu spine and the same keys for the same thing across the modules,
which is most of what made AppleWorks feel like one program. `apps/os88ui.inc`
is where anything reusable goes, not a fourth copy per package.

### Story 5 — the one thing that will be asked for
**A chart in a document, as a PICTURE.** CHART already exports BMP; PAINT
already reads one. A chart pasted as a picture is a *snapshot*, not a frame —
it does not update when the numbers change, and the status row must say so.
That is the honest 80% of frames for none of their cost, and it is the
boundary this plan defends.

---

## 6. What this will NOT do, pinned so it is not re-litigated

- **Live frames.** §3. A pasted chart is a picture and says so.
- **A typed SYSTEM clipboard.** §4. `OSAPI_CLIP_*` is untouched.
- **One binary.** §1, by arithmetic.
- **A new driver class**, unless §4.1's file measures badly, and then with a
  number attached.
- **Replacing any existing app.** SHEET, PAINT and the word processors stay
  exactly what they are; the suite is a Desktop and a clipboard they can join.

---

## 7. The first measurement, before story 1

`SYSTEM/APPDATA/WORKS/CLIP.DAT` costs a write per Copy. **Measure that write
on MartyPC at 4.77 MHz before the format is designed around it**, because if a
Copy is a second and a half the answer is a different story 1, and that is
much cheaper to learn now than after two modules speak the format.

The number to beat is the one PERFORMANCE.md already gives: ~400 ms an
`int 13h`, near enough whatever it moves.
