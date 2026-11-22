' CALC.BAS - an eight-function desk calculator for OS/8088
'
' A GUI application written in BASIC/8088 using only what the language has
' today: the menu bar is the keypad (SPEC.md 150.38), ON MENU is the event
' loop (150.36), and PRINT writes the display.
'
' THE EIGHT FUNCTIONS are add, subtract, multiply, divide, square root,
' percent, reciprocal and sign change. The ten digits, Equals, Clear and the
' two memory keys are the plumbing around them.
'
' THE DISPLAY IS A PAPER TAPE, not a seven-segment window, and that is the
' console pane's doing rather than a compromise: PRINT appends a line, so
' every key leaves its value behind and the column of numbers reads like an
' adding machine's roll. A calculator that overwrote one display line would
' need the drawing verbs, which are wave 6's.
'
' WHY THE KEYS ARE MENUS AND NOT BUTTONS: nothing in the language delivers a
' mouse click on something a program DREW. ON MENU and ALERT are the only two
' event sources that exist, so a clickable key has to be a menu item or a
' dialog button. Drawing a keypad is already possible through 150.8's raw
' OSAPI gateway - learning that one of its keys was pressed is not.
'
' WHY THREE MENUS: MENU_APPMAX is five per app and BASIC's own bar already
' carries File and Run, so a program gets three. The titles are short on
' purpose too, because what really bounds the bar is its WIDTH - the
' kernel's layout pass stops at the first title that would reach the clock.
'
' WHY THE ENGINE TAKES KEY CODES AND NOT MENU INDICES: press(k) is the whole
' calculator and knows nothing about menus; kd() turns a menu index into a
' key code. So the keypad can be re-laid-out, or driven by something that is
' not a menu at all, without touching the arithmetic - which is also what
' lets a test exercise all eight functions without clicking anything.
'
' AND THE GLUE IS ITS OWN SECTION because that separation has to be REAL to
' be worth anything. pressed() is the only procedure that knows kd() exists,
' and while it sat among the others the engine could not be compiled without
' the menu table - the whole program refused, at pressed()'s own line, with
' kd undefined. A section marker is what makes the claim checkable.

' == MAIN ==

' --- the state: five numbers and a flag --------------------------------
acc = 0                         ' what a pending operation applies to
cur = 0                         ' the number on the display
pend = 0                        ' the operation waiting for its second
ent = 0                         ' 1 while cur is being typed
mem = 0                         ' the memory register
t$ = ""                         ' whatever INKEY$ last handed over
err = 0                         ' 1 when the display says E
done = 0                        ' Quit sets this

' --- the keypad ---------------------------------------------------------
' Node [299]'s array: a heading, its entries, an empty string; again per
' menu; then one more empty string to end the bar. THE DIGITS ARE IN KEYPAD
' ORDER - 7 8 9 / 4 5 6 / 1 2 3 / 0 - which is how a calculator's keys are
' laid out and not how a list of numbers usually is.
DIM m$(29)
m$(0) = "Keys"
m$(1) = " 7 "
m$(2) = " 8 "
m$(3) = " 9 "
m$(4) = " 4 "
m$(5) = " 5 "
m$(6) = " 6 "
m$(7) = " 1 "
m$(8) = " 2 "
m$(9) = " 3 "
m$(10) = " 0 "
m$(11) = ""
m$(12) = "Math"
m$(13) = " Add "
m$(14) = " Subtract "
m$(15) = " Multiply "
m$(16) = " Divide "
m$(17) = " Sqrt "
m$(18) = " Percent "
m$(19) = " Recip "
m$(20) = " Negate "
m$(21) = ""
m$(22) = "Calc"
m$(23) = " Equals "
m$(24) = " Clear "
m$(25) = " Mem+ "
m$(26) = " Recall "
m$(27) = " Quit "
m$(28) = ""
m$(29) = ""

' --- menu index to key code --------------------------------------------
' MENU(0) answers with the ARRAY index of the entry picked - headings,
' empty strings and all - so this is indexed by exactly that. 23 is "no
' key", which is what a heading or a separator means.
DIM kd(29)
FOR i = 0 TO 29
  kd(i) = 23
NEXT i
kd(1) = 7
kd(2) = 8
kd(3) = 9
kd(4) = 4
kd(5) = 5
kd(6) = 6
kd(7) = 1
kd(8) = 2
kd(9) = 3
kd(10) = 0
kd(13) = 12
kd(14) = 13
kd(15) = 14
kd(16) = 15
kd(17) = 16
kd(18) = 17
kd(19) = 18
kd(20) = 19
kd(23) = 10
kd(24) = 11
kd(25) = 20
kd(26) = 21
kd(27) = 22

' --- and the loop the program owns, which is where it yields ------------
MENU m$()
ON MENU GOSUB pressed
PRINT 0
DO
  ON MENU
  t$ = INKEY$
  IF t$ <> "" THEN
    typed(t$)
  ENDIF
LOOP UNTIL done > 0
END

' == GLUE ==

' --- a pick becomes a key press ----------------------------------------
PROCEDURE pressed
  LOCAL i
  i = MENU(0)
  IF i >= 0 THEN
    IF i <= 29 THEN
      press(kd(i))
    ENDIF
  ENDIF
RETURN

' --- a keystroke becomes a key press -----------------------------------
' THE KEYBOARD IS A SECOND SOURCE OF THE SAME KEY CODES, which is the whole
' return on press(k) not knowing what a menu is: the bar and the keys both
' arrive here as a number between 0 and 22, and the calculator cannot tell
' which one was used.
'
' ON MENU IS WHAT LETS A KEY IN (SPEC.md 150.49). This interpreter RETURNS
' at a yield rather than spinning, so the keystroke is delivered while the
' program waits at the ON MENU above and INKEY$ finds it on the next pass.
' A loop without that line would poll an empty ring for ever.
'
' WHAT THE KEYBOARD DOES NOT CARRY: Sqrt, Recip, Negate and the memory keys
' have no key of their own on this machine, exactly as they have no key on a
' PC keypad, so they stay on the bar. Inventing letters for them would be a
' worse answer than the menu that is already there.
PROCEDURE typed(t$)
  LOCAL c
  ' A SPECIAL KEY IS TWO CHARACTERS, CHR$(0) and a scan code, so ASC() reads
  ' 0 and matches nothing below - which is the behaviour wanted and not an
  ' accident worth hiding.
  c = ASC(t$)
  IF c >= 48 THEN
    IF c <= 57 THEN
      press(c - 48)
    ENDIF
  ENDIF
  SELECT c
  CASE 43
    press(12)
  CASE 45
    press(13)
  CASE 42
    press(14)
  CASE 47
    press(15)
  CASE 61,13
    press(10)
  CASE 27,67,99
    press(11)
  CASE 37
    press(17)
  ENDSELECT
RETURN

' == ENGINE ==

' --- the calculator itself. Key codes: 0 to 9 are digits, then 10 Equals,
' 11 Clear, 12 Add, 13 Subtract, 14 Multiply, 15 Divide, 16 Sqrt,
' 17 Percent, 18 Recip, 19 Negate, 20 Mem+, 21 Recall, 22 Quit, 23 nothing.
PROCEDURE press(k)
  LOCAL j
  j = k
  ' E LOCKS THE MACHINE UNTIL CLEAR, which is what a desk calculator does
  ' and the reason there is no dialog here. ALERT would be the obvious way
  ' to report a bad key, but it SUSPENDS the program - correctly, by
  ' 150.36's re-entrant seam - and a calculator whose divide key stops the
  ' machine until someone clicks OK is not a calculator. So while E is up
  ' every key except Clear reads as 23, which is no key at all.
  IF err > 0 THEN
    IF j <> 11 THEN
      j = 23
    ENDIF
  ENDIF
  IF j <= 9 THEN
    digit(j)
  ELSE
    SELECT j
    CASE 10
      GOSUB fold
      pend = 0
      ent = 0
    CASE 11
      err = 0
      acc = 0
      cur = 0
      pend = 0
      ent = 0
    CASE 12,13,14,15
      ' AN OPERATOR FOLDS THE PENDING ONE FIRST, which is what makes
      ' 7 + 7 + show 14 without an Equals - chained arithmetic, and the
      ' same rule Equals itself uses.
      GOSUB fold
      pend = j - 11
      ent = 0
    CASE 16
      ' SQR OF A NEGATIVE IS A FATAL REFUSAL IN THIS LANGUAGE - it ends the
      ' program by name - so the guard is the whole point: an interactive
      ' program must never let its own arithmetic be the thing that stops
      ' it. Same for Divide and Recip.
      IF cur < 0 THEN
        err = 1
      ELSE
        cur = SQR(cur)
      ENDIF
      ent = 0
    CASE 17
      ' THE SIMPLE READING of the percent key: a hundredth. A desk
      ' calculator's % is context-dependent (200 + 10 % is 220 on many of
      ' them); the Compendium does not define it, because it is not a BASIC
      ' function, so the unambiguous one is here and the other is a
      ' decision for whoever wants it.
      cur = cur / 100
      ent = 0
    CASE 18
      IF cur = 0 THEN
        err = 1
      ELSE
        cur = 1 / cur
      ENDIF
      ent = 0
    CASE 19
      cur = -cur
    CASE 20
      mem = mem + cur
    CASE 21
      cur = mem
      ent = 0
    CASE 22
      done = 1
    ENDSELECT
  ENDIF
  GOSUB show
RETURN

' --- a digit joins the number being typed ------------------------------
PROCEDURE digit(k)
  IF ent = 0 THEN
    cur = 0
    ent = 1
  ENDIF
  ' SEVEN DIGITS AND NO MORE, and seven rather than eight because that is
  ' what PRINT can SHOW: the formatter keeps seven significant figures, so a
  ' display holding 12345678 prints as 12345680 and the last key a user
  ' pressed is not the one they see. A desk calculator's display shows
  ' exactly what it holds, so the entry stops where the display stops. ABS,
  ' because the number being typed may already be negative.
  IF ABS(cur) <= 999999 THEN
    ' A DIGIT TYPED AFTER THE SIGN KEY EXTENDS THE NUMBER AWAY FROM ZERO.
    ' Keying 5, Negate, 3 means -53 on every desk calculator, and cur * 10
    ' + k alone would make it -47 - the sign key does not end the entry, so
    ' digit() is where the sign has to be honoured.
    IF cur < 0 THEN
      cur = cur * 10 - k
    ELSE
      cur = cur * 10 + k
    ENDIF
  ENDIF
RETURN

' --- fold the pending operation into the accumulator -------------------
PROCEDURE fold
  SELECT pend
  CASE 0
    acc = cur
  CASE 1
    acc = acc + cur
  CASE 2
    acc = acc - cur
  CASE 3
    acc = acc * cur
  CASE 4
    IF cur = 0 THEN
      err = 1
    ELSE
      acc = acc / cur
    ENDIF
  ENDSELECT
  cur = acc
RETURN

' --- the display -------------------------------------------------------
PROCEDURE show
  IF err > 0 THEN
    PRINT "E"
  ELSE
    PRINT cur
  ENDIF
RETURN
