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

# ERASE IS REFUSED WITH ITS REASON, and the row asserts the REASON and not
# merely that something was refused - "not a statement this wave knows"
# would pass a test that only looked for an error, and it is the wrong
# answer for a word the reference has and this chapter decided about
# (SPEC.md 150.33).
PART37 = [
    ("CLS",                              None),
    ("DIM k(3)",                         None),
    ("ERASE k()",
     "Error at line 3: ERASE frees nothing here - ARRAYFILL clears one "
     "in place"),
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
PART39 = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("ON MENU GOSUB handler",
     "Error at line 3: ON MENU takes nothing yet - handlers come with MENU"),
]

PART40 = [
    ("CLS",                              None),
    ("x = 1",                            None),
    ("ON ERROR GOSUB oops",
     "Error at line 3: ON MENU is the only ON this wave knows"),
]

# THREE ROWS, ONE FILE. The whole set is past twenty minutes of typing, which
# is too slow to iterate against and too slow to sit in one soak slot while
# docs/plans/SOAK-PARALLEL.md has others idle. `--early` is the language
# through SELECT, `--late` is GOTO, labels and procedures, `--w3tail` is
# wave 3's tail - 150.33 to 150.35 - and `--wave4` is the event loop,
# 150.36; no flag runs the lot, which is what a developer typing the file's
# name means.
EARLY = (PART1, PART2, PART3, PART4, PART5)
LATE = (PART6, PART7, PART8, PART9, PART10, PART11, PART12, PART13,
        PART14, PART15, PART16, PART17, PART18, PART19, PART20, PART21,
        PART22, PART23, PART24, PART25, PART26, PART27, PART28)
W3TAIL = (PART29, PART30, PART31, PART32, PART33, PART34, PART35,
          PART36, PART37)
WAVE4 = (PART38, PART39, PART40, PART41, PART42, PART43, PART44)
PARTS = EARLY + LATE + W3TAIL + WAVE4

if "--early" in sys.argv:
    PARTS = EARLY
elif "--late" in sys.argv:
    PARTS = LATE
elif "--w3tail" in sys.argv:
    PARTS = W3TAIL
elif "--wave4" in sys.argv:
    PARTS = WAVE4

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
        after = []
        for line, _ in part:
            # `#after <key>` IS NOT TYPED: it is a keystroke for AFTER the
            # run begins, which is the only way to answer a statement that
            # SUSPENDS (SPEC.md 150.36). An ALERT part cannot finish until
            # its dialog is answered, so the poll below would time out with
            # the program still correctly waiting.
            if line.startswith("#after "):
                after.append(line.split(None, 1)[1])
                continue
            typ(m, line + "\n")
        print("      part %d: %d lines in %.1fs"
              % (pn + 1, len(part) - len(after), time.time() - t0))
        os88qemu.sendkey(m.path, "f5")          # the Run key, confirmed
        for k in after:
            os88qemu.pace(m, 2.0)               # ...let the dialog come up
            os88qemu.sendkey(m.path, k)
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
