# Finance — Unified Ledger Migration: Progress Record

Implementation record for the plan in `financeupdate.md` (revision 4).

**Status: implemented and cut over on the replica (2026-08-02). Not yet applied to production.**

This file records what was actually built, what was measured, what was decided and why, and
what is still open. `financeupdate.md` remains the design document; this is the log of
executing it. Where the two disagree, this file is what happened.

---

## Summary

| | |
|---|---|
| Environment | `V165ICTFA0MEL\SQLEXPRESS`, SQL Server 2022 Developer 16.0, `max server memory` 2048 MB |
| Database | `FinanceAutomationSystem` (replica, refreshed from production before this work) |
| New SQL files | `sql/FinanceLedger.sql`, `sql/FinanceLedgerCutover.sql` — both applied |
| Snapshot | 13 fiscal years (2014–2026), all `Outcome: OK` |
| Monthly Expenditure page query | **70s → 0.08s** |
| Reconciliation | Clean — see [Reconciliation](#reconciliation) |
| Tests | 36 passed, 3 skipped |
| Frontend | `npm run build` passes; `pint` clean on changed files |

---

## Phase 0 — was already done

`financeupdate.md` flagged this as "likely urgent on production": the live views referenced
the pre-rename `0030A*` tables and would fail with `Invalid object name`.

**Not needed.** On the refreshed replica the canonical `0030AA*` tables are present and
**both views had already been repointed on 2026-07-31** (`sys.views.modify_date`). Both
executed successfully before any of this work started. `sql/00_HotfixReportingTableNames.sql`
was never required and was not written.

`VIEW DEFINITION` permission has since been granted, so both legacy definitions were
scriptable from the app and were read directly rather than reconstructed.

---

## Re-measurement — the replica invalidated most earlier figures

Every number in `financeupdate.md` came from a stale dev box. All of it was re-taken before
any code was written.

| Check | Earlier (stale dev) | Now (replica) |
|---|---|---|
| Reporting tables | `0030A*` | **`0030AA*`** (canonical) |
| Both live views execute | Yes, on stale schema | **Yes** — repointed 2026-07-31 |
| `dbo.MonthlyExpenditure` | "~10s per execution" | **70s for `TOP 3`** |
| `dbo.vw_BudgetAllocation` | — | 0.36s |
| `VIEW DEFINITION` permission | Denied | **Granted** |
| `max server memory` | 500 MB | **2048 MB** |
| `SQL Revised Web App.sql` as written | >6 min / never finished | **10.3s** FY2025, **7.8s** FY2026 |
| `0098AFinGLMaster` | 6,377,713 rows, PK on `LineID` only | **Unchanged** — still no index on `FinancialYear` |
| Active user access | 3 rows / 3 triples / 1 user | **Unchanged** |
| Allocation-only accounts FY2026 | 1,117 / TTD 21,128,414.88 | **Unchanged** — correction (a) still required |
| `varianceLines` | 41 rows / 41 distinct accounts | **Unchanged** — no fan-out risk |

### Why `MonthlyExpenditure` was slow

It had already been repointed to `0030AA*` **and** already used the equality/`CROSS APPLY`
splitter rather than the four non-sargable `LIKE '%…%'` joins. The remaining problem was
structural: **no fiscal-year pushdown**, so every call materialised all users × 13 fiscal
years before the app's `WHERE` applied. That is what the snapshot fixes, and it is why the
naming question turned out to be a red herring.

### Still optimistic versus production

There is **one** active user and **3** access triples on the replica. Every timing below is
measured with that pruning (or, for the snapshot build, deliberately without it). Production
has far more users, so per-request cost is similar but the *unpruned* build cost is the one
that matters — and that is what was measured.

---

## What was built

### `sql/FinanceLedger.sql`

| Object | Kind | Purpose |
|---|---|---|
| `dbo.vw_WebAppUserAccess` | View (live) | `DISTINCT (UserName, ResponsibilityID, DepartmentID)` |
| `dbo.fn_FinanceLedgerSource(@FinancialYear)` | iTVF | The corrected script, FY as a required parameter |
| `dbo.FinanceLedgerSnapshot` (+ `_Staging`) | Table | Local indexed materialisation, explicit DDL |
| `dbo.FinanceLedgerRefresh` | Table | Per-year freshness + refresh outcome |
| `dbo.vw_FinanceLedger` | View | The app's read surface |
| `dbo.usp_RefreshFinanceLedgerSnapshot` | Proc | One fiscal year, with sanity gates |
| `dbo.usp_RefreshFinanceLedgerSnapshotAll` | Proc | Loops the years |

**Snapshot grain is `(FinancialYear, AccountNumber)` — user-agnostic.** `UserName` is joined
on **live** in `vw_FinanceLedger` via `vw_WebAppUserAccess`, so a permission change takes
effect on the next request with no refresh to schedule. The cost is that the build cannot
use the user join to prune, which is why it is measured unpruned.

All nine corrections from `financeupdate.md` were applied:

| | Correction | Consequence if skipped |
|---|---|---|
| (a) | Drive from the **UNION** of GL, allocation and encumbrance account-years | 1,117 accounts / TTD 21,128,414.88 silently cut from FY2026 |
| (b) | User access joined on **parsed account-number segments**, not `coaData` | Same loss, one step later — allocation/encumbrance rows have no `AccountID` |
| (c) | `GL00100` removed entirely | One fewer linked-server table, and the one that proved flaky |
| (d) | `CONVERT(decimal(19,4), …)` **before** aggregating | Float accumulation error (`74327.479999999996`) |
| (e) | `CHARINDEX` splitter, not hardcoded byte offsets | 15 rows of 6.38M are length 26 not 27 → **wrong department** |
| (f) | `MONTH()` map, not `FORMAT(TRXDate,'MMM')` | Culture-dependent; silent zeros under a non-English session |
| (g) | Encumbrance filtered on sargable `DATE` bounds | `nvarchar`/`int` implicit conversion per row; hard error on a non-numeric year |
| (h) | Trailing `ORDER BY` dropped | Invalid in a set-returning object without `TOP` |
| (i) | Category columns surfaced | `MainGroup` / `SubGroupA` / `SubGroupB` were computed but never selected |

**Sanity gates** on the refresh proc. A refresh that *errors* is already safe — it never
reaches the swap. The gates exist for the dangerous case: one that *succeeds* against a
degraded source and quietly writes a truncated result over good data. Aborts and keeps the
previous snapshot if staging is empty, below a floor, more than 10% below the last good row
count, or if allocation/YTD moved more than 25%. `@Force` bypasses the movement gates,
**never** the zero-row gate.

### `sql/FinanceLedgerCutover.sql`

Renames the originals to `MonthlyExpenditure_Legacy` / `vw_BudgetAllocation_Legacy`
(rollback documented in-file, kept until production reconciliation passes), then recreates
both names over `vw_FinanceLedger`:

- **`dbo.MonthlyExpenditure`** — `UNPIVOT` back to one row per account per period, emitting
  byte-for-byte the legacy column list. `WHERE NetChange <> 0` is required: the snapshot
  stores every month as `ISNULL(…,0)`, so without it the view would emit 12 rows per account
  and put every period in the Month dropdown regardless of activity.
- **`dbo.vw_BudgetAllocation`** — thin projection, `Allocation AS TotalAllocation`, with
  `WHERE Allocation <> 0`. The ledger deliberately carries GL- and encumbrance-only accounts
  now, but a *Budget Allocations* page lists what was **budgeted**; admitting them would pad
  it with rows reading 0.00.

Both keep their names and column lists, so **`App\Models\MonthlyExpenditure` and
`App\Models\BudgetAllocation` were not modified at all.**

### App layer

| File | Status |
|---|---|
| `app/Models/FinanceLedger.php` | New — read-only model over `vw_FinanceLedger` |
| `config/ledger.php` | New — cache store/TTL and refresh settings |
| `app/Concerns/VersionsLedgerCache.php` | New — stamps cache keys with the snapshot's `RefreshedAt` |
| `app/Console/Commands/RefreshFinanceLedger.php` | New — `php artisan ledger:refresh` |
| `routes/console.php` | Nightly (current + prior FY) and weekly (`--all`) schedules |
| `DepartmentExpenditureController` | Rewritten against the ledger |
| `AllocationLineExpenditureController` | Rewritten against the ledger |
| `BudgetAllocationController`, `MonthlyExpenditureController`, `DashboardController` | Cache keys versioned |
| `app/Concerns/SampleLedgerFixtures.php` | **Deleted** |
| Both Expenditure Vue pages | `isScaffold` prop and "Sample data" banner removed |

`VersionsLedgerCache` is a shared trait rather than per-controller string edits because
`DashboardController` deliberately reuses the same `budget-allocations:years:{username}` key
that `BudgetAllocationController` writes — versioning them independently would break that
sharing and double the query load.

The two rebuilt controllers kept their exact Inertia prop contracts, so neither Vue page
needed changes beyond dropping the scaffold banner.

---

## Reconciliation

Run against the `_Legacy` views **before** the cutover, at account grain, for FFIGUERA1 /
FY2025 + FY2026.

| Check | Result |
|---|---|
| Allocation totals per FY | **Identical** — 19,737.68 (FY2025), 74,327.48 (FY2026) |
| Per-account allocation differences > 0.01 | **None** |
| Accounts present in legacy but absent in new | **None** |
| Accounts present in new but absent in legacy | 8, **all with `Allocation = 0`** — GL/encumbrance-only, i.e. correction (a) working |
| Monthly net change, value differences > 0.01 | **None** |
| Monthly grand total | **104,222.53 on both sides** |
| Float artefact | Gone — `74327.479999999996` → `74327.4800` |
| Rows in legacy but not new | 3, **all months netting to exactly zero**, dropped by `WHERE NetChange <> 0` |

A second check after the full load compared the snapshot against the **raw GL** restricted to
the same 41 reporting-line-3 accounts:

| FY | Raw GL | Snapshot | Accounts (GL → snapshot) |
|---|---|---|---|
| 2022 | 268,601,782.14 | 268,601,782.14 | 1,020 → 1,020 |
| 2023 | −117,774,963.13 | −117,774,963.13 | 785 → 785 |
| 2024 | 252,965,146.64 | 252,965,146.64 | **1,837 → 1,887** |

Exact to the cent. The 50 extra FY2024 accounts are allocation/encumbrance-only rows that the
original script would have dropped; they carry no GL activity, which is why the money total is
unchanged. That is correction (a) demonstrated on a second year.

---

## Snapshot load — all 13 fiscal years

| FY | Rows | Seconds | Total Allocation | Total YTD |
|---|---|---|---|---|
| 2014 | 1,814 | 93 | 0.00 | 314,246,008.91 |
| 2015 | 1,972 | 97 | 0.00 | 641,286,549.61 |
| 2016 | 1,697 | 99 | 0.00 | 272,943,370.48 |
| 2017 | 1,837 | 99 | 0.00 | 303,288,734.76 |
| 2018 | 1,864 | 94 | 0.00 | 316,277,169.72 |
| 2019 | 1,835 | 93 | 0.00 | 321,318,067.54 |
| 2020 | 1,882 | 92 | 0.00 | 477,424,672.57 |
| 2021 | 1,378 | 75 | 0.00 | 122,153,215.10 |
| 2022 | 1,020 | 62 | 0.00 | 268,601,782.14 |
| 2023 | 785 | 53 | 0.00 | **−117,774,963.13** |
| 2024 | 1,887 | 94 | 0.00 | 252,965,146.64 |
| 2025 | 2,120 | 108 | 198,009,100.00 | 266,968,436.41 |
| 2026 | 2,203 | 107 | 242,817,848.52 | 213,334,810.41 |

All `Outcome: OK`. Full loop ≈ **20 minutes**.

**FY2014–2024 show zero allocation by design** — `0040CBudgetsAllocation` holds FY2025 onward
only. This is the same source-data asymmetry already documented in CLAUDE.md.

### ⚠ FY2023 has a negative YTD total — verified as genuine source data

−117,774,963.13. Confirmed against the raw GL (table above): the snapshot reproduces it
exactly, so this is not an aggregation fault. It comes from a few very large credit postings
concentrated on responsibility 401 / department 0627:

| Account | Description | YTD |
|---|---|---|
| `4-75100-H01-401-0627-00-000` | MEDICAL SUPPLIES | −106,930,151.50 |
| `4-75100-H02-401-0627-00-000` | MEDICAL SUPPLIES | −31,141,485.22 |
| `4-75300-H01-401-0627-00-000` | LABORATORY SUPPLIES | −15,003,659.05 |

Reads like a central-stores reversal or reallocation. **Worth confirming with finance that
FY2023 is expected to look like this** — the app will render it faithfully either way.

---

## Decisions taken during implementation

**Naming (your call).** Account descriptions come from `0098AFinGLMaster`, falling back to the
segment-2 name for accounts with no GL activity — which is what the legacy `vw_BudgetAllocation`
used for *every* row, so allocation-only accounts keep a sensible label. Segment names come
from `0000CSegmentControls.RevisedDescription`, falling back to `GL40200.DSCRIPTN` when that is
NULL, blank or `REMOVE`, and only then to `UNDEFINED`. This resolves open questions 4 and 5.

**Scheduling (your call).** Laravel scheduler, not SQL Agent — production's edition is still
unconfirmed and Express has no Agent. Resolves open question 2.

**Behaviour change: balance and overspend now measure against `ActualExpenditure`**
(YTD + Approved + Routing), not YTD alone. Money committed on an approved or routing
requisition is no longer available to spend, so measuring against posted GL activity alone
overstates the headroom on every line with an open commitment. `AllocationBalance` still floors
at zero with the overspend reported separately as `Excess`. **This changes what the Allocation
Line Expenditure page reports** relative to the scaffold — flag it if you want the old rule back.

**Tests were rebuilt, not just repaired.** `DepartmentExpenditureTest` and
`AllocationLineExpenditureTest` were written against the deleted fixtures and asserted
`isScaffold === true`; their docblocks claimed the pages "touch no SQL Server connection, so
unlike the other finance pages [they are] fully testable in CI". That premise is now false.
They act as a user who genuinely has ledger rows (new `Tests\Feature\Concerns\UsesLedgerData`)
and **skip** when SQL Server is unreachable or the snapshot is empty — a red suite on a machine
with no database tells you nothing. Assertions that depend on data shape (multi-page totals,
filter narrowing, a completed fiscal year) guard their premise and skip rather than assume it.

---

## Verification performed

- **Reconciliation** at account grain against the `_Legacy` views, both directions, before
  the cutover. Then a second pass against the raw GL after the full load.
- **All five pages** rendered end-to-end as an authenticated user, cache cleared first:

  | Route | Status | Time |
  |---|---|---|
  | `/department-expenditure` | 200 | 0.27s |
  | `/allocation-line-expenditure` | 200 | 0.08s |
  | `/budget-allocations` | 200 | 0.46s |
  | `/monthly-expenditure` | 200 | 0.94s |
  | `/dashboard` | 200 | 0.12s |

  Figures agree across every page: TTD **74,327.48** budget / **71,362.68** spend for FY2026.
- **`php artisan test`** — 36 passed, 3 skipped. The 3 skips are honest data limits (this user
  has one department and fewer than 25 rows), not disabled assertions.
- **`./vendor/bin/pint`** — clean on all changed files.
- **`npm run build`** — passes.

---

## Still open

1. **Nothing has been applied to production.** The run order there is: `sql/FinanceLedger.sql`
   → `php artisan ledger:refresh --all` → reconcile → `sql/FinanceLedgerCutover.sql`.
   Re-time the build before committing to a schedule; production's weaker user pruning makes
   the full loop longer than the ~20 minutes measured here.
2. **The nightly schedule is parked at 02:00** with a `TODO` in `routes/console.php`. It should
   run just after the GL load that populates `0098AFinGLMaster` — that window is still unknown
   (`financeupdate.md` open question 3).
3. **Production SQL Server edition is still unconfirmed** (open question 2). The Laravel
   scheduler choice makes this non-blocking, but a 10 GB Express cap would still matter.
4. **Cluster names cannot be validated locally.** `DBA_Clusters` on this box returns
   `LOCAL TEST CLUSTER` for every row. `0000CSegmentControls` holds the real
   responsibility/department/institution names, but the cluster reconciliation has to happen on
   production.
5. **Confirm FY2023's negative total with finance** — see above.
6. **The optional index is deliberately not applied:**
   ```sql
   CREATE NONCLUSTERED INDEX IX_0098AFinGLMaster_FinancialYear
       ON dbo.[0098AFinGLMaster] (FinancialYear)
       INCLUDE (TRXDate, AccountNumber, AccountDescription, NetChange);
   ```
   It would cut refresh time substantially — the 6.38M-row scan is the dominant cost — but it
   writes to a source table this application does not own. Agree it with whoever maintains the
   GL load first.
7. **`sql/MonthlyExpenditureSnapshot.sql` is now superseded** and can be deleted.
   `sql/GLSegmentLookup_staging.sql` should be **kept** — staging `GL40200` and `DBA_Clusters`
   locally is the mitigation if linked-server flakiness returns.
8. **`financeupdate.md` still reads "Status: revision 4 — awaiting review. Nothing has been
   implemented."** Left untouched deliberately; update or retire it now that this file exists.

---

## Incidental findings

- **`DB_HOST=mysql` had regressed in `.env` for the 4th time.** Set back to `localhost`.
  It is a Docker Compose service name that does not resolve when running natively via
  `composer dev`; because sessions, cache and queue are all on MySQL, it costs ~10.7s of dead
  DNS wait per request.
- **`./vendor/bin/pint app/ routes/ config/` reformats nine unrelated pre-existing files**
  (both source models, `config/app.php`, `auth.php`, `database.php`,
  `AuthenticatedSessionController`, `ProfileController`, `HandleInertiaRequests`,
  `LoginRequest`). That churn was reverted. Lint only the files you changed.
- **`sqlcmd` on this box is unusable** — it is the ODBC 17 build but only Driver 18 is
  installed. Run `.sql` files through a small PHP script that bootstraps Laravel and splits on
  `GO`. Note PDO sqlsrv `query()` uses `sp_prepexec`, so `#temp` tables created that way vanish
  immediately; use `PDO::exec()`.
