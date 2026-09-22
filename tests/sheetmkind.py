#!/usr/bin/env python3
"""A macro sheet reopens as a macro sheet (macro plan wave 5, SPEC.md 81.97).

    make && python3 tests/sheetmkind.py

The host writes two BIFF2 files, the way Excel 2.1d does: MAC.BIF, whose BOF
says dt 0040H (a macro sheet), and WS.BIF, whose BOF says 0010H. MAC.BIF's
formulas are the reader half's four cases:

  A1  SELECT("B2")      ptg 58H: a COMMAND, numbered in the Cetab, where
                        6DH is SELECT - and in the Ftab 6DH is something else
  A2  ECHO(FALSE)       ptg 42H, an EXTENSION function (wave 2), whose name
                        lives in CHART.OVL's own table and not sh_functab
  A3  DEREF(B1)         ptg 41H: an extension function with a FIXED count,
                        which only shm_mxargc knows
  A4  RETURN()          ptg 42H, one of the original twenty

SHEET opens MAC.BIF and saves it Normal, then opens WS.BIF through File >
Open in the same window and saves that. The host reads both saves: the first
must say 0040H and carry all four formulas, the second 0010H - the kind
belongs to the document, so opening a worksheet has to put it back.
"""
import os
import struct
import subprocess
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
import os88sym                                              # noqa: E402
from harness import check, done                              # noqa: E402
import sheetfmt as SF                                        # noqa: E402

WORK = "build/sheetmkind"               # this row's own paths (WRITING-TESTS 5.5)
DISK = "build/sheetmkind.img"
OPEN_ITEM = (SF.FILE_MENU[0] + 15, 59 + 11)     # sheetxl2's own
LIST_X, LIST_Y0, LIST_DY, LIST_ROWS = 150, 67, 16, 6
R = 0xC000
FALSE8 = bytes([1, 0, 0, 0, 0, 0, 0xFF, 0xFF])  # a cached logical FALSE
WANT = ['SELECT("B2")', 'ECHO(FALSE)', 'DEREF(B1)', 'RETURN()']


def rec(op, body):
    return struct.pack('<HH', op, len(body)) + body


def formula(r, c, toks):
    return rec(0x0006, struct.pack('<HH', r, c) + bytes([0x40, 0, 0])
               + FALSE8 + b'\x00' + bytes([len(toks)]) + toks)


def book(dt, cells):
    return (rec(0x0009, struct.pack('<HH', 0x0002, dt)) + b''.join(cells)
            + rec(0x000A, b''))


def mac():
    ref = bytes([0x44]) + struct.pack('<HB', R | 0, 1)          # B1
    return book(0x0040, [
        formula(0, 0, b'\x17\x02B2' + b'\x58\x01\x6d'),         # SELECT
        formula(1, 0, b'\x1d\x00' + b'\x42\x01\x57'),           # ECHO
        formula(2, 0, ref + b'\x41\x5a'),                       # DEREF
        formula(3, 0, b'\x42\x00\x37'),                         # RETURN
    ])


def ws():
    num = rec(0x0003, struct.pack('<HH', 0, 0) + bytes([0x40, 0, 0])
              + struct.pack('<d', 42.0))
    return book(0x0010, [num])


def bof_dt(data):
    if not data or len(data) < 8:
        return None
    op, ln, vers, dt = struct.unpack_from('<HHHH', data, 0)
    return dt if op in (0x0009, 0x0209, 0x0409) else None


def main():
    os.chdir(os.path.join(HERE, ".."))
    os.makedirs(WORK, exist_ok=True)
    files = {"MAC.BIF": mac(), "WS.BIF": ws()}
    for n, d in files.items():
        open(os.path.join(WORK, n), "wb").write(d)
    # the host's own reader agrees with the fixture before SHEET sees it
    host = F.read_biff(files["MAC.BIF"])
    host_f = [host.get((r, 0), (None, None))[1] for r in range(4)]
    subprocess.run([sys.executable, "tools/os88disk.py", "-o", DISK, "--size",
                    "360", "build/sheet.o88", "build/CHART.OVL",
                    "build/MACRO.OVL"] + [os.path.join(WORK, n) for n in files],
                   check=True, stdout=subprocess.DEVNULL)
    S = os88sym.linear
    saved = {}
    with M.launch(SF.SYS, apps=DISK, machine=SF.MACHINE) as m:
        M.settle(m)
        M.no_saver(m)
        mo = Mouse(marty=m)
        dispcp.open_drive(m, mo, S, M.settle, letter="B")
        M.settle(m)
        ds = dispcp.win_list(m, S)[-1]
        wx, wy, _, _ = dispcp.win_rect(m, S, ds)
        vol = lambda: os88flush.Flush(marty=m).volume(1)

        def shot(tag):
            _, _, rr = m.vram("cga")
            M.write_png(os.path.join(WORK, tag + ".png"), 640, 200, rr)

        def save(out, before):
            mo.menu(SF.FILE_MENU[0], SF.FILE_MENU[1], SF.SAVE_AS[0],
                    SF.SAVE_AS[1])
            M.settle(m)
            mo.click(SF.FMT_RADIO_X, SF.FMT_Y['bif'])
            M.settle(m)
            mo.click(*SF.FMT_OK)
            M.settle(m, limit=120)
            mo.click(*SF.SAVE_BUTTON)
            for _ in range(60):
                v = vol()
                if out in v.names() and v.read(out) != before:
                    return v.read(out)
                M.settle(m, quiet=2.0, stable=2, limit=60)
            return None

        dispcp.open_named(m, mo, S, M.settle, wx, wy, name="MAC.BIF")
        M.settle(m, limit=240)
        shot("1-macro")
        saved["MAC"] = save("MAC.BIF", files["MAC.BIF"])
        shown = sorted(e.name for e in vol().listdir()
                       if not e.is_system and not e.is_dir)
        row = shown.index("WS.BIF")
        mo.menu(SF.FILE_MENU[0], SF.FILE_MENU[1], *OPEN_ITEM)
        M.settle(m)
        mo.click(LIST_X, LIST_Y0 + LIST_DY * row)
        M.settle(m)
        mo.click(*SF.SAVE_BUTTON)               # Open: the same dialog's button
        M.settle(m, limit=240)
        shot("2-worksheet")
        saved["WS"] = save("WS.BIF", files["WS.BIF"])

    for k, d in saved.items():
        if d:
            open(os.path.join(WORK, k + ".out.bif"), "wb").write(d)
    check(host_f == WANT, "the host reads the fixture's four formulas",
          "tools/os88sheetfmt.py's decoder, independently of SHEET's",
          got=host_f, want=WANT)
    check(saved.get("MAC") is not None and saved.get("WS") is not None,
          "SHEET saved both, Normal", "", got=sorted(k for k, v in
                                                     saved.items() if v))
    check(bof_dt(saved.get("MAC")) == 0x40, "the macro sheet's save says so: "
          "BOF dt 0040H", "read from its BOF; the kind came off MAC.BIF's own",
          got=bof_dt(saved.get("MAC")), want=0x40)
    got = F.read_biff(saved.get("MAC") or b'')
    got_f = [(got.get((r, 0)) or (None, None))[1] for r in range(4)]
    check(got_f == WANT, "all four formulas came back as formulas",
          "a command by ptg 58H, an extension function variable and fixed, "
          "and RETURN - SHEET's decoder read each, and its writer wrote it",
          got=got_f, want=WANT)
    check(bof_dt(saved.get("WS")) == 0x10, "a worksheet opened next is a "
          "worksheet again: BOF dt 0010H", "the kind is the document's, and "
          "opening another one puts it back", got=bof_dt(saved.get("WS")),
          want=0x10)
    done("sheetmkind")


if __name__ == "__main__":
    main()
