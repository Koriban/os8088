# Printing — investigation and plan

**Status: DRAFT. Nothing is built. This document is the investigation and a
phased plan; phase 0 is a throwaway spike whose only job is to answer the one
question the rest of the plan rests on.**

The ask: OS8088 has no printing of any kind. SHEET's `File > Print...` and
SCRIBE's four print items were removed on 2026-09-04 rather than left as
entries that refuse (SPEC.md §81.5), because there is no backend behind them.
Add one — slowly, and without betting the kernel on it before the hardware
path is known to work.

This document is the investigation, the design decisions with the alternatives
rejected and why, a budget, and a phased plan in which every phase is useful
on its own and none of the early ones touches shared ABI.

---

## 1. What the tree already does, and what that buys

Four findings decided the shape. Three make this cheap; the fourth is the one
that has to be settled before anything else is worth building.

### 1.1 There is no printing anywhere, and that is unusually clean

`int 0x17` — the BIOS printer service — **appears in no file in the tree.**
There is no printer driver class in `kernel/driver.inc` (the five are
`DRVC_SOUND`, `DRVC_DISK`, retired-3, `DRVC_NET`, `DRVC_FILE`), no API slot
among the 152 in `apps/os88api.inc`, and no half-finished path to reconcile.

That is worth saying plainly because it is the good case: there is nothing to
be compatible with, no released ABI to keep, and no user with a working setup
to break. The only prior art is the two apps' dead menu items, and those are
already gone.

### 1.2 The port layer is written, field-tested, and deliberately stops one
instruction short

`drivers/net/lplink.inc` drives the parallel port for the LapLink transport,
and it already contains the two hard parts:

- **`lp_latch`** (`lplink.inc:149`) — the port probe. Takes a base address,
  forces the control register out of input mode, writes `AA` and then `55` to
  the data latch and reads each back, and restores *both* registers with the
  verdict carried in CF through a `pushf`/`popf` so the restore cannot clobber
  it. Two values and not one, so a floating ISA address cannot pass.
  `std_base` holds the three candidates in POST order — `3BC`, `378`, `278` —
  and the header records that both were confirmed on real machines
  (`docs/FIELD-MACHINES.md`): `3BC` on the Hercules-family calibration box,
  `378` on the DOS machine's DIO-500.
- **The control-register discipline.** `lp_init`'s header states it: the
  control register is **read-modify-write**, because **bit 2 is `INIT` and it
  is active low**, so `out base+2, 0` — the obvious way to put a port in a
  known state — *pulses reset at whatever printer is attached*. Only bit 5
  (direction) is touched; the low four bits are preserved exactly as found.

And the probe's header says why it restores what it found:

> *It restores what it found, which is not politeness: a printer on this port
> sees its data lines change, and because NOTHING IS STROBED, nothing prints.*

**Printing is precisely the instruction that file declines to execute.** The
author already reasoned about a printer sharing this port and arranged not to
disturb it. What is missing is the strobe, and the wait on `BUSY` around it.

### 1.3 The bit senses are already recorded, and both are traps

Two polarity facts are written down in `lplink.inc`, and both are the kind
that produce a hang or a reset rather than a wrong character:

- **`BUSY` is status bit 7 and is INVERTED in hardware** (`lplink.inc:206`).
  A *busy* printer drives the pin high, the card inverts it, and the register
  reads **0**. So "wait until the printer can take a byte" is *wait for bit 7
  to be **set***. Getting this backwards does not print garbage; it either
  hangs forever or floods the port ignoring the handshake entirely.
- **`INIT` is control bit 2 and is active low.** It must be held **high** for
  the whole of a print job. Writing a plausible-looking `0` to the control
  register resets the printer mid-page.

The idle control value a print job holds is therefore `0x0C` — `INIT` high and
`SELECT IN` asserted — never `0x00`.

### 1.4 The open question: nobody has ever strobed this port

Everything above is knowledge about the *card*. It says nothing about whether
a byte written and strobed reaches a device, because **no code in this tree
has ever strobed a parallel port**, on hardware or under an emulator. That is
phase 0's entire job, and it is the reason the plan does not begin with a
kernel change.

---

## 2. Where the code should live, and the alternative rejected

### 2.1 A new driver class is the destination, and not the starting point

The eventual home is `LPT.DRV` under a new `DRVC_PRINT`. The driver model
fits it exactly: `OSAPI_DRV_CALL` (0x0448) already exists as a generic
package→driver door taking `BH` = a `DRVC_*` class and `BL` = *a verb that
driver defines*, with `ES` = the caller's segment so a verb can read a buffer
the caller hands it, and a clean `CF=1, AX=0` when no driver of that class is
loaded. Its own header states the principle this plan inherits:

> *THE KERNEL KNOWS NOTHING ABOUT WHAT IS BEHIND IT, and that is the whole
> design. A sockets ABI in the API table would be a contract the kernel owes
> for ever and a driver ABI is one the driver owes.*

So **printing needs no new API slot.** The verbs live beside the driver that
answers them, exactly as the networking ones do, and the kernel gains no
printing code at all.

**But a class number is shared ABI.** `kernel/driver.inc` is explicit that
class numbers are never reused — class 3 sits retired and unusable precisely
because a class *is* an index into `drv_fptr*`, and renumbering would move
`DRVC_NET` and `DRVC_FILE`, "both of them shipped ABI, both of them named in a
`SYSTEM.CFG` somebody already has". Spending `DRVC_PRINT = 6` is a one-way
door. It should be spent when the thing behind it is known to work, not
before.

### 2.2 Package-level port I/O is precedented, and is the right spike

A package touching hardware directly is established practice in this tree, not
a workaround: MISSILE, CYCLONE and PAINT use `int 0x16`; TASKMGR uses
`int 0x12`; SHEET uses `int 0x1a` for `NOW()` (SPEC.md §81.42, which is
specifically the record of a *missing API being mistaken for a missing
capability*). Port I/O from a package is the same category.

So phase 0 puts the Centronics core in a throwaway test package, proves a byte
reaches a device, and is then **deleted**. It is a spike, not a shipping path:
the shipping path is the driver, and a package that keeps its own copy of the
port code is exactly the duplication §51 exists to prevent.

### 2.3 One port, two cables — the constraint that has to be a user choice

`NET.DRV` and a printer both want the parallel port, and they want *different
cables*: LapLink crosses data onto status lines, a printer cable is
straight-through. The port probe (`lp_latch`) passes either way — it only
tests the card's own latch — so **the OS cannot tell from the port which cable
is plugged in**.

That is not a defect to engineer around; it is the physical situation. It
means the two drivers are mutually exclusive on a one-port machine and the
*user* picks, which is what `SYSTEM.CFG` and the Drivers page already are for
("NOTHING LOADS UNLESS SYSTEM.CFG ASKS FOR IT", §51.3). The plan does not
attempt auto-arbitration; it states the exclusion and lets both refuse to
attach if the other holds the port.

---

## 3. The core, drafted

The whole of Centronics output, in the shape the tree's own conventions want.
Read-modify-write on the control register, `BUSY` polled with a timeout so a
missing or offline printer is an ordinary refusal (§47) rather than a hang,
and the two `jmp short $+2` settle idioms `lplink.inc` already uses.

```nasm
; -----------------------------------------------------------------------------
; lpt_putc - AL = the byte, [lpt_base] = the port. CF=1 = the printer did not
; take it (offline, out of paper, or not there) and NOTHING was strobed.
;
; BUSY IS STATUS BIT 7 AND IS INVERTED IN HARDWARE (lplink.inc's link-layer
; header): a printer that cannot take a byte drives the pin HIGH and the card
; inverts it, so the register reads 0 and READY is bit 7 SET. Backwards, this
; either spins for ever or ignores the handshake completely.
; -----------------------------------------------------------------------------
lpt_putc:
    push ax
    push cx
    push dx
    mov ah, al                      ; the byte, banked across the poll
    mov dx, [lpt_base]
    inc dx                          ; base+1 = status
    mov cx, 0                       ; 65536 polls, then give up: an offline
.wait:                              ; printer must REFUSE, not hang the task
    in  al, dx
    test al, 0x80                   ; bit 7 SET = not busy = ready
    jnz .ready
    dec cx
    jnz .wait
    stc                             ; nothing written, nothing strobed
    jmp .out
.ready:
    mov dx, [lpt_base]
    mov al, ah
    out dx, al                      ; the data latch first - the byte must be
    add dx, 2                       ; STABLE before the strobe edge
    in  al, dx                      ; READ-MODIFY-WRITE: bit 2 is INIT and is
    mov ah, al                      ; ACTIVE LOW, so a blind write resets the
    or  al, 0x01                    ; printer (lplink.inc's lp_init header)
    out dx, al                      ; strobe asserted
    jmp short $+2                   ; the period I/O settle idiom, twice, as
    jmp short $+2                   ; the nibble layer uses it
    mov al, ah
    out dx, al                      ; strobe released, everything else as found
    clc
.out:
    pop dx
    pop cx
    pop ax
    ret
```

`lpt_open` holds `INIT` high and `SELECT IN` asserted (`0x0C`) for the job and
restores the saved control byte at the end, which is `lp_init`/`lp_done`'s
shape one level simpler.

---

## 4. How it is verified, which is the part that is usually missing

**QEMU captures printed bytes to a file, byte for byte.** `qemu-system-i386`
is installed in this tree's environment and `-parallel file:out.txt` attaches a
character backend to the emulated LPT at `0x378` — confirmed to attach here.
So the gate is: boot, print a known string, compare the file. No emulator
patch, no screenshot, no pixel judgement.

That matters more than usual, because everything about this feature is
invisible: there is no window to photograph and the failure modes (a reset
pulse, an inverted `BUSY`, a strobe that never lands) all look like "nothing
happened".

**MartyPC is the second opinion and is weaker.** It has a real Centronics port
(`lpt_port.rs`, "Implementation of a basic Centronics printer port") with the
correct register model, and `os8088_5150_cga_lpt` already enables it. But the
only device it attaches to that port's channel is a Disney Sound Source, so
nothing captures bytes; and with no device attached the status register reads
all-zero, which under §1.3's inversion means **permanently busy**. A driver
that is correct will therefore *refuse* under MartyPC rather than print — a
useful negative test for the timeout path, and useless as a positive one
unless a printer device is added to the emulator (`tools/martypc/patches/`
already holds four local patches, so the mechanism exists).

---

## 5. Budget

| item | cost | where |
|---|---|---|
| `lpt_putc` + open/close + probe | ~120 bytes | phase 0: a spike package; later `LPT.DRV` |
| `LPT.DRV` complete | well under 1 KB | the smallest shipping driver, `FORMAT.DRV`, is 1,135 bytes |
| `DRVC_PRINT = 6` | ~26 bytes kernel `.bss` + one `drv_fptr`/`drv_fseg` pair + one `drv_tab` row | `kernel/driver.inc` |
| API slots | **none** | `OSAPI_DRV_CALL` is the door (§2.1) |
| SHEET's print path | ~300-400 bytes | SHEET has 5,264 bytes free |
| SCRIBE's print path | ~300 bytes | SCRIBE.OVL has 2,419 spare |

---

## 6. The phases

Each is useful alone, and the ABI commitment does not happen until phase 2.

**Phase 0 — the spike. Does a strobed byte arrive?**
A throwaway package that probes the three bases with a copy of `lp_latch`,
opens the port, writes `Hello, printer.` and a form feed, and reports what
happened in a window. Run under QEMU with `-parallel file:`; compare the file.
Then **delete the package**. Deliverable: a yes/no on §1.4, and a measured
answer on whether `BUSY` behaves as §1.3 predicts under QEMU. *Nothing shared
is touched and nothing is committed to.*

**Phase 1 — the gate, before the driver.**
`tests/lpttest` — boot under QEMU with a captured parallel file, print a known
byte sequence including the awkward ones (`0x00`, `0x1B`, high-bit bytes), and
diff. Mutation-tested by inverting the `BUSY` test, which must fail it.
Written against the spike so it exists before the thing it guards.

**Phase 2 — `LPT.DRV` and `DRVC_PRINT`.**
The kernel class, the driver, `drivers/lpt/lpt.inc` carrying the verbs
(`LPTV_STATUS`, `LPTV_WRITE`, `LPTV_FORMFEED`), a `drv_tab` row defaulting to
**not wanted**, and a Drivers-page entry. The port-exclusion note from §2.3
goes in the driver's header and in the page's refusal string. *This is the
one-way door, and it opens onto something already proven.*

**Phase 3 — SHEET prints.**
`File > Print...` returns. What it prints is the used range as text lines —
the cell text `sh_cell_totext` already produces, column-aligned, form feed at
the end. Not Excel's Page Setup, not headers and footers, not a print area:
those are §81.45.3's rule about not adding a menu item until the feature is
behind it, applied one command at a time.

**Phase 4 — SCRIBE prints.**
The document as text. `Print Preview`, `Print Merge` and `Printer Setup` stay
absent until each has something behind it.

---

## 7. Deliberately not in scope

- **Graphics printing.** Bitmapped output is a different problem (per-printer
  escape sequences, a raster path, dithering) and nothing above depends on it.
- **A printer driver *class* per printer model.** One `LPT.DRV` writing plain
  bytes serves every Centronics printer ever made. Escape sequences for bold
  or condensed print are a later cell in the service table, not a new class.
- **Serial printers.** The serial monitor driver was retired (§58,
  `DRVC_RETIRED3`) and there is no COM driver to hang one off.
- **Spooling.** Printing is synchronous and refuses when the printer is not
  ready. A queue is worth having only once there is something to queue.
- **Auto-arbitration with `NET.DRV`** over the shared port — §2.3.
