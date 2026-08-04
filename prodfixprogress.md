# Production Fix — Progress

Implementation log for the plan in `prodfix.md`.

**Status: PRODUCTION ROLLOUT IN PROGRESS — Steps 1-2 done, snapshot building.**

| Step | State |
|---|---|
| 1. Create objects | done |
| 2. Build FY2026 and time it | **done — 2,203 rows in 243s** |
| 3. Build remaining years | in progress (~40-55 min expected) |
| 4. Reconcile | pending |
| 5. Validate names | pending — **the only check never validated anywhere** |
| 6. Cutover | pending |

**FY2026 on production matches dev to the cent** — 2,203 rows,
TotalAllocation 242,817,848.5200, TotalYTD 213,334,810.4100. Dev is a replica, so identical money
is what a correct build produces. Production runs ~2.1x dev's pace (243s vs 114s).

> ## ⚠ Phase 1 (the live-encumbrance hybrid) was built, then deliberately removed
>
> It was built to keep allocation balances accurate intraday. On checking, **nobody uses the
> allocation balance as a current-state figure** — executives read the previous *closed* month and
> earlier, never the current month.
>
> That removed the hybrid's entire justification, so it was reverted: encumbrance amounts are back
> in the snapshot, and `dbo.vw_FinanceLedger` is a plain projection over it again. Every figure in
> a row now shares one as-of date.
>
> **The design is simpler than before this work started, not more complex.** What survives is the
> refresh cadence (below) and the corrected comments.
>
> Deleted with it: the `liveEncumbrance`, `intradayAccounts`, `segmentNames`, `accountNames` and
> `ledgerBase` CTEs, and the intraday encumbrance-only `UNION` — along with the whole class of
> unmeasured read-path risk they carried, and the Phase 1 measurement gate that existed to
> police it.

Last updated 2026-08-03.

---

## Production is untouched — verified

Checked immediately before and after every step:

```
server: sqlapp\SQLEXPRESS
CLEAN: no ledger objects exist on this server.
live view: MonthlyExpenditure    modify_date 2026-07-31 09:04:29.967
live view: vw_BudgetAllocation   modify_date 2026-07-31 09:09:00.160
```

Both live views still carry their pre-existing 2026-07-31 timestamps.

> **One incident worth recording.** While trying to validate the revised SQL against the
> *replica*, an environment override failed to take effect and the runner briefly targeted
> **production**. It attempted `CREATE OR ALTER VIEW dbo.vw_WebAppUserAccess` and was **rejected
> by permissions** before anything was created — the `finance` login cannot create objects. I
> verified production was clean immediately afterwards (output above) and switched to
> `SET PARSEONLY ON` for all subsequent validation, which parses without executing.
>
> Root cause: `.env` now holds production's host *and* credentials, so overriding only
> `SQLSRV_HOST` still authenticates as production. **Any future replica work must override the
> username and password too.**

---

## What the code now does

### 1. Encumbrances stay in the snapshot (Phase 1 reverted)

`sql/FinanceLedger.sql` is back to a single consistent as-of date: `encumbranceData` sums
`Approved`/`Routing` at refresh time, they are stored in `dbo.FinanceLedgerSnapshot`, and
`dbo.vw_FinanceLedger` is a plain projection joined to `vw_WebAppUserAccess`.

Re-verified after the revert: all 10 batches parse cleanly, `Approved`/`Routing` present in the
CTE, the account base, the final SELECT, the snapshot DDL, all four proc column lists, and the
view.

### 2. Refresh cadence changed to daily + monthly

`routes/console.php`: the full rebuild moved from **weekly (Sunday)** to **monthly (1st, 03:00)**.
The daily current+prior-FY run stays at 02:00.

Driven by how the business actually reads the data:

- **A fiscal period closes mid-to-late within its own month** — July closes in July. So by 1 August
  the previous month is complete, and a refresh on the 1st shows all of July throughout August.
  That is precisely what executives need; they read the previous month and back, never the
  current month.
- **Closed fiscal years never change**, so the 13-year loop has no reason to run weekly.

> I initially argued *against* monthly on the grounds that a "mid to end of the month" close was a
> moving target that a monthly schedule could not catch. **That was based on misreading the close
> as happening in the *following* month.** It closes within its own month, so monthly on the 1st
> works. The incorrect reasoning has been removed from `routes/console.php`.

**The daily run is retained for RESILIENCE, not freshness.** Monthly alone would meet the
reporting need, but it is a single point of failure: the sanity gates deliberately keep the
previous snapshot when a build looks wrong, so one linked-server blip on the 1st leaves executives
reading last month's numbers for up to 31 days, with only the health check to notice. Daily turns
that into ~30 chances at ~2-6 minutes a night, because it rebuilds only the current and prior
fiscal year.

### 3. Two false comments in `sql/FinanceLedger.sql` corrected

Both the file header and the `OPTIONAL INDEX` footer claimed the 6.38M-row scan of
`0098AFinGLMaster` was the dominant build cost and that a `FinancialYear` index was the fix.
**Both claims were wrong**, and they had already misled an external review into recommending that
index. Measured on production:

| | |
|---|---|
| `COUNT(*)` no filter | 0.95s |
| `COUNT(*) WHERE FinancialYear='2026'` | 0.95s (identical — scan, not seek) |
| Full `glData` aggregate, one FY | 0.84s |
| All fact-table reads combined | **~1s** |
| **Full build, one FY** | **74–175s** |

The index would remove about one second from a 74–175 second build. The footer now says so, and
the index is commented out and marked **NOT RECOMMENDED**. The remaining ~72s is in the
account-base `UNION`, the `CROSS APPLY` splitter and the join chain — still unprofiled, and the
correct target if refresh cost ever needs reducing.

---

## Dev environment — applied and verified (2026-08-03)

Everything below ran against **`V165ICTFA0MEL\SQLEXPRESS`** (dev). The runner refuses to execute
if `@@SERVERNAME` contains `sqlapp`, so production cannot be hit by accident again.

| Check | Result |
|---|---|
| `sql/FinanceLedger.sql` applied | 10 batches, all OK |
| Objects present | All 8, plus both cutover views and both `_Legacy` views |
| Snapshot schema | `Approved`, `Routing`, `Allocation`, `YTDTotal` all present |
| Snapshot data | 13 fiscal years, 785–2,203 rows each |
| `usp_RefreshFinanceLedgerSnapshot '2026'` | **OK in 114s** — 2,203 rows, schema-drift guard and sanity gates passed |
| FY2026 totals after refresh | Allocation 242,817,848.52 / YTD 213,334,810.41 — unchanged from the pre-revert build |
| `php artisan test` | **36 passed, 3 skipped** |
| All five pages rendered | 200, 0.05–1.32s |

Page figures agree across every page: **TTD 74,327.48** budget, **71,362.68** spend.

| Route | Status | Time |
|---|---|---|
| `/department-expenditure` | 200 | 1.32s |
| `/allocation-line-expenditure` | 200 | 0.05s |
| `/budget-allocations` | 200 | 0.36s |
| `/monthly-expenditure` | 200 | 0.31s |
| `/dashboard` | 200 | 0.08s |

### Correction: the dev SQL Server was never the problem

Earlier in this work I repeatedly concluded the replica had "stalled" (TCP timeout 258, dropped
connections) and attributed it to memory pressure. **That diagnosis was mostly wrong.** Measured:

| Host | Connect time |
|---|---|
| `host.docker.internal` | **57.6s** |
| `localhost` / `127.0.0.1` / `V165ICTFA0MEL\SQLEXPRESS` | **0.0s** |

`.env` uses `host.docker.internal` because the app runs **inside** Docker, where that is correct
and fast. From the **Windows host** the same name takes ~58 seconds to resolve — longer than the
driver's connect timeout, which surfaces as exactly `TCP Provider: Timeout error [258]`.

**When running scripts from the Windows host, override the host to `localhost`.** Do not conclude
the server is down from a 258 alone. (A genuine buffer-pool error did occur once, so the box is
not blameless — but it was available far more often than I reported.)

### Note: `phpunit.xml` hardcodes `DB_HOST=localhost`

That works from the Windows host, where the MySQL container publishes 3306, but **fails inside the
container**, where MySQL is at `mysql`. So `docker compose exec laravel.test php artisan test`
cannot connect. Tests must currently be run from the Windows host. Pre-existing, not introduced
here — flagging it rather than changing a file that affects your workflow.

---

## Verification done so far

| Check | Result |
|---|---|
| `sql/FinanceLedger.sql` — 10 batches | **All parse cleanly** (`SET PARSEONLY ON`, nothing executed) |
| `sql/FinanceLedgerCutover.sql` — 7 batches | **All parse cleanly** |
| `Approved`/`Routing` restored consistently | Verified in CTE, account base, SELECT, snapshot DDL, all 4 proc column lists, view |
| Production unchanged | Verified before and after |
| `./vendor/bin/pint --test config/ledger.php` | pass |
| `php artisan test` | **Could not run — environment down, see below** |

**The test suite could not be run.** MySQL is unreachable: `docker ps` shows no running
containers, so `127.0.0.1:3306` actively refuses connections and every test fails at
`RefreshDatabase` before reaching any assertion:

```
SQLSTATE[HY000] [2002] No connection could be made because the target machine actively
refused it (Connection: mysql, Host: 127.0.0.1, Port: 3306, Database: finance-testing)
```

This is unrelated to these changes — the only PHP touched was one default value in
`config/ledger.php`. The same suite passed **36 passed / 3 skipped** earlier in the session with
the containers up. **It still needs re-running once Docker is back**, and that is not a substitute
for the SQL verification below.

### What is NOT yet verified

Dev is fully exercised. What remains unproven is **production specifically**:

1. **The snapshot build has never run on production.** Dev takes ~114s/year; production measured
   74–175s for the equivalent work.
2. **Reconciliation against the legacy views on production data.** It passed on dev; production
   has different (real) segment and cluster data.
3. **Cluster and segment names.** Dev returns `LOCAL TEST CLUSTER` for every row, so these have
   never been eyeballed against real values. Production has 53 real clusters and 418 real segments.

All three are Steps 3, 4 and 5 of `prodfix-steps.md`.

---

## Next steps — production rollout

Dev is done. Follow **`prodfix-steps.md`**, which is the SSMS runbook.

1. **Create the objects on production** (Step 1). Additive and invisible — nothing reads them
   until cutover, and dropping them is a clean undo.
   - ⚠ The `finance` login **cannot create objects**. This needs a login that can.
2. **Build one year and time it** (Step 2), then the rest (Step 3) — 16–38 min, out of hours.
3. **Reconcile at account grain** (Step 4) and **validate cluster/segment names** (Step 5) — the
   latter has never been possible before now.
4. **Cut over** (Step 6) once 4 and 5 pass. Reversible in seconds.
5. **Scheduler** — `instructionsforschedule.md`. Two Windows Task Scheduler tasks, no queue worker.

### Still open

- ~~**Is the live-encumbrance complexity still wanted?**~~ **RESOLVED — no.** Nobody uses the
  allocation balance as a current-state figure, so the hybrid was reverted (see the banner at the
  top). Encumbrances are snapshotted with everything else.

- **When does the GL load into `0098AFinGLMaster` run?** Sets the daily refresh time. Still the
  one genuinely blocking unknown for scheduling.
- ~~**Do budget allocations change intraday?**~~ **Moot** — with everything on one snapshot date,
  this only matters if current-state figures are ever needed. They are not.

---

## Files changed

| File | Change |
|---|---|
| `sql/FinanceLedger.sql` | Net change vs the session start: **two false comments corrected**. The live-encumbrance hybrid was added and then fully reverted |
| `config/ledger.php` | Refresh timeout default 1800 → 7200, with the reasoning recorded |
| `routes/console.php` | Full rebuild weekly → **monthly (1st, 03:00)**; daily run kept for resilience, rationale recorded |
| `prodfix.md` | Plan (updated earlier with the verified external-review response) |
| `prodfix-steps.md` | Manual SSMS runbook, Steps 1-6, plus Appendix A pointing at the rollback script |
| `sql/FinanceLedgerRollback.sql` | **New** — guarded undo, two flags. Tested on dev both ways |
| `prodfix-steps-undo.md` | **New** — standalone undo runbook (Option A restore / Option B teardown) |
| `sql/FinanceLedgerCutover.sql` | Rollback comment now points at the script and warns about the `_Legacy` cleanup |
| `prodfixprogress.md` | This file |

**No application code changed.** `AllocationLineExpenditureController` already reads `Approved` and
`Routing` from the view and is unaffected. The two controller restructures remain low priority:
against a 0.03s snapshot read, five executions cost ~0.15s, not ~15s.

> The two steps that policed the live-encumbrance design — the measurement gate and the
> intraday-encumbrance proof — have been **removed** from `prodfix-steps.md`, and the remaining
> steps renumbered 1-6.
