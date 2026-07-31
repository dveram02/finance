# Finance — Unified Ledger Migration

Plan for adopting `SQL Revised Web App.sql` as the single source for Monthly Expenditure,
Budget Allocations, the Dashboard, and the new views.

**Status: revision 4 — awaiting review. Nothing has been implemented.**

Revision 4 is a restructure, not another patch. Revisions 1–3 accumulated corrections on top of
corrections and became hard to execute from; the build spec is now separated from the reasoning,
which lives in the **Findings log** at the end.

---

## 🔴 Production may be serving no data right now — check this first

The naming question is resolved: **`SQL Revised Web App.sql` reflects production, and dev is
stale.** So `0030AACOAReports` / `0030ABCOAReportlines` / `0030ACCOAReportAccounts` are the
canonical names and the script is correct as written. No change needed to its table references.

But that resolution has an uncomfortable implication. The saved definitions of **both live views**
— `dbo.MonthlyExpenditure` and `dbo.vw_BudgetAllocation` — reference the *old* names
`0030ACOAReports` / `0030BCOAReportlines` / `0030CCOAReportAccounts`. If production renamed those
tables and nobody repointed the views, **production is failing right now**:

```
Invalid object name 'FinanceAutomationSystem.dbo.0030ACOAReports'
```

Because every controller wraps its queries in try/catch and degrades to an *unavailable* state,
this would surface to users as "The financial data source is unavailable" rather than an error —
which would explain what prompted this work in the first place.

I cannot confirm it from here: dev is stale in the opposite direction, so on dev the old tables
exist and the views execute fine. **Run `sql/00_PreflightChecks.sql` CHECK 1 and CHECK 2 against
production** — that settles it in seconds. If the views fail, Phase 0 is urgent, not conditional.

---

## Every measurement in this document is from a stale dev box

The SQL Server I measured against (`10.5.12.3\SQLEXPRESS`) is **test/dev, and behind production**.
Nothing below should drive a decision until re-taken on production. `sql/00_PreflightChecks.sql` is
a read-only script that re-runs the whole battery there.

Two dev findings are especially unsafe to carry over:

- **User-access scale.** Dev has **3** active user-position rows. Every timing probe was therefore
  measured with the `userControls` join pruning to 3 department pairs and 41 accounts — which is
  worth two orders of magnitude (4.1s pruned versus >10 min unpruned). **Production will have far
  more users, so the pruning is far weaker, and both per-request cost and snapshot build cost will
  be materially higher than anything measured here.** This strengthens the case for the snapshot
  rather than weakening it, but it means the schedule cannot be set from these numbers.
- **The `DISTINCT` fan-out guard.** With 3 rows and no duplicates, dev made this look like latent
  insurance. With hundreds of users holding multiple positions, duplicate
  `(Responsibility, Department)` pairs become likely rather than hypothetical — and each one
  **doubles** that user's money figures. CHECK 6b is the one to watch.

Everything else measured clean on dev — `varianceLines`, PIVOT fan-out, NULL `TRXDate`,
`DBA_Clusters`, non-numeric `FinancialYear` — was validated against **stale schema and data** and
needs re-confirming.

The dev edition is **Developer 16.0** (full Enterprise feature set, non-production licence), SQL
Agent available, 13.8 GB database. ⚠ **Production edition still unknown.** If production is Express
there is **no SQL Agent** — the refresh would have to run from Laravel's scheduler — plus a 10 GB
cap. Nothing in this plan needs Enterprise-only features, which is deliberate, but the scheduling
mechanism depends on the answer. CHECK 0 reports it.

### Correction to revisions 1–3

Those revisions called the broken views "a production outage". That was wrong *as stated* — I was
looking at dev. The irony is that the conclusion may be right for production after all, just for a
reason I could not see. CHECK 2 decides it.

---

## What we are building

The heavy query moves off the request path into a local indexed snapshot, refreshed on a schedule.
The app reads thin views over that snapshot through its existing read-only Eloquent models.

| Object | Kind | Purpose |
|---|---|---|
| `dbo.fn_FinanceLedgerSource(@FinancialYear)` | iTVF | The corrected script, fiscal year as a **required** parameter |
| `dbo.FinanceLedgerSnapshot` (+ `_Staging`) | Table | Local indexed materialisation |
| `dbo.FinanceLedgerRefresh` | Table | One-row freshness + refresh-outcome metadata |
| `dbo.vw_WebAppUserAccess` | View (live) | `DISTINCT (UserName, ResponsibilityID, DepartmentID)` |
| `dbo.vw_FinanceLedger` | View | The app's read surface |
| `dbo.MonthlyExpenditure` | View (redefined) | `UNPIVOT` back to per-period rows |
| `dbo.vw_BudgetAllocation` | View (redefined) | Projection with `Allocation AS TotalAllocation` |
| `dbo.usp_RefreshFinanceLedgerSnapshot` | Proc | One fiscal year, with sanity gates |
| `dbo.usp_RefreshFinanceLedgerSnapshotAll` | Proc | Loops the years |

App side: one new model, one new page, one shared cache-versioning trait. The two redefined views
keep their existing names, so `App\Models\MonthlyExpenditure` and `App\Models\BudgetAllocation`
need no changes at all.

### Why not a stored procedure for the read path

A proc is the same plan in a different wrapper, and the blocker is composition. The controllers
build about a dozen queries on one source — `paginate(25)`, two `GROUP BY` stats passes and six
distinct-option queries in `MonthlyExpenditureController`; `SUM ... GROUP BY PeriodID` and
`GROUP BY MainGroup` in `DashboardController`; `count()` / `sum()` / `orderByDesc()->first()` in
`BudgetAllocationController`. None of that can be appended to a proc's result set. You would either
pull every account row into PHP and aggregate in Collections, or write a proc per query shape. It
also forfeits `->paginate()`, the model scopes and casts, and the read-only `LogicException` guards.

That verdict is scoped to the **read path**. On the **refresh path** the tradeoffs invert — one
caller, no composition, and parameter pushdown is the whole point — so the source *is* an iTVF,
driven by a proc.

---

## Open questions

**Resolved:** the naming scheme. `0030AA*` is canonical; the script is correct as written.

Remaining, in priority order:

1. **Do the two live views execute on production?** Run CHECK 1 + CHECK 2. If not, Phase 0 is an
   immediate fix, not a conditional one.
2. **What edition is production?** Determines SQL Agent vs Laravel scheduler. CHECK 0.
3. **When does the GL load populating `0098AFinGLMaster` finish?** Sets the schedule.
4. **Is the `AccountDescription` change acceptable on the Budget page?** The live
   `vw_BudgetAllocation` sources it from `GL40200` segment 2; the new script uses
   `0098AFinGLMaster.AccountDescription`. Migrating unifies the two pages but changes visible text.
5. **Are the `UNDEFINED` segment names acceptable?** The new script takes names from
   `0000CSegmentControls.RevisedDescription` rather than `GL40200.DSCRIPTN`. 5 of 150 departments,
   2 of 29 responsibilities and 1 of 54 institutions are marked `REMOVE` and will render as
   `UNDEFINED`, plus one department with no control row.

---

## Phase 0 — restore the live views (likely urgent on production)

`CREATE OR ALTER` both views with **only** the three table references corrected to the canonical
`0030AA*` names — no other change. Written to `sql/00_HotfixReportingTableNames.sql` with both full
definitions committed, so it is reproducible from a clone rather than from the SSMS files under
`Documents/`.

Gate it on CHECK 2: if the production views already execute, they were repointed and this is a
no-op. If they fail, this restores all three pages in minutes, independently of the migration.

Its second purpose holds either way: the legacy views are the **reconciliation baseline** for
Phase 1, so they must be executable before cutover.

Note the direction of the fix is now the opposite of what revision 1 assumed — the views need to
move *forward* to `0030AA*`, not back to `0030A*`.

---

## Phase 1 — SQL layer (`FinanceAutomationSystem`)

New file `sql/FinanceLedger.sql`, idempotent, **ASCII-only** (SSMS can misread UTF-8 without a BOM).

### 1. `dbo.fn_FinanceLedgerSource(@FinancialYear)` — inline TVF

The script, corrected, with the fiscal year as a **required** parameter pushed *into* `glData`,
`allocationData` and the encumbrance date bounds, where it is sargable. Not a nullable
"all years" parameter — `WHERE (@FY IS NULL OR FinancialYear = @FY)` is the classic catch-all that
defeats sargability. Full rebuilds loop the years instead.

**Corrections to the script, in order of severity:**

**(a) Drive from a complete account-year base.** The script drives from `glData` and only
`LEFT JOIN`s `allocationData`, so an account with a budget but no GL activity does not appear at
all. Measured on dev:

| FY | Allocated accounts | No GL activity | Allocation at risk |
|---|---|---|---|
| 2026 | 4,257 | **1,117 (26%)** | **TTD 21,128,414.88** |
| 2025 | 2,654 | 490 (18%) | TTD 11,451,439.28 |

Plus **121** encumbrance-only accounts in FY2026 (111 in FY2025) that would lose their `Approved` /
`Routing` figures. The live `vw_BudgetAllocation` drives *from* the allocation table, so it shows
these rows today — migrating as written would silently cut TTD 21.1M from the Total Budget KPI.

Build the base as a `UNION` of the distinct account-years in `glData`, `allocationData` and
`encumberanceData`, then `LEFT JOIN` all three fact sets onto it with `ISNULL(..., 0)`.

**(b) Do not hang user access off `coaData`.** The `UNION` base alone is *not* sufficient — this was
revision 2's bug. Script line 181 joins `userControls` to `D.AccountSegment5` / `D.AccountSegment4`,
which come from `coaData`, matched on `A.AccountID = D.AccountLineID`. Verified:
`0040CBudgetsAllocation` has **no `AccountID`** (only `AccountNumber`) and `0040DBudgetsEncumbrance`
has only `GLAccount`. So allocation-only and encumbrance-only rows would enter the base, fail the
`coaData` match, and then be eliminated by the `INNER JOIN` — the same TTD 21.1M loss, one step later.

Derive `InstitutionID` / `ResponsibilityID` / `DepartmentID` from the **account number string** and
join user access on those. `coaData` is demoted to supplying display names only, `LEFT JOIN`ed on
the parsed segments. A missing chart-of-accounts row then costs a label, never a row and never money.

**(c) Remove `GL00100` entirely.** It only enumerates accounts and maps `ACTINDX` to segments — but
(b) already derives segments from the account number, and every *name* comes from `GL40200`,
`0000CSegmentControls` and `DBA_Clusters`. Dropping it removes one linked-server table and the
dependency that proved flaky mid-session. The live `dbo.MonthlyExpenditure` view already works this
way and never touches it.

**(d) Store money as `decimal`, converting before summing.** All three money columns are **`float`**:
`0098AFinGLMaster.NetChange`, `0040CBudgetsAllocation.Allocation`,
`0040DBudgetsEncumbrance.ExtendedCost`. The accumulation error is real and measurable —
`SUM(NetChange)` for FY2025 returns `+0.00083229` as float versus `-0.0002` as decimal, and the
earlier allocation figure surfaced as `21128414.879999999`.

`CONVERT(decimal(19,4), ...)` **before** aggregating, not after. Summing floats and then rounding
preserves the error; converting first is exact. This is also the concrete reason the snapshot needs
explicit DDL — `SELECT * INTO` would bake `float` into the snapshot permanently.

**(e) Port the account-number splitter.** The script hardcodes byte offsets —
`substring(AccountNumber, 3, 5)`, `(9,3)`, `(13,3)`, `(17,4)` — assuming every account is exactly
`1-5-3-3-4`. The first dash is always at position 2, but **15 rows of 6.38M have total length 26
instead of 27**, so a later segment is short and every offset past it slides, silently mis-parsing
into the wrong department. Use the `CROSS APPLY` / `CHARINDEX` splitter from the live view —
layout-independent and `NULLIF`-guarded.

**(f) Replace `FORMAT(TRXDate, 'MMM')`** with the `CASE MONTH(...)` map. `FORMAT` is a per-row CLR
call and **culture-dependent** — under a non-English session language it returns abbreviations that
match no `PIVOT` column, producing silent zeros rather than an error. There are no NULL `TRXDate`
rows today, but guard anyway since a NULL would vanish the same way.

**(g) Fix the `nvarchar` / `int` join.** `0098AFinGLMaster.FinancialYear` is `nvarchar`;
`encumberanceData.FinYear` is `YEAR(...)+1`, an `int`. `int` has higher type precedence, so every
`FinancialYear` is implicitly converted per row — non-sargable, and a hard error the moment a
non-numeric year appears. No non-numeric values exist today. Compute `FinYear` as `varchar` instead.

**(h) Drop the trailing `ORDER BY`** (line 182) — invalid in a set-returning object without `TOP`.

**(i) Surface the category columns.** `varianceLines` already computes them; they are simply never
selected. Add `E.LineNumber, E.LineDescription, E.Part1 AS MainGroup, E.Part2 AS SubGroupA,
E.Part3 AS SubGroupB`.

**No dedupe needed** on `varianceLines` (41 rows, 41 distinct accounts) or `DBA_Clusters` (no
duplicate institution codes) — both verified clean.

### 2. `dbo.FinanceLedgerSnapshot` + `_Staging`

**Explicit `CREATE TABLE` DDL committed to the repo**, with explicit column lists on every `INSERT`.
`INSERT ... SELECT *` binds by position, so a future column reorder would silently load money into a
description field with no error. Money columns are `decimal(19,4)` per (d);
`ResponsibilityID` / `DepartmentID` are normalised `varchar(50) COLLATE Latin1_General_CI_AS`,
pre-trimmed and uppercased, so the access join needs no runtime `COLLATE` and can seek.

Clustered index on `(FinancialYear, ResponsibilityID, DepartmentID, AccountNumber)`.

A schema-drift guard at the top of the refresh proc compares the source's column set against the
snapshot's and throws on mismatch.

### 3. `dbo.vw_WebAppUserAccess` — a live view

`SELECT DISTINCT UserName, ResponsibilityID, DepartmentID` over
`SWRHAExpenseControl.dbo.0006AWebAppControls` + `0006CWebAppPostControls`, both `IsActive = 'TRUE'`.

A live view rather than a refreshed table: the control tables are on the **same instance**, there
are 3 rows, and the join is trivially cheap — so permission changes take effect immediately and
there is no extra refresh to schedule. (Revision 1 materialised this while claiming immediate
freshness, which was self-contradictory.)

`DISTINCT` is on the full triple. A user holding two `PositionID` rows mapping to the same
department would otherwise duplicate every matching account row and double every money figure.
Verified not currently happening — 3 rows, 3 distinct triples — so this is latent insurance.

### 4. `dbo.vw_FinanceLedger` — explicit column contract

Every view names its columns explicitly. This is required, not stylistic: script line 160 emits
`D.Cluster`, but the app binds `ClusterName` throughout, and without the alias every cluster cell
silently renders `—`.

| Column | Source |
|---|---|
| `ClusterName` | `D.Cluster` — **must be aliased** |
| `InstitutionName`, `ResponsibilityName`, `DepartmentName` | `coaData` |
| `Responsibility` | alias of `ResponsibilityName` — Monthly Expenditure binds this name |
| `MainGroup`, `SubGroupA`, `SubGroupB` | `E.Part1` / `Part2` / `Part3` |
| `LineNumber`, `LineDescription` | `varianceLines` |
| `FinancialYear`, `AccountNumber`, `AccountDescription` | base |
| `Oct`…`Sep`, `Q1`…`Q4`, `YTDTotal` | pivot, `decimal(19,4)` |
| `Approved`, `Routing`, `ActualExpenditure`, `Allocation`, `Excess`, `AllocationBalance` | final select, `decimal(19,4)` |
| `InstitutionID`, `ResponsibilityID`, `DepartmentID` | parsed segments, normalised |
| `UserName` | access join |

### 5. `dbo.MonthlyExpenditure` — redefined as an UNPIVOT

`UNPIVOT` the 12 month columns, emitting exactly the current column list so the model, controller,
period filter and Vue table need no change. `PeriodID` from month position (1 = Oct … 12 = Sep);
`TRXPeriod` derived as `'OCT, 25'` to match `ResolvesFiscalYear::fiscalMonthLabels()`.

Add `WHERE NetChange <> 0`. The snapshot stores months as `ISNULL(...,0)`, so without this the view
emits 12 rows per account including empty months, putting every period in the Month dropdown
regardless of activity — where the old view emitted no row at all.

### 6. `dbo.vw_BudgetAllocation` — redefined

Thin projection over `vw_FinanceLedger` returning the same nine columns the page renders today,
with `Allocation AS TotalAllocation`. Zero PHP change. Retires the old view's
`LIKE '%' + DeptFilter + '%'` joins.

### 7. Refresh procs

`usp_RefreshFinanceLedgerSnapshot @FinancialYear` builds one year from the iTVF into staging with an
explicit column list, then swaps that year's slice into the live table in one short transaction,
recording `RefreshedAt` / `RowsLoaded` / `DurationSeconds`. `THROW` on failure so the last good
snapshot survives. `usp_RefreshFinanceLedgerSnapshotAll` loops the distinct years.

Year-at-a-time is what makes pushdown structural rather than a hope: every call carries a sargable
`FinancialYear = @FY` inside the CTEs. It also makes incremental refresh fall out for free — closed
years never change, so schedule current and prior FY frequently and the full loop weekly.

**Sanity gates before the swap.** A refresh that *errors* is already safe. The dangerous case is one
that *succeeds* against a degraded source and quietly loads a truncated result — which the
mid-session object churn shows is possible. Abort, keep the previous snapshot, and log loudly if,
for the year being refreshed:

- staging row count is zero;
- staging row count is below a configured floor;
- staging row count is materially below the previous successful load (start at −10%);
- `SUM(Allocation)` or `SUM(YTDTotal)` has moved more than a configured percentage.

An `@Force` switch lets a genuine large movement (a new FY opening, a bulk reallocation) through
deliberately.

### 8. Cutover

`sp_rename` the current views to `_Legacy`, populate the snapshot, then create the new views. The
swap itself is metadata-only. Keep `_Legacy` until reconciliation has passed in production.

---

## Phase 2 — App layer

- **`App\Models\FinanceLedger`** (new) — read-only model over `vw_FinanceLedger`, following
  `app/Models/MonthlyExpenditure.php` exactly: pinned `$connection`, `$timestamps = false`,
  `$guarded = ['*']`, `LogicException` guards in `booted()`, `scopeForUser()` / `scopeForYear()`.
- **`App\Models\MonthlyExpenditure`**, **`App\Models\BudgetAllocation`** — unchanged.
- **`DashboardController`** — no change beyond the cache trait.
- **`config/ledger.php`** (new) — cache store and TTL, mirroring `config/budget.php`.
- **`App\Concerns\VersionsLedgerCache`** (new) — `ledgerCacheKey(string $key): string`, reading
  `dbo.FinanceLedgerRefresh.RefreshedAt` (one row, itself cached ~60s) and suffixing it.

  Applied to **all three** controllers. A shared trait rather than per-controller string edits is
  required, because `DashboardController` line 80 deliberately reuses the same
  `budget-allocations:years:{username}` key that `BudgetAllocationController` line 36 writes —
  versioning them independently would break the sharing and double the query load.
  `DashboardController` also has `dashboard:budget-total:...` (line 105) and
  `dashboard:expenditure:...` (line 156), both of which would otherwise stay stale after a refresh.

### Annual Expenditure page

- `AnnualExpenditureController` — read-only and flat per `.claude/context/controller-patterns.md`,
  reusing `ResolvesFiscalYear`, mirroring `MonthlyExpenditureController`'s filter and caching shape
  minus the period filter.
- `resources/js/Pages/Expenditure/Annual Expenditure.vue` — one row per account, columns Oct–Sep
  plus Q1–Q4 and `YTDTotal`, horizontally scrollable, TTD via the existing `en-TT` / `TTD`
  `Intl.NumberFormat` convention.
- Route `/annual-expenditure` in the existing `['auth', 'active.user']` group, plus a sidebar entry.

### Cleanup

Delete `sql/MonthlyExpenditureSnapshot.sql` (superseded). **Keep** `sql/GLSegmentLookup_staging.sql`
— staging `GL40200` and `DBA_Clusters` locally is the mitigation if the unpruned build proves slow,
and it insulates the refresh from linked-server flakiness.

---

## Verification

- **Reconciliation at account grain, before flipping the views.** Compare at
  `(FinancialYear, UserName, DepartmentName, AccountNumber)` and diff the full result sets — not at
  grand-total level. A matching total proves little: the `varianceLines` restriction, `REMOVE`
  filtering and missing-COA behaviour can each drop one account and inflate another, and offsetting
  errors cancel in a sum. Report every account present on one side and absent on the other, both
  directions, before comparing figures.
- **Compare money with a tolerance, not equality.** The sources are `float`, so exact equality is
  not achievable — compare the `decimal(19,4)`-converted values within a small epsilon.
- **Check the TTD 21.1M explicitly.** Confirm FY2026 `SUM(Allocation)` includes the 1,117
  allocation-only accounts. This is the defect most likely to survive as a plausible wrong total.
- **Re-measure on production.** Every timing here is from dev. Time the iTVF for a single year, then
  the full loop, before committing to a schedule.
- **App.** `composer dev`, `php artisan cache:clear file`, then walk Dashboard, Budget Allocations,
  Monthly Expenditure and Annual Expenditure: FY navigator, every filter, pagination, KPI figures
  against the reconciliation query. Confirm the outage path still degrades to *unavailable* rather
  than a fake zero.
- **Tests.** `composer test`, `./vendor/bin/pint`. Existing coverage is
  `tests/Unit/DashboardTransformsTest.php` plus auth/profile feature tests; add unit tests for any
  new pure transform. No SQL Server in CI, so the DB layer stays manually verified.

---

## Findings log

Measured read-only against dev. **All figures are dev-environment figures.**

⚠ **Dev is behind production.** Re-take all of this with `sql/00_PreflightChecks.sql`.

| Finding | Result (dev) |
|---|---|
| Live views execute | ✅ On **dev** — but dev still has the old tables, so this says nothing about production |
| Reporting tables | Dev has `0030A*`; production has `0030AA*` (canonical). Dev is stale |
| `GL00100` on linked server | Present, then absent mid-session; `OPENQUERY` failed remotely |
| Edition | Developer 16.0, SQL Agent available, 13.8 GB db |
| `0098AFinGLMaster` | 6,377,713 rows, FY2014→present |
| `0040DBudgetsEncumbrance` | 104,643 rows — the non-sargable filter is a minor cost |
| Allocation-only accounts FY2026 | 1,117 of 4,257; TTD 21,128,414.88 |
| Encumbrance-only accounts FY2026 | 121 |
| Money column types | All three `float`; accumulation error demonstrated |
| `FinancialYear` type | `nvarchar` vs encumbrance `FinYear` `int`; no non-numeric values today |
| Account layout | First dash always pos 2; 15 rows length 26 not 27 |
| `varianceLines` | 41 rows, 41 distinct accounts — clean |
| User access | 3 rows, 3 distinct triples — clean, `DISTINCT` is insurance |
| `DBA_Clusters` | No duplicate institution codes — clean |
| PIVOT fan-out | No `(FY, AccountNumber)` with multiple `AccountID`/`AccountDescription` — clean |
| NULL `TRXDate` | None — clean |
| `0000CSegmentControls` | Mirrors `GL40200`; 1 of 150 departments unmapped |
| Timings (dev, pruned) | 4.1s one FY / 10.4s all years; unpruned >10 min, cancelled |

### Corrections I made to my own analysis

1. "Production outage, both views broken" → **wrong**; dev environment, both views work.
2. "Cost is user-independent; the trailing user join narrows nothing" → **wrong**; it prunes by two
   orders of magnitude.
3. "Encumbrance scan is a major cost" → **overstated**; 104k rows.
4. "Full rebuild is cheap, drop incremental refresh" → **wrong**; measured with the pruning join still in.
5. "The `UNION` base fixes the allocation-only loss" → **insufficient**; the access join still dropped them.
6. "`varianceLines` risks fan-out" → **it does not**; verified clean.
7. "Staging is unnecessary" → **reversed**; it is the mitigation for both slowness and link flakiness.

### External review verdicts

Round 1 — eight of nine confirmed and adopted: account-year grain, user-access freshness, dashboard
cache keys, refresh pushdown, `SELECT * INTO` fragility, join normalisation, column contracts, and
the hotfix file that was claimed but absent. The mojibake claim was **not reproduced** — the file is
valid UTF-8 (`E2 80 94` for em-dash); that was CP1252 decoding on the reader's side. `.sql` files
will be ASCII-only regardless, since SSMS genuinely can misread UTF-8 without a BOM.

Round 2 — written against revision 1, so eight of its ten points were already fixed. Two were new
and both adopted: reconcile at account grain rather than grand total, and define failure behaviour
for empty or low-row refreshes. Chasing the first exposed correction 5 above.

Found while verifying the reviews, not raised by them: encumbrance-only accounts, the
`AccountDescription` source change, the `float` money types, the `nvarchar`/`int` join, and the
`GL00100` instability.

---

## Phase 3 — deferred views

All read from `vw_FinanceLedger`; no further SQL objects needed.

| View | Source columns |
|---|---|
| Year to Date Expenditure | `YTDTotal`, `ActualExpenditure` |
| Allocation per Line Expenditure | `Allocation`, spend, `AllocationBalance` per account / reporting line |
| Encumbered Expenditure | `Approved` (AP + PO) |
| Routing Expenditure | `Routing` (RT + HD + PN) |
