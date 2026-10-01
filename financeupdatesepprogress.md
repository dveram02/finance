# financeupdatesep — Progress Log

**THE SINGLE STATUS RECORD FOR THE SEPTEMBER UPDATE** (Access parity + the fiscal-year control
change). Read this before believing any status claim elsewhere, including the plan.

- **Design and rationale:** `financeupdatesep.md`. Its **As built — IN PROGRESS** section wins over
  the plan text above it; this file wins over both on *status*.
- **Opened:** 2026-09-29.
- **Branch:** `feature/ledger-oversight-update`. Not merged. The user commits and merges manually.

---

## Status at a glance

| # | Workstream | State |
|---|---|---|
| 1 | Parity source built and proven against the Access query | ✅ **DONE — GATE 1 PASSED**, all 13 FYs, 0 differences |
| 2 | Fiscal-year control on Encumbered / Routing Details | ✅ DONE |
| 3 | Knock-on fixes the parity change forces (`PartiallyReceived`, ordering tiebreak) | ✅ DONE |
| 4 | Tests updated + new offline coverage for the sign change | ✅ DONE — 199 passed / 6 skipped / 0 failed |
| 5 | `CLAUDE.md` stale access facts + how to run the suite | ✅ DONE |
| 6 | Promote into `fn_FinanceLedgerSource`, `AccountID` columns, new gates | 🟡 **WRITTEN + rehearsed, then DISCARDED by the 2026-09-30 restore.** `sql/FinanceLedgerParityCutover.sql` is ready and was applied cleanly once |
| 7 | Phase 2 in lockstep (`ActCost` + gate F aggregation) | ✅ **APPLIED, GATE 3 PASSED** on the test instance |
| 8 | The ten other files carrying the floored expression | ⬜ NOT STARTED |
| 9 | GATE 2 → GATE 3 | ✅ **ALL THREE GATES PASSED** on the test instance, 2026-09-30. Phase 5 (app release) is next |
| 10 | Vite manifest fix — **blocks any web release** | ⬜ NOT STARTED |
| 11 | `Overview.md` for Finance, `oversight-parity-steps.md` runbook, remaining `CLAUDE.md` rules | ⬜ NOT STARTED |
| 12 | Monitoring registration (open since 2026-08-26) | ⬜ NOT STARTED |

**Nothing is deployed.** No pre-existing SQL object has been altered and no snapshot rebuilt, so the
live portal still serves the **pre-parity** figures. The three new SQL functions are additive and
droppable. The app-side change is committed to the working tree only.

---

## What "done" means for workstream 1 — the evidence

`sql/ParityReconciliation.sql` → **`VERDICT: PASS`**, 68 seconds, first build, no iteration.

| FY | draft-only | parity-only | rows (both) | multiplicity diffs | splits (draft / parity) |
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

That is `EXCEPT` in both directions over the eight grain columns plus all twenty money columns,
**paired with row-count equality and per-grain-key multiplicity equality** — because `EXCEPT` is
`DISTINCT`-based and cannot see an identically duplicated row, and row multiplicity is the entire
subject of this release.

`@MaxSplitAccounts` baseline = the splits column above, **24 accounts across history**. Measured, not
guessed.

---

## Measurements taken 2026-09-29 (authoritative; supersede anything older)

**Environment.** `V200ICTF5FA0MEL\SQLEXPRESS` is the LOCAL TEST INSTANCE (SQL Server 2022 Developer Edition, EngineEdition 3) carrying CURRENT PRODUCTION DATA. It is NOT production - that is `sqlapp\SQLEXPRESS`, Standard Edition (EngineEdition 2), on its own DB server. Measurements here are production data on a replica. SQL Server runs natively on the Windows machine; Docker is used only
to run the Laravel app in the test environment. Both Agent job steps last ran **2026-09-28 21:33:01**
and **21:33:29**, both `Outcome = OK`, 32 s apart — i.e. one run, as designed. FY2026 GL holds 641,762
rows with `MAX(TRXDate) = 2026-08-31`; September has not posted.

**Access mapping — the single most misleading fact in the repo.** `0006CWebAppPostControls` holds
**exactly one row**: PositionID 10108, `H01`/`101`/`2001`, `IsActive = TRUE`. Only **`FFIGUERA1`** can
see anything; `KCHARLES1` and `SBHIM1` have no mapping. It held 6 rows (2026-08-06) and 160 rows
(2026-08-25) before this. **Always re-measure.**

**FY2026 unscoped — Access draft vs the pre-parity portal:**

| | Access draft | Portal (pre-parity) | Delta |
|---|---|---|---|
| rows / distinct accounts | 2,275 / 2,264 | 2,265 / 2,265 | +10 rows, −1 account |
| Allocation | 242,817,848.69 | 242,817,848.52 | −0.17 |
| YTDTotal | 254,553,116.94 | 254,553,116.94 | tie |
| **Approved** | 83,803,914.38 | 95,760,870.05 | **−11,956,955.67** |
| Routing | 12,637,933.09 | 12,637,933.09 | tie |
| Excess | 120,433,049.87 | 119,582,856.13 | −850,193.74 |
| AllocationBalance | 108,697,781.62 | 107,847,587.71 | −850,193.91 |

**For the only user with access,** FFIGUERA1 / FY2026: 14 accounts, and the *sole* difference is
`Approved` **129,100.00 vs 193,650.00** on `4-80400-H01-101-2001-00-000` — TTD **64,550.00**, from
eight lines on **PO00000202871** with `Quantity` 1 and `QtyShipped` 2.

**Split drivers, FY2026** — the split is a *description* effect, nothing else:

| Candidate | Accounts affected |
|---|---|
| `AccountID` (GL `nvarchar` vs COA `AccountLineID` `int`) | **0** |
| Raw `0030ADGPCOA.AccountDescription` vs GL master | **0** |
| **Corrections-driven description** (`0030AEAccountNameCorrections` on `AccountSegment2`, no fallback) | **43** (7 with both GL and allocation activity) |
| Segment derivation on short accounts | 2 accounts are 26 chars, 2,263 are 27 |
| Segments carrying two distinct final descriptions (fan-out risk) | **0** |

Worked example: `4-87300-C20-101-2004-00-000` → `RENT & ACCOMODATION` (YTD 253,000.00, Allocation 0)
and `RENT & ACCOMMODATION` (Allocation 521,336.04, Approved 138,000.00, YTD 0). One missing **M**.

**Other findings:**

- **Encumbrance date bounds:** the sargable `DATEFROMPARTS` form and the draft's per-row `CASE` select
  an **identical line set** for every FY2014–FY2026 across all **108,435** open encumbrance lines — 0
  differences either direction — and `ReqDateCreated` is never NULL.
- **Gate 4e (`THROW 51007`) fires on nothing:** **zero** open encumbrance lines match a duplicated
  `(PONumber, POLineID)` in **any** year. Removing the shipment pre-aggregate would be a numeric no-op.
- **Over-shipment exposure:** 694 FY2026 lines across 62 accounts, −17,363,584.00 raw.
- `4-80300-H01-401-0627-00-000` (Allocation −0.17) is absent from `0030ADGPCOA`, so its COA-derived
  allocation segments are NULL and it is invisible through the access join. No special handling needed.
- **Test suite:** `SQLSRV_HOST=127.0.0.1 php artisan test` → **199 passed, 6 skipped, 0 failed, 1,887
  assertions, 28.0s**. Offline only: 74 + 16 passed.

---

## Decisions changed during implementation

| Decision | Change | Why |
|---|---|---|
| **D6** — "gate 4e downgrades to a logged warning" | **Superseded.** Gate 4e is **kept**, and *widened* from FY-bounded to all-years. The shipment pre-aggregate and its `UNIQUE CLUSTERED INDEX` assertion stay. | The gate counts open lines *matching* a duplicate key, not duplicate keys — measured zero in every year. Nothing needed downgrading, and removing the floor makes this bug class *visible money* for the first time, so the tripwire matters more now. |
| `AccountID` — "omit from the projection" | **Reversed: it is carried**, declared `int` explicitly on both branches, added to snapshot + staging, **not** exposed in `vw_FinanceLedger`. | It differs on 0 accounts so it cannot affect grain today, but it *is* a group key in Access. Carrying it structurally beats a warning counter, and keeping it out of the view is what leaves the app rollback independent of the SQL rollback. |
| "Re-measure and raise `@MaxUndefinedPercent`" | **No change needed.** Default stays 2.00 and the portal's label chain is kept. | Segment *names* are neither money nor grain, so they are outside the parity mandate. Only `AccountDescription` is a group key, and it alone goes verbatim per branch. |
| `PIVOT` transcription | **Replaced with an explicit eight-column `GROUP BY` + conditional `SUM`.** | Identical semantics, and it makes the grain a written specification instead of an invisible side effect of `PIVOT`'s implicit grouping — which is the root cause of this whole release. |

---

## Corrections to earlier claims in this project

Recorded because each was believed, acted on, and wrong.

1. **"The parity change is ~20 lines in one function."** Wrong. The deployed function has no `PIVOT`
   and no tall UNION — it resolves `AccountDescription` *after* the joins with no outer `GROUP BY`, so
   the split is structurally unreachable by patching. It required a rewrite of the function body.
2. **"The shipment fan-out moves money, so gate 4e must be weakened."** Wrong — see D6 above.
3. **`CLAUDE.md`'s access-mapping paragraphs** named `KCHARLES1` with 160 rows and said `FFIGUERA1`
   had none. Exactly reversed. **Corrected in `CLAUDE.md`**, with all three dated observations kept as
   a series so the pattern (it swings) is the lesson rather than any one number.
4. **`CLAUDE.md`'s "32 of 128 institution-spanning pairs"** is stale; there is currently nothing for
   the 4-tuple `DISTINCT` to collapse. Annotated, rule retained.
5. **The suite was silently not testing the ledger.** Every ledger case skipped on a ~15 s DNS
   timeout because `.env` points `SQLSRV_HOST` at `host.docker.internal` (correct for the Docker app)
   while `phpunit.xml` runs the suite from the Windows host. Fix is a per-process override,
   `SQLSRV_HOST=127.0.0.1 php artisan test` — documented in `CLAUDE.md`. **Do not edit `.env` for
   this.**

---

## Artefacts

**New SQL files (all read-only in effect; three additive functions created on the server):**

| File | Object(s) |
|---|---|
| `sql/ParityVerbatimDraft.sql` | `dbo.fn_OversightDraftVerbatim`, `dbo.fn_OversightDraftUnscoped` — the Access query wrapped **unchanged**, generated mechanically by `sed` from the immutable source at the five documented literals so the diff is auditable |
| `sql/FinanceLedgerAccessParity.sql` | `dbo.fn_FinanceLedgerAccessParity` — the parity source (**scratch object**, GATE 1; reversible by `DROP FUNCTION`) |
| `sql/ParityReconciliation.sql` | none — the acceptance test, `#temp` only |

**Modified (working tree, uncommitted):** `resources/js/Components/RequisitionDetailView.vue`,
`resources/js/Pages/Expenditure/{Encumbered,Routing} Details.vue`,
`app/Http/Controllers/{RequisitionDetail,MonthlyExpenditure,Variance,BudgetAllocation}Controller.php`,
`app/Concerns/DerivesRequisitionDetail.php`, `tests/Feature/RequisitionDetailTest.php`,
`tests/Unit/DerivesRequisitionDetailTest.php`, `financeupdatesep.md`, `CLAUDE.md` (gitignored).

**Not mine, present in the tree:** `applicationsqlscripts.md`,
`sql/AppOutput_AllocationsRoutingEncumbered.sql` (confirmed irrelevant to this work),
`package-lock.json`.

---

## Next actions, in order

Steps 1–5 are one after-hours maintenance window on the DB server; **stop at any gate that fails.**

0. **Vite manifest fix first** — `app.blade.php` `@vite()`s `resources/css/app.css` but
   `vite.config.js` declares only the JS entry, so a fresh build throws `ViteException` on **every**
   page. `public/build` is gitignored, so it breaks only on the deploy box. The suite cannot catch it
   (`withoutVite()`). This blocks the web release, which blocks everything.
1. Back up three ways: script the three object definitions into the repo; `SELECT * INTO
   ..._ParityBackup` for both snapshots and both refresh logs; record the pre-change git SHA.
2. `ALTER TABLE` add `AccountID` to `FinanceLedgerSnapshot` **and** `_Staging`, plus
   `AccountsLoaded`/`SplitAccountCount` on `FinanceLedgerRefresh`. **Tables before function**, or the
   drift guard throws `51001`.
3. Promote the parity body into `dbo.fn_FinanceLedgerSource`; widen gate 4e; add `51008` (true fan-out
   over the grain columns) and `@MaxSplitAccounts` baselined from the table above; re-scope cutover
   check #2 (`FinanceLedgerOversightCutover.sql:161-164`) or it reports 11 false FAN-OUT hits forever.
4. Phase 2 **in the same window**: unfloor `ActCost` (`FinanceRequisition.sql:572-585`) and aggregate
   gate F's ledger side (`724-729`). Either alone freezes Phase 2 nightly — gate F is not bypassable
   by `@Force`, deliberately.
5. **GATE 2:** FY2026 refresh only, then re-run `sql/ParityReconciliation.sql` against the snapshot.
   → **GATE 3:** `usp_RefreshFinanceLedgerSnapshotAll @Force = 1` (needed — closed years will breach
   `@MaxMovePercent` on Approved), then `usp_RefreshFinanceRequisition @Force = 1`, requiring
   `ReconMismatches = 0` **and** `ReconStaleYearDrift = 0`.
6. Update the ten other files carrying the floored expression (`financeupdatesep.md` A5).
7. `php artisan up`, re-enable the Agent job, run it manually once end to end, `php artisan
   ledger:status` must exit 0 with both snapshots from the same run.
8. Docs: remaining `CLAUDE.md` rules (floor, balance, Phase 3), **`Overview.md` for Finance**, and the
   `oversight-parity-steps.md` runbook.
9. Register the monitoring.
10. Watch two unattended nightly runs, one exercising the 1st-of-month branch.

---

## Open risks

- 🔴 **No monitoring on production**, open since 2026-08-26. This release changes every money figure
  and adds a nightly gate that can abort for a new reason — silently.
- ⚠️ **Finance has not signed off.** Three visible changes will read as bugs unless explained first:
  24 accounts shown twice across history, negative Extended Cost on over-received lines, and changed
  account descriptions for the corrected accounts. `Overview.md` is the mitigation.
- ⚠️ **Some account descriptions render BLANK rather than 'UNDEFINED'.** `AccountDescription` is now grain, taken verbatim per branch, so an account absent from `dbo.0030ADGPCOA` has a NULL description. FY2026: one, `4-87800-E04-101-2004-00-000` (encumbrance-only, Approved 98,350.00). Access behaves the same way. Verified at runbook step 1.3.
- ⚠️ **Closed-year figures will change.** D2 requires it. Capture per-year before/after at step 1.
- ⚠️ **Float summation is order-dependent.** Test A6 (build FY2026 twice, `EXCEPT` both ways) is the
  guard; measurement says the exposure is nil, which is why it is a test and not a code change.
- ⚠️ **One figure does not reconcile by subtraction:** Approved delta 11,956,955.67 vs raw
  over-shipment −17,363,584.00 leaves 5,406,628.33, most likely lines on accounts outside the
  reporting-line-3 scope. The `EXCEPT` suite is the proof; do not chase it arithmetically.

---

## Cutover log — test instance, 2026-09-29

Rehearsed on the local test instance (production DATA, Developer Edition, `max server memory`
2048 MB). Production itself is untouched.

| Step | Result |
|---|---|
| Backups | `FinanceLedgerSnapshot_ParityBackup` 22,352 rows; `FinanceRequisitionSnapshot_ParityBackup` 108,435; both refresh logs. Per-year before-state captured. |
| `sql/FinanceLedgerParityCutover.sql` | ✅ **applied.** `AccountID` on snapshot + staging, `AccountsLoaded`/`SplitAccountCount` on the log, `fn_FinanceLedgerSource` promoted to parity, `usp_RefreshFinanceLedgerSnapshot` updated (gate 4e widened, `51008`, `51009`/`@MaxSplitAccounts`). |
| Drift guard | ✅ **zero rows both directions** — GATE 2 will not throw `51001`. |
| Deployed body vs proven body | ✅ **identical** once line endings are normalised. |
| `sql/FinanceRequisitionParityCutover.sql` | 🟡 written, syntax-checked, **not yet applied**. |
| GATE 2 / GATE 3 / all-years | ⬜ not yet run. |

### Three defects found by running it — all mine, all fixed

1. **Missing `GO` after the procedure's `END`.** The extraction `sed -n '600,860p'` took the body up
   to `END` at line 860 and left `GO` at 861 behind, so the verification footer was swallowed **into
   the procedure body**. Surfaced as `Msg 468` naming the procedure.
2. **Missing `COLLATE` in that footer.** `sys.columns.name` is `sysname`
   (`Latin1_General_CI_AS`); the `name` from `sys.dm_exec_describe_first_result_set` takes the
   database collation (`SQL_Latin1_General_CP1_CI_AS`). `EXCEPT` will not reconcile them. The drift
   guard inside the procedure has always forced both sides; that was not carried into the footer.
3. **`Msg 701`, insufficient system memory.** The footer's `PROMOTED_MATCHES_SCRATCH` check
   `EXCEPT`ed two heavy TVFs in both directions — **four full builds** of a query scanning 641k GL
   rows, needing workspace memory inside single statements, on a 2 GB instance. Replaced with a free
   text comparison of the two function bodies (CR/LF normalised), with a comment saying not to
   compare them by result set and why. `ParityReconciliation.sql` materialises each side into a
   `#temp` table first, which is why it runs in 68 s.

### Two process lessons worth keeping

- **`SET PARSEONLY ON` is a syntax check, not validation.** It passed the script that contained both
  defects 1 and 2 — a footer nested inside a procedure body is syntactically legal, and collation
  conflicts are a binding-time error. Do not report a parse as verification.
- **Verification footers must be cheap.** A cutover script's footer should read metadata and
  existing snapshots only. Anything that rebuilds the ledger belongs in
  `sql/ParityReconciliation.sql`, run as its own step.

### Hardening added while fixing the above

- Gates `51008` and `51009` fire *after* the staging build, unlike `51004`-`51007` which are
  preflight. As first written they threw while leaving the year's rows in staging and **no row in
  `FinanceLedgerRefresh`** — a failure with no record. Both now clean staging and write an
  `ABORTED` row before throwing, matching the existing `@abort` path.
- `sql/ParityReconciliation.sql` now targets the live `dbo.fn_FinanceLedgerSource` (13 call sites)
  rather than the scratch function, so step 3 validates the deployed object.

### Note for the production window

`max server memory` is **2048 MB on the test instance**; production is Standard Edition and will
differ. Re-measure rather than assuming. The all-years rebuild loops year-at-a-time, so each year is
its own statement and should not hit this.

---

## The gates, defined

Referenced as "GATE 1/2/3" throughout this file, `financeupdatesep.md` and the cutover scripts.
Each asks a DIFFERENT question, and none substitutes for another.

### GATE 1 — is the LOGIC right?

Does the parity source reproduce Finance's Access query? Run **before any live object changes**,
against the scratch `dbo.fn_FinanceLedgerAccessParity`.

- **Run:** `sql/ParityReconciliation.sql` (needs `sql/ParityVerbatimDraft.sql`)
- **Pass:** `VERDICT: PASS` — 0 rows either direction, equal row counts, 0 multiplicity differences,
  and split counts matching year for year, across FY2014–FY2026
- **On failure:** nothing live has changed. Fix the function and re-run.
- ✅ **Passed 2026-09-29**, first build, 68 s.

### GATE 2 — is the DATA right?

Did the deployed logic actually produce a correct FY2026 **snapshot**? Run **after the ledger cutover,
before touching any other year or Phase 2**.

- **Run:** `EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026';`
  then `sql/ParitySnapshotCheck.sql`
- **Pass:** the procedure returns `RowsLoaded` **2275**, `AccountsLoaded` **2264**,
  `SplitAccountCount` **11**, `TotalAllocation` **242817848.69**, `TotalYTD` **254553116.94**
  (unchanged), `TotalApproved` **83803914.38**, `TotalRouting` **12637933.09** (unchanged) —
  **and** `ParitySnapshotCheck` reports `PASS` for FY2026.
- **On failure:** only one year has moved. Restore FY2026 from `dbo.FinanceLedgerSnapshot_ParityBackup`.

> ⚠️ **`ParityReconciliation.sql` is NOT sufficient evidence for GATE 2.** It compares
> `fn_FinanceLedgerSource` against `fn_OversightDraftUnscoped` — **function to function** — so it
> passes whatever happens to be in the snapshot and cannot detect a bad refresh. That is why
> `sql/ParitySnapshotCheck.sql` exists: it compares the **stored rows** against the draft. Run both.

### GATE 3 — do the two snapshots still agree WITH EACH OTHER?

Does the requisition-line detail still sum to the ledger's `Approved`/`Routing` per account? Run
**after the Phase 2 cutover**. This is Phase 2's own gate F, performed internally by the refresh.

- **Run:** `EXEC dbo.usp_RefreshFinanceRequisition @Force = 1;`
- **Pass:** the newest `dbo.FinanceRequisitionRefresh` row has `Outcome = 'OK'`,
  `ReconMismatches = 0` **and** `ReconStaleYearDrift = 0`. Also read `ReconAccountsCompared` — a
  suspiciously small number means the freshness `INNER JOIN` is excluding years rather than
  reconciling them.
- **Never bypassable.** `@Force` clears the movement gates and never reaches gate F, deliberately.
- **On failure:** diagnose with `sql/Phase2ReconciliationTest.sql`. Do not force, and do not relax
  the tolerance.

### Full sequence

| # | Action | Gate |
|---|---|---|
| 0 | Disable the Agent job; back up both snapshots and both refresh logs | — |
| 1 | `sql/FinanceLedgerParityCutover.sql` | — |
| 2 | `EXEC usp_RefreshFinanceLedgerSnapshot @FinancialYear='2026'` + `ParitySnapshotCheck.sql` | **GATE 2** |
| 3 | `sql/FinanceRequisitionParityCutover.sql` | — |
| 4 | `EXEC usp_RefreshFinanceRequisition @Force = 1` | **GATE 3** |
| 5 | `EXEC usp_RefreshFinanceLedgerSnapshotAll @Force = 1` (all years) | — |
| 6 | `EXEC usp_RefreshFinanceRequisition @Force = 1` again, + `ParitySnapshotCheck.sql` | **GATE 3, all years** |
| 7 | Re-enable the Agent job, run it manually once, `php artisan ledger:status` | — |

Step 4 runs before step 5 on purpose: at that point only FY2026 is on parity, so gate F's 36-hour
freshness window covers FY2026 and records the older years as `ReconStaleYearDrift` instead of
aborting on them. Step 6 is what proves every year ties once all of them are on parity.

---

## Deployment run — restored DB, 2026-09-30

Following `finance_sep_update_deployment.md`. Database restored to production state as of
2026-09-29 before starting, so every earlier change was discarded and parity re-proven from zero.

| Step | Result |
|---|---|
| 0.1 Starting state | ✅ pre-parity; `AccountID` absent; FY2026 2,265 rows / Approved 95,760,870.05; 0 negative requisition balances |
| 0.2 Agent job | n/a — `SWRHA Finance - Ledger Refresh` does not exist on this instance (`msdb` not restored). **Mandatory on production.** |
| 1.1 `ParityVerbatimDraft.sql` | ✅ applied |
| 1.3 `FinanceLedgerAccessParity.sql` | ✅ applied. Function returns 36 columns vs the snapshot's 35; the only extra is `AccountID`. FY2026: 2,275 rows / 2,264 accounts / 11 splits / Approved 83,803,914.38 |
| **1.4 🛑 GATE 1** | ✅ **PASS.** All 13 years: 0 draft-only, 0 parity-only, 0 multiplicity differences, row counts equal, split counts equal. Reproduced independently on the restored database. |

`@MaxSplitAccounts` baseline confirmed a second time: 2014=1, 2015=1, 2017=3, 2018=3, 2024=1,
2025=4, 2026=11, others 0 — **24 total**, ceiling 40.

### Found during step 1.3 — a visible consequence not previously listed

FY2026 has one row with a NULL `AccountID`: `4-87800-E04-101-2004-00-000`, an encumbrance-only
account (Approved 98,350.00) absent from `dbo.0030ADGPCOA`. Its COA-sourced `AccountID` and
`AccountDescription` are NULL while its segments still resolve, because the encumbrance branch takes
those from byte offsets on the account number rather than from the COA. **The Access query emits the
identical row**, which is why GATE 1 passes with it present.

Consequence: that account's description renders **blank** rather than `UNDEFINED`, because
`AccountDescription` is now grain taken verbatim per branch instead of a COALESCE chain. Access
behaves the same way, so it is in scope — but it is exactly the sort of thing Finance would report as
a defect, so it belongs in `Overview.md`.

### Expected after-figures, derived 2026-09-30 before the rebuild

Taken from `dbo.fn_FinanceLedgerAccessParity` against the restored database, so step 4.1 has per-year
targets rather than only FY2026. Full table with before/after is in
`finance_sep_update_deployment.md` step 4.1.

**Two claims of mine that this measurement disproved:**

1. **"Allocation, YTDTotal and Routing do not move" is wrong about Routing.** `Routing` falls by
   **107,341.68** in FY2024 and by **0.01** in FY2025. It is unchanged everywhere else, including
   FY2026 — which is why the claim survived as long as it did. Corrected in
   `sql/FinanceLedgerParityCutover.sql`, `financeupdatesep.md` and the runbook.
2. **FY2017 and FY2018 `TotalApproved` go NEGATIVE for the whole year** — −3,974,133.73 and
   −1,444,587.97. Those years hold more over-received value than open commitment, so removing the zero
   floor takes the annual total below zero. Access produces the same figures, so it is in scope, but I
   had not predicted it and a negative *annual* total is much more conspicuous than a negative line.
   Gate 4c does not fire on it: that gate tests `@approved = 0` exactly, not a negative.

`YTDTotal` is unchanged in all 13 years, and `Allocation` moves only in FY2026 (+0.17) — those two
claims hold. Also worth noting: **FY2014's row count does not change** (1814 → 1814) despite having a
split, because one account splits while a different one drops; `AccountsLoaded` = **1813** is what
exposes it.

### Steps 2–3 and GATE 2 — 2026-09-30

| Step | Result |
|---|---|
| 2.1 Backups | ✅ 22,352 / 108,435 / 13 / 35 |
| 2.2 Before-state | ✅ Captured, all 13 years, identical to the 2026-09-29 measurement — the restore is faithful |
| 3.1 `FinanceLedgerParityCutover.sql` | ✅ applied; drift guard clean both directions |
| 3.2 FY2026 refresh | ✅ `RowsLoaded` 2,275 · `AccountsLoaded` 2,264 · `SplitAccountCount` 11 · Allocation 242,817,848.69 · YTD 254,553,116.94 · **Approved 83,803,914.38** · Routing 12,637,933.09 · `UndefinedLabelPct` 0.00 · `OK` at 2026-09-30 10:19:26 |
| **3.3 🛑 GATE 2** | ✅ **PASS for FY2026** — 0 draft-only, 0 snap-only, 2,275/2,275, 0 multiplicity differences, splits 11/11. The other 12 years correctly `FAIL`: still pre-parity, `snap_splits = 0`, and `AccountID` NULL on every row so every row differs on that column. |
| 3.4 Spot-checks | ✅ Split reproduced; FFIGUERA1 14 accounts, total Approved **346,568.08** (was 411,118.08) |

### A runbook error GATE 2 exposed

Step 3.4 told the operator to expect FFIGUERA1's approved total to be **129,100.00**. That is wrong,
and it would read as a failed step on a passing deployment.

- `129,100.00` / `193,650.00` are the **per-account** figures for `4-80400-H01-101-2001-00-000`.
- `346,568.08` / `411,118.08` are the **user totals**.

Both deltas are 64,550.00, because the entire difference sits on that one account — which is exactly
why the two got conflated. Verified against `fn_OversightDraftVerbatim` (account 129,100.00, total
346,568.08) and `FinanceLedgerSnapshot_ParityBackup` (total before 411,118.08). Step 3.4 now states
both figures at both grains, with a warning not to confuse them.

### Step 4 and GATE 3 — 2026-09-30

| Step | Result |
|---|---|
| 4.1 All-years rebuild | ✅ **13 years `OK`, 0 aborted, 13 on parity.** Every figure matched the pre-derived target table to the cent, including both Routing movements (FY2024 −107,341.68, FY2025 −0.01) and FY2014's 1,814 rows against 1,813 accounts. Completed 10:25:12–10:25:47 — **~35 seconds for all 13 years**, not the 15–45 minutes budgeted. |
| 4.2 GATE 2, all years | ✅ PASS |
| 4.3 `FinanceRequisitionParityCutover.sql` | ✅ applied — floor removed, gate F aggregated, `#Shipments` pre-aggregate kept, ledger on parity |
| **4.4 🛑 GATE 3** | ✅ **PASS.** 2026-09-30 12:54:29, `OK`, 108,435 rows, `ReconAccountsCompared` 22,351, **`ReconMismatches` 0**, **`ReconStaleYearDrift` 0** (was 7), 0 duplicate grain rows |
| 4.5 Spot-checks | ✅ Detail ties to summary to the cent |

**The detail now ties to the ledger exactly across every shared year:**

| | Approved | Routing |
|---|---|---|
| Detail, FY2014–2026 | 349,064,292.66 | 36,612,739.94 |
| Ledger, FY2014–2026 | 349,064,292.66 | 36,612,739.94 |
| Detail, FY2010–2013 (no ledger counterpart) | 9,479,410.61 | 0.00 |

Unfloored data landed: **4,342 negative lines / 240 accounts / −118,065,060.89** overall; FY2026
**694 lines / 62 accounts / −17,363,584.00**, matching the prediction exactly. FFIGUERA1's detail and
summary agree to the cent (346,568.08 / 229,173.20).

### Two figures that look like failures and are not — now documented in the runbook

1. **`TotalApproved` on the requisition refresh row does not equal the ledger's total.** The telemetry
   sums the WHOLE snapshot (FY2010–FY2026) while gate F reconciles only years the ledger holds
   (FY2014–FY2026). `358,543,703.27` = `349,064,292.66` + `9,479,410.61`. `ReconMismatches = 0` is the
   reconciliation signal; the totals column is not.
2. **`ReconAccountsCompared` falls 22,352 → 22,351**, because parity removes two COA-absent
   account-keys from the ledger (22,352 → 22,350 keys).

Also observed and pre-existing: **685 rows with an unparseable account number**, invisible to every
user because they match no access grant. Unchanged by this release; noted so it is not mistaken for a
regression.

### Timing correction

The runbook budgeted **15–45 minutes** for the all-years ledger rebuild. It took **~35 seconds** on
this instance. The old 102–256s-per-year figures predate the removal of the linked server and do not
describe this function at all. **Re-measure on production rather than carrying either number across** —
production is Standard Edition on a box that also serves live Access users.

### Step 4.5 — and the same runbook error found in a second place

Step 4.5 passed: FY2026 **694 negative lines / 62 accounts / −17,363,584.00**, and
`detail_approved` = `summary_approved` = **346,568.08**, `detail_routing` = `summary_routing` =
**229,173.20**. Detail ties to summary to the cent through the views the pages read.

But step 4.5's stated expectation ALSO read `129,100.00` — the same per-account-vs-user-total
conflation already corrected in step 3.4. I fixed one occurrence and not the other. Both now give the
user total with an explicit warning, and the figures are:

| Grain | Parity | Pre-parity |
|---|---|---|
| `4-80400-H01-101-2001-00-000` alone | 129,100.00 | 193,650.00 |
| FFIGUERA1 total | 346,568.08 | 411,118.08 |

Both deltas are 64,550.00 because the whole difference sits on that one account — which is precisely
why the substitution keeps happening. **When correcting a figure in a runbook, grep for it: it is
rarely stated once.**
