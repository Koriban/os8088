#!/usr/bin/env python3
"""Do SHEET's three file formats say what they mean? (SPEC.md 81.38)

    make && python3 tests/sheetfmt.py

SHEET reads and writes BIFF3, SYLK and DIF, and until this existed **nothing
outside SHEET had ever read one of its files**.  A format was working because
SHEET could open what SHEET had written.

That is the weakest evidence there is about an interchange format, because a
writer and a reader that share a misunderstanding agree with each other
perfectly.  The round trip passes, every number comes back, and the file is
one no other program can open.  Both defects this test found on its first run
are of exactly that shape, and neither was visible from inside SHEET.

**So the input is authored on the HOST.**  `tools/os88sheetfmt.py` writes a
SYLK file from the published grammar - not from `sheet.asm` - and the guest is
handed that.  A defect in SHEET's reader therefore cannot be cancelled out by
the matching defect in its writer, which is the one thing a save-then-load
round trip can never see.

The shape of a run:

  1. A 360KB disk carrying SHEET, `CHART.OVL` and the host's `SHIN.SLK`.
  2. **The file is opened by DOUBLE-CLICKING IT**, not through File>Open.
     SHEET claims `.SLK` and `.DIF` (SPEC.md 20.9), so the association starts
     the app with the document already loaded - which removes the file
     dialog, and with it every coordinate that would otherwise have to be
     calibrated to open the thing at all.
  3. File > Save As... three times, once per format.  The dialog asks for the
     FORMAT and derives the extension itself (SPEC.md 81.36), so the name is
     never typed: `SHIN.BIF`, `SHIN.SLK`, `SHIN.DIF` at the root of B:, with
     the input left untouched inside `APPS`.
  4. `os88flush` takes the floppy back off the emulator and the host reads all
     three.

WHAT EACH FORMAT CAN AND CANNOT CARRY, because a comparison that ignores this
is testing the wrong thing:

  * **DIF cannot say WHICH error a cell holds.**  Its value indicators are V,
    NA, TRUE, FALSE and ERROR - one ERROR for all seven.  So any error
    compares equal to any error in DIF, and only BIFF and SYLK are held to the
    specific one.
  * **DIF has no empty cell.**  It is a rectangle of tuples, so the cells past
    the end of a short column are written as NA.  Those are ignored rather
    than read as errors.
  * **A quoted TRUE in SYLK is ambiguous** and the format cannot fix it:
    Walden requires logical values to be quoted, which makes them
    indistinguishable from the text "TRUE".  Either reading is accepted here.
  * **Numbers compare with a tolerance.**  BIFF keeps the bits of a double;
    SYLK and DIF keep a decimal rendering of it.

Run it against a SHEET built before the two fixes and steps 5 and 6 fail:
that is the A/B, and it is what says this test contains its own cases.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "unit"))
import os88marty as M                                       # noqa: E402
import os88flush                                            # noqa: E402
import os88sheetfmt as F                                     # noqa: E402
from os88mouse import Mouse                                  # noqa: E402
import dispcp                                                # noqa: E402
from harness import check, done                              # noqa: E402

KINDS = ('bif', 'slk', 'dif', 'csv', 'txt', 'dbf')
MACHINE = "os8088_5150_cga_gla"
SYS = "build/os8088-360.img"
DISK = "build/sheetfmt.img"

# The cells the HOST authors.  One of everything the value model has that a
# text format can express, plus the two that turned out to matter:
#   B3 carries a SEMICOLON, which SYLK reserves as its field separator and
#      escapes by doubling.
#   A5 carries an ERROR, whose code BIFF numbers differently from the
#      ERROR.TYPE worksheet function.
CELLS = {
    # DATABASE-SHAPED ON PURPOSE: row 0 names the fields and rows 1..3 are
    # records, which is Excel's own database-range convention and the only
    # shape .DBF can carry. A ragged sheet would test a fixed-width typed
    # format against something it is not for.
    (0, 0): 'NAME',   (0, 1): 'QTY', (0, 2): 'PRICE',      (0, 3): 'FLAG',
    (1, 0): 'Widget', (1, 1): 12.0,  (1, 2): 1.5,          (1, 3): ('bool', True),
    (2, 0): 'a;b',    (2, 1): 7.0,   (2, 2): -2.25,        (2, 3): ('err', '#DIV/0!'),
    (3, 0): 'Gadget', (3, 1): 3.0,   (3, 2): 1234567.89,   (3, 3): 'x',
    # Column 4 is FORMULAS, authored as SYLK ;E expressions, and it is here
    # for the FORMULA record rather than for its values: two ordinary ones
    # and one VOLATILE one, so the option-flags check below has both cases.
    (0, 4): 'CALC',
    (1, 4): ('formula', 'B2+1', 13.0),
    (2, 4): ('formula', 'B3+1', 8.0),
    (3, 4): ('formula', 'RAND()', 0.5),
}

# The one cell whose value cannot be pinned, and the two that must not be
# volatile.  RAND is the only function this app emits that is both volatile
# and always numeric - NOW answers #N/A on a machine with no RTC, and every
# machine here is one (SPEC.md 81.43.1).
VOLATILE_CELL = (3, 4)
PLAIN_FORMULA = (1, 4)

# Which columns .DBF must make numeric: a dBASE field has ONE type for the
# whole column, so a column is N only if every record in it is a number.
def _isnum(v):
    return isinstance(v, float) or (isinstance(v, tuple) and v[0] == 'formula'
                                    and isinstance(v[2], float))


DBF_NUM = {c for c in range(5)
           if all(_isnum(CELLS.get((r, c))) for r in (1, 2, 3))}

# Calibrated by holding each menu open and photographing it, per the standing
# rule about pull-down offsets.  A missed click does not corrupt anything: the
# file simply is not written, and step 4 says which one.
FILE_MENU = (75, 45)
SAVE_AS = (90, 92)                  # File's 4th item, pitch 11 from y=59
# Format > Cell Protection..., item 4 on the same bar.  Every sh_fdlg dialog
# is one fixed size centred on the screen whatever its row count, so the
# radio column and OK below are the SAME coordinates the format dialog uses
# and did not need calibrating again (81.47).
FORMAT_MENU = (259, 45)
CELL_PROT = (259 + 34, 59 + 11 * 4)
FMT_RADIO_X = 246
# MEASURED, not stepped: the radio glyphs sit at 55/71/87/103/119/135, a pitch
# of SIXTEEN. This table was 59/73/87 with a pitch of 14 while the dialog had
# three entries, which lands inside the right row for the first three and
# drifts a whole row by the sixth - so adding DBF silently saved a .TXT
# instead. The standing rule about not reusing a remembered dialog offset
# applies to a pitch just as much (81.41).
FMT_Y = {'bif': 55, 'slk': 71, 'dif': 87,   # Normal / SYLK / DIF ...
         'csv': 103, 'txt': 119,            # ...CSV / Text (81.40)
         'dbf': 135}                        # ...and DBF 3 (81.41)
FMT_OK = (267, 170)
SAVE_BUTTON = (340, 65)
APPS_FOLDER = (140, 67)
SHIN_ROW = (165, 121)

# SHEET's extensions against os88sheetfmt's names for the grammars.
READER = {'bif': 'biff', 'slk': 'sylk', 'dif': 'dif',
          'csv': 'csv', 'txt': 'txt', 'dbf': 'dbf'}


def build_disk():
    import subprocess
    open("build/SHIN.SLK", "wb").write(F.write_sylk(CELLS))
    subprocess.run([sys.executable, "tools/os88disk.py", "-o", DISK,
                    "--size", "360", "APPS:build/sheet.o88",
                    "APPS:build/CHART.OVL", "APPS:build/SHIN.SLK"],
                   check=True, stdout=subprocess.DEVNULL)


def want(kind, key):
    """What this format is allowed to come back with for a cell."""
    if key == VOLATILE_CELL:
        return 'volatile-any-number'      # RAND: a number in [0,1), no more
    v = CELLS[key]
    if isinstance(v, tuple) and v[0] == 'formula':
        v = v[2]                          # a formula compares as its VALUE:
                                          # every format here writes the
                                          # result, and only BIFF also carries
                                          # the tokens
    if kind == 'dbf':
        # Row 0 becomes the FIELD NAMES, so it returns as text either way.
        # Below it, a column is numeric only if the whole column is.
        if key[0] == 0:
            return v
        if key[1] in DBF_NUM:
            return v
        if isinstance(v, tuple):
            return v[1] if v[0] == 'err' else ('TRUE' if v[1] else 'FALSE')
        return v
    if kind in ('csv', 'txt') and isinstance(v, tuple):
        # NEITHER FORMAT HAS A TYPE FIELD. An error goes out as its own
        # spelling and comes back as the TEXT of it; a logical likewise. That
        # is the format's limit, not the app's, and the file is still right.
        return v[1] if v[0] == 'err' else ('TRUE' if v[1] else 'FALSE')
    if kind == 'dif' and isinstance(v, tuple) and v[0] == 'err':
        return 'any-error'
    if isinstance(v, tuple) and v[0] == 'bool':
        # DIF has real TRUE and FALSE indicators, but that does not help
        # here: the ambiguity is introduced when the INPUT is read, and SYLK
        # cannot tell a logical from the text "TRUE".  Whatever SHEET decided
        # at that moment is what every output inherits, so all three formats
        # are held to the same loose expectation.
        return 'bool-or-text'
    return v


def agrees(kind, expect, got):
    if expect == 'volatile-any-number':
        if isinstance(got, tuple) and got and got[0] == 'formula':
            got = got[2]                  # BIFF and SYLK hand back the
                                          # expression as well as the value,
                                          # and it is the value that varies
        if kind in ('csv', 'txt', 'dbf') and isinstance(got, str):
            try:
                got = float(got)          # these three have no type field
            except ValueError:
                return False
        return isinstance(got, float) and 0.0 <= got < 1.0
    if expect == 'any-error':
        return isinstance(got, tuple) and got and got[0] == 'err'
    if expect == 'bool-or-text':
        return got == ('bool', True) or got == 'TRUE'
    return F.close(expect, got)


def cell_xfs(data):
    """{(row, col): ixfe} for every cell record, and [XF_TYPE_PROT] per XF.

    81.47: a cell whose format byte is its whole formatting names one of the
    64 base XFs, and one that also carries a border or a non-default
    protection names an extra XF written after them.
    """
    cells, xfs = {}, []
    i = 0
    while i + 4 <= len(data):
        op, ln = struct.unpack_from("<HH", data, i)
        if ln == 0 and op == 0:
            break
        b = data[i + 4:i + 4 + ln]
        if op in (0x0243, 0x0443) and ln >= 12:
            xfs.append(b[2] & 3)                      # bit0 locked, bit1 hidden
        elif op in (0x027E, 0x0203, 0x0204, 0x0205,
                    0x0206, 0x0406) and ln >= 6:
            r, c, xf = struct.unpack_from("<HHH", b, 0)
            cells[(r, c)] = xf
        i += 4 + ln
    return cells, xfs


def recalc_flags(data):
    """{(row, col): option flags} for every FORMULA record in a BIFF stream.

    5.50: BIFF3-4 FORMULA is 0206H/0406H, and the option flags sit at offset
    14 of the body with bit 0 = "Recalculate always".  3.11's legend requires
    that bit whenever the token array contains a VOLATILE function - of the
    five (RAND, NOW, INDIRECT, OFFSET, CELL) this app can emit three.  Written
    with the bit clear, as every record was until 81.44, a =RAND() saved by
    SHEET opens in Excel frozen at the value SHEET cached.
    """
    out = {}
    i = 0
    while i + 4 <= len(data):
        op, ln = struct.unpack_from("<HH", data, i)
        if ln == 0 and op == 0:
            break
        if op in (0x0206, 0x0406) and i + 4 + ln <= len(data) and ln >= 18:
            b = data[i + 4:i + 4 + ln]
            row, col = struct.unpack_from("<HH", b, 0)
            out[(row, col)] = struct.unpack_from("<H", b, 14)[0]
        i += 4 + ln
    return out


def main():
    build_disk()
    with M.launch(SYS, apps=DISK, machine=MACHINE) as m:
        M.settle(m)
        mo = Mouse(marty=m)
        dispcp.open_drive(m, mo, lambda n: m.sym(n), M.settle, letter="B")
        M.settle(m)
        mo.dblclick(*APPS_FOLDER)
        M.settle(m)
        mo.dblclick(*SHIN_ROW)          # the ASSOCIATION opens it
        M.settle(m, limit=180)

        # A1 is the selected cell on load, so this needs no cell click:
        # mark it UNLOCKED, which travels in the same byte as a border and
        # through the same (format, border) pair table, so it exercises the
        # whole of 81.47's extra-XF mechanism without the Border dialog.
        mo.menu(FORMAT_MENU[0], FORMAT_MENU[1], CELL_PROT[0], CELL_PROT[1])
        M.settle(m)
        mo.click(FMT_RADIO_X, FMT_Y['slk'])     # row 1 = Unlocked
        M.settle(m)
        mo.click(*FMT_OK)
        M.settle(m, limit=120)

        for kind in KINDS:
            mo.menu(FILE_MENU[0], FILE_MENU[1], SAVE_AS[0], SAVE_AS[1])
            M.settle(m)
            mo.click(FMT_RADIO_X, FMT_Y[kind])
            M.settle(m)
            mo.click(*FMT_OK)
            M.settle(m, limit=120)
            mo.click(*SAVE_BUTTON)
            M.settle(m, limit=180)

        vol = os88flush.Flush(marty=m).volume(1)
        names = vol.names()
        got = {}
        biff_raw = None
        for kind in KINDS:
            name = 'SHIN.%s' % kind.upper()
            check(name in names, "%s written" % name,
                  "%s is not on the disk - the save for it did not happen "
                  "(names: %s)" % (name, names))
            if name in names:
                raw = vol.read(name)
                if kind == 'bif':
                    biff_raw = raw
                got[kind] = F.read(name, data=raw, kind=READER[kind])

    for kind in KINDS:
        if kind not in got:
            continue
        cells = got[kind]
        bad = []
        for key in sorted(CELLS):
            expect = want(kind, key)
            if key not in cells:
                bad.append('%r missing' % (key,))
            elif not agrees(kind, expect, cells[key]):
                bad.append('%r: authored %r, %s says %r'
                           % (key, CELLS[key], kind, cells[key]))
        check(not bad, "%s round trip" % kind.upper(),
              "the host wrote a SYLK file, SHEET read it and wrote %s, and "
              "the host disagrees about %d cell(s): %s"
              % (kind.upper(), len(bad), '; '.join(bad)))

    if biff_raw is not None:
        cells, xfs = cell_xfs(biff_raw)
        check(len(xfs) > 64,
              "an unlocked cell gets an XF of its own",
              "the file carries %d XF records; 81.47 writes 64 base ones and "
              "then one per (format, border/protection) pair, so A1 being "
              "unlocked should have produced a 65th" % len(xfs))
        a1 = cells.get((0, 0))
        check(a1 is not None and a1 >= 64 and not (xfs[a1] & 1),
              "...and that XF says the cell is unlocked",
              "A1 names XF %r, whose XF_TYPE_PROT is %r - wanted an index at "
              "64 or above with the locked bit CLEAR"
              % (a1, None if a1 is None or a1 >= len(xfs) else xfs[a1]))
        ctl = cells.get((1, 1))
        check(ctl is not None and ctl < 64 and (xfs[ctl] & 1),
              "a cell nobody touched stays locked, on a base XF",
              "B2 names XF %r, whose XF_TYPE_PROT is %r - wanted an index "
              "below 64 with the locked bit SET, which is Excel's default and "
              "what every XF this app wrote before 81.47 got wrong"
              % (ctl, None if ctl is None or ctl >= len(xfs) else xfs[ctl]))

        flags = recalc_flags(biff_raw)
        check(len(flags) >= 3,
              "the formula column is written as FORMULA records",
              "found %d FORMULA record(s), wanted the three in column 4 - a "
              "token array SHEET declines to emit falls back to a plain "
              "NUMBER record, and then there is nothing here to carry the "
              "flag (%r)" % (len(flags), sorted(flags)))
        v = flags.get(VOLATILE_CELL)
        check(v is not None and (v & 1),
              "a volatile formula sets Recalculate always",
              "the =RAND() cell's FORMULA option flags are %r, wanted bit 0 "
              "set (5.50) - Excel would show SHEET's cached value forever"
              % (v,))
        q = flags.get(PLAIN_FORMULA)
        check(q is not None and not (q & 1),
              "an ordinary formula does not",
              "the =B2+1 cell's flags are %r, wanted bit 0 clear - a blanket "
              "'always recalculate' is not the fix, it just moves the "
              "question" % (q,))

    done("sheetfmt")


if __name__ == "__main__":
    main()
