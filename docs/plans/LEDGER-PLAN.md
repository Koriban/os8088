# LEDGER — a personal-finance manager, staged from the owner's own spec

**The decision this plans:** Register, Write Checks, Reconcile, Reports &
Graphs, Account List, envelope-style Budgeting, Investments, over nine
account types (Cash, Checking, Savings, Credit Card, Investment, Crypto,
Credit Line, Mortgage, Loan) — the owner's own list, verbatim. Nothing
beyond the mechanical fork (`LEDGER: a mechanical fork of PLAN`) is built.
This is the contract-and-stories document CLAUDE.md's wave process asks for
before a line of feature code — `apps/ledger/ledger.asm` today **is** PLAN
under a new name, and that fact is the whole starting position.

---

## 1. The number that decides the architecture — and it is not SHEET's

PLAN carries a SECOND ceiling SHEET does not have at all: a self-imposed
**51,712-byte "128KB machine" arena** (region + claims together), on top of
the ordinary 65,024-byte `APP_MAX_SIZE` every package is held to. Measured
this session, LEDGER today — a pure rename, zero money-manager bytes —
already sits at **701 bytes spare** against that arena.

**Seven feature areas, nine account types and investment tracking do not
fit in 701 bytes, and no amount of care changes that arithmetic.**

So the first decision, stated plainly because it is the owner's to make and
everything below assumes an answer: **LEDGER gives up PLAN's floor-machine
commitment** and targets what SHEET targets — the plain 65,024-byte
ceiling, nothing more. Against *that* number alone, today's LEDGER has
**28,349 bytes spare**, which is a real budget to stage a product against,
the way SHEET staged formulas, charts and macros against its own.

**This is a pinned assumption, not a quiet choice.** If 128KB machines are
meant to run LEDGER too, the scope below needs cutting to fit 701 bytes
instead of 28,349 — which is a different, much smaller product, closer to
"Register only, no budgeting, no reports, no investments." Say so and this
plan gets rewritten around that number instead.

**Expect the overlay treatment regardless.** SHEET's formula+macro+chart
feature set — smaller than what is asked for here — needed two overlays
(`CHART.OVL`, `MACRO.OVL`) to fit the *same* 65,024 ceiling. Reports/Graphs
and Investments, below, are the two obvious candidates: neither is touched
on every keystroke the way the Register is.

---

## 2. What is inherited for free, and it is more than it looks

- **Exact decimal arithmetic.** PLAN's `apps/os88fix.inc` is fixed-point,
  four places, range ±214,748.3647 (§81.75.3) — no floating-point rounding
  on a sum of dollars and cents, which real spreadsheet-engine money tools
  have to work around and this one does not.
- **A form dialog, already proven.** SHEET's `Data ▸ Form` (§81.71.5) is
  one record at a time, with New/Delete/Find and field-by-field editing —
  the exact SHAPE "Write Checks" needs (one transaction, fields, a save).
  Wave 2 reuses the PATTERN; whether it reuses the CODE depends on how much
  of §81.71.5 is SHEET-cell-specific versus generic, which is a wave-2
  question and not a wave-1 one.
- **File I/O, SYLK and CSV**, already round-trip tested (`tools/os88sheetfmt.py`).
- **A grid**, which is most of what a Register IS: Quicken's own register
  columns — Date, Num, Payee, Category, Payment, Deposit, Balance — are
  seven spreadsheet columns with one of them (Balance) a running formula.
  This is the single biggest reason a spreadsheet engine was the right
  thing to fork rather than starting from nothing.

---

## 3. What is NOT reusable as-is, found by checking rather than assuming

**The multi-sheet mechanism's PATTERN is exactly "accounts in one file",
and its SIZING is not big enough.** `SH_SHEETS equ 4` — a plain compile-time
constant, four fixed bss arrays (`sh_selsave`/`sh_rowsave`/`sh_sclsave`/
`sh_scrsave`, each `SH_SHEETS*2` bytes). A real household's account list —
checking, savings, two credit cards, a mortgage, a car loan, maybe a
brokerage account — clears four before it has covered the owner's own nine
*types*, let alone a realistic count of accounts.

So Account List needs the PATTERN (one book, several named named
sub-registers, the cross-reference plumbing `sh_cursheet` already proves)
but NOT the fixed-4 sizing. The right shape, matching this OS's own stated
preference elsewhere (the clipboard: "a machine that has never copied
anything pays nothing at all" — `kernel/clip.inc`) is a **claim-backed
account list**, sized to however many accounts the file actually holds, not
a constant chosen now and outgrown later.

**Reports & Graphs should not be a resident chart engine.** `CHART.O88` is
already a real, standalone, shipped package: "File ▸ Open reads a real
SYLK, DIF or BIFF file, dispatched by extension" — independent of SHEET,
sharing no code with it by design. LEDGER writing a report **as a SYLK
file** and the existing CHART.O88 graphing it is the OS's own idiom —
small single-purpose programs talking through files — and it is free: no
chart engine has to fit in LEDGER's budget at all. The alternative (a
resident bar-chart engine inside LEDGER, SHEET's `CHART.OVL` shape) is
costed here and refused: `CHART.OVL` alone is 37,737 bytes compressed,
which is bigger than LEDGER's ENTIRE current image.

---

## 4. Account types — one tag, with real behavioural consequences

The owner's nine types (Cash, Checking, Savings, Credit Card, Investment,
Crypto, Credit Line, Mortgage, Loan) are cheap to REPRESENT — one byte tag
per account — but not free to IGNORE, because they split into two families
with opposite sign conventions:

| family | types | balance reads as |
|---|---|---|
| **asset** | Cash, Checking, Savings, Investment, Crypto | money you have |
| **liability** | Credit Card, Credit Line, Mortgage, Loan | money you owe |

A net-worth figure (which Reports & Graphs will eventually want) sums
assets and SUBTRACTS liabilities; a Register showing a credit card balance
conventionally shows it as a positive number that MEANS a debt, not a
negative asset. This is a wave-1 decision (it is baked into every
transaction from the first one entered) and is stated here so it is made
once, deliberately, rather than discovered halfway through wave 3's net
worth report.

**Investment and Crypto accounts are flagged, not designed, here** — see §6.

---

## 5. Staging

Each wave ships something usable; nothing is useful half-built and left.

### Wave 1 — Accounts + Register
The claim-backed account list (§3), the asset/liability tag (§4), and the
Register itself: Date/Num/Payee/Category/Payment/Deposit/Balance columns
over the existing grid, with Balance a running total rather than a typed
formula (the one genuinely new piece of evaluator behaviour this wave
needs — a column that recomputes top-to-bottom on every edit above it,
which is NOT how a spreadsheet's own formulas behave and has to be its own
mechanism, not a repurposed one). **Categories exist from this wave on** —
even before Budgeting is built, a transaction needs somewhere to record
"Groceries" — because retrofitting a category field onto every existing
transaction in a later wave is exactly the kind of migration this project's
own `os8088_ignored_field_becomes_live` lesson warns about.

### Wave 2 — Write Checks, and the budget's DATA
Write Checks as a form over one Register row (§2's reuse question answered
here). Budgeting's categories already exist (wave 1); this wave adds
per-category, per-period planned amounts and the rollover rule the owner's
"envelope style" phrase names — unspent carries forward, which is the one
behaviour that actually distinguishes envelope budgeting from a plain
planned-vs-actual table and is worth pinning explicitly rather than
assuming.

### Wave 3 — Reconcile
A bounded, genuinely new state machine with no existing pattern to borrow:
mark each transaction cleared/uncleared, compare the running cleared total
against a statement ending balance the user types in, done when they
match. Small relative to the other waves, but has no SHEET precedent at
all, unlike Register (the grid) or Write Checks (the form).

### Wave 4 — Reports & Graphs
Built reports (category spending, net worth, cash flow — the owner's own
"Reports" is a category, not a fixed list, so the first ones built should
be the ones a register and a budget already have the data for) write SYLK;
CHART.O88 is the viewer, per §3. No resident chart engine.

### Deferred — Investments
**Its own plan, not a story in this one.** Lots, cost basis, realized vs.
unrealized gain, dividends, splits and price history are, honestly, a
second product's worth of data model — bigger than Register, Write Checks,
Reconcile and Budgeting combined, and blocking wave 1 on designing it would
cost months for a feature that only some of the owner's nine account types
even need (Cash through Credit Line do not touch a single one of those
concepts). Investment and Crypto accounts exist as a TYPE from wave 1 (so a
balance can be tracked, Register-only, no positions/lots) and gain the real
subsystem in a later, separate plan once waves 1–4 have measured what
budget is actually left.

---

## 6. What this will NOT do, pinned so it is not re-litigated

- **No resident chart engine.** §3. CHART.O88 is the viewer.
- **No lot-level investment tracking in this plan.** §5's deferral.
- **No fixed account-count ceiling.** §3 — claim-backed, not `SH_SHEETS`-shaped.
- **No multi-currency.** Not in the owner's list; would touch every sum in
  every wave if added later, so it is named here as a non-decision rather
  than a silent one.

---

## 7. Before wave 1

**Confirm §1's budget assumption** — floor-machine commitment released,
targeting the plain 65,024-byte ceiling. Everything above is staged against
that number; a different answer is a different plan, not a smaller version
of this one.
