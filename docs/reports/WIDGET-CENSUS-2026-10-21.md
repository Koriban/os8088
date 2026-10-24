# A widget census — os8088 against fifteen GUI toolkits, and a dock/launcher survey

Two things requested together: (1) what `apps/os88ui.inc` (+ `os88line.inc`,
`os88text.inc`, and the kernel's own dialogs) actually offers, set against
Windows 1–4, Mac OS 6–X, GTK 2–4, Qt 2–5, OPEN LOOK and GNUstep/NeXTSTEP —
plus Motif/CDE, since a dock redesign question below needs it — with the
real gaps named; and (2) CDE's Front Panel and OS/2 Warp 3's LaunchPad,
researched properly, for a possible dock redesign.

**Sourcing.** Part 1's os8088 column is read directly from this session's
build (`apps/os88ui.inc`, `apps/os88line.inc`, `apps/os88text.inc`,
`kernel/ctrl.inc`, `kernel/fdlg.inc`), grep-verified for absence as well as
presence. The toolkit columns are general knowledge, not a line-by-line
source read — treat them as a reliable sketch, not a citation. Part 2's CDE
and OS/2 sections are sourced from this session's web search, cited inline.

---

## Part 1: the widget census

### What os8088 actually has

| widget | where | notes |
|---|---|---|
| Push button | `os88ui.inc` (always) | text, icon-only (`OS88UI_BIMG`), or owner-drawn (`OS88UI_BOWN`) faces |
| Check box | `os88ui.inc` (`OS88UI_CHK`) | |
| Radio button | `os88ui.inc` (`OS88UI_RAD`) | grouped dots |
| Scroll bar | `os88ui.inc` (`OS88UI_SCROLL`) | thumb-drag (`OS88UI_SBDRAG`) and wheel (`OS88UI_WHEEL`) are separate opt-ins |
| Drop-down / popup picker | `os88ui.inc` (`OS88UI_DROP`) | one pick from ≤12 items, Mac-popup press-drag-release gesture (§13.14) |
| In-window menu bar + pull-downs | `os88ui.inc` (`OS88UI_MENU`) | for apps past the kernel bar's 5-title cap (Word, Sheet) |
| Modal alert | `os88ui.inc` (`OS88UI_ALERT`) | |
| "About" card | `os88ui.inc` (`OS88UI_ABOUT`) | |
| Single-line text field | `apps/os88line.inc` | "no wrap, no selection, no undo, and that is the whole specification" |
| Multi-line text box | `apps/os88text.inc` | caret, vertical scroll, no word wrap — "a cell note, a comment field... not Note Pad" |
| Group box | convention only | a frame + label drawn by hand with `gfx_frame`/`font_run`; no dedicated routine |
| Standard File (Open/Save) dialog | kernel (`fdlg.inc`) | its own thing, not built from the package-side controls above |
| Window chrome (title bar, close box, grow box, zoom) | kernel | not a "control" in the app-facing sense, but is the toolkit's window furniture |
| Dock/taskbar | kernel (`dock.inc`) | see Part 2 |

**One structural fact that matters for everything below**: `OS88UI_DROP`
(the one control closest to a combo box) is compiled OUT of the kernel's own
build — "No kernel dialog wants a list, so there is no kernel copy either"
(§13.14, confirmed this session by tracing why Control Panel can't use it).
So **the kernel's own dialogs (Control Panel, Standard File) have a smaller
widget vocabulary than an ordinary package does** — the reverse of every
toolkit below, where the *system* chrome and *application* chrome share one
widget set. That split is worth keeping in mind reading the gaps: some of
them are "missing everywhere," others are "missing only from the kernel's
own UI."

### The matrix

Columns are toolkit *eras*, since the same name means different things a
decade apart. `●` = present as a first-class, reusable, named control;
`◐` = present but limited, late, or via convention; `○` = absent.

| widget | os8088 | Win 1–2 | Win 3.x | OS/2 2.x (PM) | OS/2 3.x (Warp) | Win95/NT4 (ComCtl) | Mac OS 6 | Mac OS 7–9 (Appearance) | Mac OS X/Aqua | OPEN LOOK | NeXTSTEP/OPENSTEP/GNUstep | Motif/CDE | GTK2 | GTK3 | GTK4 | Qt2–3 | Qt4 | Qt5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Push button | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| Check box | ● | ● | ● | ● | ● | ● | ● | ● | ● | ●(nonexcl.) | ● | ● | ● | ● | ● | ● | ● | ● |
| Radio button | ● | ● | ● | ● | ● | ● | ● | ● | ● | ●(excl.) | ● | ● | ● | ● | ● | ● | ● | ● |
| Scroll bar | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| Popup/dropdown (pick-only) | ● | ○ | ◐(combo exists, see below) | ◐(`WC_COMBOBOX` drop-down style) | ◐(same) | ● | ○ | ●(Appearance popup button) | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| Editable combo box | ○ | ○ | ● | ●(`WC_COMBOBOX`) | ●(same) | ● | ○ | ○ | ●(Cocoa) | ○ | ●(NSComboBox) | ● | ● | ● | ● | ● | ● | ● |
| List box (always-visible, non-popup) | ○* | ● | ● | ●(`WC_LISTBOX`) | ●(same) | ● | ●(List Mgr) | ● | ● | ● | ●(NSTableView) | ● | ● | ● | ● | ● | ● | ● |
| Tree / outline view | ○ | ○ | ○ | ●(Container control, tree view) | ●(same) | ●(TreeView) | ○ | ◐(Finder disclosure triangles) | ●(NSOutlineView) | ○ | ●(NSBrowser, columnar) | ○→●(Motif 2.x) | ● | ● | ●(replaces TreeView) | ● | ● | ● |
| Tab / notebook control | ○ | ○ | ○ | ●(`WC_NOTEBOOK`, new in 2.0) | ●(same) | ● | ○ | ●(Appearance Mgr) | ● | ○ | ●(NSTabView) | ○→●(Motif 2.x) | ●(Notebook) | ● | ◐(GtkStack/Switcher instead) | ● | ● | ● |
| Progress bar | ○ | ○ | ○ | ○(not found in sourced material) | ○(same) | ● | ○ | ●(Appearance Mgr) | ● | ●("gauge") | ●(NSProgressIndicator) | ● | ● | ● | ● | ● | ● | ● |
| Slider / trackbar | ○ | ○ | ○ | ●(linear + circular, new in 2.0/2.1) | ●(same) | ● | ○ | ●(Appearance Mgr) | ● | ●("slider") | ●(NSSlider) | ● | ●(Scale) | ● | ● | ● | ● | ● |
| Spinner / stepper (up-down) | ○ | ○ | ○ | ●(Spin Button) | ●(same) | ●(Spin) | ○ | ◐(little arrows, ad hoc) | ●(NSStepper) | ○ | ●(NSStepper) | ○ | ●(SpinButton) | ● | ● | ● | ● | ● |
| Tooltip / fly-over help | ○ | ○ | ○ | ○(not found in sourced material) | ○(same) | ●(introduced here) | ○ | ●(Balloon Help, Sys 7, predates Win95's) | ● | ○ | ● | ○ | ● | ● | ● | ● | ● | ● |
| Toolbar (as a container) | ○† | ○ | ○ | ○(confirmed absent - third-party only, needs Warp 4+) | ○(same, confirmed) | ●(+ coolbar/rebar) | ○ | ◐(floating palettes) | ●(NSToolbar, customizable) | ○ | ◐(custom palettes) | ○ | ●(Toolbar) | ●(HeaderBar increasingly replaces it) | ◐(HeaderBar is default) | ● | ● | ● |
| Status bar | ◐(SHEET built its own) | ○ | ○ | ○(not found in sourced material) | ○(same) | ●(StatusBar) | ○ | ◐ | ● | ○ | ○ | ○ | ●(Statusbar) | ● | ● | ● | ● | ● |
| Color picker | ○ | ○ | ●(ChooseColor) | ○(not found in sourced material) | ○(same) | ● | ○ | ●(since Sys 7) | ● | ○ | ●(NSColorWell/Panel) | ○ | ● | ● | ● | ● | ● | ● |
| Date/time picker | ○ | ○ | ○ | ○(not found in sourced material) | ○(same) | ◐(late, IE4/98 era) | ○ | ○ | ◐(later) | ○ | ○ | ○ | ◐(Calendar, GTK2 late) | ● | ● | ◐(late) | ● | ● |
| Dockable panel | ○ | ○ | ○ | ○(not found; WPS folders are a different paradigm) | ○(same) | ○ | ○ | ○ | ●(Aqua "drawer," below) | ○ | ●(NSDrawer) | ○ | ◐(via WM, not a widget) | ◐ | ◐ | ●(`Q3DockWindow`, Qt3) | ●(renamed `QDockWidget`) | ● |
| Document-modal "sheet" | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ●(Aqua sheets) | ○ | ○ | ○ | ○ | ◐(GtkDialog can act like one) | ◐ | ○ | ○ | ○ |

\* os8088 has no *generalized* list-box widget, but Control Panel's own
page list (Scheduler/Date-Time/.../Floppy down the left side) is exactly a
plain always-visible single-select list, hand-rolled in `ctrl.inc` rather
than promoted to a reusable `os88ui.inc` control.
† `OS88UI_MENU`'s in-window bar is the closest relative — a fixed strip of
titled pull-downs — but it is menu-shaped, not a general icon/button
container the way Win95's toolbar or NSToolbar are.

**A cell marked "not found in sourced material" is not a claim of absence**
— it means the search that otherwise sourced this row's OS/2 cells (below)
did not surface a matching `WC_` control class, which for a CUA-era IBM
product most likely does mean it wasn't a standard control (applications of
the period commonly hand-drew status text and percentage bars the way
os8088's own SHEET does), but it was not independently confirmed the way
the container/notebook/slider/spin-button/combo/list-box rows were.

### Reading the matrix

**os8088's actual baseline is Windows 1–2 / Mac OS 6**, not a coincidence —
those are the two toolkits built for comparable hardware (a few hundred KB,
no protected mode, a floppy-booted single-tasking-adjacent machine). Every
widget present in *both* of those eras is present in os8088; every widget
absent from *both* is absent from os8088 too, with one exception in each
direction:

- **os8088 has more than Win1–2/Mac6 in one place**: the popup/dropdown
  picker (§13.14) and the in-window menu bar. Win 1.0/2.0 had no popup
  button at all (combo boxes arrived in Windows 3.0), and Mac OS 6 had no
  popup *menu button* as a control either (just pull-downs from the menu
  bar) — a System 7-era addition. os8088 built this not out of ambition but
  necessity: CLEAR SKIES needed a pick-one-of-many control and nothing
  simpler covered it.
- **os8088 has less in one place that actually matters**: no list box. Every
  single toolkit surveyed, including the two oldest, ships a plain
  always-visible scrolling list as a first-class control — it's one of the
  oldest widget ideas in the field (File Manager's directory pane, the Mac's
  System 6 List Manager). os8088 has the exact behavior *twice*, bespoke
  each time (Control Panel's page list, the Standard File dialog's
  directory listing) and never promoted either to `os88ui.inc`.

**The widgets every toolkit from Windows 95 / Mac OS 8 onward agrees on, and
os8088 has none of**: tabs, progress bars, sliders, tooltips, a real
toolbar container, tree views, spinners. That is not a surprising gap — it
is the Appearance Manager / Common Controls generation, built for machines
with 10–100× os8088's memory and no 8086 instruction-set ceiling — but it
is worth being precise about *which* era the gap starts at, because "os8088
doesn't have Windows 95 widgets" undersells how deliberately minimal the
starting point (Win 1–2, Mac OS 6) already was on *purpose*.

**Two individually interesting outliers:**

- **Balloon Help (Mac OS 7.5, 1994) predates Windows 95's tooltip by about a
  year**, and is the direct ancestor of the idea — worth knowing if os8088 ever
  adds fly-over help, since it would be reaching for something genuinely
  older than "the Windows one."
- **OPEN LOOK's pushpin** — a literal pin icon on every pull-down and popup
  menu that, when clicked, detaches the menu into a small persistent
  window — has no equivalent in os8088 (or in most of the toolkits above).
  It is the one idea in this whole survey that is *strictly more capable*
  than what any of the mainstream toolkits kept: a tear-off menu. Worth a
  look if `OS88UI_MENU` or `OS88UI_DROP` ever grows a "keep this open"
  feature — CLEAR SKIES' own Location list is exactly the kind of
  menu-shaped control a pushpin would help.

### What's worth adding, if anything is

Given the constraints this project actually operates under (resident-byte
budget, 8086 real mode, the kernel-vs-package widget split above), the
candidates in priority order:

1. **A reusable list box**, promoted out of Control Panel's own page-list
   code. It already exists twice; a third bespoke copy (needed for
   VESACTL's mode picker, see this session's other work) is the reason to
   finally generalize it. Cheapest of everything on this list because the
   drawing and hit-testing already exist and are proven.
2. **A tooltip / fly-over help primitive**, Balloon-Help-simple (a small
   opaque text box that appears after a dwell and disappears on move) —
   genuinely useful across the whole app set and small to build.
3. **Spinner/stepper** (two small up/down arrows beside a numeric or
   enumerated field) — this session's own VESA mode-cycling conversation is
   a direct use case, and it is the smallest of the "Common Controls era"
   widgets to build (no track, no thumb, no drag math — just two buttons
   and a value).
4. Progress bar and slider are the next tier — more drawing, not more
   mechanism, since the scroll bar's thumb math already solves the harder
   half of a slider.
5. Tabs, tree views and a real toolbar container are each a bigger
   undertaking than the first four combined and would only make sense if a
   specific app (not a hypothetical one) needed one.

---

### Sources for Part 1

The matrix was drafted from general knowledge, then checked against a
second round of searches; one real error was caught and fixed (below).
Confirmed directly:

- **Mac OS 8's Appearance Manager** widget set — tabs (small 16px / large
  21px per [Apple's Mac OS 8 developer docs, mirrored on
  discmaster.textfiles.com](https://discmaster.textfiles.com/file/31888/Apple%20Developer%20CD%20Series%20Reference%20Library%20%28Apple%2C%20Inc.%29%20%28September%201999%29%28Disk%202%29.iso/Technical%20Publications/macos8/HumanInterfaceToolbox/AppManager/ProgWithAppearanceMgr/Appearance.8.html?html=true)),
  sliders and progress bars grouped as "tracks" alongside scroll bars
  (same source), group boxes/pop-up buttons/bevel buttons per [Metrowerks'
  1997 CodeWarrior announcement](https://www.mactech.com/1997/08/04/md1-codewarrior-for-mac-os-8/amp/),
  disclosure triangles classed with buttons (same Apple doc tree).
- **OPEN LOOK's pushpin** mechanics — a pinned pop-up menu is taken down and
  replaced by an ordinary command frame at the same spot — confirmed via
  [O'Reilly's *Volume 7A: XView Programming Manual*, ch.
  17](https://www.oreilly.com/library/view/volume-7a-xview/9780937175873/chapter-17.html).
  The gauge widget's existence (as distinct from Motif's "scale") is
  sourced only to [Oracle's CDE Motif Transition
  Guide](https://docs.oracle.com/cd/E19620-01/805-3911/6j3ncjkvi/index.html)
  naming it as a migration difference, not to the OPEN LOOK spec itself —
  weaker sourcing than the rest of this row.
- **NeXTSTEP/OPENSTEP's NSBrowser, NSDrawer, NSStepper** all confirmed to
  exist as described — a hierarchical multi-column browser, a sliding
  panel attached to a window edge, and an up/down value control,
  respectively — via [GNUstep's NSDrawer
  reference](https://home.gnustep.org/resources/documentation/Developer/Gui/Reference/NSDrawer.html),
  [its NSBrowser
  reference](https://www.ict.griffith.edu.au/teaching/2501ICT/archive/resources/documentation/Developer/Gui/Reference/NSBrowser.html),
  and [Apple's current NSStepper
  docs](https://developer.apple.com/documentation/appkit/nsstepper.md)
  (the GNUstep pages are third-party and partly stub documentation, so
  they confirm the class existed and its rough shape, not full behavior).
- **GtkTreeView is GTK2-specific**, a ground-up redesign for the 2.0
  release that looked at Java Swing and Qt — per a [GNOME GUADEC2
  slide](https://people.redhat.com/otaylor/gtk/guadec2-gtk/slide001.html)
  and the [GTK+ 2.0.0 release
  announcement](https://lists.wireshark.org/archives/ethereal-dev/200203/msg00199.html).
- **OS/2 2.0's Presentation Manager added four new standard controls at
  once** — container, notebook, slider, value set — per [EDM2's reprint of
  IBM's PM Programming
  Guide](https://www.edm2.com/index.php/PMGuide_-_Notebook_Controls) and
  its [Slider Controls
  chapter](https://www.edm2.com/index.php/PMGuide_-_Slider_Controls),
  which also dates the circular slider specifically ("made its debut in
  2.0 and the programming interface in 2.1"). The pre-existing combo box
  and list box classes (`WC_COMBOBOX`, `WC_LISTBOX`) are confirmed via
  EDM2's [Combination
  Box](https://www.edm2.com/index.php/PMGuide_-_Combination_Box) and
  [List-Box](https://www.edm2.com/index.php/PMGuide_-_List-Box_Controls)
  chapters, and the spin button via its own [EDM2
  article](https://www.edm2.com/index.php/The_Infinitely_Floating_Spinbutton).
  Toolbar/status bar absence on Warp 3 is sourced to a search result
  describing IBM's own *OS/2 Developer Collection* add-on as needing "Warp
  4 or higher," meaning neither was a native PM control even by 1994's
  Warp 3. Progress bar, tooltip, status bar, color picker, date/time
  picker and dockable panel are marked "not found in sourced material"
  rather than asserted absent — the search that covered the rest of this
  row simply didn't surface a matching `WC_` class for them, which is
  weaker evidence than a positive citation either way.

**One real correction, caught by this pass**: the matrix originally marked
"dockable panel" absent for Qt 2–3. It wasn't — [Qt 4's `QDockWidget`
documentation itself names its direct predecessor as `Q3DockWindow`, "part
of the Qt 3 support
library"](https://doc.qt.io/Archives/qt-4.7/q3dockwindow.html), meaning
Qt 3 already had a working dock-window concept under a different name; Qt 4
renamed and rebuilt it as `QDockWidget`. Fixed above.

**Left unverified, genuinely uncertain, or softened rather than asserted**:
the exact 1995 Windows 95 Common Controls launch roster — a [Microsoft
Visual Basic 6 era
document](https://learn.microsoft.com/zh-cn/previous-versions/visualstudio/visual-basic-6/aa231207%28v%3Dvs.60%29)
names TreeView/ListView/Toolbar/StatusBar/TabStrip/Slider as the initial
group but doesn't confirm ProgressBar or the UpDown (spinner) control were
in that same initial release rather than added shortly after (Wine's
`commctrl.h` header groups them under the same `ICC_WIN95_CLASSES` flag,
which is suggestive but not a primary release record); and GtkNotebook's
own introduction date, which the search did not turn up at all (it may
predate GTK2, unlike GtkTreeView) — the matrix's GTK2/3/4 "tabs" cells are
not claims about *origin*, only about presence, so this doesn't change
anything marked, but it's a gap worth naming rather than silently papering
over. Windows 1–2/Win 3.x's own widget boundaries (what exactly shipped at
each point, as opposed to what the Common Dialog *library* added in 3.1)
were not independently re-verified this pass and rest on the same general
knowledge the rest of the matrix does.

---

## Part 2: CDE's Front Panel, OS/2 Warp 3's LaunchPad, and the dock

### How CDE's Front Panel actually works

Sourced from [Oracle's CDE Front Panel configuration guide](https://docs.oracle.com/cd/E19683-01/806-7492/frontpanelconfig-14/index.html), [the Solaris CDE user's guide](https://sea.shrubbery.net/solaris9ab/SUNWabe/CDEUG/p19.html), and [*Inside Solaris 9*'s Front Panel chapter](https://www.oreilly.com/library/view/inside-solaristm-9/0735711011/0735711011_ch25lev1sec3.html):

- **Nested containers, not a flat strip.** The Main Panel holds *boxes*,
  boxes hold *controls*. A **subpanel** is a special container attached to
  exactly one Main Panel control.
- **The tell is a small triangle.** Any Main Panel control that has a
  subpanel shows a triangular tab above it; clicking the tab slides the
  subpanel up out of the strip, titled with its own name.
- **A subpanel's contents are a mix**: a labelled copy of its parent
  control (so the common case is still one click away), other application
  launchers that can be *promoted* to the Main Panel permanently, and an
  "Install Icon" drop zone for adding new ones.
- **It closes itself** after a pick, unless the user has dragged it away
  from its home position — at which point it behaves like an ordinary small
  window instead.
- **Entirely config-file driven** (`dtwm.fp` and friends under
  `/usr/dt/appconfig`), not GUI-editable in the stock environment — a
  `SUBPANEL` block names the control it attaches to via `CONTAINER_NAME`.

### How OS/2 Warp 3's LaunchPad actually works

Sourced from [EDM2's "LaunchPad Revisited"](https://www.edm2.com/index.php/LaunchPad_Revisited), ["Creating and building your own LaunchPad"](https://www.edm2.com/index.php/Creating_and_building_your_own_LaunchPad), and the [Bubblepad project wiki](https://trac.netlabs.org/bubblepad/wiki/WikiStart) (a third-party LaunchPad replacement, useful for seeing what the stock one was felt to be missing):

- **Two kinds of button on one strip**: *faceplate* objects (the ordinary
  launcher buttons always visible) and *drawer* objects (a bar with an
  arrow, attached to a faceplate object that has one).
- **One click opens, one more launches.** Clicking a drawer's bar pops its
  contents open; clicking an object inside launches it.
- **Everything is a shadow**, never the object itself — dragging something
  onto the LaunchPad (or a drawer) with the right mouse button creates a
  reference, with a black bar showing where it will land.
- **What third parties felt was missing, confirmed by what Bubblepad
  added**: fly-over help (tooltips) on the buttons, and the ability to hide
  individual drawers or remove action buttons — i.e., the stock LaunchPad
  had neither tooltips nor much per-item configurability from the UI
  itself, matching this document's own Part 1 finding that tooltips are a
  mid-90s-and-later idea CDE/OS2's *contemporaries* (Mac OS 7.5) already
  had but these two launchers did not.

### What the two have in common, read against os8088's dock today

Both are the same shape under different names: **a fixed strip of
always-visible items, where some items have a nested, temporarily-visible
second tier** (CDE: subpanel, slides up, config-file defined; OS/2: drawer,
pops open, built by drag-and-drop). Neither is a taskbar in the Windows 95
sense (one tile per running window) — that's a different, later idea, and
it's the one os8088's dock (`kernel/dock.inc`, §30) actually implements
today: one tile per running instance, active/minimized marks, no drawers,
no launchers, nothing configurable from the strip itself.

So "move the dock toward CDE/LaunchPad" is really **adding a second idea
next to the existing one, not replacing it**: os8088's dock answers "what's
running," CDE/LaunchPad answer "what can I start." A strip that did both —
running-instance tiles on one side, a few pinned/drawer-style launchers on
the other — is a real, well-precedented design (it's roughly what Windows
95's taskbar + Quick Launch toolbar became by Windows 98, and what every
modern dock, Mac OS X's included, now is).

### The driver/app split, checked against what's actually there

The idea as given: a driver hides and unloads the stock dock; an app
replaces it. Checking that against `kernel/dock.inc`/`dockmod.inc`'s real
architecture (read this session):

- **The dock is already two pieces, but not split the way the idea needs.**
  The *basic* dock (the strip itself, tile drawing, click-to-raise/minimize)
  is permanently resident — it is not an on-demand module and the hard
  rule in CLAUDE.md ("before spending a resident byte, ask whether the
  feature is an on-demand module") was presumably weighed and the basic
  dock judged to fail that test, being needed on every boot. What *is*
  already a loadable, swappable module is `DOCK.DRV`'s **optional runtime**
  (`DOCK_OPT`, §30.5) — but it works by `dkx_hook`/`dkx_unhook` **replacing
  individual operation landing pads** inside the *same* strip (used for
  things like §30.6's hide/hover-line behavior), not by replacing the whole
  dock with a different window.
- **So the literal ask — "driver hides the dock and unloads it, app
  replaces it" — is not what exists today**, and building it means more
  than reusing `DOCK_OPT`'s hook mechanism: the basic dock's tile-per-
  running-instance behavior is presumably wired into the window manager
  itself (raise/minimize notifications, the active-window mark), not
  something a package can just opt out of and reimplement from outside —
  that would need checking against `kernel/wm.inc`'s own calls into
  `dock_paint`/`dock_click` before promising it's a clean swap.
- **A smaller, honestly-scoped version of the same idea**: keep the basic
  running-instance strip exactly as it is (it is the thing closest to a
  real taskbar, and is good), and build the CDE/LaunchPad half — pinned
  launchers with drawers — as a genuinely new, *separate* dock-adjacent
  app or Sticky App (SPEC.md §110's family already exists for "things that
  live on the desktop"), rather than one that requires unloading the
  kernel's own strip first. That sidesteps the "is the basic dock's
  wm.inc wiring actually detachable" question entirely, ships something
  real sooner, and doesn't risk a half-torn-out resident dock if the swap
  turns out to be harder than it looks from outside.

Not built — this is the research and the architectural read the request
asked for, not an implementation. Flagging the open question (is the basic
dock's window-manager wiring cleanly detachable) as the thing to answer
before committing to the "driver unloads it" half specifically, since that
is the part that doesn't yet have a precedent anywhere in this tree the way
`DOCK_OPT`'s operation-level hook does.
