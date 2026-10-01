# Finance September Update — Access Parity + Fiscal-Year Control

> **Status: PART-BUILT, NOT DEPLOYED.** GATE 1 has passed and the app-side change is done; no
> existing SQL object has been altered and no snapshot rebuilt, so the live portal still runs the
> pre-parity logic. **Read "As built — IN PROGRESS" at the foot first — it wins over everything above
> it**, and it is where the remaining work is listed.
>
> Written 2026-09-29, measured against production data. Sibling records: `financesqlupdate.md`,
> `financesqlupdatep2.md`, `financesqlupdatep3.md`, `updateviews.md`, `export.md`.

---

## Context

Two changes ship together.

**1. Access parity.** Finance's authoritative figures come from a hand-written query inside an MS
Access file, committed immutably at `sql/source/SQL Revised Allocation Oversight F.sql`
(SHA-256 `9f9f6158…f1d3ba`, acquired 2026-08-24). `prodfix.md:259` records that the Access file reads
the base tables with its own copy of that query — it does not read our views. The portal runs a
*corrected* derivation (`sql/FinanceLedger.sql` → `dbo.fn_FinanceLedgerSource`), and the two
disagree. Finance reconciles against the Access output, so the portal must match it — including where
the Access output is defective.

**2. Fiscal-year control.** Budget Allocations, Monthly Expenditure and Variance keep their year
banner unchanged. Encumbered Details and Routing Details lose the banner, year rail, prev/next
controls and page-level year keyboard navigation, and gain a required **Fiscal Year** dropdown in
their Filters section.

### Measured baseline — production, 2026-09-29

This box is the LOCAL TEST INSTANCE carrying CURRENT PRODUCTION DATA - `V200ICTF5FA0MEL\SQLEXPRESS`, SQL Server 2022 Developer Edition (EngineEdition 3). It is NOT the production server, which is `sqlapp\SQLEXPRESS`, Standard Edition (EngineEdition 2), on a separate DB box. Every measurement below is therefore production DATA taken on a replica, and the full deployment path can be rehearsed here safely. Both Agent job steps
last ran 2026-09-28 21:33:01 and 21:33:29, both `Outcome = OK`, same run. FY2026, unscoped:

| | Access draft | Portal today | Delta |
|---|---|---|---|
| rows / distinct accounts | 2,275 / 2,264 | 2,265 / 2,265 | +10 rows, −1 account |
| Allocation | 242,817,848.69 | 242,817,848.52 | −0.17 |
| YTDTotal | 254,553,116.94 | 254,553,116.94 | tie |
| **Approved** | 83,803,914.38 | 95,760,870.05 | **−11,956,955.67** |
| Routing | 12,637,933.09 | 12,637,933.09 | tie |
| Excess | 120,433,049.87 | 119,582,856.13 | −850,193.74 |
| AllocationBalance | 108,697,781.62 | 107,847,587.71 | −850,193.91 |

`0006CWebAppPostControls` holds exactly **one** row (PositionID 10108, H01/101/2001, active), so only
FFIGUERA1 has access; KCHARLES1 and SBHIM1 have none. **CLAUDE.md's "160 rows / KCHARLES1 /
32-of-128 institution-spanning pairs" note is stale** and must be corrected in this release. For
FFIGUERA1, FY2026 is 14 accounts and the sole difference is `Approved` 129,100.00 vs 193,650.00 on
`4-80400-H01-101-2001-00-000` — TTD 64,550.00, from eight lines on PO00000202871 with `Quantity` 1
and `QtyShipped` 2.

**Two independent confirmations, worth keeping as sanity anchors.** The Allocation delta is exactly
`0.17` — the one dropped account, nothing else, which means float summation contributed **zero** at
production scale. And `Excess` and `AllocationBalance` both move by ~850,193 **in the same
direction**, which is only possible from the split: dividing an account into an allocation-only half
and a YTD-only half inflates `MAX(0, A−Y)` and `MAX(0, Y−A)` simultaneously while leaving both column
sums intact.

**One figure that does not reconcile by subtraction, deliberately noted:** the Approved delta of
11,956,955.67 against a raw over-shipment of −17,363,584.00 (694 FY2026 lines, 62 accounts) leaves
5,406,628.33 unaccounted. The likely cause is lines on accounts that fail the `varianceLines`
reporting-line-3 join and so appear in neither total. **Do not chase this arithmetically** — the
`EXCEPT` suite in Part F is the proof, not the subtraction.

---

## Decisions locked

| # | Decision |
|---|---|
| D1 | Reproduce the Access output exactly, including the 11 split account rows. Do not merge or normalise. |
| D2 | Parity applies to **every** year the ledger exposes (FY2014–FY2026). Validate FY2026 as a gate, then one-time all-years rebuild. No mixture of old and new rules. |
| D3 | Parameterising the draft's hardcoded `FinancialYear = '2026'` and `EmployeeName = 'FRANCIS FIGUERA'` is expected. Authentication and authorisation stay enforced. |
| D4 | Gate F may aggregate the ledger side by `(FinancialYear, AccountNumber)` internally; that must not change displayed grain. |
| D5 | **Access join keeps `dbo.vw_WebAppUserAccess`** — 4-tuple `DISTINCT` plus both `IsActive` filters. Documented deviation from the draft's inline CTE. Identical figures today; prevents a deactivated account retaining data access. |
| D6 | ~~Gate 4e downgrades to a logged warning.~~ **Superseded — see A4.** Gate 4e is not a blocker; it is kept and *widened*. Nothing is downgraded or removed. |
| D7 | Requisition year options stay bounded to years the ledger also has, per user. Default current FY if available, else latest. `fy` preserved in URL and export. "Clear all" keeps the year. |
| D8 | Keep the `Financial Year` field in table data and CSV. |

---

## Part A — SQL parity

### A1. Rewrite `dbo.fn_FinanceLedgerSource` as a parameterised transcription

`sql/FinanceLedger.sql:150-460`. **This is a rewrite, not a patch.**

The deployed function has no `PIVOT` and no tall UNION: conditional `SUM` inside `glData`
(**257-278**), a `UNION` of account numbers as a key set (`accountBase`, **368-375**), `LEFT JOIN`s
back to three wide aggregates (**437-439**), and `AccountDescription` resolved *after* the joins by a
COALESCE chain (**386-391**) with no outer `GROUP BY`. Correction (a) at **88-93** exists specifically
to guarantee one row per account. We now need the opposite, so the organising idea has to go.

**Transcribe the draft's tall `UNION ALL` of three branches — but replace `PIVOT` with an explicit
`GROUP BY` + conditional `SUM`.** `PIVOT` is sugar for exactly that, so semantics are identical
(including NULL group keys). Three reasons to prefer the explicit form:

1. **The eight-column `GROUP BY` list *is* the specification of the row grain.** That the grain was
   an invisible emergent property of `PIVOT`'s implicit grouping is the root cause of this entire
   release. Encoding it invisibly again is how it gets broken by the next well-meaning edit.
2. It drops the `FORMAT(TRXDate,'MMM')` dependency. Keeping `MONTH()` is **not** a parity deviation:
   under an English session `FORMAT` maps 1:1, and under a non-English session language it returns
   abbreviations matching no pivot column and produces **silent zeros**. Byte-identical where the
   draft works, correct where it does not.
3. `AllConsolidated` carries fifteen `MonthN` values, three of which are measure literals
   (`'Allocation'`, `'Approved'`, `'Routing'`). Conditional `SUM` discriminates on a branch tag rather
   than string-matching a label, removing the "month abbreviation collided with a measure name" class.

**Parameterisation and sargability.**

- `glData` (draft line 10) and `allocationData` (82): substitute `@FinancialYear` directly; both are
  already sargable.
- **Encumbrance: keep the deployed `DATEFROMPARTS` bounds** (`FinanceLedger.sql:362-366`), not the
  draft's non-sargable per-row `CASE` (draft 36-40, 68-72). **Verified equivalent 2026-09-29:** the
  two forms select an identical line set for every year FY2014–FY2026 across all 108,435 open
  encumbrance lines — 0 lines selected by one and not the other, in either direction — and
  `ReqDateCreated` is never NULL. `FinanceRequisition.sql:465-470` establishes it is already a `date`,
  so the draft's `CAST` was always a no-op.
- With bounds, `FinYear` is constant for the query. Project `CONVERT(varchar(10), @FinancialYear)`
  rather than the draft's `A.FinYear`, which is an `int` and would win UNION ALL datatype precedence
  over `0098AFinGLMaster.FinancialYear`, silently making the output column an `int` against a
  `varchar(10)` snapshot column.
- **Do not** introduce a nullable all-years parameter — `FinanceLedger.sql:72-76` rejects that
  pattern. Keep the year-at-a-time loop in `usp_RefreshFinanceLedgerSnapshotAll`.

### A2. Grain versus labels — the distinction the whole change turns on

**Grain** = anything in the `GROUP BY`. Money and row identity. Must match Access byte-for-byte.
**Labels** = the four segment *names*, `ClusterName`/`InstitutionName`/`ResponsibilityName`/
`DepartmentName`. Neither money nor grain, therefore **outside the parity mandate**.

**Keep the deployed label chain** — sentinel `NULLIF` normalisation, the `deptSeg`/`respSeg`/`instSeg`
segment fallbacks, and `ISNULL(..., 'UNDEFINED')`. All three are strict improvements and none affects
a figure. Consequence: gate 4b needs **no change** and `@MaxUndefinedPercent` stays at 2.00; the
recorded percentage moves only because the denominator grows by ~10 rows.

> If that is overruled and the draft's raw NULL labels are taken verbatim, three things follow and all
> are worse: 4b's predicate tests `= 'UNDEFINED'` only, so NULLs make the gate go **blind** rather
> than fire; `MonthlyExpenditureController.php:256` and `VarianceController.php:267` both
> `->pluck('DepartmentName')->filter()`, silently dropping NULL departments from the dropdown so those
> rows are unreachable by filter while still counted in the totals row; and Finance gains nothing they
> reconcile on.

**But `AccountDescription` is a `GROUP BY` key, so it is grain, not a label** — it must become
verbatim per-branch. Same for the three segment ID columns.

### A3. The eight grain columns, expression by expression

The draft's internal inconsistency is real and must be replicated: COA segments for the allocation
branch, fixed byte offsets for GL and encumbrance.

| Grain column | GL branch (draft 7-8, 177) | Allocation branch (183-184) | Encumbrance branch (196-197 via 25) |
|---|---|---|---|
| `FinancialYear` | `0098AFinGLMaster.FinancialYear` | `0040CBudgetsAllocation.FinancialYear` | `@FinancialYear` |
| `AccountID` | `0098AFinGLMaster.AccountID` | `coaData.AccountLineID` | `coaData.AccountLineID` |
| `AccountNumber` | GL `AccountNumber` | `allocationData.AccountNumber` | `0040DBudgetsEncumbrance.GLAccount` |
| `AccountDescription` | GL `AccountDescription` (raw) | `coaData.AccountDescription` | same as allocation |
| `AccountN` | `substring(AccountNumber, 3, 5)` | `coaData.AccountSegment2` | `substring(GLAccount, 3, 5)` |
| `InstitutionID` | `substring(AccountNumber, 9, 3)` | `coaData.AccountSegment3` | `substring(GLAccount, 9, 3)` |
| `ResponsibilityID` | `substring(AccountNumber, 13, 3)` | `coaData.AccountSegment4` | `substring(GLAccount, 13, 3)` |
| `DepartmentID` | `substring(AccountNumber, 17, 4)` | `coaData.AccountSegment5` | `substring(GLAccount, 17, 4)` |

`coaData.AccountDescription` is **not** the COA mirror's own description — it is
`0030AEAccountNameCorrections.COALESCE(EditedAccountDescription, AccountDescription)` joined on
`AccountSegment2`, with **no fallback** (draft 88-98).

**Measured split drivers, FY2026** — so a non-empty `EXCEPT` can be diagnosed:

| Candidate driver | Accounts affected |
|---|---|
| `AccountID` (GL vs COA `AccountLineID`) | **0** |
| Raw `0030ADGPCOA.AccountDescription` vs GL master | **0** |
| **Corrections-driven description vs GL master** | **43** (7 carrying both GL and allocation activity) |
| Segment derivation on short accounts | 2 accounts are 26 chars, 2,263 are 27 |
| Segments with two distinct final descriptions (fan-out risk in the draft's `SELECT DISTINCT`) | **0** |

So the split is a **description** effect originating in the corrections table, plus a segment effect
on short accounts. Verified example `4-87300-C20-101-2004-00-000`: "RENT & ACCOMODATION"
(YTD 253,000.00, Allocation 0) and "RENT & ACCOMMODATION" (Allocation 521,336.04, Approved
138,000.00, YTD 0) — one missing M.

**Three consequences to accept and document, all of them Access behaviour:**

1. **The 26-character accounts split too.** Byte offsets slide, COA segments do not. The GL half may
   also vanish: a slid `AccountN` fails the `varianceLines` INNER JOIN (draft 226).
2. **`4-80300-H01-401-0627-00-000` needs no special handling.** Its allocation-branch COA segments are
   NULL, so it lands in the snapshot with NULL segments and is invisible through `vw_FinanceLedger`'s
   three-way access join (`FinanceLedgerOversightCutover.sql:135-138`) — the same net effect as the
   draft's INNER `userAccess` discarding it. **Parity therefore does not require moving the access
   join out of the view**; correction (b) survives intact.
3. **On-screen `AccountDescription` changes for the corrected accounts.** GL-sourced rows now show
   raw `0098AFinGLMaster.AccountDescription`. This is a visible change to Finance beyond the money,
   and it is the same mechanism that produces the split they asked for. Announce it.

**Keep two derivations side by side, with the reason written in the function:** the draft's per-branch
expressions produce the eight **grain** columns; the deployed `CHARINDEX` splitter
(`FinanceLedger.sql:424-435`) continues to produce the **label lookup keys** for
`deptSeg`/`respSeg`/`instSeg`. Two splitters in one function is exactly what someone tidies up.

### A4. `AccountID`, and the schema change

Add `AccountID` **nullable** to `dbo.FinanceLedgerSnapshot` *and* `dbo.FinanceLedgerSnapshot_Staging`,
and to both explicit column lists in `usp_RefreshFinanceLedgerSnapshot` (**714-730**, **817-834**).
**Alter both tables before altering the function** or the next refresh throws `51001`.

It differs on 0 accounts today, so it cannot currently affect grain — but it *is* a `GROUP BY` key in
Access, and carrying it structurally is better than carrying a warning counter: if GP ever diverges,
Access splits and so do we, with no code change.

Read the declared type off `sys.columns` for both `0098AFinGLMaster.AccountID` and
`0030ADGPCOA.AccountLineID` and **`CONVERT` both branches explicitly to one declared type**. The drift
guard compares **names only** (**696**), so a type mismatch is silent — and **354-357** documents this
trap already being hit once with `decimal(38,8)`.

**Do not add `AccountID` to `dbo.vw_FinanceLedger`.** Keep that view's column list byte-identical: it
is what makes the app rollback fully independent of the SQL rollback, and no page displays it.

Also add to `dbo.FinanceLedgerRefresh` (idempotent `IF COL_LENGTH(...) IS NULL ALTER`, matching
**539-547**): `AccountsLoaded int` and `SplitAccountCount int`, feeding the new gate below and
`ledger:status`.

### A5. Money and rounding

Byte parity requires the draft's **per-line** `ROUND(((Quantity − ISNULL(QTYShipped,0)) * UnitCost), 2)`
(draft 28/60) and its **unfloored** balance — replacing the `CROSS APPLY` pair at
`FinanceLedger.sql:343-361`. Then `encumberanceData` rounds each status total to 2dp and rounds again
summing `AP+PO` (draft 17-18), and the outer projection rounds a third time (151-161). Transcribe all
of it.

**Float vs `decimal`:** transcribe the draft's float arithmetic with its `ROUND`s, and wrap only the
**final projected columns** in `CONVERT(decimal(19,4), ...)` so the snapshot column types are
untouched. Converting a value that has just been `ROUND(x,2)`-ed is exact at these magnitudes, so this
yields byte parity *and* a stable stored type. Justified by measurement: the Allocation delta is
entirely the dropped account, so float summation contributes zero at production scale.

Residual risk: `SUM(float)` is order-dependent, so a parallel plan can wobble the last bits and a
`.xx5` boundary could round differently between runs. Mitigated by the determinism test (F2/A6), not
by a code change.

### A6. Gates — keep, widen, add. Nothing is downgraded or removed.

| Gate | Location | Action |
|---|---|---|
| `51004` COA duplicate accounts | `FinanceLedger.sql:628-632` | **KEEP**, never `@Force`. Now guards **three** `coaData` joins, not one. |
| `51005` corrections conflict | **634-641** | **KEEP**, never `@Force`. Now load-bearing: the draft's `SELECT DISTINCT` (draft 94-97) fans out where the deployed `GROUP BY`+`MIN` did not, and `coaData` is joined three times (draft 190, 210, 221). |
| `51006` shipment conversion | **650-662** | **KEEP unchanged.** `sql/00_PreflightChecks.sql` CHECK 16 stays too. |
| `51007` duplicate shipment key ∩ open line | **668-691** | **KEEP and WIDEN** — drop the FY bounds at **679-680** for the all-years form already used at `FinanceRequisition.sql:391`. See the note below. |
| `51001` schema drift | **697-709** | **KEEP**; add `AccountID` to both tables first, with an explicit type. |
| 4b `@MaxUndefinedPercent` | **780-783** | **KEEP default 2.00**; re-baseline the recorded value per year. No change needed given A2. |
| 4c encumbrance zero-collapse | **790-792** | **KEEP.** |
| `@MaxDropPercent` / `@MaxMovePercent` | **761-771** | **KEEP defaults.** FY2026: rows *rise* +10 so the drop gate cannot fire; Allocation +0.00000007%; YTD 0%; Approved −12.5%, inside 25%. **Closed years may breach 25% on Approved** — `@Force = 1` for the one-time all-years rebuild only. |
| **NEW `51008`** true fan-out | after 4c | **ADD**, never `@Force`. `GROUP BY` all eight grain columns `HAVING COUNT(*) > 1` → abort. This replaces the old "two rows per account = doubling" assumption, which the split legitimately breaks. |
| **NEW `@MaxSplitAccounts`** | new parameter | **ADD.** Count accounts with >1 row, record as `SplitAccountCount`, abort above the ceiling. Baseline per year from the rebuild; FY2026 = **11**. An unexplained jump is the new fan-out signal. |
| Cutover check #2 | `FinanceLedgerOversightCutover.sql:161-164` | **RE-SCOPE** to all eight grain columns. As written it groups by `(FinancialYear, UserName, AccountNumber)` and will report 11 false "FAN-OUT — money is doubling" hits forever. This script is re-run on any future access change; a check that cries wolf is how the real one gets ignored. |
| Gate A3 (Phase 2) | `FinanceRequisition.sql:381-402` | **KEEP unchanged**, already all-years. |
| `#Shipments` unique index | `FinanceRequisition.sql:424` | **KEEP.** |
| Gate F | `FinanceRequisition.sql:691-769` | **CHANGE the ledger side only** — see A7. Never `@Force`. |

**Why gate 4e is not a blocker, and why the shipment pre-aggregate stays.** `sql/FinanceLedger.sql:668-691`
does not count duplicate `(PONumber, POLineID)` keys — it counts *open encumbrance lines that match
one*. **Measured 2026-09-29: zero, in every fiscal year.** Where a key is not duplicated there is
exactly one shipment row per key, so the draft's raw `LEFT JOIN` and the deployed
`encumbranceShipped` pre-aggregate (**316-323**) return **identical results**. The FFIGUERA1 case
proves it: eight lines with `Quantity` 1 and `QtyShipped` 2 produced −64,550.00 = −1 × UnitCost × 8.
Two shipment rows of 1 each would instead have given `ActBalance` 0 twice and cost 0. So they are
single rows carrying 2.

Therefore keep the pre-aggregate and `#Shipments` with its `UNIQUE CLUSTERED INDEX` — the
index-as-assertion survives — and **widen** 4e rather than weakening it, because removing the zero
floor *unmasks* this bug class: previously both treatments gave 0 for an over-shipped line, so a
fan-out was invisible; now it would be visible money. **The only encumbrance behaviours that actually
change are the zero floor and the per-line `ROUND`.**

### A7. Gate F — two edits, both mandatory, in lockstep

**A7a — aggregate the ledger side.** Replace `FinanceRequisition.sql:724-729`:

```sql
    FULL OUTER JOIN (
        SELECT FinancialYear, AccountNumber,
               SUM(Approved) AS Approved,
               SUM(Routing)  AS Routing
        FROM dbo.FinanceLedgerSnapshot
        GROUP BY FinancialYear, AccountNumber
    ) AS p1
```

Exactly what D4 permits: the gate aggregates internally, `vw_FinanceLedger` is untouched, displayed
grain unchanged. Without it a split account yields two `p1` rows against one `p2` row and **both**
report a drift equal to the other half — so all 11 fail every night, `@Force`-proof.
`@reconCompared` falls by the number of splits; it is recorded, not gated. **Comment why the
`GROUP BY` is there**, or it will be removed as redundant.

**A7b — unfloor Phase 2's `ActCost`/`ActBalance`** at **572-585**, to the draft's expression
*including* the per-line `ROUND(...,2)`, keeping `#Shipments`. Do A7a without A7b and gate F fails on
the 62 over-shipped FY2026 accounts; A7b without A7a and it fails on the 11. Rewrite the
"Do not simplify this back" block at **562-571** to say what the rule now is and why.

**Knock-on effects of A7b, same release:**

- 🔴 **`app/Concerns/DerivesRequisitionDetail.php:60-61` is a real logic bug once the floor goes.**
  `PartiallyReceived` is `QtyShipped > 0 && Quantity > 0`. An over-shipped line now has
  `Quantity < 0`, so it is classed as *fully unshipped* and muted in the table. Fix with `!== 0.0`,
  or better a third `OverShipped` state so the row reads honestly. Its docblock (**18-23**) also
  becomes false.
- `CLAUDE.md` lines 169 and 213 both state the floor as a rule.
- `sql/Phase2ReconciliationTest.sql` (**81, 128, 280, 327**) and
  `sql/Phase2RequisitionDetail_{Approved,Routing}{,_NoScope}.sql` (2 each) — all ten in the same
  commit. These are documented as the reference queries the Phase 3 columns *are*; leaving them
  floored makes the repo self-contradictory at exactly the point someone consults it during an incident.
- `resources/js/Components/RequisitionDetailView.vue` — the gold `ExtendedCost` rule and the frozen
  totals row must not make a negative committed total look like a rendering fault.

### A8. Access join — keep `dbo.vw_WebAppUserAccess` (D5)

Zero difference in rows or money today: one `0006C` row means nothing for `DISTINCT` to collapse, and
FFIGUERA1 is active or could not log in. Proven by test A2, not assumed. The differences are latent
and all bad:

1. The draft has no `0006A.IsActive` predicate (draft 128-143) — a **deactivated** account would
   retain full data access, violating D3.
2. No `DISTINCT`. `0006C` held 6 rows in early 2026-08, 160 on 2026-08-25, 1 today — it moves. The
   day it regains multiple rows per 4-tuple, the draft doubles every figure. This already cost
   TTD 99.1M of cross-institution exposure once.
3. The draft filters `C.EmployeeName = 'FRANCIS FIGUERA'` from `ArrearsDatabase.dbo.0002AEmployees`.
   Parameterising *that* would be a regression: `EmployeeName` is a LEFT JOIN result that can be NULL,
   is not unique, and is not what the app authenticates with. Join on `UserName`, as
   `vw_FinanceLedger` already does. The parity tests carry the `EmployeeName` → `UserName` mapping as
   a **fixture**, asserting it is 1:1 before trusting A2.

---

## Part B — Fiscal-year control on the two requisition pages

Everything lands in **`resources/js/Components/RequisitionDetailView.vue`** plus a `fyNav` removal in
three files. `FiscalYearHero.vue`, `useFiscalYearNav.js` and `useLedgerTable.js` are shared with the
four pages that keep the banner — **do not modify them**, just stop calling them.

### B1. Remove the banner

- Delete the `<FiscalYearHero>` invocation (**230-236**) and its import (**5**). Passing `:years="[]"`
  hides the rail but keeps the prev/next chevrons and numeral, which the brief rules out — so the
  component goes entirely.
- `useTableScroll` (**117-123**): drop `onPrevYear`/`onNextYear` and the `stepYear` helper
  (**112-115**). `useTableScroll:83-84` guards with `if (step && step() !== false)`, so omitting them
  leaves arrows scrolling columns inside the table and inert elsewhere.
- Re-word the hint at **450-458**; it currently implies arrows also step years.

### B2. Add the Fiscal Year dropdown

`filters.fy` **already exists** (**75**) and `goToFy` (**102-105**) already sets it and applies. **The
server needs no change** — `resolve()` reads `$request->input('fy')` through
`ResolvesFiscalYear::resolveFiscalYear()`, which regex-gates a four-digit string and falls back.

First cell of the filter grid (**360**), cloning the existing control markup exactly (label
`class="block text-xs font-medium text-tx-subtle mb-1"`, the shared `<select>` class string ending
`focus:ring-amber-500/60`):

```html
<div>
    <label class="block text-xs font-medium text-tx-subtle mb-1">Fiscal Year</label>
    <select v-model="filters.fy" @change="applyFilters"
        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
        <option v-for="year in years" :key="year" :value="String(year)">FY {{ year }}</option>
    </select>
</div>
```

No "All Years" option — the year is required and always set.

**Grid re-cut.** Today `lg:grid-cols-6` with six `lg:col-span-2` children = three clean rows of two; a
seventh cell orphans. Change to `lg:grid-cols-4` with Account spanning 2 and the rest spanning 1:
Fiscal Year / Cluster / Institution / Department, then Account (×2) / Vendor / Status — two clean rows.

### B3. Filter-state consistency

- **Do not** add `fy` to `activeFilterCount` (**131-135**) — it is always set, so the badge would read
  1 on a virgin page and "Clear all" would always show.
- `clearFilters` (**139-145**) already preserves `fy`. No change.
- **Stale-filter re-sync (new).** `applyFilters` uses `preserveState: true`, so the local `filters`
  ref survives the visit. When the year changes and a categorical filter is no longer a valid option,
  the server nulls it in the returned prop but the local ref keeps the old value — the `<select>` then
  shows a value absent from its options (renders blank) while results are unfiltered. Pre-existing,
  inherited from the hero, but the brief explicitly asks that invalid filters be discarded on a year
  change: add a `watch` on `() => props.filters` re-seeding the local ref from the server's normalised
  values. Confirm whether the three banner pages share the defect before touching them.

### B4. Relocate the `unsummarisedYears` notice

Currently **238-249**, under the hero. With the hero gone it is orphaned between the page header and
the KPI cards. Move it directly beneath the new select. Keep the copy — bounding the year list without
naming the withheld years is indistinguishable from lost data.

### B5. Drop `fyNav` from these two pages only

- `RequisitionDetailController.php`: remove `$fyNav = …` (**267**), the `resolve()` return entry
  (**351**), the `index()` prop (**99**), the `unavailable()` prop (**565**), and the docblock line
  (**249-255**).
- `Pages/Expenditure/Encumbered Details.vue` and `Routing Details.vue`: remove the prop and binding.
- `RequisitionDetailView.vue`: remove the `fyNav` prop (**60**).
- **`ResolvesFiscalYear::fiscalYearNav()` stays** — four other pages use it.

`index()` and `unavailable()` must stay key-for-key identical; a test asserts it.

### B6. Ordering tiebreak — required by the split, easy to miss

`MonthlyExpenditureController.php:346-349` and `VarianceController.php:374-377` both end
`->orderBy('AccountNumber')`. Two split rows are therefore adjacent in **non-deterministic** order,
and pagination is in-memory over that ordering — which breaks `export.md` §11.3's "`?page=1` and
`?page=2` byte-identical" invariant. Add `AccountDescription` as a final tiebreak in both.

Vue is safe: every table row keys on `:key="rowIndex"` (`Monthly Expenditure.vue:425`,
`Variance.vue:522`, `All Budget Allocations.vue:357`), not on `AccountNumber`, so there is no
duplicate-key breakage — but the ordering must still be pinned.

---

## Part C — Tests

**The honest framing, and it belongs in the runbook: the money rules that moved live entirely in SQL,
and no PHPUnit test can prove Access parity.** The SQL suite in Part F is the real test suite.
PHPUnit's narrower job is to prove the PHP layer does not re-break what SQL now gets right. Nobody
should read a green `php artisan test` as a parity signal.

**Offline (`tests/Unit/`) — the only guaranteed coverage, so these are mandatory**

- `DerivesAllocationLinesTest`: a fixture where the same `AccountNumber` appears **twice** with
  different `AccountDescription`. Assert `allocationTotals()` sums both rows (no dedupe),
  `exceededCount` counts both, and `deriveAllocationLine()` stays row-local. The only automated
  statement anywhere that the split grain is handled.
- `DerivesRequisitionDetailTest`: negative `ExtendedCost`/`Quantity` fixtures. Assert
  `requisitionTotals()['committed']` can be negative, unique counts are unaffected,
  `largestRequisitionLine()` still picks the max (not max absolute), and — the A7b bug —
  `PartiallyReceived` is **true** for `QtyShipped = 2, Quantity = -1`.
- `StreamsCsvTest`: an explicit negative-money case through `csvMoney()`, asserting `-1234.56` is
  emitted raw and never formula-escaped. Negatives move from theoretical to routine.

**Feature tests (skip without SQL Server)**

- `RequisitionDetailTest.php`: remove `'fyNav'` from `PROPS` (**44**) or
  `test_the_page_renders_with_the_full_prop_shape` fails. Rename
  `test_the_fiscal_year_rail_is_bounded_to_years_the_ledger_has` (**92-125**) to `…dropdown…`; its
  assertions still hold. **Add:** `?fy=<valid>` selects that year; `?fy=9999` and `?fy=abc` fall back
  without error.
- `MonthlyExpenditureTest` / `VarianceTest`: **guard the premise and skip.** If the FY under test
  contains a duplicated `AccountNumber`, walk every page asserting no repeated composite key, that the
  union count equals `stats.accountCount`, and that the totals row equals the sum over all pages.
  Otherwise `markTestSkipped()`. For FFIGUERA1's 14 FY2026 accounts there is likely **no** split, so
  this will skip on production data — honest, and better than a `foreach` that silently passes over
  nothing (PHPUnit reports that as *risky*, not failing).
- `VarianceTest:158-187` should continue to hold — the `Excess`/`AllocationBalance` floors are
  unaffected and `ActualExpenditure = YTDTotal + Approved` survives `Approved` going negative. Confirm
  rather than assume; **180**'s "Balance went negative" is precisely the assertion that catches a
  floor removed in the wrong place.
- `CsvExportTest`: re-run all 28 invariants. **Nothing hardcodes `41,936,916.59` or `4,512,250.19`** —
  every assertion is relational against `vw_FinanceLedger`, so they re-derive at the new values.

**Run discipline.** Full suite with `SQLSRV_HOST` reachable, **0 skipped**, before and after — the only
result that means the ledger pages were exercised. Re-measure the wall clock rather than quoting
5,478s. `./vendor/bin/pint` on changed files only.

---

## Part D — Documentation

- **`CLAUDE.md`**: the stale access-mapping paragraphs (**158-161**), the balance rule (**167**), the
  encumbrance floor (**169**), the splitter note (**199**), the Phase 3 rules (**206-213**), and the
  Deployment state section.
- **New `oversight-parity-steps.md`** — the `[DB]`/`[WEB]`-tagged runbook, in the shape of
  `oversight-prod-steps.md` / `instructionsphase2.md`.
- **This document** gains an **As built** section at the foot, which wins over the plan above it.
- `financesqlupdate.md`, `financesqlupdatep2.md`, `financesqlupdatep3.md`, `export.md`.
- `sql/source/README.md` — the drafts are now the *implemented* basis, not a superseded input.
- ⭐ **`Overview.md`** — the document handed to Finance, and the highest-value non-code deliverable
  here. It must explain the split rows, the negative encumbrances and the changed account
  descriptions in plain language, or all three will be reported as portal bugs.

---

## Part E — Deployment

Two servers. Refresh is Agent job `SWRHA Finance - Ledger Refresh` (step 1 ledger, step 2
requisition). This release also carries **Phase 3, the 7→6 rename and the CSV export** — committed at
`8405c8a`/`1cc2a87`, never deployed.

### Phase 0 — before anything touches production

1. **Fix the Vite manifest bug first; it blocks the web release, which blocks everything.**
   `app.blade.php` calls `@vite(['resources/css/app.css','resources/js/app.js'])` but `vite.config.js`
   declares only the JS entry, so a fresh build on the deploy box throws `ViteException` on **every**
   page. `app.js` already does `import '../css/app.css'`, so drop the CSS entry from `@vite()`.
   Verify with `rm -rf public/build && npm ci && npm run build` and grep the manifest. The suite
   cannot catch this (`withoutVite()`), so the check is manual and non-negotiable.
2. Build and validate the whole change **on the dev replica first** — full function, full all-years
   rebuild, full parity suite. Do not discover the FY2014 cases on production.
3. Agree the open questions at the foot of this document.

### Phase A — web server, ordinary app release, its own day

4. Merge `feature/ledger-oversight-update` (**the user does merges**). Deploy: `composer install
   --no-dev -o`, `npm ci && npm run build`, `php artisan optimize:clear`, `php artisan cache:clear file`
   (the filter caches are on the `file` store; plain `cache:clear` will not touch them).
5. Smoke all six pages and all six export routes in a browser, and open one CSV in Excel — the one
   item `export.md` §11 still lists as outstanding.

Rationale for app-first: Phase 3, the rename and the export change **no SQL object** and are already
verified against the *current* data shape, so shipping them against the data they were tested on
isolates their failure modes from the parity change. The forward-compatible parts they must carry
(B6's ordering tiebreak, the A7b `PartiallyReceived` fix, copy changes) are harmless on old data.

### Phase B — DB server, the parity change, after-hours window (~1 hour)

6. `php artisan down --retry=60`. Between the ledger and requisition rebuilds the two snapshots
   legitimately disagree and the Phase 3 pages would show floored detail against unfloored summary.
7. `EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh', @enabled = 0`. **Disable
   the whole job, not just step 2** — step 1 alone leaves the snapshots from different runs and
   `ledger:status` red.
8. **Back up three ways:** script the current definitions of `fn_FinanceLedgerSource`,
   `usp_RefreshFinanceLedgerSnapshot`, `usp_RefreshFinanceRequisition` via `OBJECT_DEFINITION` into a
   file **committed to the repo**; `SELECT * INTO dbo.FinanceLedgerSnapshot_ParityBackup FROM
   dbo.FinanceLedgerSnapshot` and the same for `FinanceRequisitionSnapshot` and both `*Refresh` logs;
   record the pre-change git SHA.
9. **Validate before installing.** Create the new logic as a *separate* object
   `dbo.fn_FinanceLedgerAccessParity(@FinancialYear)` and run F2's A0-A4 for **FY2026 only** against
   it. **GATE 1: all `EXCEPT` results empty both directions, plus count and multiplicity equality, and
   FY2026's figures reproduce to the cent.** Nothing live has changed — reversible by `DROP FUNCTION`.
10. `ALTER TABLE` to add `AccountID` to snapshot **and** staging, and
    `AccountsLoaded`/`SplitAccountCount` to `FinanceLedgerRefresh`. **Then** `CREATE OR ALTER FUNCTION
    dbo.fn_FinanceLedgerSource` and `ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshot` (widened
    4e, new `51008`, `@MaxSplitAccounts`, new columns in both INSERT lists). **Tables before function**
    or `51001` throws.
11. **FY2026 only:** `EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026'`. `@Force`
    should not be needed — if it aborts, read the message before reaching for it.
    **GATE 2, the deployment gate:** re-run A1-A4 *against the snapshot*, plus A7 (fan-out) and
    cutover check #1 (every user's accessible-account count > 0). Stop on any failure; one year has
    changed and rollback is one `DELETE`+`INSERT` from `_ParityBackup`.
12. **Only after GATE 2:** `EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 1`. All years.
    `@Force` **is** needed — closed years will breach `@MaxMovePercent` on Approved. Budget ≥45 min and
    **re-measure**; the wider grain and per-branch derivations add work the old 102-256s figures do not
    describe. `SnapshotAll` catches per-year failures and throws at the end, so **read
    `dbo.FinanceLedgerRefresh` for `Outcome = 'ABORTED'`** rather than trusting the absence of an error.
13. `ALTER PROCEDURE dbo.usp_RefreshFinanceRequisition` (A7a + A7b) then
    `EXEC dbo.usp_RefreshFinanceRequisition @Force = 1`. **GATE 3: `ReconMismatches = 0` **and**
    `ReconStaleYearDrift = 0`** in the newest `FinanceRequisitionRefresh` row. This is the strongest
    moment in the release: every year's ledger was refreshed minutes ago, so gate F's 36-hour
    freshness window covers FY2014-FY2026 simultaneously — the only time it ever will. Read
    `ReconAccountsCompared` too; a suspiciously small number means the `fy` INNER JOIN is excluding years.
14. `php artisan up`. Re-enable the Agent job and **run it manually once end to end under the Agent's
    own credentials**. Both steps `Outcome = OK`, and from the web server `php artisan ledger:status`
    exits 0 reporting both snapshots from the same run.
15. 🔴 **Register the monitoring.** `CLAUDE.md` calls this the biggest open item in the project and it
    has been open since 2026-08-26. This release changes every money figure on production and adds a
    nightly gate that can abort for a new reason, with no alerting. Run
    `scripts/register-health-check-task.ps1` on the web server and apply `sql/FinanceDatabaseMail.sql`
    on the DB server **as part of this window** — or state explicitly in the runbook that it is
    deferred a fourth time.
16. Watch **two unattended nightly runs** before declaring done, one of which must exercise the
    1st-of-month branch (`FinanceLedgerAgentJob.sql:220-235`). Force one manually if the release does
    not span a 1st.
17. **Finance sign-off** on FY2026 against Access before announcing.

Do **not** add a `Schedule::command('ledger:refresh')` entry — it would double-schedule the Agent job.

---

## Part F — Verification

### F1. The parameterised verbatim draft

New `sql/ParityVerbatimDraft.sql` — the immutable source copied byte-for-byte with **exactly two**
literal substitutions: `'2026'` → `@FinancialYear` (draft lines 10, 40, 72, 82) and
`'FRANCIS FIGUERA'` → `@EmployeeName` (line 143). The header records the source SHA-256 and lists the
substitutions so the diff is auditable. `@Scoped = 0` drops the final `INNER JOIN … userAccess`
(draft 227-231) for the unscoped test.

Mechanics already proven: inject `INTO #draft` before the draft's final `FROM (` (original line 174)
to capture the unmodified script's output.

### F2. The tests — `sql/ParityReconciliation.sql`, read-only, writing only to `dbo.FinanceLedgerParityResult`

**A0 — structural.** `sys.dm_exec_describe_first_result_set` over the draft vs `sys.columns` over
`FinanceLedgerSnapshot`, both directions, on name **and declared type**. Catches the `AccountID` type
ambiguity before any money comparison.

**A1 — unscoped, per year.** Full grain + money projection (8 grain columns, `Oct`-`Sep`, `Q1`-`Q4`,
`YTDTotal`, `AcutalYTDExpense`, `Allocation`, `Approved`, `Routing`, `ExcessTotals`,
`TrueBalanceOfAllocation`), `EXCEPT` both directions.

> ⚠️ **`EXCEPT` alone is not sufficient, and this is the easiest thing in the plan to get wrong.**
> `EXCEPT` is `DISTINCT`-based, so it cannot see a row duplicated identically on one side — and row
> multiplicity is precisely what this release is about. Pair it with (i) `COUNT(*)` equality and
> (ii) a per-grain-key multiplicity comparison: `SELECT <8 grain cols>, COUNT(*) … GROUP BY …` on both
> sides, `FULL OUTER JOIN`ed, asserting equal counts.

**A2 — per user, per year.** Scoped draft vs `vw_FinanceLedger WHERE UserName = @UserName`. First
prove the fixture: `SELECT UserName, EmployeeName FROM vw_WebAppUsers WHERE EmployeeName = @EmployeeName`
returns exactly one row (today `FRANCIS FIGUERA` / `FFIGUERA1`). A2 is also what proves the A8 access
decision costs nothing — if `vw_WebAppUserAccess` and the inline CTE disagreed, A2 would be non-empty.

**A3 — aggregate tie-out, per year.** `COUNT(*)`, `COUNT(DISTINCT AccountNumber)`, and `SUM` of the six
money columns, with signed deltas. FY2026 expected: **2,275 / 2,264 / 242,817,848.69 /
254,553,116.94 / 83,803,914.38 / 12,637,933.09 / 120,433,049.87 / 108,697,781.62**. Put this at the
top of the output — it is the human-readable one.

**A4 — grain assertion.** `GROUP BY AccountNumber HAVING COUNT(*) > 1` with
`STRING_AGG(AccountDescription, ' | ')`. FY2026 must return exactly **11**, including
`4-87300-C20-101-2004-00-000` with both spellings and the money divided as measured. Separately assert
`4-80300-H01-401-0627-00-000` is absent or present with NULL segments matching no access row.

**A5 — Phase 2 ↔ Phase 1.** Gate F's own query with the aggregated ledger side, read-only per year.
0 mismatches, 0 stale drift.

**A6 — determinism.** Build FY2026 twice into two scratch tables, `EXCEPT` both ways, empty. The only
defence against float non-determinism under a parallel plan (A5 of Part A).

**A7 — true fan-out.** The re-scoped cutover check over all eight grain columns plus `UserName`. Empty.

**A8 — the loop.** A cursor over FY2014-FY2026 running A1/A3/A4 into `FinanceLedgerParityResult`. The
draft is expensive per year; expect this to be the long pole. **Run it on the replica first so the
window is booked against a known runtime.**

### F3. Acceptance criteria

1. A0 clean on names **and** types.
2. A1 empty both directions **plus** `COUNT(*)` equality **plus** per-grain-key multiplicity equality,
   every year FY2014-FY2026.
3. A2 empty both directions for every `(UserName, FinancialYear)` pair with any row in
   `vw_WebAppUserAccess` — **today that is one pair per year; say so in the report** rather than
   letting "all users pass" imply breadth it does not have.
4. A3 deltas exactly `0.00` on all six money columns, every year; FY2026 reproduces the eight figures
   to the cent.
5. A4: exactly 11 splits in FY2026; every split in every other year individually named and explained
   in the As-built record. **An unexplained split is a stop.**
6. A5: `ReconMismatches = 0`, `ReconStaleYearDrift = 0` immediately after step 13.
7. A6 and A7 empty.
8. Cutover check #1: no user's accessible-account count is zero.
9. `php artisan ledger:status` exits 0, both snapshots same run.
10. Agent manual run: both steps `OK`; no `ABORTED` row in either log.
11. Two unattended nightly runs green, one exercising the 1st-of-month branch.
12. App: all six pages render; suite **0 skipped**; exports byte-identical across `?page=`; negative
    `Extended Cost` emitted as a raw decimal, never text, never `-0.00`; Encumbered/Routing have no
    banner and a working required year dropdown; the four banner pages unchanged.

---

## Part G — Rollback

**L1 — code + data restore, ~5 minutes, no rebuild.** One guarded `sql/FinanceLedgerParityRollback.sql`
patterned on the existing rollback scripts, with `@RestoreData`, `@RestoreCode`, `@DropAccountID`,
which **refuses to run while the Agent job is enabled**. In one transaction:

1. `DELETE` + `INSERT` `FinanceLedgerSnapshot` from `_ParityBackup`; same for
   `FinanceRequisitionSnapshot` and both `*Refresh` logs.
2. `CREATE OR ALTER` the three objects back from the repo-committed definitions.
3. `DROP COLUMN AccountID` from snapshot and staging — **last**, and only with `@DropAccountID = 1`.
   The restored old function does not project it, so `51001` throws on the next refresh while the
   column exists. Dropping is cleaner than a loud failure.

`vw_FinanceLedger` needs no change at all, because `AccountID` was never exposed there. That is the
entire point of the A4 decision.

**L2 — reinstall from git, ~1 hour.** If `_ParityBackup` is gone:
`git show <pre-parity-sha>:sql/FinanceLedger.sql` and `:sql/FinanceRequisition.sql`, apply both,
`EXEC usp_RefreshFinanceLedgerSnapshotAll @Force = 1`, `EXEC usp_RefreshFinanceRequisition @Force = 1`.
Gate F re-ties on the floored basis.

**App rollback is independent** — `git checkout <pre-release tag>`, `npm ci && npm run build`,
`php artisan optimize:clear`. Because the app ships first and changes no SQL object, either side can
roll back alone.

**Rollback triggers, stated now so nobody debates them at 23:00:** any user's accessible-account count
falls to zero; A1/A2 non-empty; A3 delta ≠ 0.00 on any money column; A6 or A7 non-empty;
`SplitAccountCount` above baseline with no named explanation; gate F `ReconMismatches > 0` after
step 13; `ledger:status` non-zero; any `Outcome = 'ABORTED'` row after step 14.

**Cleanup — make it a dated step with a named owner.** Keep `_ParityBackup` until Finance signs off
one full period close. The repo already carries undropped `*_OversightBackup` tables from 2026-08-26
pending runbook step 11. Do not create a third generation of orphaned backups.

---

## Known visible consequences — tell Finance before, not after

1. **11 accounts appear twice** on Budget Allocations, Monthly Expenditure and Variance — one line
   with budget and no spend, one with spend and no budget.
2. **Negative Extended Cost** on Encumbered Details for over-shipped lines: 694 FY2026 lines across
   62 accounts, −17,363,584.00 raw. The "floored at zero" copy must go.
3. **Approved / Encumbered falls by TTD 11,956,955.67** FY2026 unscoped; TTD 64,550.00 for the one
   user with access today.
4. **Excess and AllocationBalance each rise by ~TTD 850,193** for FY2026.
5. **Account descriptions change** for the corrected accounts — GL-sourced rows now show the raw GL
   master description rather than the curated correction.
6. **Some account descriptions render BLANK, not 'UNDEFINED'.** AccountDescription is now grain taken verbatim per branch rather than a COALESCE chain, so an account absent from `dbo.0030ADGPCOA` has a NULL description. FY2026: one such account, `4-87800-E04-101-2004-00-000` (encumbrance-only, Approved 98,350.00). This is Access behaviour.
7. **Closed-year figures change.** D2 requires it. Capture per-year before/after so any historical
   report can be explained.
8. `4-80300-H01-401-0627-00-000` disappears from the portal.
9. **FY2017 and FY2018 `Approved` go NEGATIVE for the whole year** — −3,974,133.73 and
   −1,444,587.97. Those years hold more over-received value than open commitment, so removing the
   floor takes the annual total below zero. Access reports the same figures. A negative *annual* total
   is far more conspicuous than a negative line, and Finance will see it immediately.
10. **`YTDTotal` does not move in any year.** `Allocation` moves in one year only (FY2026, +0.17).
    **`Routing` moves in two** — FY2024 by −107,341.68 and FY2025 by −0.01; earlier drafts of this
    document claimed Routing never moves, which is true of FY2026 alone. Measured 2026-09-30.

---

## Open questions

1. **Account descriptions becoming verbatim** (A3, consequence 3) changes the displayed description
   beyond the money and the split. Agreed with Finance, or should the curated description be carried
   as an additional display column?
2. **Float arithmetic transcribed verbatim** (A5) is a deliberate un-correction. Confirm, given the
   measured evidence that float summation contributes zero at production scale.
3. **`AccountID` not exposed through `vw_FinanceLedger`** (A4) — confirm Finance does not need it on
   screen or in the CSV.
4. **App-first vs one combined window** (Part E). App-first is recommended; the alternative is shorter
   overall but couples two independent failure domains.
5. **Monitoring** (step 15) — in scope, or explicitly deferred again and written down as such?
6. **B3** — confirm whether the stale-filter re-sync is a pre-existing defect on the three banner
   pages before changing them.
7. **A6 `@MaxSplitAccounts`** — the per-year baseline is a measurement from the rebuild, not a guess;
   FY2026 is 11 and the rest are unknown until step 12.

### Closed

- ~~Encumbrance date bounds~~ — verified equivalent 2026-09-29, all 13 years, all 108,435 open lines.
- ~~Gate 4e must be downgraded~~ — it is not a blocker; kept and widened (A6).
- ~~`@MaxUndefinedPercent` must be re-measured and raised~~ — no change needed given A2's grain/label
  split.

---

## As built — IN PROGRESS (last updated 2026-09-29)

**This section wins over the plan above it.** Everything below was done and measured; everything not
listed is still outstanding.

### A — SQL parity: GATE 1 PASSED, nothing live altered

Three new files, three new **additive** functions on the production instance. No existing object was
altered and no snapshot was rebuilt, so the live portal still runs the pre-parity logic.

| File | Object | What it is |
|---|---|---|
| `sql/ParityVerbatimDraft.sql` | `dbo.fn_OversightDraftVerbatim(@FinancialYear, @EmployeeName)`, `dbo.fn_OversightDraftUnscoped(@FinancialYear)` | The Access query wrapped **unchanged**. Generated mechanically by `sed` from the immutable source at the five documented literal positions — never hand-typed — so the diff against `sql/source/` is auditable. |
| `sql/FinanceLedgerAccessParity.sql` | `dbo.fn_FinanceLedgerAccessParity(@FinancialYear)` | The parity source. Tall UNION ALL + **explicit eight-column `GROUP BY`** (the grain is written out, not emergent from `PIVOT`), unfloored per-line-`ROUND`ed `ActCost`, per-branch descriptions and segments, portal label chain and access join retained. |
| `sql/ParityReconciliation.sql` | — | The acceptance test. Read-only, `#temp` only. |

**Result, first build, all thirteen years, 68 seconds — `VERDICT: PASS`:**

| FY | draft-only | parity-only | rows (both sides) | multiplicity diffs | splits (draft / parity) |
|---|---|---|---|---|---|
| 2014 | 0 | 0 | 1,814 | 0 | 1 / 1 |
| 2015 | 0 | 0 | 1,973 | 0 | 1 / 1 |
| 2016 | 0 | 0 | 1,697 | 0 | 0 / 0 |
| 2017 | 0 | 0 | 1,840 | 0 | 3 / 3 |
| 2018 | 0 | 0 | 1,867 | 0 | 3 / 3 |
| 2019 | 0 | 0 | 1,835 | 0 | 0 / 0 |
| 2020 | 0 | 0 | 1,882 | 0 | 0 / 0 |
| 2021 | 0 | 0 | 1,378 | 0 | 0 / 0 |
| 2022 | 0 | 0 | 1,020 | 0 | 0 / 0 |
| 2023 | 0 | 0 | 785 | 0 | 0 / 0 |
| 2024 | 0 | 0 | 1,887 | 0 | 1 / 1 |
| 2025 | 0 | 0 | 2,121 | 0 | 4 / 4 |
| 2026 | 0 | 0 | 2,275 | 0 | 11 / 11 |

`@MaxSplitAccounts` baseline is therefore the "splits" column above — **24 accounts across history**.
That closes the open item; it was a measurement, not a guess.

**Findings that simplified the plan:**

- **Deviation 3 (sargable date bounds) is provably free.** The `DATEFROMPARTS` form and the draft's
  per-row `CASE` select an identical line set for every year across all 108,435 open encumbrance
  lines — 0 differences either direction — and `ReqDateCreated` is never NULL.
- **Gate 4e never fires, so nothing is downgraded.** It counts open lines *matching* a duplicated
  `(PONumber, POLineID)`: **zero, in every year**. The shipment pre-aggregate and the
  `UNIQUE CLUSTERED INDEX` assertion are therefore kept as-is, and the raw join would be a numeric
  no-op. Decision D6 is superseded rather than implemented.
- **`AccountID` cannot affect the grain today** (differs on 0 accounts; GL's `nvarchar` value always
  equals the COA's `int`), but it *is* declared `int` explicitly on both branches, because the
  draft's UNION ALL lets int precedence decide silently and the drift guard compares names only.
- **The split driver is `AccountDescription` alone**, sourced from `0030AEAccountNameCorrections`
  joined on `AccountSegment2` with no fallback — not the COA's own description (differs on 0) and not
  `AccountID`. 43 FY2026 accounts differ; 7 carry both GL and allocation activity.

### B — Fiscal-year control and its knock-ons: DONE

- `RequisitionDetailView.vue`: `FiscalYearHero` removed entirely (import and invocation); required
  **Fiscal Year** select added as the first filter cell; grid re-cut `lg:grid-cols-6` →
  `lg:grid-cols-4` with Account spanning two; `unsummarisedYears` notice relocated beneath the select;
  `useTableScroll` called **without** `onPrevYear`/`onNextYear`, so arrows scroll columns inside the
  table and are inert elsewhere; stale-filter re-sync `watch` added on `props.filters`.
- `fyNav` removed from the view, both wrapper pages, and the controller (`index()`, `unavailable()`,
  `resolve()` and its docblock). `ResolvesFiscalYear::fiscalYearNav()` untouched — four pages still use it.
- **B6 ordering tiebreak** added to `MonthlyExpenditureController`, `VarianceController` and
  `BudgetAllocationController`: `->orderBy('AccountDescription')` after `AccountNumber`. Without it a
  split account makes the in-memory pagination non-deterministic and breaks `export.md` §11.3's
  byte-identical `?page=` invariant.
- **A7b knock-on fixed:** `DerivesRequisitionDetail::deriveRequisitionRow()` — `PartiallyReceived`
  now tests `!== 0.0` rather than `> 0`, and a new `OverShipped` flag marks a negative balance.
  Under the old test an over-received line read as *fully unshipped* and was muted in the table.

### C — Tests: DONE for this stage

- `RequisitionDetailTest::PROPS` no longer lists `fyNav`; the rail test is renamed to `…dropdown…`;
  two new cases assert the server contract for `?fy=` (valid year selects it; `9999`, `abc`, `20261`
  and empty all fall back to a selectable year without erroring).
- `DerivesRequisitionDetailTest` gains four offline cases pinning the sign change: an over-received
  line is flagged rather than read as unshipped, `OverShipped` is false for ordinary lines, totals
  carry a negative through (193,650 + −64,550 = 129,100), and `largest` stays the maximum rather than
  the maximum absolute.
- `./vendor/bin/pint` run on changed files only.
- **`SQLSRV_HOST=127.0.0.1 php artisan test` → 199 passed, 6 skipped, 0 failed, 1,887 assertions,
  28.0s.** All six skips are the same premise guard: the only mapped user sees one department. See the
  new "HOW TO RUN THE SUITE" note in `CLAUDE.md` — without that override every ledger case skips on a
  15s DNS timeout, because SQL Server is native on Windows while `.env` points at
  `host.docker.internal` for the Docker app.

### Still outstanding

1. **Promote** the parity body into `dbo.fn_FinanceLedgerSource`; add `AccountID` to
   `FinanceLedgerSnapshot` **and** `_Staging` (tables first, or `51001` throws) plus
   `AccountsLoaded`/`SplitAccountCount` to `FinanceLedgerRefresh`.
2. **New gates**: `51008` true fan-out over the grain columns, and `@MaxSplitAccounts` baselined from
   the table above. Widen 4e to all years. Re-scope cutover check #2
   (`FinanceLedgerOversightCutover.sql:161-164`) or it reports 11 false FAN-OUT hits forever.
3. **Phase 2 in lockstep**: unfloor `ActCost` (`FinanceRequisition.sql:572-585`) and aggregate gate
   F's ledger side (`724-729`). Either alone freezes Phase 2 nightly.
4. The ten other files carrying the floored expression (Part A5).
5. FY2026 validation refresh → **GATE 2**, then all-years `@Force = 1` → **GATE 3**.
6. **Vite manifest fix** (Part E step 0) — still the blocker for any web release.
7. `CLAUDE.md` rules for the floor/balance/Phase 3, `Overview.md` for Finance, and the
   `oversight-parity-steps.md` runbook. (`CLAUDE.md`'s stale access-mapping facts and the testing
   note are already corrected.)
8. Monitoring registration (Part E step 15).
