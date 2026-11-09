# Writing GUI and text applications in BASIC — tier A

**Status: planned 2026-11-04. Nothing built.** Branch `basic-o88`. The
keyword layer of `BASIC-PLAN.md`; `BASIC-BINDINGS-PLAN.md` is the two tiers
underneath it; SPEC §150 is the contract.

This is the half the target is actually about. A BASIC that can evaluate
expressions is a toy; the goal is a BASIC somebody writes an OS/8088
application in, with a window, a menu bar and a dialog — which is what
GFA-BASIC was on the ST.

## 1. This OS hands BASIC a better substrate than GEM did

A GEM program is handed a stream of numbered messages and decodes them. In
GFA that reads:

```
ON MENU MESSAGE GOSUB handler
...
PROCEDURE handler
  IF MENU(1) = 20       ! 20 is "redraw a rectangle"
    ...
  ELSE IF MENU(1) = 22  ! 22 is "the close box"
```

An OS/8088 window is a **template of callback slots**, and the kernel calls the
one that applies. From `apps/os88api.inc`:

| slot | off | the kernel passes |
| --- | --- | --- |
| `W_PAINT` | 12 | `SI` = win ptr. **Content only** |
| `W_ONKEY` | 14 | `AL` = ascii, `AH` = scan, `SI` = win |
| `W_ONCLICK` | 16 | `CX` = x, `DX` = y, `SI` = win |
| `W_ONSIZE` | 24 | your resize negotiator |
| `W_ONMOUSEUP` | 26 | the release half of a drag |
| `W_ONDRAG` | 28 | the pointer moved while down |
| `W_ONTIMER` | 30 | your one-shot timer fired |
| `W_ONWAKE` | — | |
| `W_MENUS` | 18 | your menu set, 0 = none |
| `W_TITLE` | 10 | near ptr to a NUL title |

Each is a **near pointer relative to `W_SEG`**, which is the fact that makes
this safe to expose: the interpreter registers *its own* trampolines in those
slots once, and dispatches from a table of BASIC handler addresses. **A BASIC
program never holds a code address**, so there is no way to write a handler
pointer that the next heap compaction invalidates.

So the event model is not `MENU(1) = 20`. It is one named hook per slot, and
the decoding GFA made the programmer do is work the kernel has already done.

## 2. The event keywords

```basic
ON PAINT    GOSUB proc      ' W_PAINT     — and see §4, this one is special
ON KEY      GOSUB proc      ' W_ONKEY     — KEYASCII, KEYSCAN
ON CLICK    GOSUB proc      ' W_ONCLICK   — MOUSEX, MOUSEY
ON DRAG     GOSUB proc      ' W_ONDRAG
ON MOUSEUP  GOSUB proc      ' W_ONMOUSEUP
ON SIZE     GOSUB proc      ' W_ONSIZE    — WINW, WINH
ON TIMER    GOSUB proc      ' W_ONTIMER   — one-shot, see §5
ON WAKE     GOSUB proc      ' W_ONWAKE
ON MENUPICK GOSUB proc      ' a menu item was chosen — MENUITEM$, MENUIDX
ON CLOSE    GOSUB proc      ' the close box; returning without CLOSEW cancels
```

The event's parameters arrive as named read-only values rather than as a
`MENU(x)` array, because the kernel already separates them: `KEYASCII`,
`KEYSCAN`, `MOUSEX`, `MOUSEY`, `MOUSEK`, `WINW`, `WINH`, `MENUIDX`,
`MENUITEM$`. `REG()` from the bindings plan stays available for anything tier
A has not named.

**The loop.** GFA's `ON MENU` inside a `DO`/`LOOP` is kept, because SPEC §150.8
makes it the yield point and because it is the idiom a GFA programmer already
knows:

```basic
DO
  ON MENU           ' pump one round of events; dispatch to the hooks above
LOOP UNTIL quit%
```

`ON MENU [t]` keeps GFA's optional timeout. A text-mode program that never
calls it never yields and does not need to.

## 3. The keyword set

**Windows** — GFA's spellings, since the concepts match:

```basic
OPENW  n [,x,y,w,h]        ' create; no args = a sensible default size
CLOSEW n                   ' see §5: this must be DESTROY, not CLOSE
CLEARW n                   ' erase content
TITLEW n, title$
TOPW   n                   ' bring to front
FULLW  n                   ' maximise
SIZEW  n, w, h             ' OSAPI_WM_RESIZE
MOVEW  n, x, y
WINX WINY WINW WINH        ' the current window's content rectangle
```

**Menus** — `MENU m$()` with GFA's array, under §5's two caps:

```basic
MENU m$()                  ' install the bar from a string array
MENU KILL                  ' deactivate
MENU x, y                  ' y: 0 untick, 1 tick, 2 grey, 3 ungrey
MENUIDX  MENUITEM$         ' what was picked
```

**Dialogs and alerts** — `ALERT` and `FILESELECT` map onto facilities that
exist; the rest is §6:

```basic
ALERT icon, message$, default, button$, choice
FILESELECT path$, default$, file$
```

**Drawing** — GFA's verbs, legal only inside a paint (§4):

```basic
PLOT x,y            LINE x1,y1,x2,y2     DRAW TO x,y
BOX  x1,y1,x2,y2    PBOX x1,y1,x2,y2     RBOX / PRBOX
CIRCLE x,y,r        PCIRCLE x,y,r        ELLIPSE / PELLIPSE
POLYLINE n,x(),y()  POLYFILL n,x(),y()
TEXT x,y,text$      GRAPHMODE m          DEFLINE / DEFFILL / DEFTEXT
COLOR c             GET / PUT            ' save and blit a rectangle
```

**Text output** — the other half of the target, and it is not a second
mechanism: `apps/os88con.inc` is an 80x25 console of character/attribute pairs
with a CP437 face, so the ordinary statements simply work.

```basic
PRINT  CLS  LOCATE row,col  COLOR attr  POS  CSRLIN  INPUT  LINE INPUT
```

## 4. `SCREEN` says what kind of surface a window has

`BASIC-PLAN.md` left this open: GFA's `SCREEN n` picked a resolution, and there
are no mode numbers here because a window already has a surface. The answer
that fits both this OS and the target's "GUI **or** text" requirement:

```basic
SCREEN TEXT        ' the window is an os88con.inc console; PRINT, CLS, LOCATE
SCREEN GRAPHICS    ' the window is a drawing surface; PLOT, LINE, BOX
```

A window is one or the other, chosen when it opens, defaulting to `TEXT` so
that the smallest useful program is still three lines. This makes a text
application a GUI application whose surface happens to be a console — one
window model, one event loop, one paint hook, two kinds of content.

**The paint discipline is the interpreter's job, not the programmer's.**
Drawing on this OS means taking `OSAPI_GFX_LOCK`, arming `OSAPI_WM_CLIP_SET`
(`CF=1` when not one pixel is visible, in which case draw nothing), drawing,
clearing the clip, and releasing the lock. Getting that wrong is not a wrong
pixel, it is a corrupted screen or a held lock. So:

- the interpreter takes the lock and arms the clip **around** the `ON PAINT`
  handler, and releases both when it returns;
- a drawing verb outside a paint is **refused by name**, with the reason — the
  same contract §150.7 sets for everything else. `REDRAW n` posts damage and
  lets the paint happen through the normal path, which is what a program that
  wants to redraw actually needs;
- `SCREEN TEXT`'s paint is `con_rows_owed`, so a text program needs no
  `ON PAINT` at all unless it wants one.

This is strictly better than GFA, where drawing anywhere was allowed and GEM
punished you for it later.

## 5. Traps this project has already paid for

Each of these cost real debugging in this repository, so tier A should be built
knowing them rather than rediscovering them.

**`CLOSEW` must destroy, not hide.** There is no close slot: there is
`OSAPI_WM_HIDE` 0x0082, which in the kernel's own words "only takes the pixels
down, and the slot stays used with your segment in its `W_SEG`", and
`OSAPI_WM_DESTROY` 0x02BC, which "frees the RECORD". Hide is right for a
window you keep and wrong for one you are finished with, and the difference is
invisible until the slots run out — **`MAX_WIN` is 12 on `kern_big` and
`equ 6` on `kern_small`** (`kernel/wm.inc:147`). Six is few enough that a
program opening and closing dialogs exhausts them quickly, after which every
further dialog silently fails to appear. BASIC's `CLOSEW` binds to **destroy**,
and both calls want the gfx lock already held, which is the interpreter's job
either way (§4).

**`W_PAINT` is content-only and wants `SI`.** The slot's contract passes the
window pointer in `SI`, and a paint path that clobbers it silently skips the
redraw while the data underneath is perfectly correct — a defect that looks
like a drawing bug and is not. The trampoline preserves `SI` across the BASIC
handler.

**`W_ONTIMER` is one-shot.** `W_TIMER` is a deadline the kernel clears when it
fires. GFA's `EVERY` therefore has to re-arm inside its own handler; `AFTER` is
the natural primitive here and `EVERY` is built on it, not the reverse.

**`MENU_APPMAX equ 5`.** Five menus per app on the shared bar. SHEET and Word
both outgrew it and answered with their own in-window bars. `MENU m$()` with a
sixth menu must say so, by name, rather than quietly dropping it — and the
in-window-bar pattern is the escape hatch if BASIC programs need more.

**`MENU_MAXCH` is 24 glyphs** of item text, derived from `MENU_MAXW` 208px.
Longer items need truncating somewhere, and silently is the wrong somewhere.

**`m$(3)`–`m$(8)` are GEM's desk-accessory slots.** What they do there, from
the User Manual: a Desk Accessory is a resident program loaded at boot which
calls `MENU_REGISTER(ap_id, m_text$)` to insert its name **into the first menu
of every application's bar** — "provided that this does not carry the number of
Accessories beyond six (they are numbered 0 to 5)", returning the slot 0..5 or
−1 when full, and usable "only ... with a Desk Accessory, not a compiled
program". The application's job is purely to leave the room: the six strings
"need only be a single character long, as their contents are ignored", the AES
overwrites the ones in use and does not print the rest, and the application
never handles the selection — GEM sends `MENU(1) = 40` to *the accessory*,
which checks `MENU(5)` to see whether it was the one meant, and `41` when it is
closed.

So it is a system-wide extension point that every application is obliged to
provide, by reserving holes in its own menu for the system to fill.

**This OS has the same extension point and inverts it.** The kernel owns that
part of the bar and an application *registers a handler* rather than leaving a
hole: `OSAPI_ABOUT_SET` 0x018A takes `BX = win ptr, SI = your About handler's
offset`. Nothing is reserved, nothing is overwritten, and there is no
accessory to name.

**So drop them, and say so when a program still has them.** Keeping six dead
strings would be keeping GEM's mechanism without GEM's purpose, which is the
thing `BASIC-BINDINGS-PLAN.md` §8 forbids; but silently reading them as menu
items would turn a ported program's placeholders into six garbage entries. The
first menu is therefore read like every other one — items until an empty string
— and `MENU m$()` **recognises the GEM shape** (a run of one-character strings
at 3..8 closed by an empty string at 9) and **refuses it by name**, with the
reason and the fix: delete `m$(3)` to `m$(8)`. One mechanical edit when porting,
a diagnostic rather than a surprise, and no GEM concept embedded in the
language for good.

**And the kernel drops a sixth menu silently.** `MENU_APPMAX equ 5`, with
"extras ... silently dropped by the kernel's layout pass" — so `MENU m$()` has
to count the menus itself and refuse the sixth by name. A silent drop is the one
outcome a BASIC programmer cannot debug, since the bar simply renders without
it.

## 6. Dialogs — decided: by calls

**Settled, and specified in SPEC §150.12.** GEM's dialogs are data in a `.RSC`
run by `FORM_DO`; `os88ui.inc`'s widgets are code opted into with `%define`,
which a BASIC program cannot do. So a dialog is built by calling, and the
`DIALOG` block is kept for later — a dialog built by calls can be wrapped in a
block without changing the widgets underneath, while starting from the block
means a layout engine before anything can show a button.

`DIALOG` is **reserved from the start and means nothing yet**, held for that
block exactly as `POKE`'s name is held: reserving a word early costs nothing,
and taking one away later breaks programs. The call API is `DLG` with the verb
after it — `NEW` `TEXT` `EDIT` `CHECK` `RADIO` `DROP` `GROUP` `BUTTON` `RUN`
`FREE` — in the shape `MENU KILL` already uses.

Controls bind to variables rather than being read back: the variable supplies
the initial state and receives the result, nothing is written on cancel, and
`DLG RUN` returns the id that dismissed the dialog or **0 for the close box**.

Four things §150.12.1 fixes, each for a reason this repository already paid
for: the dialog is **modal** (a non-modal one here can be orphaned by a stray
click or the close box and gate-lock the application); `DLG FREE` **destroys**
rather than hides (`MAX_WIN` is 12, and 6 on `kern_small`); coordinates are
**content-relative** with the height derived, so **no BASIC program contains
the number 18**; and the widget set is **fixed when the interpreter is built**,
since the opt-ins are assembly-time `%define`s. The engine lives in
`BASIC.OVL`. `ALERT` and `FILESELECT` stay their own verbs. No fake `FORM_DO`.

## 7. What it should look like finished

The whole design on one page — a graphical window with a menu bar that
responds to picks and repaints itself:

```basic
DIM bar$(12)
bar$(0) = " Desk "  : bar$(1) = " About..."  : bar$(2) = "-"
bar$(9) = ""                                  ' slots 3-8: see 5
bar$(10) = " File " : bar$(11) = " Quit"     : bar$(12) = ""

OPENW 1, 40, 30, 320, 200
TITLEW 1, "Spindle"
SCREEN GRAPHICS
MENU bar$()

ON PAINT     GOSUB repaint
ON CLICK     GOSUB poke_at
ON MENUPICK  GOSUB picked
ON CLOSE     GOSUB bye

DO
  ON MENU
LOOP UNTIL done%
CLOSEW 1
END

PROCEDURE repaint                 ' lock and clip are already held
  BOX 0, 0, WINW - 1, WINH - 1
  TEXT 8, 16, "clicks: " + STR$(hits%)
RETURN

PROCEDURE poke_at
  hits% = hits% + 1
  REDRAW 1
RETURN

PROCEDURE picked
  IF MENUITEM$ = " Quit" THEN done% = TRUE
  IF MENUITEM$ = " About..." THEN ALERT 1, "Spindle 1.0", 1, "OK", c%
  MENU OFF
RETURN

PROCEDURE bye
  done% = TRUE
RETURN
```

Nothing in that program mentions a slot number, a register, a lock, a clip
rectangle or a message number — and every one of those is happening. That is
the measure of whether tier A is finished.

## 8. Waves

Numbered to sit beside `BASIC-PLAN.md`'s and `BASIC-BINDINGS-PLAN.md`'s.

**G1 — the window and the loop.** `OPENW`/`CLOSEW`/`TITLEW`/`CLEARW`/`TOPW`,
the trampoline table, `ON MENU` as the pump, `ON CLOSE`, `WINX`/`WINY`/`WINW`/
`WINH`. Exit: a BASIC program opens a real titled window and closes it
cleanly, and opening and closing it twenty times does not exhaust `MAX_WIN`.

**G2 — `SCREEN TEXT` and the console.** `PRINT`, `CLS`, `LOCATE`, `COLOR`,
`POS`, `CSRLIN`, `INPUT`, `LINE INPUT` over `os88con.inc`. Exit: a text
application, which is half the target, works end to end.

**G3 — input events.** `ON KEY`, `ON CLICK`, `ON DRAG`, `ON MOUSEUP`,
`ON SIZE`, and the named event values.

**G4 — menus.** `MENU m$()`, `MENU KILL`, `MENU x,y`, `ON MENUPICK`, under
§5's caps and with the accessory-slot decision made.

**G5 — `SCREEN GRAPHICS` and the paint discipline.** `ON PAINT` with the
lock and clip owned by the interpreter, `REDRAW`, and the refusal for a
drawing verb used outside a paint. Then the drawing verbs themselves.

**G6 — `ALERT`, `FILESELECT`, and dialogs** by §6's decision.

**G7 — timers.** `AFTER` on `W_ONTIMER`, `EVERY` built on `AFTER` with
re-arming, `ON BREAK`.
