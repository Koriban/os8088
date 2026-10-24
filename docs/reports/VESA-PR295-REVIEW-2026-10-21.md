# Comment on `jggonz/os8088#295` — `VESA.DRV`, read against this fork's VBE work

A technical read of the upstream draft, requested by the owner, with this
fork's own `docs/reports/VBE-EFFORT-SUMMARY-2026-10-21.md` as the point of
comparison. Not posted to the PR — this is local commentary; say the word if
it should go up as a review comment instead.

**This replaces an earlier, thinner pass on the same PR from a few days
prior**, which only had the PR's description and file list to go on and
called it "QEMU-only, no real hardware." That was accurate as of when it was
read and is no longer the whole picture: S7 landed since, with a 486DX2/66 +
Cirrus CL-GD5428 timing pass on 86Box. The PR's own Testing section is still
honest about the remaining gap, and that gap is this review's main finding —
not that the PR is lying about its evidence, but that its evidence sits one
rung below this fork's.

## 1. What it actually is

A fifth adapter kind, `VID_VESA`, whose renderer is a **loadable driver**
(`drivers/vesa/vesa.asm`, ~2,520 lines) rather than resident kernel code.
`VESA.DRV` probes VBE at attach, builds a table of every 8/15/16bpp packed
mode from 640×400 to 1024×768 the card offers, picks the largest (or the
`SYSTEM.CFG` class byte's choice), and draws through the card's 64KB window A
via `4F05h` banking — at any of those depths, not one fixed mode. The kernel
side is one compare-and-untaken-branch (`VIDEXT`) inserted into each planar
drawing body, far-calling the driver when it is attached: the same shape as
the dual-display hook, one line below it. A new OSAPI slot, `OSAPI_GFX_BLITD`,
is how a package reaches the real depth instead of the desktop's fixed 16
colours — PiXEL was ported to use it at 16bpp as the proof.

That is a materially larger feature than this fork's: one mode, planar,
4bpp, zero new kernel API surface, versus five-plus modes across two pixel
formats and one new OSAPI cell. Worth saying plainly before anything below
reads as a complaint about scope — the PR is not trying to build what this
fork built, it is building something bigger, and some of what follows is
simply the bill for that.

## 2. The code itself holds up well, read closely

I read `vx_prim`'s dispatcher, `vx_setwin`/`vx_nextwin`/`vx_addr` (the
bank-select and address-of-pixel routines), `vx_rowfill`/`vx_rowcopy`/`vx_px`
(the window-edge-crossing primitives) and `vx_offer`/`vx_select` (mode
qualification). Three things stood out as genuinely sound, not just
plausible-looking:

- **Every piece of per-call state that must survive across a window crossing
  is read `[cs:...]`, consistently**, in `vx_setwin`, `vx_rowfill`,
  `vx_rowcopy`, `vx_px`. That is exactly the defect this fork's own stage 2
  cost two of its five field-found bugs to learn (`ROW_BYTES`→`[vid_stride]`
  needing `cs:`, and `vbe_bank` addressing its own state through a DS it had
  already given away) — §39.29.10.1/§39.29.10.2 in
  `VBE-EFFORT-SUMMARY-2026-10-21.md`. The PR's driver arrived with that
  lesson already applied rather than needing to re-learn it in the field,
  which is either luck or a careful read of how this kernel's DS contract
  actually works inside a far-called body. Either way it is the right code.
- **The window-crossing test is a carry check on the address arithmetic**
  (`add bx, cx` / `jnc`, in `vx_rowfill` and `vx_rowcopy`), not a separate
  bounds compare. That is the same shape as this fork's own stage-2 insight
  — the natural 16-bit carry IS the bank crossing — applied independently, to
  a window edge rather than a 64KB page.
- **`vx_offer`'s mode qualification is defensive in the right places**:
  it rejects anything whose window isn't exactly A000/64KB/writable, rejects
  non-power-of-two granularities, and rejects a stride shorter than a row.
  A BIOS that answers something subtly wrong gets refused rather than drawn
  on incorrectly — the same posture `vidsel.inc`'s fifth-kind `%error` and
  this fork's own `vx_attach`-equivalent refusal path take.

## 3. Where the evidence still sits one rung below this fork's

- **No real VBE card has ever booted it.** The PR's own Testing section says
  so directly: *"QEMU's standard VGA carries a VBE BIOS and is the fixture;
  MartyPC and the 86Box XTs have no VBE and are the negative control. No real
  VBE card has been booted; that limitation stays in the plan until a field
  run says otherwise."* That is the right way to write an open limitation,
  and it is still a real one. This fork's equivalent claim is not "we also
  used QEMU as a fixture" — QEMU cannot map a VBE window at A000 at all, on
  either tree, which §39.28.1 and the PR's own S1 note both independently
  confirm (QEMU's `0104h` answers `003B`, not VGA-compatible, and the window
  is not addressable). What this fork has that the PR does not yet is a
  *second independent real chip* in the loop at all: the Satellite 4025CDT's
  C&T 65555 confirmed every stage before it shipped, and found three of the
  five field defects.
- **S7's 486+Cirrus pass is real progress and the right instrument, but it is
  a timing fixture, not a correctness one.** `vm/486-vesa` is 86Box modelling
  a Cirrus CL-GD5428's real BIOS — the same category of improvement this
  fork made going from QEMU to 86Box's Trident for development — and the
  numbers it produced (BIOS call 7.0 µs, a `rep stosw` fill at the VL bus's
  10.7 MB/s, the depth-blit/restore rewrite from 7.9ms to 3.4ms) are
  specific and measured, not asserted. But `docs/TESTING.md`'s own standing
  position — echoed in this fork's SPEC.md §39.29.8's heading, "86Box is the
  development machine, and QEMU cannot be" — is that an emulator's model of
  one chip answers *that chip's* questions and nothing wider. A correctness
  question (does the real card's bank register behave as assumed; does the
  real card's BIOS answer the mode-info block the same way) is not what a
  timing bench on the same emulated chip can settle, and nothing in the PR's
  evidence list yet does.
- **Resident/size cost is larger and has crossed a rung**, where this fork's
  stayed inside one: through S6, `.text` +562, `.cold` +247, `.lowbss` +128,
  `.bss` +5, and *"the image rung crossed once at S2."* This fork's whole
  feature (§5 above) is `.text` +312, `.ovl` +12, `.cold` +0, no rung
  crossed. That is not a fair apples-to-apples number — the PR's feature
  does more — but it is the number a reviewer should actually compare
  against `docs/KERNEL-MEMORY.md`'s budget rather than the PR's own
  framing, and it is worth watching through S8.

## 4. One structural question worth asking before merge, not a defect

`VESA.DRV` is an overlay with a `drv_tab` row, "VMMOUSE.DRV's shape": no
class, because the kernel is its only caller and holds the far pointer. This
fork's `VBE.DRV` is `XMEM.DRV`'s shape instead — no `drv_tab` row at all,
because a machine either has the mode or it does not and a settings-page tick
would only be a way to break a working one (`VBE-EFFORT-SUMMARY-2026-10-21.md`
§5). The PR's driver needs a row because it is genuinely choosable (multiple
depths and resolutions, not one fixed mode), so the two designs are each
right for the scope they chose — this is not a case where one fork should
copy the other. It is worth naming here only because a reviewer comparing the
two PRs by file-count or line-count alone would miss that the shape
difference is load-bearing, not incidental.

## 5. Bottom line

Well-built code, by a team that has independently converged on several of
the same hard-won lessons this fork paid field round trips for (CS-relative
state, carry-as-bank-test). The gap that matters is not code quality, it is
evidentiary: the PR has not yet put a physical VBE card in the loop, and its
newest evidence (S7) answers a timing question on an emulated chip rather
than the correctness questions only real silicon settles. That gap is
explicitly acknowledged in the PR's own words, which is the right way to
leave it open — but it is the one thing this review would flag before S8
("Acceptance") closes it out.
