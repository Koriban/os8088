#!/usr/bin/env python3
"""BASIC/8088 runs a program and the answers are right (SPEC.md 126).

    python3 tests/basiclang.py

THE FIRST ROW THAT EXECUTES THE LANGUAGE. Everything before it checked the
package's LAYOUT (tests/unit/t_fpscratch.py) or its size; nothing ran a
program and compared what came back, and the cost of that was five defects
that the build could not see and reading did not catch:

  * the value stack reserved four slots while bas_exec permitted sixteen, so
    a right-nested expression wrote over os88fp.inc's register-A scratch and
    `1+(2+(3+(4+(5+(6+(7+8))))))` answered -2.668453E+307 for 36;
  * the variable table outlived the program text its entries point into, so
    `PRINT n` answered a previous RUN's `y`;
  * `PRINT 10\\3` refused as "outside an INTEGER" from wave 1c until wave 2b -
    `\\` had never once been executed;
  * File > New cleared the console and not the program, and the repaint after
    it went through a clobbered SI;
  * the console blanked on its first scroll, because the carrier never spent
    os88con.inc's scroll debt.

Every one of them is a line below.

**IT READS THE CONSOLE BUFFER, NOT THE PIXELS.** The answers are (character,
attribute) cells in the package's own bss, so a row that matches glyphs would
be testing the renderer as well and could not say which half was wrong - and
the console is EIGHT rows of a 25-row buffer (SPEC.md 126.17), so most of a
long program's output is not on the glass at all. The buffer is found by its
CONTENT: BASIC's banner, as cells, locates it with no kernel symbol and no
package map. One pixel assertion stands beside the text, and only one - that
the pane is not blank - because that is the renderer defect above and it is
invisible to every buffer read.

**IT PRESSES F5.** Run is a menu pick and a menu pick is a drag whose offsets
drift (the pulldown's dy is not a constant across adapters); F5 is what every
BASIC of this line runs on, it is what the package ships, and it makes the
whole row keyboard-only once the window is open.

VERIFIED TO FAIL - and what is NOT verified, which matters more:

  * putting `BAS_STK_MAX*2` back - the wave 1c defect - reports `PRINT x`
    answering 0 where it owes 7. **It did NOT, until the program had a
    variable read AFTER the deep expression.** A short reservation does not
    corrupt the expression that overruns it; it corrupts whatever the chain
    puts above, and since wave 2a that is bas_nvar and the variable table,
    not register A. The mutation passed a row whose deep line stood alone,
    which is the fixture failing and not the assertion.
  * wave 2c: giving `OP_LT` the mask that means "greater" reports
    `PRINT 1 < 2` answering 0, and every IF arm inverting - the 99, 98 and
    97 above are values no correct run prints, which is what they are for.
  * wave 2d: testing a NEGATIVE `STEP` with `<=` instead of `>=` reports
    the `STEP -3` loop running zero times - 0 where it owes 4.
  * the block IF: stopping ENDIF from patching its forward jump reports the
    run dying immediately after part three's sentinel - the unpatched jump
    lands at offset 0.
  * EXIT IF: taking the TOP open block in bas_blkinloop instead of searching
    downwards for the nearest loop - the mutant refuses `EXIT IF` inside a
    block IF and part 3 never prints its sentinel, so the row fails on the
    anchor rather than on the value. A coarse red, but a red. It also caught
    a CL clobber in bas_blkat on the first run, as part two hanging and part
    three reading the stale console behind it.
  * ELSEIF: taking ENDIF's walk of the finished-jump chain out - every arm
    then falls into the one below it, and part 3's ELSE case goes wrong
    before part 4 is reached.
  * SELECT: sending a range's FAILED LOWER END out of the arm instead of on
    to the next value after the comma. Writing that mutation is what showed
    the row had no range in the MIDDLE of a list - the only shape where the
    two targets differ - so `CASE 5 TO 9, 1` was added and the mutant loses
    exactly it (80), while `CASE 1, 5 TO 9, 20` (78) still passes.
  * GOTO: making every loop identity 0 (what a DEPTH count would effectively
    do for two loops at the same depth) - the jump out of a FOR stops being
    refused and that one sentence disappears from the console.
  * NOT shown to fail: deleting the cursor restore in `.ifnoelse`. It is
    unreachable in this grammar (see the comment there) and the row says so
    rather than covering it by accident.
  * the ink assertion is **NOT** shown to catch its own defect. Deleting
    bas_paint's `con_takescroll` leaves this row green - with one run and
    with three - though it blanks the pane under a hand-driven session of
    six or more. So the line below guards a pane that is blank OUTRIGHT, and
    the scroll debt is held by inspection and by os88con.inc's header, not
    by this row. Said here rather than claimed, because a row that is
    believed to cover something it does not is worse than one that says so.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import os88sym                                              # noqa: E402
import os88qemu                                             # noqa: E402
import os88fixture                                          # noqa: E402
import dispcp                                               # noqa: E402

S = os88sym.linear
SOCK = os88qemu.SOCK

CON_COLS, CON_ROWS = 80, 25
ROW = CON_COLS * 2                      # a row of (character, attribute)
BANNER = "BASIC/8088"                   # bas_s_banner's first word

# The program, and what each line owes the console. A blank expectation is a
# line that prints nothing - an assignment, which is most of what a program
# is. SPEC.md 126.4's PRINT puts a space where the sign would be and another
# after the number, so the text is compared STRIPPED.
PART1 = [
    # CLS FIRST, and it is not decoration: the buffer is 25 rows and this
    # program's answers very nearly fill it, so the banner and `Ready` would
    # push the first of them off the top before they could be read. They did
    # - the row lost `42` and `7` the moment WHILE's cases were added.
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),   # the anchor; see SEED
    ("x = 7",                            None),
    ("y = x * 6",                        None),
    ("PRINT y",                          "42"),      # variables at all
    ("PRINT 1+2*3",                      "7"),       # precedence
    ("PRINT (1+2)*3",                    "9"),       # ...and parentheses
    ("PRINT 1+(2+(3+(4+(5+(6+(7+8))))))", "36"),     # eight slots at once
    # **AND A VARIABLE READ AFTER IT**, which is what makes the line above an
    # assertion rather than a decoration. A value stack that reserves too
    # little does not corrupt the expression - it corrupts whatever the chain
    # puts above it, and since wave 2a that is bas_nvar and the VARIABLE
    # TABLE (bas_vars, 192 bytes), not os88fp.inc's register A. Reserving
    # words instead of slots and running the deep line alone comes back 36,
    # correct, with x quietly gone. Measured: the mutation PASSED this row
    # until this line existed.
    ("PRINT x",                          "7"),
    ("PRINT 10/4",                       "2.5"),     # `/` is REAL division
    ("PRINT 10\\3",                      "3"),       # `\` is integer division
    ("PRINT -10",                        "-10"),     # unary minus
    ("PRINT n",                          "0"),       # never assigned reads 0
    ("N = 3",                            None),
    ("PRINT n + N",                      "6"),       # ...and names fold case
]

# **TWO RUNS, NOT ONE.** The console buffer is 25 rows and the cursor takes
# one of them, so 24 answers is the ceiling - and a wave that adds cases
# would otherwise have to delete older ones to make room, which is exactly
# the coverage a growing language must not trade away. Each part CLSes and
# is self-contained (RUN clears the variables, SPEC.md 126.17), so they are
# read one after the other and the answers concatenated.
PART2 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),   # ...and part two's
    # --- wave 2c: the comparisons, and IF ---------------------------------
    ("PRINT 1 < 2",                      "-1"),      # TRUE is -1, a NUMBER
    ("PRINT 2 < 1",                      "0"),       # ...and false is 0
    ("PRINT 3 = 3",                      "-1"),
    ("PRINT 3 <> 3",                     "0"),
    ("PRINT 3 <= 3",                     "-1"),      # the two-character ones
    ("PRINT 3 >= 4",                     "0"),       # are read before `<`/`>`
    ("PRINT 1+1 < 3*1",                  "-1"),      # looser than arithmetic
    ("IF 1 < 2 THEN PRINT 11",           "11"),      # the taken arm
    ("IF 2 < 1 THEN PRINT 99",           None),      # ...and the skipped one
    ("IF 2 < 1 THEN PRINT 98 ELSE PRINT 12", "12"),  # ELSE
    ("IF 1 < 2 THEN PRINT 13 ELSE PRINT 97", "13"),  # ...and not ELSE
    ("IF 0 THEN PRINT 96",               None),      # 0 is false
    ("IF -1 THEN PRINT 14",              "14"),      # anything else is true
    ("q = 5",                            None),
    ("IF q > 4 THEN q = 6",              None),      # an arm that ASSIGNS
    ("PRINT q",                          "6"),
    # --- wave 2d: the whole program is compiled first, so a loop can jump --
    ("s = 0",                            None),
    ("i = 1",                            None),
    ("WHILE i <= 5",                     None),
    ("s = s + i",                        None),
    ("i = i + 1",                        None),
    ("WEND",                             None),
    ("PRINT s",                          "15"),      # 1+2+3+4+5
    ("PRINT i",                          "6"),       # ...and it ran out
    ("z = 9",                            None),
    ("WHILE z < 0",                      None),      # false at the top:
    ("z = 1",                            None),      # the body runs NO times
    ("WEND",                             None),
    ("PRINT z",                          "9"),
    # --- FOR/NEXT -----------------------------------------------------
    ("t = 0",                            None),
    ("FOR k = 1 TO 4",                   None),
    ("t = t + k",                        None),
    ("NEXT k",                           None),      # ...and NEXT may name it
    ("PRINT t",                          "10"),      # 1+2+3+4
    ("d = 0",                            None),
    ("FOR k = 10 TO 1 STEP -3",          None),      # a NEGATIVE literal step
    ("d = d + 1",                        None),
    ("NEXT",                             None),      # ...and NEXT need not
    ("PRINT d",                          "4"),       # 10, 7, 4, 1
    ("e = 0",                            None),
    ("FOR k = 5 TO 1",                   None),      # never true at the top
    ("e = 9",                            None),
    ("NEXT",                             None),
    ("PRINT e",                          "0"),       # ...so the body is skipped
]

# Part three: the block IF, and the two bottom-tested loops. Its own CLS and
# sentinel, like the others - the buffer holds 24 answers and this wave
# would otherwise have had to evict wave 2a's.
PART3 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- the block IF, which is what 2d's whole-program change was for ----
    ("a = 3",                            None),
    ("IF a > 2 THEN",                    None),      # nothing after THEN
    ("PRINT 21",                         "21"),
    ("PRINT 22",                         "22"),      # ...more than one line
    ("ENDIF",                            None),
    ("IF a > 9 THEN",                    None),
    ("PRINT 91",                         None),      # skipped entirely
    ("ENDIF",                            None),
    ("IF a > 9 THEN",                    None),
    ("PRINT 92",                         None),
    ("ELSE",                             None),
    ("PRINT 23",                         "23"),      # ...the ELSE arm
    ("ENDIF",                            None),
    ("IF a > 2 THEN",                    None),
    ("PRINT 24",                         "24"),
    ("ELSE",                             None),
    ("PRINT 93",                         None),      # ...and not the ELSE
    ("ENDIF",                            None),
    # --- bottom-tested: the body always runs once -------------------------
    ("c = 0",                            None),
    ("REPEAT",                           None),
    ("c = c + 1",                        None),
    ("UNTIL c >= 3",                     None),
    ("PRINT c",                          "3"),
    ("f = 7",                            None),
    ("REPEAT",                           None),
    ("f = f + 1",                        None),
    ("UNTIL f > 0",                      None),      # true at once...
    ("PRINT f",                          "8"),       # ...but it ran once
    ("g = 0",                            None),
    ("DO",                               None),
    ("g = g + 2",                        None),
    ("LOOP UNTIL g >= 6",                None),
    ("PRINT g",                          "6"),
    # --- EXIT IF: leaves the innermost LOOP, not the innermost block ------
    ("h = 0",                            None),
    ("FOR k = 1 TO 100",                 None),
    ("h = h + 1",                        None),
    ("EXIT IF h >= 4",                   None),
    ("NEXT",                             None),
    ("PRINT h",                          "4"),       # ...not 100
    ("p = 0",                            None),
    ("WHILE 1",                          None),      # ...and out of a WHILE
    ("p = p + 1",                        None),
    ("IF p > 2 THEN",                    None),      # from inside a BLOCK IF,
    ("EXIT IF 1",                        None),      # which is the case the
    ("ENDIF",                            None),      # downward search is for
    ("WEND",                             None),
    ("PRINT p",                          "3"),
]

PART4 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- ELSEIF: the middle arm runs, and only it -------------------------
    ("m = 2",                            None),
    ("IF m = 1 THEN",                    None),
    ("PRINT 41",                         None),
    ("ELSEIF m = 2 THEN",                None),
    ("PRINT 42",                         "42"),
    ("ELSE",                             None),
    ("PRINT 43",                         None),
    ("ENDIF",                            None),
    # ...the FIRST arm, with two ELSEIFs below it that must not run --------
    ("m = 1",                            None),
    ("IF m = 1 THEN",                    None),
    ("PRINT 44",                         "44"),
    ("ELSEIF m = 1 THEN",                None),      # true as well, and
    ("PRINT 45",                         None),      # still not taken
    ("ELSEIF m = 1 THEN",                None),
    ("PRINT 46",                         None),
    ("ENDIF",                            None),
    # ...and the ELSE, when no arm matches ---------------------------------
    ("m = 9",                            None),
    ("IF m = 1 THEN",                    None),
    ("PRINT 47",                         None),
    ("ELSEIF m = 2 THEN",                None),
    ("PRINT 48",                         None),
    ("ELSE",                             None),
    ("PRINT 49",                         "49"),
    ("ENDIF",                            None),
    # ...no ELSE at all, and nothing matching: the whole thing is skipped --
    ("IF m = 1 THEN",                    None),
    ("PRINT 50",                         None),
    ("ELSEIF m = 2 THEN",                None),
    ("PRINT 51",                         None),
    ("ENDIF",                            None),
    ("PRINT 52",                         "52"),      # ...and the line AFTER
    # ...inside a loop, so the arms' jumps and the loop's must not cross ---
    ("t = 0",                            None),
    ("FOR k = 1 TO 4",                   None),
    ("IF k = 2 THEN",                    None),
    ("t = t + 10",                       None),
    ("ELSEIF k = 3 THEN",                None),
    ("t = t + 100",                      None),
    ("ELSE",                             None),
    ("t = t + 1",                        None),
    ("ENDIF",                            None),
    ("NEXT",                             None),
    ("PRINT t",                          "112"),     # 1 + 10 + 100 + 1
]

PART5 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- SELECT: a range arm, among a single value and a list -------------
    ("x = 3",                            None),
    ("SELECT x",                         None),
    ("CASE 1",                           None),
    ("PRINT 61",                         None),
    ("CASE 2 TO 4",                      None),
    ("PRINT 62",                         "62"),
    ("CASE 5,6",                         None),
    ("PRINT 63",                         None),
    ("DEFAULT",                          None),
    ("PRINT 64",                         None),
    ("ENDSELECT",                        None),
    # ...the SECOND value of a list, which is the matched-jump chain --------
    ("x = 6",                            None),
    ("SELECT x",                         None),
    ("CASE 1",                           None),
    ("PRINT 65",                         None),
    ("CASE 5,6",                         None),
    ("PRINT 66",                         "66"),
    ("DEFAULT",                          None),
    ("PRINT 67",                         None),
    ("ENDSELECT",                        None),
    # ...the DEFAULT, when nothing matches ---------------------------------
    ("x = 9",                            None),
    ("SELECT x",                         None),
    ("CASE 1",                           None),
    ("PRINT 68",                         None),
    ("DEFAULT",                          None),
    ("PRINT 69",                         "69"),
    ("ENDSELECT",                        None),
    # ...no DEFAULT and no match: the whole thing is skipped ---------------
    ("SELECT x",                         None),
    ("CASE 1",                           None),
    ("PRINT 70",                         None),
    ("ENDSELECT",                        None),
    ("PRINT 71",                         "71"),     # ...and the line after
    # ...the open ends, over an EXPRESSION subject -------------------------
    ("x = 2",                            None),
    ("SELECT x + 3",                     None),
    ("CASE TO 4",                        None),
    ("PRINT 72",                         None),
    ("CASE 5 TO",                        None),
    ("PRINT 73",                         "73"),
    ("ENDSELECT",                        None),
    # ...SWITCH, OTHERWISE and ENDSWITCH, which are GFA's own spellings ----
    ("SWITCH x",                         None),
    ("CASE 1",                           None),
    ("PRINT 76",                         None),
    ("OTHERWISE",                        None),
    ("PRINT 77",                         "77"),
    ("ENDSWITCH",                        None),
    # ...a range IN THE MIDDLE of a list, which is the only place a failed
    # end's jump target can be told apart: it owes the values after the
    # comma their turn, and must not leave the arm
    ("x = 20",                           None),
    ("SELECT x",                         None),
    ("CASE 1, 5 TO 9, 20",               None),     # the UPPER end fails...
    ("PRINT 78",                         "78"),
    ("DEFAULT",                          None),
    ("PRINT 79",                         None),
    ("ENDSELECT",                        None),
    ("x = 1",                            None),
    ("SELECT x",                         None),
    ("CASE 5 TO 9, 1",                   None),     # ...and the LOWER end,
    ("PRINT 80",                         "80"),     # which is a jump and not
    ("DEFAULT",                          None),     # a fall-through
    ("PRINT 81",                         None),
    ("ENDSELECT",                        None),
    # ...inside a FOR, where the arms' jumps and the loop's share a stream
    ("s = 0",                            None),
    ("FOR k = 1 TO 5",                   None),
    ("SELECT k",                         None),
    ("CASE 2,4",                         None),
    ("s = s + 10",                       None),
    ("CASE 3 TO 5",                      None),
    ("s = s + 100",                      None),
    ("DEFAULT",                          None),
    ("s = s + 1",                        None),
    ("ENDSELECT",                        None),
    ("NEXT",                             None),
    ("PRINT s",                          "221"),    # 1 + 10 + 100 + 10 + 100
]

PART6 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- GOTO forwards, over a line that must not run ---------------------
    ("GOTO skip",                        None),
    ("PRINT 91",                         None),
    ("skip:",                            None),
    ("PRINT 82",                         "82"),
    # ...and backwards, which is a loop made out of a jump ----------------
    ("n = 0",                            None),
    ("again:",                           None),
    ("n = n + 1",                        None),
    ("IF n < 3 THEN GOTO again",         None),
    ("PRINT n",                          "3"),
    # ...a label spelled the way only a LABEL may be: a leading digit, a
    # dot and an underscore (SPEC.md 126.22, GFA's entry 249)
    ("GOTO 2nd.step_a",                  None),
    ("PRINT 92",                         None),
    ("2nd.step_a:",                      None),
    ("PRINT 83",                         "83"),
    # ...and a jump WITHIN a loop, which is the one GFA's table allows ----
    ("q = 0",                            None),
    ("FOR k = 1 TO 3",                   None),
    ("q = q + 1",                        None),
    ("GOTO inside",                      None),
    ("q = q + 10",                       None),
    ("inside:",                          None),
    ("NEXT",                             None),
    ("PRINT q",                          "3"),     # ...not 33
    # ...a label sharing its line with a statement ------------------------
    ("GOTO together",                    None),
    ("together: PRINT 84",               "84"),
]

# --- the refusals, one program each, because a refusal ends the program ---
# NOTHING IS PRINTED BY THESE, not even their CLS: the whole program is
# compiled before any of it runs, so the console holds the refusal alone.
PART7 = [
    ("CLS",                              None),
    ("PRINT 31415",                      None),
    ("GOTO nowhere",
     "Error at line 3: GOTO names a label the program does not have"),
]

PART8 = [
    ("CLS",                              None),
    ("FOR k = 1 TO 3",                   None),
    ("GOTO outside",                     None),
    ("NEXT",                             None),
    ("outside:",
     "Error at line 3: GOTO cannot jump into or out of a loop"),
]

PARTS = (PART1, PART2, PART3, PART4, PART5, PART6, PART7, PART8)

FAILED = []


def check(cond, what, why="", got=None, want=None):
    if cond:
        print("  ok   %s" % what)
        return True
    FAILED.append(what)
    print("  FAIL %s" % what)
    if want is not None:
        print("       want: %r" % (want,))
    if got is not None:
        print("       got:  %r" % (got,))
    if why:
        print("       why:  %s" % why)
    return False


class Qemu:
    """QMP, one connection per command - never a persistent one.

    `-qmp unix:...,server,nowait` serves a SINGLE client, so a held
    connection parks every other tool in the listen backlog for ever, which
    reads exactly like the guest having hung. tests/ethernet.py's class, with
    only what this row uses.
    """

    def __init__(self, path=None):
        self.path = path or os88qemu.SOCK
        self.tmp = tempfile.mkdtemp(prefix="basiclang")
        for _ in range(150):
            try:
                self.hmp("info status")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("no QMP socket at %s" % self.path)

    def hmp(self, cmd):
        k = re.match(r"^sendkey (\S+)$", cmd)
        if k is not None:                       # CONFIRMED, per os88qemu
            os88qemu.sendkey(self.path, k.group(1))
            return ""
        # QMP ON THIS CONNECTION, never a tools/qmp.py subprocess from
        # inside one. `-qmp ...,server,nowait` serves a SINGLE client: hold
        # the socket and spawn the tool and the tool sits in the listen
        # backlog for ever, which is not an error and not a return - it reads
        # exactly like the guest having hung on the gesture. (It did: the
        # first version of this class did both and the row never printed a
        # line.)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        f = s.makefile("rw")

        def send(obj):
            f.write(json.dumps(obj) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("QMP closed")
                msg = json.loads(line)
                if "event" not in msg:
                    return msg
        try:
            json.loads(f.readline())            # the greeting
            send({"execute": "qmp_capabilities"})
            r = send({"execute": "human-monitor-command",
                      "arguments": {"command-line": cmd}})
            return r.get("return", "")
        finally:
            f.close()
            s.close()

    QKEYS = {"ArrowDown": "down", "ArrowUp": "up", "Home": "home",
             "End": "end", "PageDown": "pgdn", "PageUp": "pgup",
             "Tab": "tab", "Enter": "ret"}

    def key(self, name):
        self.hmp("sendkey " + self.QKEYS[name])
        os88qemu.pace(self, 0.05)

    def read(self, linear, n):
        p = os.path.join(self.tmp, "m.bin")
        # THE FILENAME IS QUOTED: HMP parses an unquoted path as an
        # EXPRESSION and answers "invalid char 't'", which reads as a bad
        # address rather than a bad argument.
        self.hmp('pmemsave 0x%X %d "%s"' % (linear, n, p))
        with open(p, "rb") as f:
            return f.read()

    def readseg(self, seg, off, n):
        return self.read(os88qemu.lin(seg, off), n)

    def lin(self, seg, off=0):
        return os88qemu.lin(seg, off)

    def quit(self):
        try:
            self.hmp("quit")
        except Exception:
            pass


class Mouse:
    """The three gestures tests/dispcp.py asks of a pointer, DEAD-RECKONED.

    dispcp names its fallback: tools/mouse.py, which walks the pointer and
    paces itself in GUEST time. ethernet.py's Mouse is closed-loop on the
    kernel's own `mouse_x`/`mouse_btn` and is the better one under a loaded
    soak; this row opens two windows and then never touches the mouse again,
    so the fallback is the whole of what it needs.

    THE SOCKET IS READ AT CALL TIME. os88qemu.make_test re-points SOCK at the
    machine it launched, and a Mouse that captured it at construction drives
    whatever instance happened to be there first.
    """

    def _mouse(self, *a):
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mouse.py"),
                        os88qemu.SOCK] + list(a), cwd=ROOT,
                       capture_output=True)

    def _hmp(self, *c):
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "qmp.py"),
                        os88qemu.SOCK] + list(c), cwd=ROOT,
                       capture_output=True)

    def click(self, x, y, settle=None, **kw):
        self._mouse("click", str(x), str(y))

    def dblclick(self, x, y, settle=None, **kw):
        # tools/mouse.py has no double click (it would be two processes and
        # the gap between them is the host's): the pointer is parked first
        # and BOTH button pairs go in ONE qmp.py call, so the only time
        # between them is the guest's own.
        self._mouse("to", str(x), str(y))
        self._hmp("mouse_button 1", "sleep 0.05", "mouse_button 0",
                  "sleep 0.06", "mouse_button 1", "sleep 0.05",
                  "mouse_button 0", "gsleep 0.5")

    def menu(self, px, py, ix, iy, settle=None, **kw):
        self._mouse("to", str(px), str(py))
        self._hmp("mouse_button 1", "gsleep 0.2")
        self._mouse("to", str(ix), str(iy))
        self._hmp("mouse_button 0", "gsleep 0.3")


def settle(m, card=None):
    """The UI task finished with what it was given - a CEILING, not a pause."""
    os88qemu.ui_done(m, S, cap=2.0)


def typ(m, text):
    """os88qemu.type_text: EVERY KEYSTROKE CONFIRMED.

    Firing `sendkey` per character and moving on types 160 keys in 0.9
    seconds and loses some of them - measured, and the editor showed it:
    `PRINT n` and `N = 3` arrived merged as `N =3RINT n`. type_text releases
    each key only once the ROM has STORED the press, which is the whole
    difference between a row that types a program and a row that types most
    of one.
    """
    os88qemu.type_text(m.path, text)


SEED = "31415"          # ...printed first by every part; see console_lines


_BUF = [None]                   # where a part last found the console


def console_lines(m):
    """Every non-blank line of the console BUFFER, in order.

    **ANCHORED ON A SENTINEL THE PROGRAM ITSELF PRINTS.** Two earlier
    anchors did not survive the language growing. BASIC's banner as cells
    works until a program prints more than the 25-row buffer holds and the
    banner scrolls off - wave 2c's did. "One attribute byte across 25 rows"
    then looked structural enough to be safe, and is not: after CLS no such
    region was in the dump at all, and the row could only report that it
    could not find one.

    So each part prints SEED as its first line. It is a number no answer
    is, it is at the TOP of a freshly cleared buffer so nothing can scroll
    it away, and it is written by the very console being looked for. From
    it the region is bounded by the attribute byte its own cells carry -
    whatever that turns out to be - rather than by a guess about it.

    **A PART THAT TESTS A REFUSAL CANNOT PRINT IT.** The whole program is
    compiled before any of it runs (SPEC.md 126.19), so a program refused
    at compile time prints nothing at all - not the sentinel, not even its
    own CLS. Those parts are read at the address a previous part found: the
    buffer is in the package's bss and the package does not move while the
    window stays open. The fallback is only taken when the scan fails, the
    attribute-shape check still applies to it, and a refusal's expectation
    is an exact sentence - so a stale address cannot pass quietly.
    """
    img = m.read(0, 0x100000)
    pat = SEED.encode()
    at = -1
    for i in range(len(img) - 2 * len(pat)):
        if img[i] == pat[0] and all(img[i + 2 * k] == pat[k]
                                    for k in range(len(pat))):
            at = i
            break
    if at < 0:
        if _BUF[0] is None:
            print("      no buffer: the sentinel %s is not in memory as cells"
                  % SEED)
            return None
        at = _BUF[0]
        print("      no sentinel: reading the buffer a part before it found")
    attr = img[at + 1]
    # back up to the row this sits on, then to the first row sharing its
    # attribute - SEED is at column 1 (PRINT's sign space is column 0)
    start = at - 2
    while start - ROW >= 0 and all(img[start - ROW + 2 * c + 1] == attr
                                   for c in range(CON_COLS)):
        start -= ROW
    rows = 0
    while (start + (rows + 1) * ROW <= len(img) and rows < CON_ROWS
           and all(img[start + rows * ROW + 2 * c + 1] == attr
                   for c in range(CON_COLS))):
        rows += 1
    print("      console buffer: 0x%X, %d rows, attr 0x%02X"
          % (start, rows, attr))
    _BUF[0] = at
    out = []
    for base in range(start, start + rows * ROW, ROW):
        txt = "".join(chr(img[base + 2 * c])
                      if 32 <= img[base + 2 * c] < 127 else " "
                      for c in range(CON_COLS)).strip()
        if txt:
            out.append(txt)
    return out


def pane_has_ink(m):
    """The console pane is DRAWN - text lit INSIDE it, not pixels anywhere.

    The first version counted lit pixels in the lower half of the SCREEN and
    passed with the pane stone blank, because most of that half is desktop:
    a 50% dither is half lit and swamps anything the window does. It was a
    vacuous assertion and the mutation proved it - taking con_takescroll out
    of bas_paint left every check green.

    So the pane is found by what makes it unmistakable: it is the only SOLID
    BLACK on the screen. A dither alternates, so its longest run of dark
    pixels is one or two; the pane's is its full width. Rows carrying a long
    dark run are the pane, and the white pixels in them are its TEXT.
    """
    png = os.path.join(m.tmp, "pane.png")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, png], capture_output=True, cwd=ROOT)
    try:
        from PIL import Image
    except ImportError:
        return None
    im = Image.open(png).convert("L")
    w, h = im.size
    px = im.load()
    lit = rows = 0
    for y in range(h):
        run = best = 0
        for x in range(w):
            if px[x, y] < 128:
                run += 1
                best = max(best, run)
            else:
                run = 0
        if best < 300:                      # not the pane: dither or chrome
            continue
        rows += 1
        lit += sum(1 for x in range(w) if px[x, y] >= 128
                   and 0 < x < w - 1 and px[x - 1, y] < 128 or
                   (px[x, y] >= 128 and _in_dark_row(px, w, y, x)))
    return lit if rows else 0


def _in_dark_row(px, w, y, x):
    """`x` lies inside the pane's dark span on row `y`."""
    left = right = False
    for i in range(x - 1, max(-1, x - 400), -1):
        if px[i, y] < 128:
            left = True
            break
    for i in range(x + 1, min(w, x + 400)):
        if px[i, y] < 128:
            right = True
            break
    return left and right


def main():
    os88fixture.need("build/basic.img")
    os88qemu.make_test("TESTAPPS=build/basic.img")
    m = Qemu()
    os88qemu.own(sock=m.path)
    os88qemu.kernel_up(m, S, secs=180)

    # B:, then APPS, then the package - BY NAME at every step. dispcp.open_*
    # looks the row up in the staged listing and CHECKS it before it clicks,
    # which is the only way a gate should name a file: a coordinate drifts
    # with the window and a miss reads as the package having failed to start.
    mo = Mouse()
    dispcp.open_drive(m, mo, S, settle, "B")
    wins = dispcp.win_list(m, S)
    wx, wy = dispcp.win_rect(m, S, wins[-1])[:2]
    dispcp.open_named(m, mo, S, settle, wx, wy, "APPS")
    dispcp.open_named(m, mo, S, settle, wx, wy, "BASIC.O88")

    answers, want = [], []
    for pn, part in enumerate(PARTS):
        if pn:
            # A FRESH EDITOR, THROUGH File > New. Backspacing the previous
            # part out was 900 confirmed keys and the BIOS buffer cannot
            # take them that fast: `the ROM had not stored the press after
            # 10 guest seconds`, once per key, for minutes. New clears the
            # program, the console and the variable table in one gesture
            # (SPEC.md 126.17), and is the only menu this row touches.
            mo.menu(112, 8, 112, 30)
            os88qemu.pace(m, 2.0)
        t0 = time.time()
        for line, _ in part:
            typ(m, line + "\n")
        print("      part %d: %d lines in %.1fs"
              % (pn + 1, len(part), time.time() - t0))
        os88qemu.sendkey(m.path, "f5")          # the Run key, confirmed
        os88qemu.pace(m, 6.0)
        got = console_lines(m)
        if got is None:
            check(False, "the console buffer is found by its shape",
                  why="no run can be read without it")
            return 1
        answers += got
        want += [e for _, e in part if e is not None]
    check(True, "the console buffer is found by its shape")

    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, os.path.join(m.tmp, "end.png")],
                   capture_output=True, cwd=ROOT)
    print("      screen: %s" % os.path.join(m.tmp, "end.png"))
    answers = [g for g in answers if g not in (BANNER + " - SPEC.md 126",
                                               "Ready")]
    check(answers == want,
          "every line of the program answers what SPEC.md 126 says it does",
          why="the language is what this row is for; an answer that is merely "
              "PLAUSIBLE is the failure mode (-2.668453E+307 was not)",
          got=answers, want=want)

    # --- and now the RENDERER, which needs more than one run ---------------
    # The answers are read above, while the banner is still in the buffer and
    # can anchor it. The scroll defect needs REPEATED paint cycles - a single
    # run leaves the pane drawn with bas_paint's con_takescroll deleted, which
    # is a mutation that passed - so two more runs happen here, after the text
    # is in hand. They also scroll the banner off the top, which is why the
    # order is not the other way round.
    for _ in range(2):
        os88qemu.sendkey(m.path, "f5")
        os88qemu.pace(m, 6.0)

    lit = pane_has_ink(m)
    if lit is not None:
        check(lit > 50,
              "the console pane is DRAWN, not just right in the buffer",
              why="os88con.inc's scroll debt is the carrier's to settle, and "
                  "a carrier that does not leaves the pane blank with every "
                  "cell behind it correct (bas_paint owes con_takescroll)",
              got="%d lit pixels" % lit, want="> 50")

    print("basiclang: %s" % ("FAILED: " + ", ".join(FAILED) if FAILED
                             else "all checks passed"))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
