# LEDGER — a mix of QuickBooks and Quicken, staged from the owner's own spec

**The decision this plans:** Register, Write Checks, Reconcile, Reports &
Graphs, Account List, envelope-style Budgeting, Investments, over nine
account types (Cash, Checking, Savings, Credit Card, Investment, Crypto,
Credit Line, Mortgage, Loan) — the owner's own list, verbatim — built as
**a mix of QuickBooks and Quicken** (the owner's framing, 2026-10-21):
Quicken's simplicity of entry over QuickBooks' rigor of a real ledger
underneath. Nothing beyond the mechanical fork (`LEDGER: a mechanical fork
of PLAN`) is built. This is the contract-and-stories document CLAUDE.md's
wave process asks for before a line of feature code —
`apps/ledger/ledger.asm` today **is** PLAN under a new name, and that fact
is the whole starting position.

---

## 0. Two decisions already taken, so this plan does not re-litigate them

- **LEDGER is a standard big app** (2026-10-21, the owner's call). PLAN's
  self-imposed 128KB-machine arena ceiling — on top of the ordinary
  65,024-byte `APP_MAX_SIZE` every package is held to — does not apply.
  The build recipe no longer runs that check and `tools/ledgerclaims.py`,
  which existed only to feed it, is deleted rather than left orphaned.
  **28,349 bytes spare against the plain ceiling, measured this session,
  is the real number this plan stages against.**
- **"A mix of QuickBooks and Quicken"** (2026-10-21, the owner's framing) —
  which is an architecture decision, not a wording one, and §1 is what it
  actually costs.

---

## 1. Quicken is single-entry; QuickBooks is double-entry — and this has to
## be decided in the data model, not the UI

**Quicken**: a transaction moves money in or out of ONE account, tagged
with a category. **QuickBooks**: every transaction posts as BALANCED
debits and credits across a formal Chart of Accounts — and that is what
makes real financial statements (Profit & Loss, Balance Sheet) possible,
because those reports are nothing more than sums over a ledger that is
guaranteed to balance.

**The read this plan takes**: Quicken's simplicity where the OWNER types —
entering a check still means picking "Groceries" from a list, not
understanding debits and credits — with a real double-entry ledger
underneath, posting automatically. That gets both halves of "a mix" rather
than picking one.

**Why this is a wave-1 decision and not a later one.** A single-entry
register retrofitted into double-entry later is not a feature added, it is
every existing transaction re-posted and every report rebuilt around data
that was never captured — exactly the shape this project's own
`os8088_ignored_field_becomes_live` lesson warns about, one layer up: a
foundational field is cheap before the first row is saved and expensive
after. So the posting engine is wave 1, even though nothing visible in
wave 1's UI looks different from a plain register.

### 1.1 The Chart of Accounts is ONE tree, and it already subsumes
### "categories"

QuickBooks' Chart of Accounts has five top-level types:

| type | what it holds |
|---|---|
| **Asset** | Cash, Checking, Savings, Investment, Crypto — money you have |
| **Liability** | Credit Card, Credit Line, Mortgage, Loan — money you owe |
| **Equity** | opening balances, owner's equity — the balancing entry a double-entry system needs somewhere |
| **Income** | salary, interest, dividends — what Quicken calls an income category |
| **Expense** | groceries, utilities — what Quicken calls a spending category |

**This is why Quicken's "categories" were never a separate idea from
"accounts" — they are Income and Expense accounts in the SAME chart.** A
Register entry that says "paid $50, category Groceries" is, underneath,
`DEBIT Groceries (Expense) / CREDIT Checking (Asset) $50`. One data
structure, read two ways: Quicken's register shows one side and infers the
other; a QuickBooks-style report sums the whole tree by type.

The owner's nine account TYPES (§5) are now Asset/Liability LEAVES of
this one tree, not a separate taxonomy.

### 1.2 What this buys for free, once it exists

- **Balance Sheet** = sum of Asset leaves minus sum of Liability leaves, by
  construction always consistent with every account's own balance, because
  they are the same numbers read two ways.
- **Profit & Loss** = sum of Income leaves minus sum of Expense leaves over
  a date range — no separate "reports engine" data model, just a
  date-ranged sum over the same tree.
- **An audit trail that cannot silently drift** — a posting that only hit
  one side of the ledger is a bug the structure itself can catch (the
  tree's own total must net to zero across Asset+Liability+Equity at any
  moment), which a single-entry register has no way to even express, let
  alone check.

### 1.3 What it costs, honestly

More code than a flat category tag: a posting routine that writes two
ledger entries instead of one, a tree walk for reports instead of a flat
sum, and a balance-equation check worth having as a correctness gate
(mutate a posting to hit only one side, confirm a reports/consistency check
catches it — this project's own standing rule for exactly this class of
defect). None of this is costed in bytes yet; that is wave 1's own
measurement, not a planning-stage guess.

---

## 2. What is inherited for free, and it is more than it looks

- **Exact decimal arithmetic.** `apps/os88fix.inc` is fixed-point, four
  places, range ±214,748.3647 (PLAN's own §81.75.3) — no floating-point
  rounding on a sum of dollars and cents, and no rounding drift across a
  posting's two sides either, which matters more here than it would have
  for a plain register.
- **A form dialog, already proven.** SHEET's `Data ▸ Form` (§81.71.5) is
  one record at a time, with New/Delete/Find and field-by-field editing —
  the shape Write Checks needs. Whether it reuses the CODE depends on how
  much of §81.71.5 is SHEET-cell-specific, a wave-2 question.
- **File I/O, SYLK and CSV**, already round-trip tested
  (`tools/os88sheetfmt.py`).
- **A grid**, which is most of what a Register IS: Date, Num, Payee,
  Category, Payment, Deposit, Balance are seven spreadsheet columns, one
  of them (Balance) a running total rather than a typed formula — the one
  genuinely new evaluator behaviour Register needs, because a
  top-to-bottom running total on edit is not how a spreadsheet formula
  behaves and is not a repurposed mechanism.

---

## 3. What is NOT reusable as-is, found by checking rather than assuming

**The multi-sheet mechanism's PATTERN is exactly "accounts in one book",
and its SIZING is not big enough.** `SH_SHEETS equ 4` — a plain
compile-time constant, four fixed bss arrays. A real household's account
list — checking, savings, two credit cards, a mortgage, a car loan, maybe
a brokerage account — clears four before covering the owner's own nine
*types*, and a Chart of Accounts has MORE leaves than that once Income and
Expense categories are counted as the same tree (§1.1).

So the Chart of Accounts needs the PATTERN (one book, named
sub-documents, cross-reference plumbing `sh_cursheet` already proves) but
NOT the fixed-4 sizing. The right shape, matching this OS's own stated
preference elsewhere (the clipboard: "a machine that has never copied
anything pays nothing at all" — `kernel/clip.inc`) is a **claim-backed
tree**, sized to however many accounts and categories the file actually
holds.

**Reports & Graphs should not be a resident chart engine.** `CHART.O88` is
already real, standalone, shipped: "File ▸ Open reads a real SYLK, DIF or
BIFF file, dispatched by extension" — independent of SHEET, sharing no
code with it by design. LEDGER writing a report (Balance Sheet, P&L, cash
flow — all of them now date-ranged sums over §1.1's one tree) **as a SYLK
file**, graphed by the existing CHART.O88, is free. Costed and refused: a
resident engine SHEET's own shape (`CHART.OVL`) is 37,737 bytes
compressed, bigger than LEDGER's entire current image.

---

## 4. Invoicing, Accounts Receivable, Accounts Payable — flagged, not
## designed, same treatment as Investments

**The owner's own itemized list (Register, Write Checks, Reconcile,
Reports & Graphs, Account List, Budgeting, Investments) never named
Invoicing, AR or AP.** "A mix of QuickBooks and Quicken" could mean QuickBooks'
*rigor* (§1's double-entry decision, taken) without QuickBooks' specific
*small-business workflows* — or it could mean both. This plan takes the
narrower read as its working assumption, stated here so it is easy to
correct rather than discovered as a gap three waves in.

**If invoicing/AR/AP IS wanted**, it is costed the same way Investments
is below: a real subsystem (invoice numbering, customer records, an aging
schedule for receivables, a bills-to-pay list) that is genuinely larger
than Register+Write Checks+Reconcile+Budgeting combined, and — unlike
those four — has **no existing precedent anywhere in this tree** to build
from. A Chart of Accounts under §1.1 is the correct foundation for it
either way (Accounts Receivable and Accounts Payable are themselves just
two more Asset/Liability leaves), so taking §1's decision costs nothing
toward this even if it turns out to be wanted.

---

## 5. Account types — one tag, with real behavioural consequences,
## now Chart-of-Accounts leaves per §1.1

The owner's nine types sort into §1.1's Asset/Liability split:

| family | types |
|---|---|
| **asset** | Cash, Checking, Savings, Investment, Crypto |
| **liability** | Credit Card, Credit Line, Mortgage, Loan |

A liability account's balance reads as a debt owed, not a negative asset —
baked into every transaction from the first one entered, which is why it
is pinned here rather than discovered halfway through a Balance Sheet
report.

**Investment and Crypto accounts are flagged, not designed, here** — §6.

---

## 6. Staging

Each wave ships something usable; nothing is useful half-built and left.

### Wave 1 — The Chart of Accounts, double-entry posting, and the Register
The claim-backed tree (§3), the posting engine (§1 — every Register entry
writes two ledger sides, invisibly to the user), the asset/liability tag
(§5), and the Register itself over the existing grid. **Categories —
Income/Expense leaves — exist from this wave on**, same reasoning as
before and now doubly true: retrofitting a posting model onto transactions
that were never captured with one is the exact migration §1 exists to
avoid.

### Wave 2 — Write Checks, and the budget's data
Write Checks as a form over one Register row (§2's reuse question answered
here). Budgeting's categories already exist (wave 1, as Expense leaves);
this wave adds per-category, per-period planned amounts and the rollover
rule "envelope style" names — unspent carries forward, pinned explicitly
because it is the one behaviour that actually distinguishes envelope
budgeting from a plain planned-vs-actual table.

### Wave 3 — Reconcile
A bounded, genuinely new state machine with no existing pattern to borrow:
mark each transaction cleared/uncleared, compare the running cleared total
against a statement ending balance the user types in, done when they
match.

### Wave 4 — Reports & Graphs
Balance Sheet and P&L (§1.2) and cash-flow write SYLK; CHART.O88 is the
viewer, per §3. No resident chart engine.

### Deferred — Investments, and Invoicing/AR/AP if wanted (§4)
**Their own plans, not stories in this one.** Lots, cost basis, realized
vs. unrealized gain, dividends, splits and price history are, honestly, a
second product's worth of data model — bigger than waves 1–4 combined, and
blocking wave 1 on designing it would cost months for a feature only two
of the owner's nine account types even need. The TYPE exists from wave 1
(so a balance can be tracked, Register-only, no positions/lots); the
subsystem does not, yet. Invoicing/AR/AP is the same shape if §4's
narrower read turns out to be wrong.

---

## 7. What this will NOT do, pinned so it is not re-litigated

- **No resident chart engine.** §3. CHART.O88 is the viewer.
- **No lot-level investment tracking in this plan.** §6's deferral.
- **No fixed account-count ceiling.** §3 — claim-backed, not
  `SH_SHEETS`-shaped.
- **No multi-currency.** Not in the owner's list; would touch every
  posting in every wave if added later, so it is named here as a
  non-decision rather than a silent one.
- **No 128KB-machine arena ceiling.** §0 — confirmed, not assumed, as of
  this revision.

---

## 8. Before wave 1

**Confirm §4's narrower reading of "QuickBooks"** — rigor (double-entry,
real statements) without the specific small-business workflows
(invoicing, AR, AP), unless told otherwise. Everything in §1.1's Chart of
Accounts is compatible with either answer, so nothing here is at risk if
the answer turns out to be the broader one — only §4's own deferred wave
grows.
