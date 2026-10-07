# financeupdatesep — Progress Log

**THE SINGLE STATUS RECORD FOR THE SEPTEMBER UPDATE** (Access parity + the fiscal-year control
change). Read this before believing any status claim elsewhere, including the plan.

- **Design and rationale:** `financeupdatesep.md`. Its **As built — IN PROGRESS** section wins over
  the plan text above it; this file wins over both on *status*.
- **Opened:** 2026-09-29.
- **Branch:** `feature/ledger-oversight-update`. Not merged. The user commits and merges manually.

---

## 🆕 DEPLOYED TO PRODUCTION — 2026-10-06. All three gates passed.

**The whole September release is live.** Eight queued changes shipped in one window: Access parity,
Phase 3's two drill-down pages, the 7→6 rename, CSV export, FY-optional drill-downs with the row
ceiling, the display-only banner, the self-service password change, and the Privacy/Terms removal.
**Production serves parity figures.**

| Gate | Result on production |
|---|---|
| **GATE 1** — logic | **PASS** |
| **GATE 2** — stored data, all 13 years | **PASS**, `years_failing 0` |
| **GATE 3** — the two snapshots agree | **PASS** — `ReconMismatches 0`, `ReconStaleYearDrift 0`, `ReconAccountsCompared 22,354`, `RowsLoaded 109,256` |
| Step 4.5 — detail ties to summary | **EXACT** — approved `428,008.08 = 428,008.08`, routing `204,709.08 = 204,709.08` |
| FY2026 negatives arrived | 674 lines / 59 accounts / **−17,265,069.60** (0 before the cutover) |
| Pre-deploy suite, parity data | **352 passed, 7 skipped, 0 failed, 3,402 assertions** |

🔑 **Production matched the local rehearsal digit for digit** — every row count, split count, per-year
`max_abs_delta` and the 20099/20087/40186 totals at step 3.3. The 05-10 restore was a faithful dry run,
which is the strongest thing that can be said for a rehearsal.

**`ReconStaleYearDrift` went 9 → 0**, confirming the deliberate phase ordering: rebuilding all
thirteen years *before* the requisition cutover is what brings every year inside the 36-hour window.

**Money moved as predicted.** FY2026 `Approved` 99,890,944.67 → **88,092,538.18**; FY2017 and FY2018
**negative** at −3,974,133.73 / −1,444,587.97, matching the 2026-09-30 forecasts **to the cent**
because closed years do not drift; requisition `TotalApproved` 444,594,701.39 → 362,698,460.83.

**`master` was fast-forwarded** to `feature/ledger-oversight-update` the same day (20 commits, at the
user's request). Local only — nothing pushed.

### Outstanding after go-live

- 🔴 **No monitoring.** Still unregistered, now guarding a release that changed every money figure and
  added new abort conditions. **The most urgent open item.**
- **`Overview.md` not rewritten** — splits, negative encumbrances and changed account descriptions
  will be reported as portal bugs without it.
- **Finance sign-off on FY2026 against Access** — then step 6.3. Keep
  `fn_FinanceLedgerAccessParity`, both draft functions and all four `_ParityBackup` tables until one
  period close, **with a named owner and a date**.
- **The 1st-of-month Agent branch has never run on parity code** — first exercise **1 November 2026**.
- **Browser and Excel verification outstanding** since 2026-08-29, and note that **splits cannot be
  browser-verified at all** (`FFIGUERA1` sees none).
- **`sql/ParityReconciliation.sql` lacks the money tolerance** and will fail on the known cent.

---

## Status at a glance

| # | Workstream | State |
|---|---|---|
| 1 | Parity source built and proven against the Access query | ✅ **GATE 1 PASSES — all 13 FYs, 2026-10-06, local 05-10 restore** (`@MaxDop 1`, tolerance 0.01, 191.5 s). Twelve years bit-identical; one tolerated row (FY2025, one cent of float representation, named in the output). Got here via two FAILs — production 2026-10-05 and local 2026-10-06 — whose cause was measured, not guessed, and fixed in the GATES, not the function. 🔴 **Production must still be re-gated ON production with `@MaxDop 0`** — a capped run is not evidence about an uncapped one |
| 2 | Fiscal-year control on Encumbered / Routing Details | ✅ DONE (committed `79eef8e`). **🆕 SUPERSEDED 2026-10-01 — the select is now OPTIONAL, defaulting to All Fiscal Years. See the entry at the foot of this file and `routingupdateprogress.md`** |
| 3 | Knock-on fixes the parity change forces (`PartiallyReceived`, ordering tiebreak) | ✅ DONE |
| 4 | Tests updated + new offline coverage for the sign change | ✅ DONE — 199 passed / 6 skipped / 0 failed |
| 5 | `CLAUDE.md` stale access facts + how to run the suite | ✅ DONE |
| 6 | Promote into `fn_FinanceLedgerSource`, `AccountID` columns, new gates | 🟡 **WRITTEN + rehearsed, then DISCARDED by the 2026-09-30 restore.** `sql/FinanceLedgerParityCutover.sql` is ready and was applied cleanly once |
| 7 | Phase 2 in lockstep (`ActCost` + gate F aggregation) | ✅ **APPLIED, GATE 3 PASSED** on the test instance |
| 8 | The ten other files carrying the floored expression | ⬜ NOT STARTED |
| 9 | GATE 2 → GATE 3 | ✅ **ALL THREE GATES PASSED** on the test instance, 2026-09-30. 🔴 **GATE 2 carries the same float exposure GATE 1 failed on** — it compares the function's output to the stored snapshot, so it can fail with no defect present. Read the 2026-10-05 entry before running it |
| 10 | Vite manifest fix — **blocks any web release** | ⬜ NOT STARTED |
| 11 | `Overview.md` for Finance, `oversight-parity-steps.md` runbook, remaining `CLAUDE.md` rules | ⬜ NOT STARTED |
| 12 | Monitoring registration (open since 2026-08-26) | ⬜ NOT STARTED |

**Nothing is deployed.** No pre-existing SQL object has been altered and no snapshot rebuilt, so the
live portal still serves the **pre-parity** figures. The three new SQL functions are additive and
droppable. The app-side change is committed to the working tree only.

🆕 **Production carries NONE of this as of 2026-10-05.** The GATE 1 attempt described at the foot of
this file was undone by `sql/ParityGate1Undo.sql`: all three scratch functions dropped,
`fn_FinanceLedgerSource` still pre-parity, Agent job re-enabled, no `AccountID` column and no
`_ParityBackup` tables. Verified.

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


---

## 2026-10-01 — fiscal year became an OPTIONAL filter on the two drill-downs

A follow-on change to workstream 2, planned in `routingupdate.md` (rev 7) and recorded in
**`routingupdateprogress.md`**, which is the status authority for it. Summarised here because this
file is the project's status record and workstream 2's row above would otherwise read as finished.

**What changed.** Encumbered Details and Routing Details now **open on All Fiscal Years** — every
year this route's detail shares with the ledger (11 for Encumbered, 3 for Routing on `FFIGUERA1`).
Choosing a year is an ordinary filter: it counts in the badge, "Clear all" returns it to All, and
`fy` leaves the URL when All is selected. A read-only gold period chip beside the title states the
scope in words. **No hero, no year rail, no prev/next stepper, no page-level arrow-key year
stepping** — none of that came back.

**Implemented and verified locally; not committed, not deployed.**

**Measured 2026-10-01** (local SQL Server, `FFIGUERA1`, via `sql/Phase3AllYearsReconciliation.sql`):

| Fact | Value |
|---|---|
| Eligible years — Encumbered / Routing | **11** / **3** (ledger boundary is 13 — the three are not the same thing) |
| Withheld years, named on the page | FY2011, FY2012, FY2013 |
| All-years rows, Encumbered | **416** |
| Reconciliation, Encumbered | detail **TTD 111,089,421.36** = `SUM(Approved)` — **diff 0.00** |
| Reconciliation, Routing | **TTD 241,553.20** = `SUM(Routing)` — **diff 0.00** |
| Sort-key uniqueness (5 keys) and `DuplicateGrainRows`' key (4) | **no tied rows** in either |
| Cross-year requisition undercount for this user | **0** — which is exactly why it is covered by a test and not an assumption (worst case measured 106 of 24,065) |

**Test results, all run with `SQLSRV_HOST=127.0.0.1`:**

| Suite | Result |
|---|---|
| `RequisitionScopeDecisionTest` (new, **offline**) | **16 passed**, 40 assertions |
| `DerivesRequisitionDetailTest` (**offline**) | **18 passed**, 51 assertions |
| `RequisitionScopeCeilingTest` (new, SQL-backed, both routes) | **30 passed, 0 skipped**, 194 assertions |
| `RequisitionDetailTest` | **49 passed, 3 skipped**, 502 assertions |
| `CsvExportTest` | **26 passed, 1 skipped**, 1,281 assertions |
| `npm run test:js` (new, `node --test`) | **5 passed** |

Every skip is a legitimate premise guard, not an unreachable database: two are "fewer than two
departments" (`FFIGUERA1` sees one, which CLAUDE.md documents as the current and permanent access
state), one is "no unsummarised years" on Routing, and one is the pre-existing one-department guard
in `CsvExportTest`.

**Capacity, since the all-years default removed the one-year bound on the read.** The read is now
bounded by `FINANCE_REQUISITION_ROW_CEILING` (default 25,000) via a `LIMIT ceiling + 1` fetch, and
**refuses rather than truncating** — a CSV holding 25,000 of 93,336 rows reads as complete. The
ceiling is a **usability** limit, not a memory one: production `memory_limit` is 4096M on a shared
`php.ini` (so the figure applies to Apache too), which would allow ~388,000 rows, but 93,336 rows
is a ~5.1 s response and 3,734 pages of 25. The refusal is unreachable for every real user today.

**Still outstanding — carried from `routingupdate.md` §12, none of them code in this change:**

| # | Item | Blocking? |
|---|---|---|
| 1 | **A named owner for the capacity log.** The `row ceiling` / `working set is large` warnings land in `storage/logs` and nobody is watching it | 🟠 non-blocking, but the guard is unobserved without it |
| 2 | **Monitoring** — no Database Mail, no health-check task. The project's largest open item, open since 2026-08-26 | 🟠 non-blocking here |
| 3 | **`DuplicateGrainRows` is recorded every refresh and nothing acts on it.** The durable fix is one more condition in `ledger:status`, which already exits non-zero for staleness and run-drift. **Not implemented** — `ledger:status` is outside the plan's file list | 🟠 non-blocking at 0 |
| 4 | **SQL-pushdown refactor** — the remedy if a single fiscal year ever exceeds the ceiling, or if categorical filters must be able to rescue a scope. `export.md`'s rejection of it rested on a 3,408-row premise this change raises to 93,336, so it is re-opened rather than left standing | ⚪ deferred, triggered |
| 5 | **The browser checks** — step 5.7 of `finance_sep_update_deployment.md`. The PHP suite verifies the server contract; it cannot see rendered Vue (there is no Inertia SSR), so "no TTD 0 on a refusal" is a manual check by construction | 🟠 before release |

---

## 2026-10-02 — the two drill-downs' header, and arrow keys stopped changing the year

**Full detail, measurements and decision history: `routingupdateprogress.md` §7.** Recorded here
because the fiscal-year control on those two pages is this update's own subject, and §"2026-10-01 —
fiscal year became an OPTIONAL filter" above now has a sequel.

Four changes, all on the user's instruction, none touching PHP except one test:

1. **The banner came back, display-only.** The same shared `FiscalYearHero` the four summary pages
   use, passed `:controls="false"` (no stepper, no year rail) and `all-years-label="All Years"`, with
   the line beneath it the span across the ELIGIBLE years from new `fiscalYearRangeSpan()` in
   `resources/js/fiscalYear.js`. Both new hero props default to the old behaviour, so the four
   summary pages are untouched. `fyNav` is still not passed and no controller changed.
2. **The gold period chip is gone**, and with it `periodSpan` and `isCurrentFiscalYear` in
   `RequisitionDetailView` — the banner derives both.
3. **`SnapshotFreshness` is `faults-only`** on these two pages: the quiet "as at … rebuilt nightly,
   not live" line was removed, the amber `stale` / `failed` strips were NOT. Those are separate
   decisions and only the first was taken — the alarm is the only user-visible signal that the
   nightly job has stopped, and monitoring is still unregistered.
4. 🔴 **Arrow-key fiscal-year stepping was removed from EVERY page**, not just these two. It had
   three sources: `composables/useFiscalYearNav.js` (**deleted**), `useTableScroll`'s
   `onPrevYear`/`onNextYear` and the year branch of its `handleKeydown` (**gone**), and
   `useLedgerTable` forwarding them (**gone**). `useTableScroll` is now the only arrow-key listener
   in the app and only ever scrolls a table. `fyNav` still drives the hero's prev/next **buttons**;
   only the keyboard path went, and the tooltips lost their "(←)" / "(→)" hints.

**Verification:** suite with the override **275 passed, 7 skipped, 0 failed, 3,105 assertions**;
`npm run test:js` **12 passed**; `npm run build` clean; Pint pass on the one PHP file
(`tests/Feature/RequisitionDetailTest.php`, whose snapshot test was renamed and tightened).

**Committed `b0f42a4`:** the 2026-10-01 all-years work and the first banner iteration.
**Uncommitted:** everything in the list above. **Still unverified in a browser** — the "All Years"
label at its two sizes, the span line, dark mode, and that the four summary pages render
identically.

**One incident worth carrying forward:** `CLAUDE.md` was truncated to zero bytes the same day by a
scripted edit that opened the file for writing and only then failed to encode its replacement text.
`CLAUDE.md` and `.claude/` are **gitignored**, so there was nothing to restore from and the file was
rebuilt by hand. When editing it from a script, encode the whole new text first — or write a temp
file and rename.

---

## 2026-10-05 — GATE 1 FAILED ON PRODUCTION, and the cause is float non-associativity

**The production attempt was aborted cleanly at GATE 1. Nothing live was changed; everything was
undone the same day.** This entry is the record of why, because the cause is **not** a defect in the
parity logic and a future attempt will hit it again.

### What happened

The runbook was taken as far as step 1.4 against **production** (`sqlapp\SQLEXPRESS`), on production
data as of 2026-10-05. `sql/ParityReconciliation_Gate1.sql` returned:

```
VERDICT   total_draft_only 1   total_parity_only 1   total_multiplicity_diffs 0
          years_with_rowcount_diff 0   years_with_split_diff 0   ->  FAIL - DO NOT DEPLOY
```

Twelve of thirteen fiscal years were byte-identical. **FY2025** reported `draft_only 1`,
`parity_only 1`, with `draft_rows = parity_rows = 2121`, `mult_diffs = 0` and `splits 4 / 4`.

🔴 **That signature is NOT a grain defect, and reading it as one wastes the day.** `mult_diffs = 0`
means every grain key appears the same number of times on both sides; the row counts and split
counts agree. So one row shares its key across both sides and differs only in a **money** column.

### The actual difference — one cent

`sql/Gate1Diagnose_FY2025.sql` (written for this; read-only) isolated it to one row:
FY2025 · `4-76100-H01-203-0251-00-000` · FOOD SUPPLIES · H01/203/0251 · AccountID 12480.

| Column | Draft (Access) | Parity | Delta |
|---|---|---|---|
| `Feb` | 818,966,030,193.12 | 818,966,030,193.11 | **−0.01** |
| `Q2` | 3,714,287,202,312.62 | 3,714,287,202,312.61 | −0.01 (carries Feb) |
| `YTDTotal` | 6,315,268.79 | 6,315,268.78 | −0.01 (carries Feb) |

**Only `Feb` is an independent finding** — `Q2` and `YTDTotal` are derived from the monthly values
and inherit the same cent. It **reproduced identically** on a second materialisation, so it is not a
moving source.

### Why — and it is NOT a logic difference

`dbo.0098AFinGLMaster.NetChange` is **`float`**, and **both sides sum it as float**: the draft
through `PIVOT (SUM(NetChange) …)`, the parity function through
`SUM(CASE WHEN Measure = '2' THEN Amount END)`. Same rows, same branch, same filter — but a
different physical aggregation plan, therefore a different **addition order**, and float addition is
not associative.

`sql/Gate1Diagnose_FloatOrder.sql` measured February for that account — 1,208 GL rows, 10 of them
over 1bn, max absolute value **1,774,376,625,857.04**:

```
exact_decimal_sum   818,966,030,193.109965   -> rounds to .11
float_sum           818,966,030,193.114746   -> .11
sum_small_first     818,966,030,193.109863
sum_large_first     818,966,030,193.109253
```

**Three different float answers for one set of rows, spanning 0.0055** — more than half a cent,
straddling the `.115` boundary that `ROUND(…, 2)` turns into a whole cent. One ulp of a double at
1.77e12 is ~0.00024, so a few hundred additions with heavy cancellation drift into millicents.

🔴 **The parity function is the one that is RIGHT.** The exact decimal sum is `…93.109965`, which
rounds to **.11** — what the parity function produced. The draft, i.e. **Access, is the cent that is
wrong**. GATE 1 failed because the new function is *more accurate* than the query it is measured
against. There is no branch to fix.

### The part that matters more than the cent

- 🔴 **It is a lottery across five accounts, not one bad row.** Every GL account carrying
  billion-scale entries, measured 2026-10-05 — all FY2025:

  | Account | rows ≥ 1bn | max abs |
  |---|---|---|
  | `4-20700-A01-401-0627-00-000` | 30 | 12,999,999,999,999.87 |
  | `4-42800-A01-401-0627-00-000` | 2 | 12,999,999,999,999.87 |
  | `4-76100-H01-203-0251-00-000` | 22 | 3,058,823,528,651.52 |
  | `4-76100-H04-203-0251-00-000` | 5 | 1,274,509,804,830.00 |
  | `4-76100-E03-106-1127-00-000` | 9 | 509,803,921,441.92 |

  The two at **13 trillion** have an ulp of ~0.002 per addition and are *more* exposed than the one
  that actually failed. They passed by luck.
- 🔴 **GATE 1 is therefore NON-DETERMINISTIC on production.** The same query gave three different
  sums above. Plan shape, parallelism and row order decide the cent, so the gate can pass, then fail
  on an identical dataset, on a different account each time.
- 🔴 **GATE 2 (`ParitySnapshotCheck.sql`) is exposed the same way** — it compares the function's
  output to the stored snapshot, so it too can fail with no defect present.
- **The shipped snapshot stops being bit-reproducible.** Two refreshes of an unchanged fiscal year
  can differ by a cent on these accounts. The refresh proc's movement gates sit far above that so
  nothing will abort, but "re-running the refresh reproduces the snapshot" is no longer strictly
  true.

### 2026-10-06 — REPRODUCED on the local restore, and the mechanism is now proven

The 05-10-2026 production databases were restored to a local SQL Server 2022 instance
(**Developer Edition, `EngineEdition` 3, RTM 16.0.1000.6, 2048 MB, 12 CPUs, instance MAXDOP 12,
cost threshold 5**) and the gate re-run. Results:

| Run | Instance | Parallelism | Elapsed | Verdict |
|---|---|---|---|---|
| 2026-09-29 | test instance | default | ~70 s | PASS, 0 differences |
| 2026-10-05 | production `sqlapp\SQLEXPRESS` (Standard) | default | — | **FAIL** 1/1 FY2025 |
| 2026-10-06 | local restore (Developer) | **MAXDOP 1** | **226.9 s** | **FAIL** 1/1 FY2025 |

**Identical failure**: same account, same `Feb` column, same values, same cent, `mult_diffs 0`,
`GRAIN_MISMATCH` empty. Steps 1.2 and 1.3 both passed, and the parity function's FY2026 figures
matched the draft's in all six values.

🔴 **`OPTION (MAXDOP 1)` was REQUIRED to run anything here.** At the instance default (DOP 12),
materialising `fn_FinanceLedgerAccessParity('2026')` into a temp table **stalled 11 minutes** on
`CXSYNC_PORT` with **2,293 logical reads and zero tempdb allocation** — a parallel-exchange stall,
not work, on an RTM build with known `CXSYNC_PORT` hangs. Capped, the same statement took **12.3 s**.
The gate materialises 26 such sets. **Cap both sides, never one** — a one-sided cap puts a plan
asymmetry inside the comparison itself. The committed `sql/ParityReconciliation_Gate1.sql` was left
**unmodified**; the capped copy lives in the scratchpad, because the hint is a property of this box,
not of the gate.

#### The mechanism, now measured rather than inferred

Over the identical 1,208 February rows for that account:

| How summed | Result | Rounds to |
|---|---|---|
| **Exact (`decimal`) — the true value** | 818,966,030,193.**109965** | **.11** |
| Production, default plan | …93.114746 | .11 |
| Local, parallel (DOP 12) | …93.110107 | .11 |
| **Local, `MAXDOP 1`** | …93.**115479** | **.12** |
| Production, forced small-first | …93.109863 | .11 |
| Production, forced large-first | …93.109253 | .11 |

**Five different float answers for one set of rows. `MAXDOP` alone flips the cent.** The exact value
rounds to **.11** — the parity function's answer. `exact_decimal_sum` is **identical on both
machines**, confirming the restore is faithful and the data is not the variable.

🔴 **The decisive observation.** `sql/Gate1Diagnose_FY2025.sql` **Part 2** re-materialises the *same
two functions* over a **reduced 9-column projection** and returned `draft_only 0, parity_only 0` —
the `YTDTotal` cent **agreed** — in the same session, at the same `MAXDOP 1`, minutes after Part 1
showed it differing. SQL Server inlines these TVFs into the calling query, so **the surrounding
projection changes the plan, changes the addition order, changes the cent.** The disagreement is a
property of the *whole statement*, not of the parity logic.

Three things follow, and they close the question:

1. **No tuning will make this gate pass.** Re-running it is not a strategy.
2. **Narrowing the comparison to obtain agreement would be self-deception** — Part 2 agrees because
   it compares fewer columns, not because the arithmetic improved.
3. **A future "it passed" is luck, not a fix**, and must not be recorded as evidence.

The tolerance is therefore no longer a judgement call about whether to mask a risk: **without it
this gate cannot function.** The recommendation below stands unchanged, and is now the only way
forward that does not involve weakening the comparison.

#### The money at stake, measured — `sql/ParityMoneyDelta.sql` (new)

GATE 1 counts differing **rows**, and reported one. That is not the same claim as "the money differs
by one cent" — a single differing row could in principle hide a large delta — so the money was
measured directly. Each side materialised once per year, every figure `CONVERT`ed to
`decimal(19,2)` **per row** before summing, so the comparison contributes no float error of its own.
Measured 2026-10-06, all 13 FYs, 214.4 s:

| Figure | 13-FY total (draft) | Parity − draft |
|---|---|---|
| Allocation | 440,826,948.69 | **0.00** |
| Approved | 353,219,050.22 | **0.00** |
| Routing | 36,346,867.64 | **0.00** |
| YTDTotal | 3,694,251,307.70 | **−0.01** (FY2025 only) |
| Row count | — | **0 in every year** |

`months_delta` is the same −0.01 (`YTDTotal` is derived from the months), so `total_abs` reads 0.02
— one cent counted twice, not two cents.

🔑 **The whole disagreement between the portal and the finance department's Access query is ONE CENT
in 3.69 BILLION — 2.7e-12 — and the portal is the correct side.** Re-run this file after any change
to the parity function: a delta that grows beyond a cent is a real defect, not an artifact.

**Process note worth keeping:** the first version of that script called the functions five times per
side per year (130 builds, ~19 min) instead of materialising once (26 builds, ~3.5 min) — exactly
what `ParityReconciliation_Gate1.sql`'s own header warns against. The warning is there because it is
easy to do; the file now repeats it.

### ✅ 2026-10-06 — THE TOLERANCE IS IMPLEMENTED, AND GATE 1 PASSES

Both gate scripts changed. 🔴 **They are read-only test harnesses — no data, no stored figure, no
page and no export changed. Only what the TEST calls a failure changed.**

**`sql/ParityReconciliation_Gate1.sql`** (GATE 1) and **`sql/ParitySnapshotCheck.sql`** (GATE 2):

- Money compares at **≤ `@Tolerance`, default 0.01**, and **every tolerated row is PRINTED** —
  account, column, both values, delta — plus a summary with the largest delta and the tolerance in
  force. The listing is the half that keeps the tolerance honest.
- **Grain stays EXACT**: row counts, per-grain-key multiplicity, split counts and the key columns
  carry no tolerance at all.
- **The exact comparison is still reported** per year (`exact_draft_only` / `exact_parity_only`), so
  a bit-identical year still reads as bit-identical.
- **A NULL-vs-value mismatch is NEVER tolerated** — otherwise "no activity" and "exactly zero" merge.
- **`@MaxDop`** knob: 0 production, 1 local restore, applied to both sides or neither.
- GATE 1 was rewritten from **thirteen copy-pasted blocks into one loop**, so the comparison exists
  once. The old shape would have needed the tolerance correct in thirteen places.

**GATE 1, measured 2026-10-06 — local restore, `@MaxDop 1`, `@Tolerance 0.01`, 191.5 s: PASS.**
`total_draft_only 0`, `total_parity_only 0`, `total_tolerated_rows 1`, `mult_diffs 0`,
`years_with_rowcount_diff 0`, `years_with_split_diff 0`. **Twelve of thirteen years bit-identical.**
The one tolerated row is FY2025 `4-76100-H01-203-0251-00-000`, three cells (`Feb`, `Q2`,
`YTDTotal`) at −0.01 — **one cent propagating, not three defects.**

#### Verified rather than assumed

| Test | Result |
|---|---|
| GATE 1, 13 FYs, tolerance 0.01 | **PASS**, 1 tolerated row, named |
| GATE 1, FY2025, **tolerance 0** | **FAIL 1/1** — old behaviour reproduced exactly |
| GATE 2 tolerance path (stand-in source) | **PASS**, same single tolerated row |

The middle row matters: the header claims `@Tolerance = 0` restores the old behaviour, and that is
now measured.

#### Three implementation traps, recorded because they will recur

1. 🔴 **`(a IS NULL) <> (b IS NULL)` is a SYNTAX ERROR** — T-SQL has no boolean type. The NULL
   patterns are compared as 0/1 `CASE` flags instead.
2. 🔴 **Msg 468, collation conflict.** Temp **tables** take tempdb's collation
   (`SQL_Latin1_General_CP1_CI_AS`); a table **variable** takes the current database's
   (`Latin1_General_CI_AS`). Joining them fails. Every string column in both scripts is now
   `COLLATE DATABASE_DEFAULT`. The previous versions never hit this because they never used a table
   variable.
3. 🔴 **A table variable declared INSIDE a `WHILE` body is not re-created per iteration** — it would
   accumulate rows across fiscal years and every count after the first would be wrong. Declared
   outside the loop, emptied at the top of each iteration.

#### 🔴 GATE 2's exposure is WORSE than GATE 1's, and the scripts now say so

GATE 1 compares two functions evaluated in one session. GATE 2 compares a function evaluated **now**
against values the refresh **stored on an earlier night**, under whatever plan was in force then. One
side is already on disk, so **re-running cannot make them converge**. Without the tolerance that gate
would fail intermittently on a correct deployment — the worst kind of gate: one that cries wolf and
gets ignored.

#### Still unexercised

**GATE 2 cannot be run against the real snapshot yet** — it selects `AccountID` from
`FinanceLedgerSnapshot`, which runbook **step 3.1** adds. This is **pre-existing** (the previous
version had the same dependency), not a regression. The GATE 2 test above therefore used
`fn_FinanceLedgerAccessParity` as a **stand-in** for the snapshot: the tolerance machinery is proven,
the snapshot read itself is not, and it cannot be until after the cutover.

### 🛑 Consequence for testing on a RESTORED LOCAL INSTANCE

The plan after this abort is to restore the production databases to a local SQL Server 2022 instance
and re-run the gate there. **A clean GATE 1 locally does NOT prove production will pass**, and this
is the trap to avoid: the float addition order is a property of the **execution plan**, and that
changes with edition, `max server memory`, core count and DOP. Local is Developer edition with
different memory and parallelism from `sqlapp\SQLEXPRESS` Standard. The *data* will be identical;
the *sums* need not be.

So local is the right place to develop and prove the **tolerance change** — but the verdict it
returns is instance-specific, and **production must be re-gated on production**.

### The open decision — NOT yet taken

How GATE 1 should treat a sub-cent float artifact. Recommended, and not yet applied:

- money columns compare at **≤ 0.01**, and **every row that uses the tolerance is listed in the
  output**, so a tolerance that starts absorbing more than these known accounts is visible rather
  than silent;
- **grain, row counts, multiplicity and split counts stay EXACT** — those are the actual subject of
  this release, and were identical across all thirteen years, FY2026's eleven splits included;
- keep the exact-comparison count as a separate reported column, so a bit-identical year is still
  visibly bit-identical.

**Rejected:** aggregating in `decimal` on both sides of the gate. It would give a deterministic
comparison, but the deployed function must sum floats to match Access, so it would test something
other than what ships — hiding this behaviour rather than recording it.

### Data quality, and the limit of what this project may do

The root cause is the trillion-scale offsetting journal entries in `dbo.0098AFinGLMaster` — a FOOD
SUPPLIES account with a 2.0M allocation carrying Dec −3,714,285,689,284.16 against Jan
+2,895,320,880,063.63 and netting to a plausible 6.3M year, plus two accounts at
12,999,999,999,999.87 that look like data-entry errors. **That is a pre-existing table this project
may only read.** It is a conversation to have with Finance; it is not something to correct here, and
no `UPDATE` against it may be proposed as a fix.

### Every expected figure in the runbook is now stale

Production has refreshed nightly since the 2026-09-29 baseline. Measured 2026-10-05, pre-parity:

| | Runbook (2026-09-29) | Production (2026-10-05) |
|---|---|---|
| `FinanceLedgerSnapshot` FY2026 rows | 2,265 | **2,267** |
| FY2026 `Approved` | 95,760,870.05 | **99,890,944.67** |
| `fn_OversightDraftUnscoped('2026')` rows | 2,275 | **2,278** |

Step 0.1's `PASS` values and step 1.3's whole expected table must be **re-measured**, not treated as
mismatches. The gate does not compare against them, which is why this drift failed nothing — but a
reader following the runbook will stop on them.

### Undo — production is clean

`sql/ParityGate1Undo.sql` was written and run. Verified output:

```
POST_UNDO   parity_fn dropped   draft_unscoped dropped   draft_verbatim dropped
            live_ledger_fn pre-parity (correct)   agent_job_enabled 1
```

Steps 1.1 and 1.3 create **three functions and nothing else** — no table created, altered or
written, no live object replaced, nothing in the request path referencing them. Step 1.4 and both
diagnostics are read-only and `#temp` only. **The single change with operational consequence was
step 0.2 disabling the Agent job**, and that is the part of the undo that matters: left disabled,
both snapshots go stale and nothing alerts, because the production health-check task has still never
been registered (open since 2026-08-26 — workstream 12).

### Artefacts added

| File | What it is |
|---|---|
| `sql/Gate1Diagnose_FY2025.sql` | Names the differing row and unpivots the money columns to find the differing one; Part 2 re-materialises both sides to separate a real difference from a moving source. Read-only, diagnostic only |
| `sql/Gate1Diagnose_FloatOrder.sql` | Computes the month three ways — float, exact decimal, and two forced addition orders — and lists every GL account with billion-scale entries. This is the file that settles the cause |
| `sql/ParityGate1Undo.sql` | Undoes runbook steps 0.2–1.4: confirms Phase 1 was as far as it got, re-enables the Agent job, drops the three scratch functions, verifies |
