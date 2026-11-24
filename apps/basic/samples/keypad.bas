' KEYPAD.BAS - three buttons a BASIC program DRAWS and then HIT-TESTS
'
' The point of this one is the whole chain in a dozen lines: tier C draws
' (SPEC.md 150.8), 150.53's pointer says where the mouse is, and 150.36's
' ON MENU is the loop that joins them. Nothing here is a new language
' feature - it is what BASIC/8088 could already do once something reported
' the pointer.
'
' IT REDRAWS EVERY PASS, AND IT HAS TO (150.54). This interpreter RETURNS at
' a yield rather than spinning, so the callback ends and the window is
' REPAINTED - taking the program's pixels with it. W_PAINT belongs to the
' editor; a program is a guest inside that window, not its owner. Drawing
' once and expecting it to stay is the mistake this sample exists to not
' make.
'
' AND IT WORKS OUT ITS OWN ORIGIN, which is the trick worth stealing. The
' drawing slots take SCREEN coordinates and MOUSEX/MOUSEY are CONTENT-
' relative (150.53), and no verb returns the window's position - but
' OSAPI_MOUSE reports the SAME pointer in screen coordinates at the SAME
' instant, so the difference between the two IS the content origin. It is
' recomputed every pass, so moving the window does not strand the buttons.

' == MAIN ==

ox = 0                          ' the content origin, worked out below
oy = 0
mx = 0
my = 0
k = 0
h = 0
seen = 0                        ' the last key reported, so a held one
ty = 0                          ' does not print on every pass
by = 0                          ' the key row's top and bottom, on screen

PRINT 0
DO
  ON MENU
  GOSUB origin
  GOSUB draw
  MOUSE mx, my, k
  IF k = 1 THEN
    hit(mx, my, h)
    IF h <> seen THEN
      PRINT h
      seen = h
    ENDIF
  ENDIF
  IF k = 0 THEN
    seen = 0
  ENDIF
LOOP UNTIL k = 2
PRINT 77                        ' ...the right button is how you leave
END

' == ENGINE ==

' --- the content origin, from the pointer in two frames ------------------
PROCEDURE origin
  OSAPI 160                     ' OSAPI_MOUSE: REG(2) is x, REG(3) is y,
  ox = REG(2) - MOUSEX          ' both SCREEN - and MOUSEX is the same
  oy = REG(3) - MOUSEY          ' pointer CONTENT-relative, so the
  ty = oy + 60                  ' difference is where the content starts
  by = oy + 89                  ' ...and the key row, in screen rows
RETURN

' --- three outlined keys, 80 wide and 20 apart ---------------------------
' FIVE ARGUMENTS, FIVE SIMPLE NAMES, AND THE ARITHMETIC IN STEPS. Two
' things are refused as "expression too deep" here and both look modest:
' putting the sums inside the argument list, and `ox + 20 + (i - 1) * 100`
' as one expression - that last one compiles without the `ox +`. The limit
' is nearer three operators than ten, so a program that computes anything
' writes it in lines rather than in one.
' THE LABELS COST NO VARIABLE, which matters at a sixteen-name ceiling
' (SPEC.md 150.55): `@` takes a string EXPRESSION, so a literal works and
' no `t$` has to exist. 104 is OSAPI_FONT_STR_XPARENT - CX=x, DX=y, SI=the
' NUL string - so the two leading zeros are AX and BX, which it ignores.
PROCEDURE draw
  LOCAL l
  LOCAL m
  l = ox + 20
  m = l + 79
  OSAPI 64, l, ty, m, by
  l = l + 34
  m = ty + 11
  OSAPI 104, 0, 0, l, m, @"1"
  l = ox + 120
  m = l + 79
  OSAPI 64, l, ty, m, by
  l = l + 34
  m = ty + 11
  OSAPI 104, 0, 0, l, m, @"2"
  l = ox + 220
  m = l + 79
  OSAPI 64, l, ty, m, by
  l = l + 34
  m = ty + 11
  OSAPI 104, 0, 0, l, m, @"3"
RETURN

' --- which key is under (mx, my), in CONTENT coordinates, or 0 -----------
' THE PARAMETERS REUSE THE CALLER'S NAMES ON PURPOSE: the variable table is
' by NAME and holds SIXTEEN, procedure names included, so a parameter called
' px costs a slot that mx has already paid for. This program needs every one
' of them.
' The gaps matter as much as the keys: a click between two of them must
' answer 0, which is what an origin off by more than the gap would break.
' **THE VAR PARAMETER IS NOT CALLED h**, and that is not a style choice:
' passing the global h into a parameter ALSO named h silently answers
' nothing. The table is by NAME, so the reference and the thing it refers to
' become one entry. hit(mx, my, h) with `VAR h` returned 0 for every
' position; the identical body with `VAR o` returns the key.
PROCEDURE hit(mx, my, VAR o)
  LOCAL i
  LOCAL l
  o = 0
  IF my >= 60 THEN
    IF my <= 89 THEN
      FOR i = 1 TO 3
        l = 20 + (i - 1) * 100
        IF mx >= l THEN
          IF mx <= l + 79 THEN
            o = i
          ENDIF
        ENDIF
      NEXT i
    ENDIF
  ENDIF
RETURN
