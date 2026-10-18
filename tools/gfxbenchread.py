#!/usr/bin/env python3
"""gfxbenchread: tests/gfxbench's report, off a running guest - never off the
glass.

    make bench
    python3 tools/gfxbenchread.py                        # run it and read it
    python3 tools/gfxbenchread.py --machine os8088_5150_cga_gla
    python3 tools/gfxbenchread.py --file GFXVGA.TXT      # a report in hand
    python3 tools/gfxbenchread.py --grep 'blit|hline' --json out.json

WHY THIS EXISTS. gfxbench is an INSTRUMENT (docs/TESTING.md): its numbers go
into PERFORMANCE.md Part 2 and are never gated, so what it needs is not a
pass/fail row but a way to get 100-odd figures onto the host without a human
in the loop. The alternative is eleven pages of PgDn, a framebuffer capture
each, and then somebody reading digits off 8x8 glyphs - which is how
`GFX_XOR_RECT 256x1` was first taken here, and its middle digits are
genuinely ambiguous at that cell size.

HOW IT READS THE REPORT, and it is the cheap way round. benchlib keeps the
whole report in the package's own bss - `bl_arena` holds the line text packed
and NUL-terminated, `bl_idx` an arena-relative offset per line and `bl_nrow`
the count (tests/benchlib.inc's BL_BSS) - so the rows are READABLE WITHOUT A
DISK WRITE, by symbol, through the debug server. `bl_save`'s file is the
FIELD channel, for a 5150 that has no debugger; here it is the cross-check
(`--save`, on by default), because the file is written by a second walk of
the same rows and two readers that disagree is the only thing that can catch
either.

THE THREE TRAPS in front of the RUN are docs/TESTING.md's and this obeys all
three: Run is reached through the Bench MENU and not a keystroke (a scripted
key did not start sysbench here and the splash was still up 150 s later);
there is no `settle` after starting, because the machine is deliberately
frozen while a row is timed, so stillness means nothing and the wait never
returns; and the wait is on the END-OF-REPORT LINE rather than a clock, which
is better than the fixed generous sleep that advice settles for.

THE COLUMNS ARE DERIVED from tests/benchlib.inc's own BL_C_* equates and the
end-of-report sentence from tests/gfxbench/gfxbench.asm, so a format change is
still one edit in one file. A reader with the offsets copied into it reads the
counts column as the microseconds column the day one of them moves, and every
figure is then plausible and wrong.

THE MICROSECONDS ARE THE GUEST'S OWN PIT and MartyPC counts it to the cycle,
so `cycles` here is `us * 4.772727` and means what it says on a 4.77 MHz
8088. Under QEMU it would not (PERFORMANCE.md Part 3), which is why this
drives MartyPC and nothing else.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))

HZ = 4772727.0                  # the 5150's 8088, PERFORMANCE.md Part 2
VKIND = {0: "VGA", 1: "HERC", 2: "CGA", 3: "EGA"}       # kernel/viddet.inc
SRC = "tests/gfxbench/gfxbench.asm"
LIB = "tests/benchlib.inc"


def u16(b, i=0):
    return b[i] | (b[i + 1] << 8)


# =============================================================================
# the format, read out of the source rather than copied into this file
# =============================================================================

def columns(root=ROOT):
    """BL_C_* and the two sizes, out of tests/benchlib.inc."""
    txt = open(os.path.join(root, LIB)).read()
    out = {}
    for name, val in re.findall(r"^(BL_\w+)\s+equ\s+(\d+)", txt, re.M):
        out[name] = int(val)
    for need in ("BL_C_N", "BL_C_CNT", "BL_C_US", "BL_C_UNIT", "BL_C_FLAG",
                 "BL_MAXLINE", "BL_MAXROWS"):
        if need not in out:
            raise SystemExit("gfxbenchread: no %s in %s - has the report "
                             "format moved?" % (need, LIB))
    return out


def end_marker(root=ROOT):
    """gb_trailer's first line: what says the suite has finished."""
    txt = open(os.path.join(root, SRC)).read()
    m = re.search(r"^gb_s_end1:\s+db\s+'([^']*)'", txt, re.M)
    if not m:
        raise SystemExit("gfxbenchread: no gb_s_end1 in %s - what says the "
                         "run is over?" % SRC)
    return m.group(1)


def report_names(root=ROOT):
    """gb_save's three names, keyed by the VID_* kind it picks each for."""
    txt = open(os.path.join(root, SRC)).read()
    out = {}
    for tag, kind in (("vga", 0), ("herc", 1), ("cga", 2)):
        m = re.search(r"^gb_f_%s:\s+db\s+'([^']*)'" % tag, txt, re.M)
        if not m:
            raise SystemExit("gfxbenchread: no gb_f_%s in %s" % (tag, SRC))
        out[kind] = m.group(1)
    out[3] = out[0]             # EGA takes the VGA path in gb_save
    return out


# =============================================================================
# parsing
# =============================================================================

def parse(text, cols=None):
    """The report's text -> [{label, n, counts, us, flag}] for its ROWS.

    A measurement row is one carrying benchlib's unit in the unit column with
    three numbers in front of it. Everything else in the report - the banner,
    the provenance block, bl_kv's key/value lines, the column headings, the
    trailer - has no unit there and is skipped, which is why this needs no
    list of row names and cannot go stale against one.
    """
    cols = cols or columns()
    cn, cc = cols["BL_C_N"], cols["BL_C_CNT"]
    cu, ct, cf = cols["BL_C_US"], cols["BL_C_UNIT"], cols["BL_C_FLAG"]
    rows = []
    for ln in text.splitlines():
        if ln[ct:ct + 2] != "us":
            continue
        try:
            n = int(ln[cn:cc])
            counts = int(ln[cc:cu])
            us = float(ln[cu:ct].strip())
        except ValueError:
            continue
        rows.append(dict(label=ln[:cn].strip(), n=n, counts=counts, us=us,
                         flag=ln[cf:cf + 1].strip()))
    return rows


FLAGS = {"t": "method T (tick-timed, coarse)",
         "!": "one iteration came within a third of the PIT wrap",
         "w": "the row LAPPED the PIT and was re-run with method T"}


def table(rows, hz=HZ, out=sys.stdout):
    w = max([24] + [len(r["label"]) for r in rows])
    print("   %-*s %6s %12s %12s %10s" % (w, "measurement", "N", "us/op",
                                          "cycles", "flag"), file=out)
    for r in rows:
        print("   %-*s %6d %12.2f %12.0f %10s"
              % (w, r["label"], r["n"], r["us"], r["us"] * hz / 1e6,
                 r["flag"]), file=out)
    seen = sorted({r["flag"] for r in rows if r["flag"]})
    for f in seen:
        print("   %s = %s" % (f, FLAGS.get(f, "an unknown flag")), file=out)


# =============================================================================
# the run
# =============================================================================

def run(sysimg="build/os8088.img", benchimg="build/bench.img",
        machine="os8088_xt_vga_144", save=True, guest=1200.0, limit=3600.0,
        verbose=True, knobs=()):
    """Boot, open GFXBENCH.O88 on B:, pick Bench > Run, read the report.

    Returns (text, info) where `text` is the whole report as the guest built
    it and `info` carries the adapter, the row count, benchlib's truncation
    flag and - with `save` - the file read back off the floppy.
    """
    import os88marty, os88ui, os88build, os88flush    # noqa: E402
    import os88geom as geom                           # noqa: E402
    from cycweb import pkg_syms                       # noqa: E402

    os.chdir(ROOT)
    # THE OTHER ARM OF AN A/B. A knob kernel is built into a tree of its own
    # (never over build/, which is the control), and `apply` points the symbol
    # reader at it - BOTH halves, because os88ui and os88marty resolve names
    # through the module default and not through anything this file threads.
    # The bench disk is resolved FIRST: `apply` makes `at("build/x")` mean
    # `<tree>/x`, and the knob tree holds a kernel and no bench floppy.
    apps = os88build.at(benchimg)
    binpath = os88build.at("build/gfxbench.bin")    # ...for the same reason
    if knobs:
        t = os88build.tree(*knobs, targets=("os8088.img",)).apply()
        sysimg = t.img("os8088.img")
        if verbose:
            print("   arm: %s" % " ".join(knobs))
    else:
        os88build.plain().apply()
        sysimg = os88build.at(sysimg)
    cols, marker = columns(), end_marker()
    names = report_names()
    syms, image = pkg_syms(SRC, ("apps/", "tests/"))
    # THE BUILT PACKAGE MUST BE THIS SOURCE. Every offset below comes off a
    # re-assembly of the .asm, so a tree edited since `make bench` reads
    # plausible rubbish out of the middle of the wrong variable (cycweb's own
    # lesson, and the one that cost it "the warp never finished").
    try:
        built = open(binpath, "rb").read()
    except OSError:
        sys.exit("gfxbenchread: no build/gfxbench.bin - run `make bench`")
    if built != image:
        sys.exit("gfxbenchread: build/gfxbench.bin is behind the tree - run "
                 "`make bench`")

    with os88ui.boot(sysimg, apps=apps,
                     machine=machine, verbose=verbose) as ui:
        m = ui.m
        w = ui.path("B:/GFXBENCH.O88")
        rec = m.read(ui._S("wm_wins") + w.i * geom.WIN_SIZE, geom.WIN_SIZE)
        base = u16(rec, geom.W_SEG) << 4    # the package is PINNED (it opts
                                            # into no OS88_REGION_MOVABLE), so
                                            # one read of W_SEG holds good
        def rw(name):
            return u16(m.read(base + syms[name], 2))

        def rb(name):
            return m.read(base + syms[name], 1)[0]

        def lines():
            n = rw("bl_nrow")
            if not n:
                return []
            idx = m.read(base + syms["bl_idx"], n * 2)
            used = max(rw("bl_used"), 1)
            arena = m.read(base + syms["bl_arena"], used)
            out = []
            for i in range(n):
                o = u16(idx, i * 2)         # ARENA-RELATIVE (bl_lcommit), and
                if o >= len(arena):         # bl_fetch adds the base itself
                    break
                e = arena.find(b"\0", o)
                out.append(arena[o:e if e >= 0 else len(arena)]
                           .decode("latin-1"))
            return out

        # WAIT FOR THE BAR FIRST. `open` returns when the WINDOW exists, and
        # the bar is relaid by the kernel's own UI pass a moment later - so a
        # pick sent immediately reads the DISK window's cells and fails
        # saying there is no Bench menu, which reads as the package having no
        # menus. Measured here: ['Apple','File','Edit','Nav','Disk','Sticky
        # Apps','Gfx Bench'] one read too early, ['Apple','Bench','Gfx Bench']
        # a few reads later.
        os88marty.until(m, lambda _m: "Bench" in [c[0] for c in ui.menus()],
                        "the Bench menu to reach the bar", poll=0.2,
                        limit=60.0)

        # Through the MENU, and `menu_pick` confirms the item is the
        # highlighted one before it releases - a release over the wrong item
        # runs the wrong command and the picture afterwards never says so.
        ui.menu_pick("Bench", "Run")

        def done(_m):
            # the trailer's first line, which gb_run emits last of all. NOT a
            # row count and NOT a clock: the suite's length moves with the
            # adapter and every fixed sleep is either short or wasteful.
            return any(ln.startswith(marker) for ln in lines()[-4:])

        os88marty.until(m, done, "the gfxbench suite to finish", poll=1.0,
                        limit=limit, guest=guest)

        text = "\n".join(lines())
        info = dict(machine=machine, knobs=" ".join(knobs),
                    kind=VKIND.get(rb("gb_kind"), rb("gb_kind")),
                    nrow=rw("bl_nrow"), used=rw("bl_used"),
                    arena=cols["BL_ARENA"], maxrows=cols["BL_MAXROWS"],
                    truncated=bool(rb("bl_full")), file=None, fileerr=None)
        if save:
            name = names.get(rb("gb_kind"), names[0])
            info["filename"] = name
            ui.menu_pick("Bench", "Save Report")
            try:
                # B:, the volume the package was launched from - gb_s_end2
                # says the report lands in the CURRENT volume's CURRENT
                # directory. MartyPC keeps the guest's writes in RAM, so
                # os88flush is the only way the file reaches the host, and it
                # SHARES this connection (a second Marty hangs).
                info["file"] = os88flush.Flush(marty=m).volume(1) \
                    .read(name).decode("latin-1")
            except Exception as e:           # a save that failed is a finding
                info["fileerr"] = str(e)     # about bl_save, not a reason to
    return text, info                        # throw the run away


def crosscheck(text, info, cols=None):
    """bl_save's file against the arena the rows were read out of.

    Two walks of the same rows, so a disagreement is a defect in one of them -
    the only thing that can catch either, and the reason --save is the default.
    """
    bad = []
    if info.get("fileerr"):
        bad.append("no %s on B: - bl_save did not write it (%s)"
                   % (info.get("filename", "report"), info["fileerr"]))
        return bad
    if info.get("file") is None:
        return bad
    mine = parse(text, cols)
    theirs = parse(info["file"], cols)
    if len(mine) != len(theirs):
        bad.append("the arena holds %d measurement rows and the saved file "
                   "%d" % (len(mine), len(theirs)))
        return bad
    for a, b in zip(mine, theirs):
        if a != b:
            bad.append("the arena and the saved file disagree: %r vs %r"
                       % (a, b))
    return bad


def main():
    ap = argparse.ArgumentParser(
        description="read tests/gfxbench's report off a guest, or a saved one")
    ap.add_argument("--file", help="parse this saved report instead of running")
    ap.add_argument("--image", default="build/os8088.img",
                    help="the SYSTEM disk to boot (default %(default)s)")
    ap.add_argument("--bench", default="build/bench.img",
                    help="the bench disk for B: (default %(default)s)")
    ap.add_argument("--machine", default="os8088_xt_vga_144",
                    help="MartyPC machine (default %(default)s - a 4.77MHz "
                         "XT with a VGA; os8088_5150_cga_gla and "
                         "os8088_5150_herc_gla_144 are the 1bpp arms)")
    ap.add_argument("--knob", action="append", default=[], metavar="K=V",
                    help="build a knob kernel into a private tree and boot "
                         "THAT instead (os88build.tree), e.g. "
                         "--knob NOVBEROW=1 - the A/B arm; --image is then "
                         "ignored and build/ is left alone")
    ap.add_argument("--no-save", dest="save", action="store_false",
                    help="skip the Save Report cross-check (and the ~seconds "
                         "of 8088 floppy write it costs)")
    ap.add_argument("--grep", metavar="RE",
                    help="only rows whose label matches this (case-blind)")
    ap.add_argument("--hz", type=float, default=HZ,
                    help="the clock the cycles column assumes")
    ap.add_argument("--guest", type=float, default=1200.0,
                    help="guest seconds the suite is allowed")
    ap.add_argument("--json", metavar="FILE", help="write the rows as JSON")
    ap.add_argument("--out", metavar="FILE", help="write the whole report")
    ap.add_argument("--full", action="store_true",
                    help="print every line, not only the measurement rows")
    a = ap.parse_args()
    cols = columns()

    info = {}
    if a.file:
        text = open(a.file, encoding="latin-1").read()
    else:
        text, info = run(a.image, a.bench, a.machine, save=a.save,
                         guest=a.guest, knobs=tuple(a.knob))
    rows = parse(text, cols)
    if a.grep:
        rx = re.compile(a.grep, re.I)
        rows = [r for r in rows if rx.search(r["label"])]

    print()
    if info:
        if info.get("knobs"):
            print("   arm: %s" % info["knobs"])
        print("   %s: adapter %s, %d report lines (%d of %d rows, %d of %d "
              "arena bytes)" % (info["machine"], info["kind"], info["nrow"],
                                info["nrow"], info["maxrows"], info["used"],
                                info["arena"]))
    print("   %d measurement rows%s; cycles at %.0f Hz"
          % (len(rows), " matching %r" % a.grep if a.grep else "", a.hz))
    # SAY WHICH READERS AGREED, because a cross-check that silently did not
    # run looks exactly like one that passed (os8088's standing lesson: a
    # skip is not a pass).
    if info:
        if info.get("file") is not None:
            print("   cross-check: %s read back off B: (%d lines), parsed as "
                  "%d rows" % (info.get("filename", "the report"),
                               len(info["file"].splitlines()),
                               len(parse(info["file"], cols))))
        elif info.get("fileerr"):
            print("   cross-check: NOT DONE - %s" % info["fileerr"])
        else:
            print("   cross-check: not asked for (--no-save)")
    print()
    if a.full:
        for ln in text.splitlines():
            print("   | " + ln)
        print()
    table(rows, hz=a.hz)

    if a.out:
        open(a.out, "w").write(text + "\n")
        print("\n   report -> %s" % a.out)
    if a.json:
        open(a.json, "w").write(json.dumps(
            dict(info={k: v for k, v in info.items() if k != "file"},
                 hz=a.hz, rows=rows), indent=1) + "\n")
        print("   rows   -> %s" % a.json)

    bad = []
    if not rows:
        bad.append("the report carries no measurement rows at all")
    if info.get("truncated"):
        bad.append("the report TRUNCATED (bl_full): BL_ARENA or BL_MAXROWS "
                   "is too small for this suite")
    bad += crosscheck(text, info, cols)
    lapped = [r["label"] for r in rows if r["flag"] == "w"]
    if lapped:
        print("\n   note: %d row(s) lapped the PIT and were re-run with "
              "method T: %s" % (len(lapped), ", ".join(lapped)))
    if bad:
        print()
        for b in bad:
            print("   FAIL: %s" % b)
        return 1
    print("\n   ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
