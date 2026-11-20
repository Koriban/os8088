#!/usr/bin/env python3
"""BASIC/8088 runs a program and the answers are right (SPEC.md 150).

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
the console is EIGHT rows of a 25-row buffer (SPEC.md 150.17), so most of a
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
  * PROCEDURE: making a RETURN restore EVERY frame's saved locals instead of
    only its own, down to the frame's mark. Writing it is what added the case
    that catches it - a procedure with a local calling another procedure with
    a local - and the caller's 7 becomes the global 5 the moment the callee
    returns.
  * parameters: running the callee's prologue FORWARDS instead of backwards.
    Writing it showed that both two-value calls in the part were symmetric -
    3*4 and 4*3 are one number - so `order(10, 3)` printing `a - b` was
    added, and it is the single difference the mutant makes: 7 against -7.
  * VAR: leaving a by-reference argument's OP_LOAD alone instead of
    rewriting the byte to OP_VREF. The alias then points at whatever
    variable number the VALUE rounds to - which for GFA's own entry-238
    example is variable 0, so `a` collects both answers (16) and `b` keeps
    0. A plausible-looking wrong answer, which is what this row is for.
  * the built-ins: taking the CLAMP out of the slice, so a count larger than
    what is left is passed through. `MID$(s$, 4)` compiles its missing
    length as 32767 (SPEC.md 150.29), so without the clamp the slice asks
    the arena for 32767 bytes: `Error at line 9: one piece of text is longer
    than the arena`, which is the clamp's whole job stated as a refusal.
  * string arrays: making bas_nroots count only the variables, so an array
    element stops being a compaction root (SPEC.md 150.32). After the
    120-iteration loop that forces a compaction, `File` `Edit` `Help` come
    back as `yyyy` - the elements still point into the arena and the loop's
    own string is living in those bytes now. Five differences, all of them
    the lines after the loop.
  * arrays: taking the UPPER bound out of bas_aelem's check. `PRINT a(5)`
    on a `DIM a(4)` stops being refused and answers `0` - a plausible number
    read from past the end of the array, which is the one thing an 8086
    cannot catch for itself. One exact difference, at index 107.
  * arrays: restoring DI in OP_ASTORE, which leaks a slot per assignment -
    found by reading rather than by running, so it is listed for the shape
    and not as a verified mutation.
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
import glass                                                # noqa: E402

S = os88sym.linear
SOCK = os88qemu.SOCK

CON_COLS, CON_ROWS = 80, 25
ROW = CON_COLS * 2                      # a row of (character, attribute)
BANNER = "BASIC/8088"                   # bas_s_banner's first word

# The program, and what each line owes the console. A blank expectation is a
# line that prints nothing - an assignment, which is most of what a program
# is. SPEC.md 150.4's PRINT puts a space where the sign would be and another
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
# is self-contained (RUN clears the variables, SPEC.md 150.17), so they are
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
    # dot and an underscore (SPEC.md 150.22, GFA's entry 249)
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

PART9 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- the three spellings of one call (SPEC.md 150.23) -----------------
    # AN EXPECTATION IS PINNED TO THE LINE THAT RUNS, not to the line that
    # holds the PRINT: the console is in execution order, and a procedure's
    # body runs at its CALL - which is below its own text here.
    ("GOSUB hello",                      "85"),
    ("@hello",                           "85"),
    ("hello",                            "85"),
    # --- LOCAL is DYNAMIC scope: the global is saved and put back ---------
    ("x = 2",                            None),
    ("y = 9",                            None),
    ("GOSUB hide",                       "0"),      # ...its local, born 0
    ("PRINT x",                          "2"),      # ...untouched outside
    ("PRINT y",                          "9"),
    # --- a local is visible to what the procedure CALLS, which is GFA's
    # own wording and what save-and-restore gives for nothing
    ("z = 5",                            None),
    ("GOSUB outer",                      ["7", "7"]),  # inner sees outer's z,
                                                     # and outer still has it
    ("PRINT z",                          "5"),      # ...and it is back
    # --- values handed over, which are LOCALs that arrive full -----------
    ("w = 100",                          None),
    ("area(3, 4)",                       "12"),
    ("GOSUB area(5, 6)",                 "30"),
    ("@area(2, 2)",                      "4"),
    ("PRINT w",                          "100"),    # ...the global, untouched
    # ...IN ORDER, which `area` cannot show: 3*4 and 4*3 are the same number,
    # so nothing above would notice a prologue that ran forwards
    ("order(10, 3)",                     "7"),
    # ...and one per frame, which is what recursion needs of them ---------
    ("r = 1",                            None),
    ("GOSUB fact(5)",                    None),
    ("PRINT r",                          "120"),
    # --- recursion, which a stack of frames already is -------------------
    ("d = 0",                            None),
    ("c = 4",                            None),
    ("GOSUB down",                       None),
    ("PRINT d",                          "4"),
    ("END",                              None),
    ("PROCEDURE hello",                  None),
    ("PRINT 85",                         None),
    ("RETURN",                           None),
    ("PROCEDURE hide",                   None),
    ("LOCAL x, y",                       None),
    ("PRINT x",                          None),     # ...expected at the CALL
    ("x = 77",                           None),
    ("y = 88",                           None),
    ("RETURN",                           None),
    ("PROCEDURE outer",                  None),
    ("LOCAL z",                          None),
    ("z = 7",                            None),
    ("GOSUB inner",                      None),
    ("PRINT z",                          None),     # ...STILL outer's 7:
    ("RETURN",                           None),     # inner's RETURN restores
    ("PROCEDURE inner",                  None),     # only ITS OWN saves, down
    ("LOCAL w",                          None),     # to the frame's mark
    ("w = 1",                            None),
    ("PRINT z",                          None),     # ...outer's z, not 5
    ("RETURN",                           None),
    ("PROCEDURE area(w, h)",             None),
    ("PRINT w * h",                      None),
    ("RETURN",                           None),
    ("PROCEDURE order(a, b)",            None),
    ("PRINT a - b",                      None),
    ("RETURN",                           None),
    ("PROCEDURE fact(n)",                None),
    ("IF n > 1 THEN",                    None),
    ("r = r * n",                        None),
    ("GOSUB fact(n - 1)",                None),
    ("ENDIF",                            None),
    ("RETURN",                           None),
    ("PROCEDURE down",                   None),
    ("IF c > 0 THEN",                    None),
    ("c = c - 1",                        None),
    ("d = d + 1",                        None),
    ("GOSUB down",                       None),
    ("ENDIF",                            None),
    ("RETURN",                           None),
]

PART10 = [
    ("CLS",                              None),
    ("PRINT 31415",                      None),
    ("GOSUB missing",
     "Error at line 3: that names a procedure the program does not have"),
]

PART11 = [
    ("CLS",                              None),
    ("RETURN",
     "Error at line 2: RETURN is not inside a procedure"),
]

PART13 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- FUNCTION: a value comes back, in an expression (SPEC.md 150.25) --
    ("PRINT @twice(21)",                 "42"),
    ("PRINT FN twice(5)",                "10"),     # ...GFA's other spelling
    ("v = @twice(3) + @twice(4)",        None),
    ("PRINT v",                          "14"),
    # ...several RETURNs, and recursion through one -----------------------
    ("PRINT @fac(5)",                    "120"),
    ("PRINT @sgn3(0)",                   "0"),
    ("PRINT @sgn3(-7)",                  "-1"),
    ("PRINT @sgn3(9)",                   "1"),
    # ...a body that falls off its end answers 0, not whatever was there --
    ("PRINT @nothing(1)",                "0"),
    # ...and a value may be worked out and FORGOTTEN (SPEC.md 150.27)
    ("k2 = 0",                           None),
    ("~@bump(5)",                        None),
    ("PRINT k2",                         "5"),      # the call HAPPENED...
    ("VOID @bump(2)",                    None),
    ("PRINT k2",                         "7"),      # ...by either spelling
    ("~1 + 2",                           None),     # ...and not only a call
    ("PRINT k2",                         "7"),
    ("END",                              None),
    ("FUNCTION bump(n)",                 None),
    ("k2 = k2 + n",                      None),
    ("RETURN k2",                        None),
    ("ENDFUNC",                          None),
    ("FUNCTION twice(n)",                None),
    ("RETURN n + n",                     None),
    ("ENDFUNC",                          None),
    ("FUNCTION fac(n)",                  None),
    ("IF n < 2 THEN",                    None),
    ("RETURN 1",                         None),
    ("ENDIF",                            None),
    ("RETURN n * @fac(n - 1)",           None),
    ("ENDFUNC",                          None),
    ("FUNCTION sgn3(n)",                 None),
    ("IF n > 0 THEN",                    None),
    ("RETURN 1",                         None),
    ("ELSEIF n < 0 THEN",                None),
    ("RETURN 0 - 1",                     None),
    ("ENDIF",                            None),
    ("RETURN 0",                         None),
    ("ENDFUNC",                          None),
    ("FUNCTION nothing(n)",              None),
    ("ENDFUNC",                          None),
]

PART16 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- VAR: the variable itself, not its value (SPEC.md 150.26) --------
    ("a = 0",                            None),
    ("b = 0",                            None),
    ("sum(13, 12, a)",                   None),
    ("sum(7, 9, b)",                     None),
    ("PRINT a",                          "25"),     # GFA's own entry-238
    ("PRINT b",                          "16"),     # example, and its answers
    # ...and a reference reaches through a SECOND call ---------------------
    ("c = 1",                            None),
    ("outer2(c)",                        None),
    ("PRINT c",                          "9"),
    # ...each frame's own, under recursion --------------------------------
    ("e = 0",                            None),
    ("climb(3, e)",                      None),
    ("PRINT e",                          "3"),
    # ...a value parameter beside it is still a COPY ----------------------
    ("f = 5",                            None),
    ("both(f, f)",                       None),
    ("PRINT f",                          "11"),     # the VAR one won, not 5
    ("END",                              None),
    ("PROCEDURE sum(x, y, VAR z)",       None),
    ("z = x + y",                        None),
    ("RETURN",                           None),
    ("PROCEDURE outer2(VAR q)",          None),
    ("inner2(q)",                        None),
    ("RETURN",                           None),
    ("PROCEDURE inner2(VAR r)",          None),
    ("r = r + 8",                        None),
    ("RETURN",                           None),
    ("PROCEDURE climb(n, VAR acc)",      None),
    ("IF n > 0 THEN",                    None),
    ("acc = acc + 1",                    None),
    ("climb(n - 1, acc)",                None),
    ("ENDIF",                            None),
    ("RETURN",                           None),
    ("PROCEDURE both(v, VAR w2)",        None),
    ("v = 99",                           None),
    ("w2 = 11",                          None),
    ("RETURN",                           None),
]

PART17 = [
    ("CLS",                              None),
    ("sum(1, 2, 3 + 4)",
     "Error at line 2: a VAR value wants a variable to point at"),
    ("PROCEDURE sum(x, y, VAR z)",       None),
    ("RETURN",                           None),
]

PART14 = [
    ("CLS",                              None),
    ("PRINT @aproc(1)",
     "Error at line 2: that is a PROCEDURE and returns no value"),
    ("PROCEDURE aproc(n)",               None),
    ("RETURN",                           None),
]

PART15 = [
    ("CLS",                              None),
    ("afunc(1)",
     "Error at line 2: that is a FUNCTION - its value has nowhere to go"),
    ("FUNCTION afunc(n)",                None),
    ("RETURN n",                         None),
    ("ENDFUNC",                          None),
]

PART12 = [
    ("CLS",                              None),
    ("area(1)",
     "Error at line 2: that call hands over the wrong number of values"),
    ("PROCEDURE area(w, h)",             None),
    ("RETURN",                           None),
]

PART18 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- text: a literal, a $ name, and the two kept apart (150.28) ------
    ('PRINT "hello"',                    "hello"),
    ('a$ = "world"',                     None),
    ("PRINT a$",                         "world"),
    ('PRINT "say " + a$',                "say world"),
    ("b$ = a$",                          None),
    ('a$ = "other"',                     None),
    ("PRINT b$",                         "world"),    # ...a COPY, not a share
    # ...an empty one, and a name that only LOOKS like another ------------
    ('e$ = ""',                          None),
    ('PRINT "<" + e$ + ">"',             "<>"),
    ("a = 7",                            None),       # `a` and `a$` are two
    ("PRINT a",                          "7"),        # different variables
    ("PRINT a$",                         "other"),
    # ...the six relations, from one compare op ---------------------------
    ('PRINT "abc" = "abc"',              "-1"),
    ('PRINT "abc" = "abd"',              "0"),
    ('PRINT "abc" < "abd"',              "-1"),
    ('PRINT "Z" < "a"',                  "-1"),       # byte order, not locale
    ('PRINT "ab" < "abc"',               "-1"),       # a prefix sorts first
    ('PRINT "abc" <> "ab"',              "-1"),
    ('PRINT a$ >= "other"',              "-1"),
    ('IF a$ = "other" THEN',             None),
    ('PRINT "matched"',                  "matched"),
    ("ENDIF",                            None),
    # ...and the arena survives being filled and refilled ----------------
    ('c$ = "x"',                         None),
    ("FOR i = 1 TO 200",                 None),
    ('c$ = "y" + c$',                    None),       # 200 assignments, each
    ("NEXT",                             None),       # leaking its old bytes
    ("PRINT c$ = c$",                    "-1"),
    ('PRINT "still here"',               "still here"),
]

PART19 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- the eight built-ins (SPEC.md 150.29) ----------------------------
    ('s$ = "abcdef"',                    None),
    ("PRINT LEN(s$)",                    "6"),
    ('PRINT LEN("")',                    "0"),
    ('PRINT LEFT$(s$, 3)',               "abc"),
    ('PRINT RIGHT$(s$, 2)',              "ef"),
    ('PRINT MID$(s$, 2, 3)',             "bcd"),
    ('PRINT MID$(s$, 4)',                "def"),      # ...to the end
    ('PRINT ASC("A")',                   "65"),
    ('PRINT CHR$(66)',                   "B"),
    ('PRINT ASC(CHR$(200))',             "200"),      # a round trip
    # ...VAL reads a PREFIX and answers 0, it does not refuse -------------
    ('PRINT VAL("42 parts")',            "42"),
    ('PRINT VAL("not a number")',        "0"),
    ('PRINT VAL("-7.5")',                "-7.5"),
    # ...STR$ keeps PRINT's leading space, so this is `[ 42]` ------------
    ('PRINT "<" + STR$(42) + ">"',       "< 42>"),
    ('PRINT "<" + STR$(0 - 42) + ">"',   "<-42>"),
    # ...the ends are CLAMPED, not refused -------------------------------
    ('PRINT LEN(LEFT$(s$, 99))',         "6"),
    ('PRINT LEN(MID$(s$, 99))',          "0"),        # start past the end
    ('PRINT LEN(RIGHT$(s$, 99))',        "6"),
    ('PRINT MID$(s$, 0, 2)',             "ab"),       # 0 reads as 1
    # ...and the diary's own example line finally runs --------------------
    ("r = 1",                            None),
    ("GOSUB fact5",                      None),
    ('PRINT "5! is " + STR$(r)',         "5! is  120"),
    # ...a slice of a variable INTO ITSELF, which the temporary makes safe
    ('t$ = "hello"',                     None),
    ("t$ = MID$(t$, 2)",                 None),
    ("PRINT t$",                         "ello"),
    ("END",                              None),
    ("PROCEDURE fact5",                  None),
    ("FOR i = 2 TO 5",                   None),
    ("r = r * i",                        None),
    ("NEXT",                             None),
    ("RETURN",                           None),
]

PART20 = [
    ("CLS",                              None),
    ('PRINT ASC("")',
     "Error at line 2: ASC wants text with at least one character in it"),
]

PART21 = [
    ("CLS",                              None),
    ("PRINT CHR$(300)",
     "Error at line 2: CHR$ takes a code from 0 to 255"),
]

PART22 = [
    ("CLS",                              None),
    ('PRINT LEFT$("abc", 0 - 1)',
     "Error at line 2: that many characters is a negative number"),
]

PART23 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- DIM a(8) is 0..8, NINE slots (SPEC.md 150.31) -------------------
    ("DIM rows(8)",                      None),
    ("rows(0) = 1",                      None),
    ("rows(8) = 9",                      None),
    ("PRINT rows(0)",                    "1"),
    ("PRINT rows(8)",                    "9"),
    ("PRINT LBOUND(rows)",               "0"),
    ("PRINT UBOUND(rows)",               "8"),
    ("PRINT rows(4)",                    "0"),       # never stored: born 0
    # ...explicit bounds ---------------------------------------------------
    ("DIM sq(1 TO 5)",                   None),
    ("FOR i = 1 TO 5",                   None),
    ("sq(i) = i * i",                    None),
    ("NEXT",                             None),
    ("PRINT sq(1)",                      "1"),
    ("PRINT sq(5)",                      "25"),
    ("PRINT LBOUND(sq)",                 "1"),
    ("PRINT UBOUND(sq)",                 "5"),
    # ...two dimensions, row-major ----------------------------------------
    ("DIM grid(1 TO 3, 1 TO 3)",         None),
    ("grid(2, 2) = 5",                   None),
    ("grid(1, 3) = 7",                   None),
    ("PRINT grid(2, 2)",                 "5"),
    ("PRINT grid(1, 3)",                 "7"),
    ("PRINT grid(3, 1)",                 "0"),       # ...and not aliased
    # ...TWENTY stores in a loop, which is what a stack leak would break
    ("DIM many(1 TO 20)",                None),
    ("t = 0",                            None),
    ("FOR i = 1 TO 20",                  None),
    ("many(i) = i",                      None),
    ("NEXT",                             None),
    ("FOR i = 1 TO 20",                  None),
    ("t = t + many(i)",                  None),
    ("NEXT",                             None),
    ("PRINT t",                          "210"),
    # ...an element in an expression, and as a subscript -------------------
    ("PRINT many(3) + many(4)",          "7"),
    ("PRINT many(many(2))",              "2"),
]

PART24 = [
    ("CLS",                              None),
    ("DIM a(4)",                         None),
    ("PRINT a(5)",
     "Error at line 3: that subscript is outside the array"),
]

PART25 = [
    ("CLS",                              None),
    ("DIM a(4)",                         None),
    ("OPTION BASE 1",
     "Error at line 3: OPTION BASE must come before any DIM"),
]

PART26 = [
    ("CLS",                              None),
    ("OPTION BASE 1",                    None),
    ("DIM a(5)",                         None),
    ("a(1) = 7",                         None),
    ("PRINT LBOUND(a)",                  "1"),       # the base moved
    ("PRINT UBOUND(a)",                  "5"),
    ("PRINT a(1)",                       "7"),
    ("PRINT 31415",                      "31415"),
]

PART27 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    # --- a string array (SPEC.md 150.31) ---------------------------------
    ("DIM m$(3)",                        None),
    ('m$(0) = "File"',                   None),
    ('m$(1) = "Edit"',                   None),
    ('m$(2) = "Help"',                   None),
    ("PRINT m$(0)",                      "File"),
    ("PRINT m$(2)",                      "Help"),
    ("PRINT m$(3)",                      None),      # never stored: empty
    ("PRINT LEN(m$(1))",                 "4"),
    ('PRINT m$(1) + "!"',                "Edit!"),
    ('PRINT LEFT$(m$(2), 2)',            "He"),
    ("PRINT m$(1) < m$(0)",              "-1"),       # Edit < File: 'E' < 'F'
    ("PRINT m$(0) < m$(1)",              "0"),        # ...and not the reverse
    # --- AND THE ROOT THAT 150.32 IS ABOUT -------------------------------
    # The elements above are live. Now fill the string arena from a loop so
    # a compaction MUST happen, then read them back: if the walk does not
    # cover array elements, their bytes have moved and this prints rubbish.
    ('c$ = "x"',                         None),
    ("FOR i = 1 TO 120",                 None),
    ('c$ = "yy" + c$',                   None),
    ("NEXT",                             None),
    ("PRINT LEN(c$)",                    "241"),
    ("PRINT m$(0)",                      "File"),     # ...still, after it
    ("PRINT m$(1)",                      "Edit"),
    ("PRINT m$(2)",                      "Help"),
    ('PRINT m$(1) + m$(2)',              "EditHelp"),
    # ...and an element reassigned after the compaction ------------------
    ('m$(1) = "Search"',                 None),
    ("PRINT m$(1)",                      "Search"),
    ("PRINT m$(0)",                      "File"),
]

PART28 = [
    ("CLS",                              None),
    ("DIM n(3)",                         None),
    ('PRINT n(1) + "x"',
     "Error at line 3: that mixes text and numbers"),
]

# --- CLR, ARRAYFILL and SWAP (SPEC.md 150.33, 150.34) -------------------
# EVERY NUMBER BELOW IS THE REFERENCE'S OWN, not this implementation's. The
# oracle of plan §8 cannot answer here - `basicnw` is the QuickBASIC line
# and has no ARRAYFILL - so the authority is the manual's worked examples,
# which print their results: node [94] runs `x=2 : y=3 : CLR x` and prints 0
# and 3, node [95] runs `x=1 : y=2 : SWAP x,y` and prints 2 and 1, and node
# [73] runs `ARRAYFILL x(),5+1` and prints 0 before it and 6 after.
PART29 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("x = 2",                            None),
    ("y = 3",                            None),
    ("CLR x",                            None),
    ("PRINT x",                          "0"),
    ("PRINT y",                          "3"),       # ...and ONLY x moved
    ('s$ = "gone"',                      None),
    ("CLR s$",                           None),
    ("PRINT LEN(s$)",                    "0"),       # a `$` name goes to ""
    ("n = 5",                            None),
    ("m = 6",                            None),
    ("CLR n, m",                         None),      # the comma list
    ("PRINT n + m",                      "0"),
    ("a = 1",                            None),
    ("b = 2",                            None),
    ("SWAP a, b",                        None),
    ("PRINT a",                          "2"),
    ("PRINT b",                          "1"),
    ('p$ = "left"',                      None),
    ('q$ = "right"',                     None),
    ("SWAP p$, q$",                      None),
    ("PRINT p$",                         "right"),   # two offset/length
    ("PRINT q$",                         "left"),    # pairs, no arena work
    ("DIM w(10)",                        None),
    ("PRINT w(4)",                       "0"),
    ("ARRAYFILL w(), 5 + 1",             None),
    ("PRINT w(4)",                       "6"),
    ("PRINT w(0)",                       "6"),       # EVERY element, and the
    ("PRINT w(10)",                      "6"),       # two ends are the test
]

# A WHOLE-ARRAY SWAP MOVES NO ELEMENTS, and this part says the BOUNDS TRAVEL
# WITH THE CONTENTS, which is node [95]'s actual claim: swap only
# BAS_ARR_AT and LBOUND/UBOUND come back the old array's; swap only the
# bounds and the elements do. Both are red here, which is why LBOUND and
# UBOUND are asserted on both names after the swap and not just the values.
#
# WHAT IT DOES NOT PIN, measured rather than assumed: whether the swap takes
# twelve bytes or all sixteen. A build swapping all sixteen - the name's two
# fields included - passed this part with every answer unchanged, because an
# array's index is resolved at COMPILE time and nothing reads BAS_ARR_SRC
# after that (SPEC.md 150.19, 150.34). The twelve are held by a `times` pair
# in baslang.inc instead. The first version of this comment claimed the
# opposite and would have been believed.
PART30 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("DIM r(2)",                         None),
    ("DIM c(1 TO 4)",                    None),
    ("r(0) = 11",                        None),
    ("c(1) = 22",                        None),
    ("SWAP r(), c()",                    None),
    ("PRINT r(1)",                       "22"),      # r sees c's elements...
    ("PRINT LBOUND(r)",                  "1"),       # ...and c's bounds
    ("PRINT UBOUND(r)",                  "4"),
    ("PRINT c(0)",                       "11"),      # ...and the other way
    ("PRINT UBOUND(c)",                  "2"),
]

# THE FOUR REFUSALS, ONE PART EACH, because a refusal ends the program and a
# second one in the same part would never be reached (PART28's shape).
PART31 = [
    ("CLS",                              None),
    ("DIM q(3)",                         None),
    ("CLR q()",
     "Error at line 3: CLR takes variables; ARRAYFILL fills an array"),
]

PART32 = [
    ("CLS",                              None),
    ("DIM t$(3)",                        None),
    ("ARRAYFILL t$(), 1",
     "Error at line 3: ARRAYFILL cannot fill a string array"),
]

PART33 = [
    ("CLS",                              None),
    ("a = 1",                            None),
    ('b$ = "x"',                         None),
    ("SWAP a, b$",
     "Error at line 4: SWAP wants two of the same kind"),
]

PART34 = [
    ("CLS",                              None),
    ("DIM g(3)",                         None),
    ("a = 1",                            None),
    ("SWAP a, g()",
     "Error at line 4: SWAP takes two variables or two arrays, not one of each"),
]

# --- LSET and RSET (SPEC.md 150.35) -------------------------------------
# EVERY ANSWER IS DELIMITED. A console line is read out of a cell buffer
# that is space-padded to its width, so trailing spaces cannot be asserted
# on their own - "7" and "7    " read alike. The closing `>` is what makes
# the padding visible, and the padding IS the statement.
#
# `<` AND `>` RATHER THAN BRACKETS, which is not a style choice: the typist
# drives a real keyboard through QEMU and os88qemu._QCHAR has no qcode for
# `[`, so the first version of this part died mid-run with "no qcode for
# '['" after six parts had passed. `<` and `>` are already in that table.
PART35 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ('a$ = "xxxxx"',                     None),
    ('LSET a$ = "7"',                    None),
    ("PRINT LEN(a$)",                    "5"),       # the field's width
    ('PRINT "<" + a$ + ">"',             "<7    >"), # ...kept, and padded
    ('RSET a$ = "7"',                    None),
    ('PRINT "<" + a$ + ">"',             "<    7>"),
    # AND A NEIGHBOUR BEHIND IT, which is what makes the over-long lines an
    # assertion rather than a decoration. A missing clamp writes the source's
    # whole length into a field that is five bytes - and `PRINT a$` STILL
    # SHOWS FIVE, the length being the variable's and not the write's, so
    # the overrun is invisible here and lands in whatever owns the next
    # bytes. Measured, both ways: with the two justify mutations applied the
    # `<abcde>` lines below did not move at all, and with the clamp removed
    # for LSET this z$ came back `<fghZ>` - the three bytes past a five-byte
    # field - while both reads of a$ AND `LEN(z$)` stayed correct. So the
    # neighbour's CONTENT is the only assertion here that sees an overrun.
    # z$ is allocated after a$ in the same bump arena (150.28), which is why
    # it is what the stray bytes take, and it is read AFTER both writes.
    ('z$ = "ZZZZ"',                      None),
    ('LSET a$ = "abcdefgh"',             None),      # longer than the field
    ('PRINT "<" + a$ + ">"',             "<abcde>"), # the field does not grow
    ('RSET a$ = "abcdefgh"',             None),
    ('PRINT "<" + a$ + ">"',             "<abcde>"), # the SAME first five:
    ('PRINT "<" + z$ + ">"',             "<ZZZZ>"),  # one rule for both...
    ("PRINT LEN(z$)",                    "4"),       # ...and nothing spilled
    ('e$ = ""',                          None),
    ('LSET e$ = "zz"',                   None),
    ("PRINT LEN(e$)",                    "0"),       # a zero field: no-op
]

PART36 = [
    ("CLS",                              None),
    ("n = 1",                            None),
    ("LSET n = 2",
     "Error at line 3: LSET and RSET want a $ name"),
]

# ERASE DELETES AN ARRAY FOR REAL (SPEC.md 150.41, node [94]). It was
# refused by name through 150.33 for a reason that expired when 150.40 moved
# the arena to run time - it would have freed nothing - and this part is what
# that refusal was standing in for. THE MEMORY HAS TO COME BACK: node [94]'s
# own example prints FRE(0) either side of an ERASE to show it, and this row
# has no FRE, so it proves the release the only other way there is - by
# allocating again in the space that was freed.
PART37 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM k(3)",                         None),       # 3
    ("k(0) = 5",                         None),       # 4
    ("PRINT k(0)",                       "5"),        # 5
    ("ERASE k()",                        None),       # 6
    # ...and it is gone: the bound check meets a count of zero (150.40)
    ("PRINT k(0)",                                    # 7
     "Error at line 7: that subscript is outside the array"),
]

# THE MEMORY REALLY COMES BACK, which is the half of node [94] that a
# "deleted" flag alone would fake. 400 elements is most of the arena's 512,
# so the second DIM only fits if the first array's bytes were released.
PART58 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("big = 400",                        None),       # 3
    ("DIM p(big)",                       None),       # 4
    ("ERASE p()",                        None),       # 5
    ("DIM q(big)",                       None),       # 6  ...only now it fits
    ("q(400) = 7",                       None),       # 7
    ("PRINT q(400)",                     "7",),       # 8
]

# RE-DIM: node [94]'s "which can then be redimensioned". The same name twice
# in the text, which compiled to a refusal before 150.41, with an ERASE
# between them - and the NEW bounds are in force afterwards, which is the
# part a flag-only ERASE would get wrong.
PART59 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM r(2)",                         None),       # 3
    ("r(2) = 1",                         None),       # 4
    ("ERASE r()",                        None),       # 5
    ("DIM r(6)",                         None),       # 6
    ("r(6) = 9",                         None),       # 7  outside the OLD one
    ("PRINT r(6)",                       "9"),        # 8
    ("PRINT UBOUND(r)",                  "6"),        # 9
]

# ...AND WITHOUT THE ERASE IT IS REFUSED AT RUN TIME. The text rule is now
# "one descriptor per name" and the dynamic rule is "one live allocation at a
# time" (150.41), so this compiles and then meets 150.40's flag.
PART60 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM s(2)",                         None),       # 3
    ("DIM s(6)",                                      # 4
     "Error at line 4: that array is already DIMmed"),
]

# A RE-DIM MAY NOT CHANGE THE NUMBER OF SIZES, and that is correctness: an
# element reference is compiled against the count while bas_aelem reads it at
# RUN time to decide how many subscripts to pop, so references compiled
# before would push one for a run that pops two (150.41).
# NO SENTINEL IN THIS ONE, NOR IN PART64, and the reason is the difference
# between the two kinds of refusal: these two are refused at COMPILE time, so
# the program never runs and its `PRINT 31415` never prints. The run-time
# refusals above all keep their sentinel, because the program gets as far as
# printing it. PART24 and PART25 have had this shape since wave 2 without
# anybody writing down why; asserting a sentinel here is what asked.
PART61 = [
    ("CLS",                              None),       # 1
    ("DIM t(2)",                         None),       # 2
    ("ERASE t()",                        None),       # 3
    ("DIM t(2, 2)",                                   # 4
     "Error at line 4: that array was DIMmed with a different number "
     "of sizes"),
]

# ERASE TAKES A LIST - "in contrast to Version 2, several arrays can be
# deleted at once" (node [94]) - and the hole it closes is in the MIDDLE
# here, which is the case a bump arena cannot pop: u() is erased while v()
# sits above it, so v() has to MOVE and keep its contents.
PART62 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM u(100)",                       None),       # 3
    ("DIM v(100)",                       None),       # 4
    ("v(100) = 33",                      None),       # 5
    ("ERASE u()",                        None),       # 6  the hole is BELOW v
    ("PRINT v(100)",                     "33"),       # 7  ...and v moved with
    ("DIM w(300)",                       None),       # 8  its bytes intact
    ("w(300) = 44",                      None),       # 9
    ("PRINT w(300)",                     "44"),       # 10
    ("ERASE v(), w()",                   None),       # 11 both at once
    ("DIM x(500)",                       None),       # 12 nearly the whole
    ("x(500) = 55",                      None),       # 13 arena, so only a
    ("PRINT x(500)",                     "55"),       # 14 real release fits it
]

# ERASE ON AN ARRAY WHOSE DIM HAS NOT RUN refuses by the same name LBOUND and
# UBOUND give for that state (150.40), rather than quietly doing nothing.
PART63 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("z = 0",                            None),       # 3
    ("IF z > 0 THEN",                    None),       # 4
    ("DIM y(3)",                         None),       # 5
    ("ENDIF",                            None),       # 6
    ("ERASE y()",                                     # 7
     "Error at line 7: that array has not been DIMmed yet on this run"),
]

# ...and a name the text never DIMs at all is refused at COMPILE time, which
# is a different message: there is no row to erase.
PART64 = [
    ("CLS",                              None),       # 1
    ("ERASE nosuch()",                                # 2
     "Error at line 2: ERASE wants an array this program DIMs somewhere"),
]

# --- ON MENU: the suspend/resume seam (SPEC.md 150.36) ------------------
# WHAT THIS PROVES IS THAT THE PROGRAM COMES BACK. Each ON MENU saves the op
# cursor, posts an OSAPI_WM_WAKE and RETURNS out of bas_exec - ending the
# AM_ONCMD callback and releasing the gfx lock - and bas_onwake resumes it.
# So `3` on the console means the loop went round three times across three
# suspensions, and the two statements after the loop ran on the third
# resume. Without a wake the program stops dead at the first ON MENU and
# nothing after it is ever printed, which is exactly the mutation below.
#
# IT IS NOT A HANG IF IT BREAKS, which is worth stating: the callback has
# already returned, so the window stays responsive and the row reads a
# console missing its answer rather than timing out. That is the whole point
# of the seam and it is also what makes this row cheap to run.
PART38 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("i = 0",                            None),
    ("DO",                               None),
    ("  i = i + 1",                      None),
    ("  ON MENU",                        None),
    ("LOOP UNTIL i >= 3",                None),
    ("PRINT i",                          "3"),
]

# --- MENU m$() (SPEC.md 150.38) -----------------------------------------
# WHAT THIS DOES NOT ASSERT, said first because it matters more than what it
# does: THE BAR'S VISIBLE TEXT. A menu bar is CHROME, and this row reads the
# console BUFFER out of memory - so `Plot` and `Zap` appearing on the glass
# is exactly the thing it cannot see. That is this repository's own standing
# hazard (a values-only gate is blind to the chrome; sheetmmenu once passed
# 8 of 8 with the bar in rubble), and reading it wants glass.py's glyph
# match over the bar strip, which wants VRAM access this harness does not
# have yet. It is owed, and it is named here rather than left to be assumed.
#
# WHAT IT DOES ASSERT: that the whole builder RUNS - the array walk, the
# text copies into the stable arena, the pointer tables, OSAPI_MENU_SET -
# and that the program carries on afterwards, which a builder that walked
# off its array or filled its arena would not allow.
PART45 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("DIM m$(6)",                        None),
    ('m$(0) = "Plot"',                   None),
    ('m$(1) = " Draw "',                 None),
    ('m$(2) = ""',                       None),
    ('m$(3) = "Zap"',                    None),
    ('m$(4) = " Kill "',                 None),
    ('m$(5) = ""',                       None),
    ("MENU m$()",                        None),
    # ...AND THEN IT PUMPS, which is the realistic shape and not decoration.
    # menu_win_set only MARKS the bar (menu_relayout sets menu_bdirty); the
    # redraw is menu_draw_bar's, and that is driven by WINDOW EVENTS in
    # wm.inc, not by a timer. A program that installs a bar and exits
    # leaves it stale with nothing owed to anyone - which is exactly what
    # this part did at first, and the bar still read `BASIC File Run` with
    # a set that probed as File/Run/Plot/Zap. A GUI program loops on
    # ON MENU by construction (150.36), so the wakes are what carry the
    # redraw, and asserting the bar without them tests a state no real
    # program sits in.
    ("i = 0",                            None),
    ("DO",                               None),
    ("  i = i + 1",                      None),
    ("  ON MENU",                        None),
    ("LOOP UNTIL i >= 3",                None),
    ("PRINT 7",                          "7"),
    ("#bar Plot",                        None),
    ("#bar Zap",                         None),
]

# --- ON MENU GOSUB and MENU(0): WAVE 4'S EXIT (SPEC.md 150.38) ----------
# A GUI PROGRAM WITH A MENU BAR THAT RESPONDS TO CLICKS, which is the wave's
# stated exit criterion, in one part: the program builds a bar, registers a
# handler, and loops on ON MENU; the ROW picks `Plot`'s first item off the
# glass; the handler stores MENU(0) and the loop ends on it.
#
# `1` IS THE WHOLE ASSERTION and it is not an arbitrary number: m$(1) is
# " Draw ", the first entry of the first menu, and node [300] numbers
# MENU(0) by the ARRAY index - titles, accessory slots and "" included. So
# 1 says the pick arrived, the frame carried the handler, OP_RET came back
# to the ON MENU, and the index was the array's and not the item's.
PART48 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("DIM m$(6)",                        None),
    ('m$(0) = "Plot"',                   None),
    ('m$(1) = " Draw "',                 None),
    ('m$(2) = ""',                       None),
    ('m$(3) = "Zap"',                    None),
    ('m$(4) = " Kill "',                 None),
    ('m$(5) = ""',                       None),
    ("MENU m$()",                        None),
    ("ON MENU GOSUB hit",                None),
    ("k = 0",                            None),
    ("DO",                               None),
    ("  ON MENU",                        None),
    ("LOOP UNTIL k > 0",                 None),
    ("PRINT k",                          "1"),
    ("END",                              None),
    ("PROCEDURE hit",                    None),
    ("  k = MENU(0)",                    None),
    ("RETURN",                           None),
    ("#pick Plot",                       None),
]

PART49 = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("PRINT MENU(1)",
     "Error at line 3: MENU() takes 0 here - the rest is the AES message "
     "buffer"),
]

PART46 = [
    ("CLS",                              None),
    ("n = 1",                            None),
    ("MENU n()",
     "Error at line 3: MENU wants a DIMmed string array, as MENU m$()"),
]

# FOUR PROGRAM MENUS, where the bar has room for three beside File and Run.
# Refused BY NAME at the fourth rather than dropped: MENU_APPMAX's own
# overflow is SILENT in the kernel, and a bar quietly missing its last menu
# is the wrong answer 150.7 exists to stop.
PART47 = [
    ("CLS",                              None),
    ("DIM m$(11)",                       None),
    ('m$(0) = "A"',                      None),
    ('m$(1) = " a "',                    None),
    ('m$(2) = ""',                       None),
    ('m$(3) = "B"',                      None),
    ('m$(4) = " b "',                    None),
    ('m$(5) = ""',                       None),
    ('m$(6) = "C"',                      None),
    ('m$(7) = " c "',                    None),
    ('m$(8) = ""',                       None),
    ('m$(9) = "D"',                      None),
    ('m$(10) = " d "',                   None),
    ('m$(11) = ""',                      None),
    ("MENU m$()",
     "Error at line 15: MENU fits three menus beside File and Run"),
]

# --- ALERT (SPEC.md 150.37) ---------------------------------------------
# THE FIRST STATEMENT THAT CARRIES A VALUE BACK, and the seam's data path is
# the whole subject. `b` is 7 before the ALERT and 0 after it, so printing 0
# says the resume WROTE the variable rather than leaving it - and 0 is the
# DISMISSED answer, which no button maps to.
#
# ESCAPE RATHER THAN A CLICK, which keeps this row keyboard-only like the F5
# that runs it: os88ui_ask reports its close box, its minimize box and Esc
# alike as OS88UI_ACANCEL, so Esc exercises the completion, the wake and the
# store without a drag whose offsets drift across adapters.
PART41 = [
    ("CLS",                              None),
    ("PRINT 31415",                      "31415"),
    ("b = 7",                            None),
    ('ALERT 1, "Press Escape", 1, "OK", b', None),
    ("PRINT b",                          "0"),
    ("#after esc",                       None),
]

PART42 = [
    ("CLS",                              None),
    ("b = 0",                            None),
    ('ALERT 1, "x", 1, "Left|Right", b',
     "Error at line 3: those ALERT buttons are not one of the six sets"),
]

PART43 = [
    ("CLS",                              None),
    ("b = 0",                            None),
    ('ALERT 1, "a|b", 1, "OK", b',
     "Error at line 3: an ALERT message is ONE line here - no | in it"),
]

PART44 = [
    ("CLS",                              None),
    ('s$ = "x"',                         None),
    ('ALERT 1, "x", 1, "OK", s$',
     "Error at line 3: ALERT wants a number variable for the choice"),
]

# THE TWO REFUSALS, one part each. `ON MENU GOSUB` is refused until MENU
# exists to fire from, and any other ON is refused by name rather than read
# as a variable called ON.
# ON MENU GOSUB NAMES A PROCEDURE, and a missing one is caught by the
# ORDINARY forward-reference check - bas_calfix resolves it exactly as it
# resolves a call's, which is what lets a handler be written BELOW the loop
# that registers it. This part used to assert the statement was refused
# outright ("handlers come with MENU"); MENU exists now, so the honest
# assertion is the one that survives: the handler has to be real.
PART39 = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("ON MENU GOSUB handler",
     "Error at line 3: that names a procedure the program does not have"),
]

# ...and ON MENU still takes GOSUB or nothing: `ON MENU 5` is neither.
PART39B = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("ON MENU 5",
     "Error at line 3: ON MENU takes nothing yet - handlers come with MENU"),
]

PART40 = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("ON ERROR GOSUB oops",
     "Error at line 3: ON MENU is the only ON this wave knows"),
]

# --- SPEC.md 150.40: DIM of an EXPRESSION ---------------------------------
# The arena is handed out at RUN time now, so these are the parts that prove
# a size the compiler could not know. Each has its own CLS and sentinel, and
# ONE VALUE PER `PRINT` - no part in this file asserts a comma-separated line,
# so the separator is not something these rows should be the first to assume.
PART50 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    # --- the headline: a bound that is a variable ------------------------
    ("n = 4",                            None),       # 3
    ("DIM score(n)",                     None),       # 4
    ("score(0) = 7",                     None),       # 5
    ("score(4) = 9",                     None),       # 6  n is the TOP index
    ("PRINT score(0) + score(4)",        "16"),       # 7
    ("PRINT LBOUND(score)",              "0"),        # 8
    ("PRINT UBOUND(score)",              "4"),        # 9
    # --- an arithmetic bound, and `lo TO hi` with expressions both ends --
    ("m = 2",                            None),       # 10
    ("DIM b(m * 3)",                     None),       # 11
    ("b(6) = 11",                        None),       # 12
    ("PRINT b(6)",                       "11"),       # 13
    ("DIM c(m TO m + 2)",                None),       # 14
    ("c(2) = 1",                         None),       # 15
    ("c(4) = 2",                         None),       # 16
    ("PRINT c(2) + c(4)",                "3"),        # 17
    ("PRINT LBOUND(c)",                  "2"),        # 18
    ("PRINT UBOUND(c)",                  "4"),        # 19
]

# TWO DIMENSIONS, one bound plain and one `TO` - the mixed case, which is
# where the form bits earn their keep: the compiler emits ONE expression for
# `2` and TWO for `1 TO k`, and OP_DIM has to pop them in that shape. Get the
# bits backwards and this part reads a bound off the wrong dimension.
PART51 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("k = 3",                            None),       # 3
    ("DIM g(2, 1 TO k)",                 None),       # 4
    ("g(0, 1) = 5",                      None),       # 5
    ("g(2, 3) = 6",                      None),       # 6
    ("PRINT g(0, 1) + g(2, 3)",          "11"),       # 7
    ("PRINT LBOUND(g)",                  "0"),        # 8
    ("PRINT UBOUND(g)",                  "2"),        # 9
    # ...and the bound check still knows the computed second extent
    ("PRINT g(2, 4)",                                 # 10
     "Error at line 10: that subscript is outside the array"),
]

# AN ELEMENT TOUCHED BEFORE ITS DIM HAS RUN. This is the refusal 150.40 gets
# for free: N0 is 0 until OP_DIM writes it, and every element reference
# already compares against N0 with `jae`. The DIM sits inside an IF that does
# not fire, so the array is known to the COMPILER and unallocated at run.
PART52 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("z = 0",                            None),       # 3
    ("IF z > 0 THEN",                    None),       # 4
    ("DIM late(3)",                      None),       # 5
    ("ENDIF",                            None),       # 6
    ("PRINT late(0)",                                 # 7
     "Error at line 7: that subscript is outside the array"),
]

# ...and LBOUND/UBOUND on that same array refuse BY A DIFFERENT NAME, because
# they read N0 as an answer rather than as a bound (150.40). Without their
# own check they would report UBOUND as LBOUND-1 - a wrong answer, which is
# the one thing this chapter refuses to let an array do.
PART53 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("z = 0",                            None),       # 3
    ("IF z > 0 THEN",                    None),       # 4
    ("DIM late2(3)",                     None),       # 5
    ("ENDIF",                            None),       # 6
    ("PRINT UBOUND(late2)",                           # 7
     "Error at line 7: that array has not been DIMmed yet on this run"),
]

# A DIM THAT EXECUTES TWICE: it succeeds on the first pass of the loop and is
# refused on the second. The compile-time rule cannot see this - there is one
# DIM in the text - and it is the state ERASE will clear (150.40).
PART54 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("FOR i = 1 TO 2",                   None),       # 3
    ("DIM twice(3)",                                  # 4
     "Error at line 4: that array is already DIMmed"),
    ("NEXT",                             None),       # 5
]

# HIGH TO LOW, and the arena full - the two refusals that MOVED from compile
# time to run time, each still by name. The arena is 512 elements, so 400 and
# 400 cannot both fit.
PART55 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("hi = 1",                           None),       # 3
    ("DIM bad(5 TO hi)",                              # 4
     "Error at line 4: a size runs low TO high"),
]

PART56 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("big = 400",                        None),       # 3
    ("DIM p(big)",                       None),       # 4
    ("DIM q(big)",                                    # 5
     "Error at line 5: out of room for arrays - this wave holds 512 elements"),
]

# THE ARENA IS RESET PER RUN, and THIS PART IS WHY PART56 COMES FIRST. 56
# allocated 400 elements and then failed; 57 is a separate program through
# File > New, so if `bas_exec` did not zero the arena top this DIM would be
# refused for room that the previous part's run is still holding. The order
# is the assertion - neither part proves it alone.
PART57 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("big = 400",                        None),       # 3
    ("DIM r(big)",                       None),       # 4
    ("r(400) = 3",                       None),       # 5
    ("PRINT r(400)",                     "3"),        # 6
]

# --- TWO CELLS THAT SHARE A ROW -----------------------------------------
# THE PART WAVE 2's GRID TEST COULD NOT BE. That part stores grid(2,2),
# grid(1,3) and grid(3,1) and reads all three back, which passes whatever the
# second subscript does: no two of those cells share a FIRST subscript, so
# they land at different indices even if `j` is dropped entirely - and a
# store and a load that share one wrong index agree with each other.
#
# These three cells differ ONLY in j. If the row-major arithmetic loses the
# second subscript they are one cell, the last store wins, and all three
# reads answer 33.
PART65 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM h(1 TO 2, 1 TO 3)",            None),       # 3
    ("h(1, 1) = 11",                     None),       # 4
    ("h(1, 2) = 22",                     None),       # 5
    ("h(1, 3) = 33",                     None),       # 6
    ("PRINT h(1, 1)",                    "11"),       # 7
    ("PRINT h(1, 2)",                    "22"),       # 8
    ("PRINT h(1, 3)",                    "33"),       # 9
    # ...and the other row is untouched by any of it
    ("PRINT h(2, 1)",                    "0"),        # 10
]

# --- A THIRD DIMENSION (SPEC.md 150.42, node [71]) ----------------------
# EACH COORDINATE IS VARIED ON ITS OWN, which is the lesson PART65 cost: a
# set of cells that all differ in more than one subscript cannot say which
# subscript matters, and a store and a load sharing one wrong index agree
# with each other. So three of these cells differ from the origin in exactly
# one coordinate, one differs in all three, and one nothing wrote is checked
# for 0.
PART66 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM c(1, 2, 3)",                   None),       # 3  2 x 3 x 4 = 24
    ("c(0, 0, 0) = 1",                   None),       # 4
    ("c(0, 0, 1) = 2",                   None),       # 5  k alone
    ("c(0, 1, 0) = 3",                   None),       # 6  j alone
    ("c(1, 0, 0) = 4",                   None),       # 7  i alone
    ("c(1, 2, 3) = 9",                   None),       # 8  the far corner
    ("PRINT c(0, 0, 0)",                 "1"),        # 9
    ("PRINT c(0, 0, 1)",                 "2"),        # 10
    ("PRINT c(0, 1, 0)",                 "3"),        # 11
    ("PRINT c(1, 0, 0)",                 "4"),        # 12
    ("PRINT c(1, 2, 3)",                 "9"),        # 13
    ("PRINT c(0, 2, 1)",                 "0"),        # 14 nothing wrote it
]

# THE ELEMENT COUNT TRAVELS, which is what the four private counts becoming
# bas_arrcount was for: ARRAYFILL walks the whole array, so if the count
# missed the third dimension it would fill a PREFIX and the last element
# would still be 0. `lo TO hi` on the third dimension too, and an
# expression for its bound.
PART67 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("n = 1",                            None),       # 3
    ("DIM f(1, 1, n)",                   None),       # 4  2 x 2 x 2 = 8
    ("ARRAYFILL f(), 7",                 None),       # 5
    ("PRINT f(0, 0, 0)",                 "7"),        # 6  the first...
    ("PRINT f(1, 1, 1)",                 "7"),        # 7  ...and the LAST
    ("DIM g(1 TO 2, 1 TO 2, 1 TO 2)",    None),       # 8
    ("g(2, 2, 2) = 5",                   None),       # 9
    ("PRINT g(2, 2, 2)",                 "5"),        # 10
    ("PRINT LBOUND(g)",                  "1"),        # 11
]

# THE THIRD DIMENSION IS BOUND-CHECKED LIKE THE OTHERS, and a subscript
# count that does not match the DIM is refused - both run-time, both by name.
PART68 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM p(1, 1, 1)",                   None),       # 3
    ("PRINT p(0, 0, 2)",                              # 4  k is out of range
     "Error at line 4: that subscript is outside the array"),
]

# FOUR SIZES IS REFUSED AT COMPILE TIME - node [71] allows seven and this
# record holds three, so the message says what it holds.
PART69 = [
    ("CLS",                              None),       # 1
    ("DIM q(1, 1, 1, 1)",                             # 2
     "Error at line 2: DIM takes one, two or three sizes here"),
]

# ...and so is the wrong NUMBER of subscripts, which is the same message a
# two-dimensional array gives for one subscript.
PART70 = [
    ("CLS",                              None),       # 1
    ("DIM r(1, 1, 1)",                   None),       # 2
    ("PRINT r(0, 0)",                                 # 3
     "Error at line 3: that array was DIMmed with a different number "
     "of sizes"),
]

# SWAP CARRIES THE WHOLE SHAPE, which the record widening could have broken
# quietly: its loop runs from the bounds to the record's END, so the third
# dimension's bound and count travel with the rest. a() is 2x2x2 and b() is
# 3x3x3, so after the swap b() has a()'s elements AND a()'s extents - and
# ARRAYFILL on b() proves the COUNT came too.
PART71 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM a(1, 1, 1)",                   None),       # 3  8 elements
    ("DIM b(2, 2, 2)",                   None),       # 4  27 elements
    ("a(1, 1, 1) = 5",                   None),       # 5
    ("SWAP a(), b()",                    None),       # 6
    ("PRINT b(1, 1, 1)",                 "5"),        # 7  b sees a's cells
    ("PRINT UBOUND(b)",                  "1"),        # 8  ...and a's bounds
    ("PRINT UBOUND(a)",                  "2"),        # 9  ...both ways
    ("ARRAYFILL b(), 6",                 None),       # 10
    ("PRINT b(1, 1, 1)",                 "6"),        # 11 its LAST element
    ("PRINT b(0, 0, 0)",                 "6"),        # 12 ...and its first
]

# --- DIM?() (SPEC.md 150.43, node [71]) ---------------------------------
# EVERY NUMBER HERE IS THE MANUAL'S OWN. Node [71]'s worked example prints
# 11 for `DIM x(10)` and 12 for `DIM y%(2,3)`, and its memo gives the base
# interaction outright: base 0 -> 3*4 = 12, base 1 -> 2*3 = 6. The 6 is the
# one that matters - a reader who sees no OPTION BASE term in the arithmetic
# and adds one gets 12 there.
PART72 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("DIM x(10)",                        None),        # 3
    ("PRINT DIM?(x())",                  "11"),       # 4  node [71]'s own
    ("DIM y(2, 3)",                      None),       # 5
    ("PRINT DIM?(y())",                  "12"),       # 6  ...and its other
    ("DIM z(1, 1, 1)",                   None),       # 7
    ("PRINT DIM?(z())",                  "8"),        # 8  three dimensions
    # ...and it is an expression, not a statement
    ("t = DIM?(x()) * 2",                None),       # 9
    ("PRINT t",                          "22"),       # 10
]

# THE BASE-1 CASE, WHICH IS THE MANUAL'S MEMO VERBATIM: the same DIM y(2,3)
# that answers 12 at base 0 answers SIX at base 1, because a count is the
# inclusive extent its bound produced and the base never enters.
PART73 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("OPTION BASE 1",                    None),       # 3
    ("DIM y(2, 3)",                      None),       # 4
    ("PRINT DIM?(y())",                  "6"),        # 5
]

# ...and on an array whose DIM has not run it refuses by the same name
# LBOUND and UBOUND give (150.40), rather than answering 0.
PART74 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("z = 0",                            None),       # 3
    ("IF z > 0 THEN",                    None),       # 4
    ("DIM q(3)",                         None),       # 5
    ("ENDIF",                            None),       # 6
    ("PRINT DIM?(q())",                               # 7
     "Error at line 7: that array has not been DIMmed yet on this run"),
]

# THE UNNESTED PART, AND IT STAYS BECAUSE IT IS WHAT SPLIT THE CASE. FRAC
# first answered a residue instead of -0.4, and reading the library said
# nothing: fp_trunc, fp_a_to_b, fp_swap_ab and fp_sub are each right on their
# own and TRUNC through the same op path was right. Line 4 is FRAC and line 5
# is the same arithmetic by hand through the ordinary operators - they AGREED,
# which cleared the wrapper and left only the one difference between this part
# and the ones below: these calls are not NESTED. The outer function of
# `ROUND(FRAC(...))` was running as a second FRAC, the index having been kept
# in a word of bss that the inner compile overwrote.
#
# So it is kept as the cheap half of the pair: if the functions ever go wrong
# again, this part says whether it is the arithmetic or the nesting before
# anything is read.
PART74B = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT TRUNC(-1.4)",                "-1"),       # 3  known good
    ("PRINT FRAC(-1.4) * 10",            "-4"),       # 4  the wrapper
    ("PRINT (-1.4 - TRUNC(-1.4)) * 10",  "-4"),       # 5  ...by hand
    ("PRINT FRAC(1.4) * 10",             "4"),        # 6  and positive
    ("PRINT TRUNC(-4.4)",                "-4"),       # 7
    ("PRINT FRAC(-4.4) * 10",            "-4"),       # 8
]

# --- wave 5 slice 1: the numeric functions (SPEC.md 150.44) --------------
# NODE [133]'S OWN EXAMPLE IS THE ORACLE for the four rounding names. It
# prints `TRUNC(1.3), INT(x), FIX(3*x), FRAC(x-3)` for x = -1.4 and says the
# answers are 1, -2, -4 and -0.4.
#
# THE FIRST THREE ARE ASSERTED AS THE MANUAL PRINTS THEM; the fourth is
# asserted SCALED, as ROUND(FRAC(...) * 10) = -4. That is the same number -
# the manual's -0.4 - without resting on how many digits the formatter
# chooses for a value binary cannot hold exactly, which is a property of
# PRINT and not of FRAC.
PART75 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("x = -1.4",                         None),       # 3
    ("PRINT TRUNC(1.3)",                 "1"),        # 4  node [133]
    ("PRINT INT(x)",                     "-2"),       # 5  ...its own four
    ("PRINT FIX(3 * x)",                 "-4"),       # 6
    ("PRINT ROUND(FRAC(x - 3) * 10)",    "-4"),       # 7  its -0.4, scaled
    # TRUNC and FIX are ONE routine because node [133] says they are
    # "identical" - so they must agree on the case that separates them
    # from INT, which is a negative non-integer.
    ("PRINT TRUNC(x)",                   "-1"),       # 8
    ("PRINT FIX(x)",                     "-1"),       # 9
    ("PRINT INT(x)",                     "-2"),       # 10 ...and INT differs
]

# NODE [133]'S IDENTITY, BOTH HALVES - which is how it defines FRAC rather
# than by a procedure: "It is always true that x=TRUNC(x)+FRAC(x), but
# INT(x)+FRAC(x) is not equal to x for negative values."
#
# THE SECOND HALF IS THE TEST THAT MATTERS. A FRAC built on fp_floor instead
# of fp_trunc satisfies the first sentence and fails the second, so asserting
# only the identity would pass a wrong FRAC.
PART76 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("x = -1.4",                         None),       # 3
    ("PRINT ROUND((TRUNC(x) + FRAC(x)) * 10)", "-14"),  # 4  ...IS x
    ("PRINT ROUND((INT(x) + FRAC(x)) * 10)",   "-24"),  # 5  ...is NOT x
    # ...and for a positive x the manual says there is no difference
    ("y = 1.4",                          None),       # 6
    ("PRINT ROUND((TRUNC(y) + FRAC(y)) * 10)", "14"),   # 7
    ("PRINT ROUND((INT(y) + FRAC(y)) * 10)",   "14"),   # 8
]

# ABS and SGN, whose answers are exact at every point - including SGN of
# zero, which is the case a sign-byte test gets wrong if it reads the byte
# without asking whether the number is zero at all.
PART77 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT ABS(-5)",                    "5"),        # 3
    ("PRINT ABS(5)",                     "5"),        # 4
    ("PRINT ABS(0)",                     "0"),        # 5
    ("PRINT SGN(-3)",                    "-1"),       # 6
    ("PRINT SGN(7)",                     "1"),        # 7
    ("PRINT SGN(0)",                     "0"),        # 8  ...the sign byte
    ("PRINT SGN(-0.5)",                  "-1"),       # 9  of a fraction
    ("PRINT ROUND(ABS(-1.4) * 10)",      "14"),       # 10
]

# THE TRANSCENDENTALS, at points where the answer is exact, and then through
# IDENTITIES at points where it is not - which is how to assert a series
# approximation without writing its error bound into the row.
PART78 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT SIN(0)",                     "0"),        # 3
    ("PRINT COS(0)",                     "1"),        # 4
    ("PRINT TAN(0)",                     "0"),        # 5
    ("PRINT EXP(0)",                     "1"),        # 6
    ("PRINT LOG(1)",                     "0"),        # 7
    ("PRINT SQR(16)",                    "4"),        # 8  a perfect square
    ("PRINT SQR(0)",                     "0"),        # 9
    # ...and the inexact ones, scaled or inverted
    ("PRINT INT(SQR(2) * 1000)",         "1414"),     # 10
    ("PRINT ROUND(ATN(1) * 400000)",     "314159"),   # 11 pi, four ways out
    ("PRINT ROUND(LOG(EXP(1)))",         "1"),        # 12 ln and exp invert
    ("PRINT ROUND(EXP(LOG(5)))",         "5"),        # 13 ...both ways round
    ("PRINT ROUND(SIN(ATN(1) * 2))",     "1"),        # 14 sin(pi/2)
    ("PRINT ROUND(COS(ATN(1) * 4))",     "-1"),       # 15 cos(pi)
    ("PRINT ROUND(TAN(ATN(1)) * 1000)",  "1000"),     # 16 tan(pi/4)
]

# ROUND IS NODE [134]'S, and its two worked numbers are a rule rather than
# two cases: "half away from zero", so -1.2 goes to -1 and 1.7 to 2.
PART79 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT ROUND(-1.2)",                "-1"),       # 3  node [134]
    ("PRINT ROUND(1.7)",                 "2"),        # 4  ...its own two
    ("PRINT ROUND(0.5)",                 "1"),        # 5  away from zero...
    ("PRINT ROUND(-0.5)",                "-1"),       # 6  ...in both
    ("PRINT ROUND(2.5)",                 "3"),        # 7  NOT ties-to-even,
    ("PRINT ROUND(-2.5)",                "-3"),       # 8  which would give 2
]

# A DOMAIN ERROR IS REFUSED BY NAME, from the routine's own CF - one part
# each, a refusal ending the program.
PART80 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT SQR(-1)",                                 # 3
     "Error at line 3: that number is outside what the function accepts"),
]

PART81 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT LOG(0)",                                  # 3
     "Error at line 3: that number is outside what the function accepts"),
]

# --- `^` (SPEC.md 150.45, node [128]) -----------------------------------
# NODE [128]'S OWN EXAMPLE opens it: `PRINT 3*2^2` displays 12, which is the
# manual's check that `^` is above `* /`. The rest of this part is the
# hierarchy's OTHER consequence, which is the one that matters.
PART82 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT 3 * 2 ^ 2",                  "12"),       # 3  node [128]
    ("PRINT 2 ^ 2 * 3",                  "12"),       # 4  ...either side
    ("PRINT 2 ^ 3",                      "8"),        # 5
    ("PRINT 10 ^ 2",                     "100"),      # 6  EXACTLY 100: whole
    ("PRINT 10 ^ 4",                     "10000"),    # 7  exponents square
    ("PRINT 2 ^ 0",                      "1"),        # 8
    # `.125` AND NOT `0.125`: this formatter omits a leading zero below 1,
    # which is every BASIC of this line's habit - and worth a note, because
    # node [133]'s own example prints FRAC(-4.4) as `-0.4` WITH one. That is
    # a question about PRINT's number format (and SPEC.md 150's, not this
    # section's); `^` is doing arithmetic here, and PART75 asserts FRAC
    # SCALED for exactly this reason.
    ("PRINT 2 ^ -3",                     ".125"),     # 9  no brackets needed
    ("PRINT (-2) ^ 3",                   "-8"),       # 10 a NEGATIVE base is
    ("PRINT (-2) ^ 2",                   "4"),        # 11 ordinary here
]

# THE DIVERGENCE, ON ITS OWN, because it is the first place following the
# Compendium over basicnw produces a different NUMBER. Node [128] puts
# SIGNING above exponentiation, so the base is already negated when `^` sees
# it: `-2^2` is (-2)^2 = 4. basicnw's parser says the opposite in as many
# words - "`^` binds tighter than unary minus" - and answers -4. A
# differential run against the oracle is EXPECTED to disagree here.
PART83 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT -2 ^ 2",                     "4"),        # 3  NOT -4
    ("PRINT -3 ^ 2",                     "9"),        # 4  NOT -9
    ("PRINT -2 ^ 3",                     "-8"),       # 5  (-2)^3, either way
    # ...and the brackets that force the other reading, so the row shows both
    ("PRINT -(2 ^ 2)",                   "-4"),       # 6  basicnw's answer
    ("x = 2",                            None),       # 7
    ("PRINT -x ^ 2",                     "4"),        # 8  a variable too
]

# RIGHT-ASSOCIATIVE, which node [128] does NOT state - it is basicnw's answer
# taken where the Compendium is silent. 2^3^2 is 2^(3^2) = 512, where
# left-associativity would give (2^3)^2 = 64, so the two readings are 448
# apart and this row cannot be satisfied by both.
PART84 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT 2 ^ 3 ^ 2",                  "512"),      # 3  NOT 64
    ("PRINT (2 ^ 3) ^ 2",                "64"),       # 4  ...the other way
    ("PRINT 2 ^ (3 ^ 2)",                "512"),      # 5  ...and this one
]

# THE TWO PAIRS WITH NO REAL ANSWER, one part each, from fp_pow's own CF.
PART85 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT (-8) ^ 0.5",                              # 3  a negative base to
     "Error at line 3: that number is outside what the function accepts"),
]

PART86 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT 0 ^ 0",                                   # 3
     "Error at line 3: that number is outside what the function accepts"),
]

# --- wave 5 slice 2: the string chapter's four (SPEC.md 150.46) ---------
# NODE [159]'S OWN EXAMPLE for TRIM$: b$ = "   test  " displays 9, then the
# word without spaces, then 4. Asserted BRACKETED, because a console line
# comes out of a space-padded cell buffer where "test" and "test   " read
# alike - and spaces are the whole subject here, which is PART29's rule for
# LSET/RSET applied where it matters even more.
PART87 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ('b$ = "   test  "',                 None),       # 3
    ("PRINT LEN(b$)",                    "9"),        # 4  node [159]
    ('PRINT "<" + TRIM$(b$) + ">"',      "<test>"),   # 5  ...its middle
    ("PRINT LEN(TRIM$(b$))",             "4"),        # 6  ...and its last
    # ...both ends in ONE call, which is why GFA has no LTRIM$/RTRIM$ pair
    ('PRINT "<" + TRIM$("  a") + ">"',   "<a>"),      # 7
    ('PRINT "<" + TRIM$("a  ") + ">"',   "<a>"),      # 8
    ('PRINT "<" + TRIM$("   ") + ">"',   "<>"),       # 9  all spaces
    ('PRINT "<" + TRIM$("") + ">"',      "<>"),       # 10 and empty
    ('PRINT "<" + TRIM$("a b") + ">"',   "<a b>"),    # 11 the MIDDLE stays
]

# NODE [163]'S OWN EXAMPLE for UPPER$, verbatim: a$ = " test",
# b$ = UPPER$(a$) + UPPER$("ware"), PRINT UPPER$("Gfa basic 3"); b$ puts
# 'GFA BASIC 3 TESTWARE' on the screen - the leading space of " TEST" being
# what separates the two halves.
PART88 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ('a$ = " test"',                     None),       # 3
    ('b$ = UPPER$(a$) + UPPER$("ware")', None),       # 4
    ('PRINT UPPER$("Gfa basic 3") + b$', "GFA BASIC 3 TESTWARE"),   # 5
    # ...and what it must NOT touch: digits, punctuation, and capitals
    ('PRINT UPPER$("a1-B!z")',           "A1-B!Z"),   # 6
    ('PRINT LEN(UPPER$("abc"))',         "3"),        # 7  length unchanged
]

# NODE [162]'S OWN EXAMPLE for the repeaters, in pieces: it prints
# SPACE$(5); STRING$(3,a$); SPC(4); STRING$(5,65) for a$ = "GFA " and gets
# '     GFA GFA GFA     AAAAA'. SPC() is a PRINT item rather than a function
# and is not in this slice, so the row asserts the other three and the
# spaces are BRACKETED.
PART89 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ('a$ = "GFA "',                      None),       # 3
    ('PRINT "<" + SPACE$(5) + ">"',      "<     >"),  # 4  five
    ("PRINT LEN(SPACE$(5))",             "5"),        # 5
    ('PRINT "<" + STRING$(3, a$) + ">"', "<GFA GFA GFA >"),  # 6  node [162]
    ('PRINT STRING$(5, 65)',             "AAAAA"),    # 7  ...its code form
    ("PRINT LEN(STRING$(5, 65))",        "5"),        # 8
    # ...the two forms are one op, so they must agree where they overlap
    ('PRINT STRING$(3, "x")',            "xxx"),      # 9
    ('PRINT STRING$(3, 120)',            "xxx"),      # 10 120 is 'x'
    # ...and the degenerate counts
    ('PRINT "<" + STRING$(0, "x") + ">"', "<>"),      # 11 none at all
    ('PRINT "<" + SPACE$(0) + ">"',      "<>"),       # 12
    ('PRINT "<" + STRING$(4, "") + ">"', "<>"),       # 13 empty, repeated
]

# A COUNT THE ARENA CANNOT HOLD is refused by name, which is the answer to
# node [162]'s own memo - "SPACE$() and STRING$(count,code) do weird things
# without of range string sizes in compiled applications. No error is
# generated and the string LEN() ends up -negative." 150.28's whole arena is
# 4,096 bytes, so 5000 cannot be had.
PART90 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    # bas_stmpalloc has TWO refusals and this is the specific one: 5000 in
    # ONE piece is more than the arena could ever hold, which it says before
    # it even looks at what is free. The op adds no message of its own -
    # doing so put two lines on the console and shifted every answer after
    # them, which is how this expectation was wrong twice over.
    ("PRINT LEN(SPACE$(5000))",                       # 3
     "Error at line 3: one piece of text is longer than the arena"),
]

# ...and a NEGATIVE count is refused as a count, which bas_sarg1 already
# does for every count in the language (SPEC.md 150.29).
PART91 = [
    ("CLS",                              None),       # 1
    ("PRINT 31415",                      "31415"),    # 2
    ("PRINT LEN(SPACE$(-1))",                         # 3
     "Error at line 3: that many characters is a negative number"),
]

# FIVE ROWS, ONE FILE. The whole set is past half an hour of typing, which is
# too slow to iterate against and too slow to sit in one soak slot while
# docs/plans/SOAK-PARALLEL.md has others idle. `--early` is the language
# through SELECT, `--late` is GOTO, labels and procedures, `--w3tail` is
# wave 3's tail (150.33 to 150.35), `--wave4` is the event loop (150.36) and
# `--arrays` is the run-time arena, ERASE, re-DIM and the third dimension
# (150.40 to 150.42); no flag runs the lot, which is what a developer typing
# the file's name means.
#
# `--arrays` IS A SPLIT OF `--w3tail` AND NOT A NEW IDEA: that group went from
# 9 parts to 30 while 150.40 to 150.42 were built, 236 seconds to 744, which
# is the same reasoning that made these groups in the first place.
EARLY = (PART1, PART2, PART3, PART4, PART5)
LATE = (PART6, PART7, PART8, PART9, PART10, PART11, PART12, PART13,
        PART14, PART15, PART16, PART17, PART18, PART19, PART20, PART21,
        PART22, PART23, PART24, PART25, PART26, PART27, PART28)
W3TAIL = (PART29, PART30, PART31, PART32, PART33, PART34, PART35,
          PART36, PART37)
ARRAYS = (PART50, PART51, PART52, PART53, PART54, PART55, PART56, PART57,
          PART58, PART59, PART60, PART61, PART62, PART63, PART64,
          PART65, PART66, PART67, PART68, PART69, PART70, PART71,
          PART72, PART73, PART74)
WAVE4 = (PART38, PART39, PART39B, PART40, PART41, PART42, PART43, PART44,
         PART45, PART46, PART47, PART48, PART49)
MATH = (PART74B, PART75, PART76, PART77, PART78, PART79, PART80, PART81,
        PART82, PART83, PART84, PART85, PART86,
        PART87, PART88, PART89, PART90, PART91)
PARTS = EARLY + LATE + W3TAIL + WAVE4 + ARRAYS + MATH

if "--early" in sys.argv:
    PARTS = EARLY
elif "--late" in sys.argv:
    PARTS = LATE
elif "--w3tail" in sys.argv:
    PARTS = W3TAIL
elif "--wave4" in sys.argv:
    PARTS = WAVE4
elif "--arrays" in sys.argv:
    PARTS = ARRAYS
elif "--math" in sys.argv:
    PARTS = MATH

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

    # NO `sym` METHOD, DELIBERATELY, and it must stay that way. `m.sym` is
    # a CAPABILITY PROBE, not a getter: tests/dispcp.py says so in its own
    # words - os88ui reads guest state through `m.sym`, `m.readseg` and
    # `m.status`, "a MartyPC debug-server surface that a QEMU `Qemu` object
    # does not have and cannot grow" - and it branches on
    # `hasattr(m, "sym")`. Adding one for glass.glyphs() made dispcp
    # delegate this row to os88ui, which then died on `m.status` four
    # frames from the cause. dispcp records the mirror of that from
    # `minesrc`. The glyph table is read locally below instead.
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


MBAR_H = 20             # kernel.asm's: the white field is rows 0..18


def bar_scan(m, tmp):
    """(cells, xs) for the MENU BAR, read off the GLASS through the kernel's
    glyphs - or None if nothing in the strip reads as a run of them.

    **THIS ROW HAD NO WAY TO SEE THE BAR AND IT COST A DEFECT.** Everything
    else here reads the console BUFFER out of memory, which is the right
    instrument for an answer a program printed and the wrong one for
    CHROME. MENU m$()'s first version installed a set whose AM_NAME,
    AM_ONCMD and File/Run entries were still zeroed bss - a bar with a NULL
    command handler - and the positive part PASSED, because the interpreter
    was fine and only the bar was rubble. It surfaced one part later, when
    File > New had no handler to reach. A values-only gate is blind to the
    chrome, which this repository already knew (sheetmmenu once passed 8 of
    8 with the bar in pieces); this is the row learning it.

    THE INK IS DARK HERE, which is the one thing to get right: the bar is a
    WHITE field with BLACK text, so a glyph's set bits are the DARK pixels
    and the threshold is inverted against the usual chrome read.
    """
    table = {}
    seg = int.from_bytes(m.read(S("font_seg"), 2), "little")
    base = int.from_bytes(m.read(S("font_base"), 2), "little")
    raw = m.readseg(seg, base, glass.FONT_N * 8)
    for i in range(glass.FONT_N):
        table.setdefault(bytes(raw[i * 8:i * 8 + 8]),
                         chr(glass.FONT_FIRST + i))
    png = os.path.join(tmp, "bar.png")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, png], capture_output=True, cwd=ROOT)
    try:
        from PIL import Image
        im = Image.open(png).convert("L")
    except Exception:
        return None
    w, h = im.size
    px = im.load()
    # ...and MBAR_H + 8 rows, not MBAR_H: cell_text reaches y+7 for a
    # glyph's eight, so a box ending at row 18 still reads past row 19
    rows = [[1 if px[x, y] < 128 else 0 for x in range(w)]
            for y in range(min(h, MBAR_H + 8))]
    # PER CELL, NOT glass.cell_text, which wants EVERY slot in its box to
    # match a glyph and so rejects this strip whole: the bar carries an
    # 11-pixel logo at x=10..20 that is no glyph at all, and cell_text
    # answered None for a bar that plainly said `BASIC File Run`. The text
    # IS 8-pixel aligned here (measured: every ink run starts at 40, 104,
    # 152, 488, 520, 544, 592 - all multiples of 8), so each cell can be
    # matched on its own and anything unrecognised becomes a space.
    # THE ROW IS DERIVED, NOT SEARCHED FOR. Scoring candidate rows by "most
    # cells that matched a glyph" picks a DEGENERATE one: row 19 is the
    # bar's rule, a solid dark line across the screen, so the window
    # starting at row 12 makes every cell an UNDERSCORE and scores higher
    # than the right row ever can. It answered
    # `_ __ ___ __ ____...` for a bar reading `BASIC File Run Plot Zap`.
    # The font cell's top is simply the first row carrying ink PAST THE
    # LOGO, and the rule is excluded by not looking at row MBAR_H - 1.
    y0 = None
    for y in range(0, MBAR_H - 1):
        if any(rows[y][x] for x in range(32, w)):
            y0 = y
            break
    if y0 is None or y0 + 8 > len(rows):
        return None
    out, xs = [], []
    for sx in range(0, w - 7, 8):
        g = bytes(sum(1 << (7 - c) for c in range(8) if rows[y0 + r][sx + c])
                  for r in range(8))
        ch = table.get(g)
        out.append(ch if ch is not None else " ")
        xs.append(sx)
    return "".join(out), xs


def bar_text(m, tmp):
    """...and its text with the runs squashed, for an `in` test."""
    r = bar_scan(m, tmp)
    if r is None:
        return None
    return " ".join(r[0].split()) or None


def bar_find(m, tmp, word):
    """The SCREEN x of `word`'s first cell on the bar, or None.

    A MENU IS PICKED WHERE IT IS DRAWN, not where a constant says. The bar's
    cells move the moment a program adds menus to it, and this repository's
    own lesson is that a remembered pulldown offset drifts - so the title's
    x is read off the glass each time rather than written down."""
    r = bar_scan(m, tmp)
    if r is None:
        return None
    cells, xs = r
    i = "".join(cells).find(word)
    return xs[i] if i >= 0 else None


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
_MIN_ROWS = 20                  # a console is 25; a coincidence in the BIOS
                                # data area is one or two


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

    **AND EVERY MATCH IS A CANDIDATE, NOT THE FIRST ONE.** The third design
    of this anchor. Taking the first match in memory order found 0x42E -
    five bytes of the BIOS data area reading as the sentinel's cells - with
    0 rows and attribute 0x04, so the part answered nothing and looked
    exactly like a program that had hung. The shape decides now: a console
    is 25 rows of one attribute, and a candidate that is not at least 20 is
    not it. The language was correct in that run; the fixture was not.

    **A PART THAT TESTS A REFUSAL CANNOT PRINT IT.** The whole program is
    compiled before any of it runs (SPEC.md 150.19), so a program refused
    at compile time prints nothing at all - not the sentinel, not even its
    own CLS. Those parts are read at the address a previous part found: the
    buffer is in the package's bss and the package does not move while the
    window stays open. The fallback is only taken when the scan fails, the
    attribute-shape check still applies to it, and a refusal's expectation
    is an exact sentence - so a stale address cannot pass quietly.
    """
    img = m.read(0, 0x100000)
    pat = SEED.encode()

    def _shape(at):
        """(start, rows, attr) for a candidate, or None if it is not one."""
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
        return (start, rows, attr) if rows >= _MIN_ROWS else None

    # **EVERY MATCH IS A CANDIDATE AND THE SHAPE DECIDES**, which is this
    # anchor's third design. Taking the FIRST match in memory order put the
    # buffer at 0x42E - five bytes of the BIOS data area that happen to read
    # as the sentinel's cells - with 0 rows and attribute 0x04, so the part
    # answered nothing and looked exactly like a program that had hung. A
    # console is 25 rows of one attribute; anything that is not is not it.
    hit = None
    for i in range(len(img) - 2 * len(pat)):
        if img[i] == pat[0] and all(img[i + 2 * k] == pat[k]
                                    for k in range(len(pat))):
            shape = _shape(i)
            if shape:
                hit = (i, shape)
                break
    if hit is None:
        if _BUF[0] is None:
            print("      no buffer: the sentinel %s is not in memory as cells"
                  % SEED)
            return None
        shape = _shape(_BUF[0])
        if shape is None:
            print("      no buffer: the address a part before it found no "
                  "longer has a console's shape")
            return None
        hit = (_BUF[0], shape)
        print("      no sentinel: reading the buffer a part before it found")
    at, (start, rows, attr) = hit
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
            # (SPEC.md 150.17), and is the only menu this row touches.
            mo.menu(112, 8, 112, 30)
            os88qemu.pace(m, 2.0)
        t0 = time.time()
        after, wantbar, pick = [], [], []
        for line, _ in part:
            # `#after <key>` IS NOT TYPED: it is a keystroke for AFTER the
            # run begins, which is the only way to answer a statement that
            # SUSPENDS (SPEC.md 150.36). An ALERT part cannot finish until
            # its dialog is answered, so the poll below would time out with
            # the program still correctly waiting.
            if line.startswith("#after "):
                after.append(line.split(None, 1)[1])
                continue
            # `#bar <text>` IS NOT TYPED either: it is a substring the MENU
            # BAR must show once this part has run, read off the glass by
            # bar_text() rather than out of the console buffer
            if line.startswith("#bar "):
                wantbar.append(line.split(None, 1)[1])
                continue
            # `#pick <title>` IS NOT TYPED: it is a menu pick made once the
            # program is running, which is the only way to answer an
            # ON MENU GOSUB handler
            if line.startswith("#pick "):
                pick.append(line.split(None, 1)[1])
                continue
            typ(m, line + "\n")
        print("      part %d: %d lines in %.1fs"
              % (pn + 1,
                 len(part) - len(after) - len(wantbar) - len(pick),
                 time.time() - t0))
        os88qemu.sendkey(m.path, "f5")          # the Run key, confirmed
        for k in after:
            os88qemu.pace(m, 2.0)               # ...let the dialog come up
            os88qemu.sendkey(m.path, k)
        for t in pick:
            # THE BAR IS READ BEFORE IT IS CLICKED. The program has to have
            # installed its menus and the kernel to have drawn them, and
            # the title's x is wherever that left it - 30 is the first
            # item's y, which is what File > New above already uses.
            os88qemu.pace(m, 3.0)
            bx_ = bar_find(m, m.tmp, t)
            print("      pick %r at x=%s" % (t, bx_))
            if bx_ is None:
                check(False, "the bar shows %r to pick" % t,
                      why="a pick cannot be aimed at a menu that is not "
                          "drawn, and the x is read off the glass")
                continue
            mo.menu(bx_ + 4, 8, bx_ + 4, 30)
            os88qemu.pace(m, 2.0)
        # **WAIT FOR THE LAST ANSWER, NOT FOR A CLOCK.** A fixed pace was
        # six seconds, which every part until SPEC.md 150.28's fitted inside
        # - and a loop that reassigns a string 200 times does not. The row
        # then read the console mid-run and reported the last two lines as
        # missing, which looks exactly like a defect in the feature. Polling
        # for the part's own last expectation is both faster when the part is
        # quick and patient when it is not.
        last = None
        for _, e in part:
            if e is not None:
                last = e if not isinstance(e, (list, tuple)) else e[-1]
        got = None
        for _ in range(30):
            os88qemu.pace(m, 2.0)
            got = console_lines(m)
            if last is None or (got and last in got):
                break
        if got is None:
            check(False, "the console buffer is found by its shape",
                  why="no run can be read without it")
            return 1
        if wantbar:
            # LET THE BAR BE DRAWN FIRST. menu_win_set only marks it -
            # menu_relayout sets menu_bdirty and the redraw is owed, not
            # done - so a shot taken the instant the program ends can
            # legitimately show the OLD bar. This pace is the difference
            # between "the set is wrong" and "the paint had not happened",
            # which are not the same defect at all.
            os88qemu.pace(m, 3.0)
            bar = bar_text(m, m.tmp)
            print("      bar: %r" % (bar,))
            for t in wantbar:
                check(bar is not None and t in bar,
                      "the menu bar shows %r" % t,
                      why="a program's own bar is CHROME: the console "
                          "buffer cannot see it, and the first MENU m$() "
                          "put up a bar with a null command handler while "
                          "every value assertion passed",
                      got=bar, want=t)
        answers += got
        for _, e in part:
            if e is None:
                continue
            # A LINE MAY ANSWER WITH MORE THAN ONE, which is what a CALL
            # does: the body is written below the line that runs it, so
            # every line a procedure prints is owed by its caller.
            if isinstance(e, (list, tuple)):
                want += list(e)
            else:
                want.append(e)
    check(True, "the console buffer is found by its shape")

    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, os.path.join(m.tmp, "end.png")],
                   capture_output=True, cwd=ROOT)
    print("      screen: %s" % os.path.join(m.tmp, "end.png"))
    answers = [g for g in answers if g not in (BANNER + " - SPEC.md 150",
                                               "Ready")]
    check(answers == want,
          "every line of the program answers what SPEC.md 150 says it does",
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
