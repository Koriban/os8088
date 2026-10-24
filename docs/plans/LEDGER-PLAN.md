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

## 4. Invoicing, Accounts Receivable, Accounts Payable — deferred, same
## treatment as Investments, confirmed by the owner

**Confirmed (2026-10-21): deferred, not in scope for waves 1–4.** The
owner's own itemized list (Register, Write Checks, Reconcile, Reports &
Graphs, Account List, Budgeting, Investments) never named Invoicing, AR or
AP, and "a mix of QuickBooks and Quicken" meant QuickBooks' *rigor*
(§1's double-entry decision) rather than its specific small-business
workflows too — the narrower read this plan took as a working assumption
is the one that stands.

**If invoicing/AR/AP is ever wanted**, it is costed the same way
Investments is below: a real subsystem (invoice numbering, customer
records, an aging schedule for receivables, a bills-to-pay list) that is
genuinely larger than Register+Write Checks+Reconcile+Budgeting combined,
and — unlike those four — has **no existing precedent anywhere in this
tree** to build from. A Chart of Accounts under §1.1 is the correct
foundation for it
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

### Deferred — Investments, and Invoicing/AR/AP (§4, confirmed)
**Their own plans, not stories in this one.** Lots, cost basis, realized
vs. unrealized gain, dividends, splits and price history are, honestly, a
second product's worth of data model — bigger than waves 1–4 combined, and
blocking wave 1 on designing it would cost months for a feature only two
of the owner's nine account types even need. The TYPE exists from wave 1
(so a balance can be tracked, Register-only, no positions/lots); the
subsystem does not, yet. Invoicing/AR/AP is deferred the same way, by the
owner's own confirmation (§4) rather than this plan's working assumption.

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

## 8. Before wave 1 — resolved

**§4's narrower reading of "QuickBooks" is confirmed (2026-10-21)**: rigor
(double-entry, real statements), not the specific small-business
workflows — invoicing/AR/AP deferred alongside Investments. That was the
last open question this plan was staged against; wave 1 (the Chart of
Accounts, the posting engine, the Register) has nothing left to confirm.

---

## 9. Register — screen and fields, researched against real period mechanics

**What was actually findable.** No DOS-era Quicken/QuickBooks screenshot or
manual turned up a confirmed 1990s field layout — every search returned
either modern Quicken Windows/web documentation or bare product-history
facts (WinWorld: QuickBooks 2.x DOS, 1993, text UI, 8088 minimum). That is
recorded here rather than papered over. What DID turn up usable, and is
what this section is built on, is the **mechanics** that have not changed
since — the register's field set and the split-transaction rule — plus
this OS's own grid, which is the actual constraint on the screen design.

**Columns**, over the existing grid (§2):

| column | holds |
|---|---|
| Date | transaction date; defaults to today on a new row |
| Num | check number, or a fixed token for a non-check transaction (`DEP`, `XFR`, `ATM`) |
| Payee | free text |
| Category | one Income/Expense leaf (§1.1), or the token `--Split--` when the transaction has more than one |
| Memo | free text |
| Payment / Deposit | two columns, exactly one filled per row — this is the single-entry FACE of the posting (§1), the two-sided write happens underneath |
| Balance | running total, computed, never typed — the one evaluator behaviour that is genuinely new (§2) |

**Split transactions**, confirmed by the Quicken Interchange Format's own
file layout (the oldest real source that surfaced): a split is a sequence
of (Category, Memo, Amount) lines, each adjacent, under the one parent
Payment/Deposit row — QIF's spec states the three must stay adjacent per
split. The register shows `--Split--` in Category; a second, smaller
dialog (reusing §2's Form) lists the split lines and must foot to the
parent amount before it can close — the same "must balance before it is
allowed to exist" shape as §1's own posting engine, at a smaller scale.

**Entry conventions that are not negotiable, because they are what makes a
register usable rather than just a grid**: Date auto-fills to today and
accepts a bare day-of-month as "this month"; Category autocompletes
against the Chart of Accounts' Income/Expense leaves (§1.1) as the user
types, so entering a check still never requires typing a full account
name; Tab/Enter advance field-to-field and a filled Payee can
autocomplete the LAST category used for that payee — the one piece of
"memorized transaction" behaviour cheap enough to include in wave 1
without building a separate memorized-transaction list.

---

## 10. Write Checks — a form over one Register row, not a second ledger

Per §2's reuse question, now answered: Write Checks is SHEET's `Data ▸
Form` shape (one record, New/Delete/Find, field-by-field) over exactly
one Register row — not a parallel data store. Saving a check POSTS it
(§1) the same way a Register row typed directly would.

**Fields**: Pay to the Order of; Amount (numeric); the written-word amount
line (`One hundred twenty-three and 45/100`) generated FROM the numeric
amount, never typed — a classic check-writing feature and a pure function
of the Amount field, so it costs a conversion routine and nothing in the
data model; Memo; Category or split (§9's same split engine, reused
rather than rebuilt); a Date; and a "To be printed" flag distinguishing a
check queued for batch printing from one already handwritten and simply
being recorded.

**Check printing itself is flagged, not designed, here.** Nothing in this
tree's package list (`/tmp/app_desc.txt`'s full inventory) names a printer
driver, and this plan does not assume one exists or costs what it would
take to add one. The "To be printed" flag and a check-number sequence are
cheap to carry in wave 2's data model regardless of whether printing ever
ships; the print mechanism is a separate question for whoever picks that
up, not assumed away by omission.

---

## 11. Reconcile — the real workflow, confirmed by research rather than guessed

This is the one feature where a search actually returned the live
mechanics (modern Quicken's own reconcile documentation, and the
mechanism has no reason to have changed): the user types a **Statement
Ending Balance** copied off the paper or online statement; the window
opens already showing the account's **Prior Balance** (the opening
balance going into this statement period) and starts the running
**Cleared Balance** at that same figure; the user checks off each
transaction that appears on the statement, one at a time, in any order;
each checkmark updates the Cleared Balance LIVE; a **Difference** field —
`Statement Ending Balance − Cleared Balance` — is always on screen,
targeting exactly `$0.00`.

**Screen**: §9's own Register grid, reused rather than rebuilt, with one
added column (a cleared mark, toggled by Space or a click) and a header
strip showing the four running numbers (Prior Balance, Statement Ending
Balance — typed once at the start, Cleared Balance, Difference) — the
same "reuse the grid, add exactly the one new column a feature needs"
shape as the Register's own Balance column (§2, §9). "Done" is live only
when Difference reads `$0.00`; finishing marks every checked row
Reconciled (a stronger, separate state from merely cleared) and that
state should make the row resist casual editing — reconciled history
silently drifting is exactly the kind of defect §1.3's standing
mutation-test rule exists to catch, applied here to a new state machine
rather than the posting engine.

**Not costed here, flagged for wave 3's own measurement**: real
Quicken/QuickBooks both allow forcing a reconciliation closed on a small
stubborn difference via an automatic adjustment entry. That is a genuine
feature decision (silently accepting drift vs. forcing the user to find
every cent) and belongs to wave 3's own design, not assumed into this
plan.

---

## 12. Account List — a plain view over wave 1's own tree, nothing new

The Asset/Liability leaves of §1.1's one tree (the accounts a user
actually opens, as opposed to the Income/Expense leaves that only ever
appear inside a Category picker), listed: Name, Type (§5's family tag),
Current Balance, an optional free-text Memo (account number, institution
name — never a real credential, this is a label field only). New/Edit/
Delete reuses §2's Form dialog. There is no new structure behind this
screen — it is wave 1's claim-backed tree (§3) with a view on it, which is
exactly why it is staged alongside the Register in wave 1 rather than
getting its own wave.

---

## 13. Budgeting (envelope style) — the rollover rule is the whole feature

The owner's own word was "envelope style," which names a specific,
researchable mechanic (the modern term for it comes from YNAB, but the
mechanic itself — unspent money carries forward as a per-category
balance rather than resetting to zero each period — is the actual
distinguishing behaviour, independent of which product popularized the
name) and is NOT the same as classic Quicken's plain planned-vs-actual
budget report, which does not roll over at all. The owner asked for the
rollover, so that is what gets built, named explicitly so it is not
quietly simplified away during wave 2.

**Mechanic, confirmed by research**: each period (monthly, the standard
unit), every Expense leaf (§1.1 — Budgeting needs no structure beyond
categories that already exist from wave 1) carries `Available = prior
Available + this period's Planned − this period's Actual spent`. A
positive Available carries forward untouched. A category that goes
negative (overspent) carries that deficit into the next period rather
than resetting — covering it (moving money in from another category, or
from next period's income) is the user's decision, not something the
software silently fixes, which is the actual mechanical meaning of
"envelope": a real envelope cannot go negative on its own, so a category
reading negative is the system faithfully reporting that the user spent
money that was not yet budgeted anywhere, which is information, not an
error state to hide.

**Screen**: one period at a time, a grid of categories (rows) by Planned /
Spent / Available (columns) — reusing §2's grid exactly as Register and
Reconcile do. A "Move Money" action, transferring Available between two
categories, is REQUIRED for the envelope mechanic to be usable in
practice (an overspent category needs somewhere for its cover to come
from) and is flagged here as part of wave 2's own scope, not an
afterthought — without it the rollover number is accurate but the user
has no in-app way to act on it.

---

## 14. Reports & Graphs — what is free, what needs a rule, and what is new work

Per §3's decision (SYLK out, `CHART.O88` as the viewer, no resident chart
engine), each report below is sorted by what it actually costs to
produce, not treated as one undifferentiated "Reports" bucket:

| report | source | cost |
|---|---|---|
| **Balance Sheet** | §1.2 — sum of Asset leaves minus Liability leaves | free: one tree walk, no date range even |
| **Profit & Loss** | §1.2 — sum of Income minus Expense leaves, date-ranged | free: the same tree walk with a date filter |
| **Trial Balance** | every leaf's own balance, no netting | free — the cheapest report of all, no logic beyond listing what §1.1's tree already holds |
| **Category Summary** / Income & Expense by category | Income/Expense leaves individually, not netted into one figure | free: §1.2's same sum, reported per-leaf instead of per-type |
| **Net Worth (over time)** | Balance Sheet's own figure, sampled per period | free to compute; the ONLY report that is naturally a graph rather than a grid, and the direct reason `CHART.O88` exists in this plan at all |
| **General Ledger** / Transaction List | a filtered, sorted dump of ledger rows | cheap, but genuinely NEW: these read individual postings, not tree sums, so they need their own query shape rather than reusing §1.2's walk |
| **Cash Flow** | Income/Expense sums, but must EXCLUDE transfers | needs one rule, not new data: a transfer is any posting whose BOTH sides are Asset/Liability leaves — it never touches an Income or Expense leaf at all (§1.1), so "is this a transfer" is already fully derivable from the tree structure and costs a filter predicate, not a new flag on every transaction |

**Screen**: a report picker (a menu, not a new widget class) prompts for a
date range where one applies, then either renders as a grid tab — exactly
like opening a sheet — for the text reports, or writes the SYLK file and
hands off to `CHART.O88` for Net Worth and any other report the user asks
to see as a graph. No report in this list requires inventing a second
data model; the General Ledger/Transaction List pair is the only new
QUERY shape, and it is still reading the same one ledger §1 already
commits to building in wave 1.
