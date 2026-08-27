# Allocation Oversight Update — Progress

What was actually built, measured, decided and left open. Companion to
`financesqlupdate.md` (the Phase 1 plan), `financesqlupdatep2.md` and `financesqlupdatep3.md`
(Phases 2 and 3), and `oversight-prod-steps.md` (the Phase 1 runbook). **This file is the single
progress log for all phases.**

**Status: Phase 1 is LIVE in production as of 2026-08-26.** Steps 1–10 of the runbook are
complete; Step 11 (merge, and dropping the backup tables) is deliberately outstanding.

**Phase 2 (the requisition-detail data layer) is BUILT, and RE-VERIFIED 2026-08-27 against a
fresh PRODUCTION RESTORE on dev — all 15 fiscal years reconcile, 0 mismatches. It is NOT deployed
to production.** See the Phase 2 sections at the foot of this file.

---

## What shipped

Adopted `sql/source/SQL Revised Allocation Oversight F.sql` as the source of truth for how the
ledger is calculated, keeping the corrections the previous implementation already carried.

| # | Change | Effect |
|---|---|---|
| **A** | Chart of accounts reads the local mirror (`0030ADGPCOA` + `0030AEAccountNameCorrections`) | The `GL40200` / `0000CSegmentControls` / `DBA_Clusters` chain is gone. **The refresh no longer touches the linked server at all.** |
| **B** | Encumbrance net of receipts — `(Quantity − QtyShipped) × UnitCost` | Approved falls ~5%; a received PO line is no longer counted twice |
| **C** | `ActualExpenditure = YTDTotal + Approved`, balance measured against `YTDTotal` alone | Routing is displayed and deducted from nothing |
| **D** | Access join gains `InstitutionID` | Closes a measured cross-institution data exposure |

### Objects and files

**New SQL:** `FinanceLedgerOversightCutover.sql` (owns both views, one transaction),
`FinanceLedgerOversightBackup.sql`, `FinanceLedgerOversightRestore.sql`, `sql/source/` (the three
finance-team scripts with SHA-256s and a provenance README).

**Modified SQL:** `FinanceLedger.sql` (function rewrite, new gates, views removed),
`00_PreflightChecks.sql` (CHECKs 12–20), `FinanceLedgerAgentJob.sql` and `GL00100_Rebuild.sql`
(linked-server notes).

**Application:** `app/Concerns/DerivesAllocationLines.php` (new — the pure allocation logic),
`AllocationLineExpenditureController.php`, `Allocation Line Expenditure.vue`.
`app/Models/FinanceLedger.php` needed no change.

**Tests:** `tests/Unit/DerivesAllocationLinesTest.php` (new, 10 tests, fully offline),
`tests/Feature/AllocationLineExpenditureTest.php` (updated to the new rule).

---

## Measured

All figures from the 2026-08-25 production backup unless noted. **Measurements, not invariants.**

### FY2026 ledger — before vs after

| | Before | After | Verdict |
|---|---|---|---|
| Accounts | 2,236 | 2,236 | unchanged ✅ |
| Allocation | 242,817,848.52 | 242,817,848.52 | unchanged ✅ |
| YTD | 235,178,209.57 | 235,178,209.57 | unchanged ✅ |
| Approved | 78,371,828.80 | 74,446,077.43 | **−3,925,751.37 (−5.0%)** — intended |
| Routing | 11,667,664.20 | 11,667,664.19 | 1 cent, float→decimal |
| Label mismatches | — | **0** across all four columns | ✅ |
| Description changes | — | 73 | curated corrections, e.g. `RENT & ACCOMODATION` → `ACCOMMODATION` |

Zero accounts appeared on only one side. Whole-table FY2026 encumbrance (unscoped by the
reporting-line filter): Approved 1,307,659,013.55 → 1,288,452,730.24 (−1.47%); Routing unchanged
at 125,619,041.88, because RT/HD/PN are pre-PO statuses with no shipments.

### Access — the headline finding

Measured on **production**, FY2026, `KCHARLES1` (the only user with mappings):

| | Two-way (old) | Three-way (new) | Change |
|---|---|---|---|
| Accounts | 2,072 | 831 | −1,241 (−59.9%) |
| Allocation | 227,404,246.21 | 128,258,284.14 | **−99,145,962.07 (−43.6%)** |

**This is not lost visibility — it is a confidentiality defect closed.** The old join matched a
`(Responsibility, Department)` pair in *any* institution, and 32 of 128 active pairs span more
than one, against 50 institutions in the snapshot. Dev produced identical figures to the cent.

### Source data

| | Value |
|---|---|
| `0030ADGPCOA` | 9,463 rows / 9,463 distinct accounts, 0 duplicates, **0 blank labels**, 24 `DepartmentName` + 1 `ResponsibilityName` sentinels |
| `0030AEAccountNameCorrections` | 190 rows / 168 accounts, **0 conflicting descriptions**; `IsDuplicate` present but 0 on every row |
| `0098FPOShipmentDetails` | 250,897 rows; 65 duplicated `(PONumber, POLineID)` keys, **0 intersecting an open requisition**; 0 non-numeric |
| `0040DBudgetsEncumbrance` | 319,074 rows (104,643 in scope); 0 NULL/negative `Quantity`/`UnitCost`; `Received` is **0 on every row** |
| Over-shipped lines | 4,365, carrying TTD 118,656,213.96 removed by the zero floor |
| `varianceLines` | 41 rows / 41 distinct accounts — cannot fan out |
| Account-number lengths | **4 distinct at 26 chars**, 6,776 at 27 — the splitter is still load-bearing |
| `0006C` | 160 rows, all active, all PositionID 10038; 114 `H01` / 46 `H03`; 0 blank |
| `0006A` | 3 users — `SBHIM1`, `FFIGUERA1`, `KCHARLES1` |
| Unmatched access grants | **15** — baseline for comparison, not a failure |

### Performance and tests

- **Build time ~22s per fiscal year on dev**, against 102–256s previously. Production timing
  **still needs measuring** — see TODO 6.
- **102 tests / 30,552 assertions pass.** The ledger feature tests ran against real data rather
  than skipping.

---

## Decisions

| Decision | Outcome |
|---|---|
| Balance rule | Implemented **exactly as the source script states**, including that Routing deducts nothing. Previous rule and revert path recorded in `financesqlupdate.md`. |
| `InstitutionID` | Adopted. **No fallback to the two-way join** — an absent column fails the release, because that rule is the exposure being fixed. |
| COA source | Adopted, linked server dropped from the ledger entirely. |
| Encumbrance | Pre-aggregate shipments and floor at zero. |
| Column names | Kept `ActualExpenditure` / `Excess` / `AllocationBalance`. Only the definitions changed, so no PHP or Vue rename cascaded, and the source script's `AcutalYTDExpense` typo was not propagated. |
| Dev parallelism stall | Treated as a **local environment limitation**. Query-scoped `OPTION (MAXDOP 1)` used for local validation only; **no MAXDOP hint exists in any committed SQL.** |

---

## As-built — where this differs from the plan

`financesqlupdate.md` was written before implementation. Five things changed:

1. **Both views moved out of `FinanceLedger.sql`** into `FinanceLedgerOversightCutover.sql`. The
   plan had the installer applying them unguarded, which reopens the fan-out window it was meant
   to close. `FinanceLedger.sql` is now cleanly the prepare stage.
2. **A segment-level label fallback was added.** The full-account COA join left 2 of 2,236 FY2026
   accounts with all four labels reading `UNDEFINED`. Segment→name is 1:1 across the whole COA
   (0 ambiguous segments), so the fallback is safe — label mismatches went 2 → 0.
3. **`public/build` is gitignored.** The plan said to commit it; deployment must run
   `npm run build` on the target instead.
4. **Step 6 moved to the DB side.** `php artisan ledger:refresh --all` is a thin wrapper around
   `EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll`, and running it in SSMS gives live `PRINT`
   progress (which `->statement()` discards) and avoids a ~45-minute network call.
5. **Two scripts hardened** after the incidents below.

---

## Incidents during deployment

**1. Backup script re-run on production (2026-08-26).** `THROW` aborts only its own batch, and
every `GO` starts a new one — so the guard fired correctly and the script then carried on and
rebuilt `FinanceLedgerDefs_PreOversight` from *current* objects, before printing "Backup
complete."

- **Data was safe**: `SELECT ... INTO` cannot overwrite an existing table and errored (Msg 2714).
- **Both views were safe**: the cutover had not yet run, so pre-change definitions were captured.
- **`fn_FinanceLedgerSource` and `usp_RefreshFinanceLedgerSnapshot` in that table are now
  POST-change.** See TODO 4 — this changes the rollback path.
- Fixed: the backup script now uses `SET NOEXEC ON`; the restore script detects post-change
  definitions and throws `51223` rather than silently reinstating the code being rolled back.
  That second bug was the more dangerous of the two and only surfaced because of the first.

**2. Runbook Step 7b was missing `WHERE FinancialYear`.** The Step 4 baseline filters to one
fiscal year; 7b counted all thirteen, so the "after" figure came out ~4× the "before" and looked
like a catastrophic access failure. Query fixed, with expected values written into the runbook.

**3. Dev instance parallelism stall.** Queries hung on `CXSYNC_PORT` — 25s elapsed for 20ms of
CPU — with `MAXDOP 0` across 12 CPUs and `cost threshold 5`. The *unmodified* original query was
equally affected, so this predates the change. Environment, not code.

**4. Dev disk exhaustion.** 3 GB free of 951 GB. Sorts and hash joins had nowhere to spill, so
everything except bare `COUNT(*)` stalled. Resolved by freeing space.

---

## TODO / next steps

### Immediate

1. **Confirm the 21:30 Agent job ran** (first run after Step 10 re-enabled it). A stopped
   scheduler produces no error of any kind — that is the failure `ledger:status` exists to catch.
   `php artisan ledger:status` must exit 0.
2. **Tell the finance team the two numbers**, if not already done: the "over" count has fallen,
   and the affected user's page totals dropped ~44%. Framed as *"a user could see TTD 99.1M of
   another institution's allocation and now cannot"*, this reads as the fix it is.
3. **Commit the outstanding work** — four modified files (`oversight-prod-steps.md`,
   `FinanceLedgerOversightBackup.sql`, `FinanceLedgerOversightRestore.sql`,
   `00_PreflightChecks.sql`) plus a decision on the two commits already on
   `feature/ledger-oversight-update`. Then merge to `master`.

### Before dropping the backups

4. **Rollback path is currently split**, because of incident 1:
   - views + data → `FinanceLedgerOversightRestore.sql` ✅
   - `fn_FinanceLedgerSource` + `usp_RefreshFinanceLedgerSnapshot` → **git**
     (`git show master:sql/FinanceLedger.sql`)

   The restore script throws `51223` and says so. Keep this in mind while the backups still exist.
5. **Do not drop `_PreOversight` tables until the change has been accepted** — at least one period
   close. After that, `FinanceLedgerOversightRestore.sql` can restore nothing.

### Measurement still owed

6. **Measure the production build time** and update the timings note in the header of
   `sql/FinanceLedger.sql`. The 102–256s/FY figures describe the pre-change function and are now
   wrong; ~22s/FY on dev is the only new data point.
7. **Capture the four-key execution plan** on production and decide the index question. Both
   snapshot indexes still lead `(FinancialYear, ResponsibilityID, DepartmentID, AccountNumber)`
   while the access predicate now has four columns. Deliberately left to evidence rather than
   assumption — the DDL is written in `financesqlupdate.md` step 5.
8. **Check whether production shows the same `CXSYNC_PORT` behaviour** as dev. If it does, that is
   a DBA conversation and a separate piece of work — not an application change.

### Phase 2 — access join DECIDED 2026-08-26

9. **Two-way vs three-way access join — DECIDED: three-way.** The corrected scripts are the
   Phase 2 basis; the drafts' two-way join is not to be shipped. Recorded as Decision E in
   `financesqlupdatep2.md`. The measurements behind the decision: The two
   `SQL Web App Workings E` scripts join on two columns (`Responsibility` + `Department`) and do
   not select `InstitutionID` at all; the Oversight script — now live — joins on three. Both
   scripts were run against production as `KEN CHARLES` / `KCHARLES1`, FY2026, read-only:

   | Script | as written (2-way) | 3-way | |
   |---|---|---|---|
   | Routing | 5,949 rows / TTD 131,164,220.53 | 777 rows / TTD 4,696,550.19 | 47 → 2 institutions |
   | Approved | 30,626 rows / TTD 2,711,349,433.34 | 3,452 rows / TTD 38,080,501.68 | 48 → 2 institutions |

   Two separable defects. **Fan-out:** the inline `userAccess` CTE has no `DISTINCT` and 32 of
   128 pairs span two institutions, so Routing emits 2,667 duplicate rows and Approved 13,924 —
   money inflated ~2x before access is even considered. **Over-permissiveness:** the remaining
   drop is institutions the user was never granted. Shipping Approved as written would report
   TTD 2.71bn against a correct 38.1M.

   **Reconciliation confirmed:** two-way detail touches 654 accounts, 441 (67%) absent from the
   831-account summary; three-way touches 215, of which 2 are absent and both are off
   reporting-line-3. The access fix reconciles the pages to within the goods and services rule.

   **Corrected scripts written and verified:** `sql/Phase2RequisitionDetail_Routing.sql` and
   `sql/Phase2RequisitionDetail_Approved.sql` (originals in `sql/source/` untouched). They
   replace the inline CTE with `dbo.vw_WebAppUserAccess` and parameterise `'2026'`.

   **Goods and services scope — DECIDED 2026-08-26:** Phase 2 carries the same reporting-line-3
   scope as the summary, since these are drill-downs for the summary's own figures. Applied in
   both corrected scripts.

   **A second defect surfaced while proving this.** `sql/Phase2ReconciliationTest.sql` compares
   Phase 2 to Phase 1 per account; it failed on 16 accounts, net −9,930,333.27 on Approved with
   Routing tying exactly. Cause: the drafts' `ActCost` is not floored at zero, does not
   pre-aggregate shipments, and uses float. One account read −5,945,460.79 against +1,513,488.86
   in the summary. Both scripts now use the Phase 1 definition verbatim and the test PASSES —
   0 mismatches over 831 accounts, net drift TTD 0.01.

   **Shipping figures:** Routing 773 rows / TTD 4,512,250.19; Approved 3,408 rows /
   TTD 41,936,916.59. Both tie exactly to `vw_FinanceLedger`.

   **Both behaviours kept runnable:** `sql/Phase2RequisitionDetail_*_NoScope.sql` omit the scope
   join; `sql/Phase2ScopeVariants.md` documents the choice and the measurements.

   **Open — and item 10 below needs revisiting.** Approved runs ~47s. The first reading blamed
   the scope join; four timed configurations show that is wrong. Either the scope join OR the
   corrected `ActCost` alone costs ~47s, and both together add nothing. Isolated: dropping only
   the shipment pre-aggregation returns it to 0.5s, so the cost is
   `GROUP BY PONumber, CONVERT(int, POLineID)` over `0098FPOShipmentDetails` — which is required
   for correctness (65 duplicated keys). Phase 1 pays it once per refresh; a live view pays it per
   page load.

   **Nice to confirm, but blocking nothing:** that the two-way join was drift rather than intent.
   `InstitutionID` landed on `0006C` between 2026-07-31 and 2026-08-25 while the drafts are
   timestamped 2026-08-24, which points that way.
10. **DECIDED 2026-08-26 — Phase 2 is SNAPSHOT-BACKED, not live views.** The earlier
    recommendation (*live views, not snapshots — they read only two small local tables, and users
    expect current state for open requisitions*) is reversed. "Two small local tables" was wrong
    about cost, and the reconciliation requirement settled by item 9 cannot be enforced on a live
    view at all. Full design in `financesqlupdatep2.md`; the pages are `financesqlupdatep3.md`.

    The work is **split into two phases**, mirroring how Phase 1 was structured:

    * **Phase 2 — data layer.** `dbo.FinanceRequisitionSnapshot` (+ `_Staging`,
      `FinanceRequisitionRefresh`, refresh proc, read views), and a second step in the existing
      Agent job. Independently deployable, independently rollback-able, testable without any app
      change — exactly the Phase 1 shape.
    * **Phase 3 — pages.** Controllers and Vue pages over the Phase 2 views. No SQL risk.

    `sql/Phase2RequisitionDetail_*.sql` remain the reference queries the snapshot is built from;
    they keep the Phase 1 `ActCost` definition verbatim, which they now do.

### Housekeeping

11. **`CLAUDE.md` is gitignored**, so this change's updates to it exist only on this machine.
    Anyone cloning fresh gets the stale version — including the "only FFIGUERA1 is mapped" claim,
    which is now wrong (access moved to `KCHARLES1`, and `FFIGUERA1` has no mappings at all).
    Worth deciding whether that file should be tracked.
12. **`/notifications` 404** — pre-existing and unrelated. `HeaderBar.vue` polls an endpoint that
    has never existed, every 30 seconds, on every page. Options: remove the UI (recommended),
    build the endpoint, or stub it.
13. Retire `scripts/refresh-ledger.ps1` and `manage-ledger.bat` now that go-live has passed, per
    the note in `CLAUDE.md`.

---

## Facts that changed underneath this work

Worth recording, because several documents still assert the old values:

| | Was documented | Actually measured 2026-08-25 |
|---|---|---|
| Mapped user | `FFIGUERA1` (PositionID 10108), 3 mappings | **`KCHARLES1`** (PositionID 10038), **160 mappings**. `FFIGUERA1` has none. |
| `0006C` rows | 6 | **160** |
| `0006A` users | 2 | **3** |
| `0098AFinGLMaster` | 6.38M rows | **12,989,844 rows** |
| `0006C` columns | Position → Responsibility + Department | now also **`InstitutionID`** |

Any worked example naming a specific user is a dated observation. Re-measure; never quote.

---

## Phase 2 — BUILT AND VERIFIED ON DEV, 2026-08-26

**Status: the data layer is implemented and proven on dev. Nothing is deployed to production.**
Design and the full as-built record are in `financesqlupdatep2.md`; this is the log entry.

Items 9 and 10 above are the decisions this implements. Both stand — three-way access join,
snapshot-backed rather than live views — and nothing measured during implementation contradicted
them.

### What was built

| File | Role |
|---|---|
| `sql/FinanceRequisition.sql` | Snapshot, staging, run-keyed refresh log, `usp_RefreshFinanceRequisition`, both read views, verification queries |
| `sql/FinanceRequisitionAgentJobStep.sql` | Amends the **existing** Agent job: step 1's success action, then step 2. Grants, verification, rollback |
| `sql/FinanceRequisitionRollback.sql` | Guarded teardown; refuses to run while the Agent step still exists |
| `app/Console/Commands/RefreshFinanceRequisition.php` | `php artisan requisition:refresh` — manual only |
| `app/Console/Commands/LedgerStatus.php` | Extended to read **both** refresh logs and assert they are from the same run |
| `config/ledger.php` | `ledger.requisition.max_run_drift_minutes` |
| `scripts/check-ledger-health.ps1` | Alert body widened; the assertion itself lives in `ledger:status` |

### Measured on dev

106,358 rows / 15 fiscal years / 1,644 accounts, built in **18–19s**. 22,324 accounts reconciled,
**0 mismatches**, 0 duplicate grain rows, 685 unparsed account numbers.

**The whole 15-year build is faster than one page query used to be** — the Approved reference query
runs ~47s per execution because of the shipment aggregate, and the snapshot pays it once.

Reconciliation, per account and user-agnostic, against `FinanceLedgerSnapshot`:

| FY | Ledger snapshot built | Accounts | Drifting |
|---|---|---|---|
| 2026 | 2026-08-24 (post-Oversight) | 2,236 | **0** |
| 2025 | 2026-08-24 (post-Oversight) | 2,117 | **0** |
| 2024 … 2014 | 2026-08-03 (**pre**-Oversight) | 1,814–1,887 each | 355 total |

Every drifting account is in a year whose summary still carries the OLD encumbrance rule. Read back
per user through the live views, `KCHARLES1`/FY2026: detail Approved 41,901,433.34 vs summary
41,901,433.34, Routing 4,300,785.01 vs 4,300,785.01 — **diff 0.0000 on both**, 3,388 + 777 = 4,165
rows. Those are exactly the dev figures `sql/Phase2ScopeVariants.md` records for the same day,
reached through a different code path. FY2025 had never been checked and also ties exactly. No
fan-out; the scoped view drops exactly the two known off-line-3 accounts.

**Negative test passed.** Forcing every year into the freshness window aborts the build with
`RECONCILIATION FAILED: 355 account(s)...`, `@Force = 1` does **not** bypass it, the previous
snapshot survives intact and the abort appends its own log row without overwriting the last good
run's figures.

**102 tests / 30,552 assertions still pass** — unchanged from the Phase 1 baseline.

### Decisions taken during implementation

Four of these close items the plan left open; the first was not anticipated at all.

1. **The reconciliation gate aborts only on fiscal years the LEDGER refreshed recently**
   (`@ReconMaxLedgerAgeHours`, default 36h); older years are compared and recorded as
   `ReconStaleYearDrift`. **Without this the gate aborts every night forever** — step 1 refreshes
   two years nightly and all years monthly, while step 2 rebuilds all years every run, so a closed
   year that moves in the source disagrees *correctly* for up to a month. Dev demonstrated it
   immediately: 355 accounts across eleven pre-Oversight years.
2. **The refresh log is RUN-KEYED** (`RunId IDENTITY`, append-only, trimmed to 200 runs). The plan
   left this open. Appending keeps the last good figures without `FinanceLedgerRefresh`'s MERGE and
   gives a short history for free.
3. **Segment parsing uses Phase 1's delimiter splitter, not the drafts' fixed substring offsets** —
   closing the plan's open item. Two different splitters would let a parsing difference present as
   a money defect through the reconciliation gate. No measured figure changed; it closes a latent
   defect.
4. **The `int = varchar` `LineNbr = POLineID` join is settled** — the plan flagged it as unresolved
   "because a live view has no pre-pass". The snapshot has one (gate A2, whole-table), so the build
   keeps Phase 1's fail-closed `CONVERT`.
5. **No `fn_FinanceRequisitionSource`.** The build is inline in the proc so the shipment aggregate
   is materialised once for all fifteen years; a per-year TVF would pay the dominant cost fifteen
   times.
6. **No cutover script.** Phase 1 needed one because two views that had to change together were
   already being read. Nothing reads the Phase 2 views, so there is no window to close — explicitly
   not a precedent for future changes.

### Incident during implementation

**5. Column widths were guessed, and one was wrong (2026-08-26, dev only).** The first snapshot DDL
declared `ItemDescription nvarchar(500)` on the reasoning that GP descriptions are short. The build
failed on the first row over 500 characters. The source column is `varchar(max)` and the longest
value is 668; `ReqDateCreated` is a `date`, not a datetime; everything else is
`varchar(255) COLLATE Latin1_General_CI_AS`. All passthrough types are now read off `sys.columns`
rather than chosen. Caught by the build on dev, which is what dev is for — but it would have been
caught by reading the source schema first, which costs one query.

### Verified 2026-08-27: the Agent job step and the rollback both EXECUTED on dev

Both scripts were unexecuted when the entry above was written. Both have now been run.

* **§0 preflight on dev**: exactly one step, `on_success_action = 1`, `on_fail_action = 2`,
  retry 2/20 — matching the committed `FinanceLedgerAgentJob.sql` precisely.
* **Job ran end to end**: step 1 succeeded (26s) → **chained to** step 2 (24s) → job outcome
  succeeded, 51s, both as `NT SERVICE\SQLAgent$SQLEXPRESS`. A second run reproduced it (48s).
  **That chaining is the whole point of the `on_success_action = 3` change** — left at 1 the job
  reports success nightly while step 2 never runs.
* **`ledger:status` then returned drift 0 min / outcome OK / exit 0** — the same-run assertion
  satisfied for real, not just exercised.
* **Rollback guard tested armed**: with `@DropObjects = 1` and step 2 still present it threw
  `51300` and dropped nothing. That is precisely incident 1's failure mode (`THROW` aborts only
  its own batch; every `GO` starts a new one) — the single-batch design holds.
* **Rollback tested for real**: after §8 removed step 2 and restored step 1 (job verified back to
  its original shape), the script dropped the views, proc and staging, **retained** the snapshot
  (106,358 rows) and log, and printed the last three runs. Flags back at 0 = no-op. Re-running the
  installer over the retained data restored everything.
* **Degradation confirmed**: with the proc gone, `requisition:refresh` exits 1 with a clear
  message and `ledger:status` still reports ledger freshness.

Dev is left in the intended production shape, step 2 included. Revert with §8 if unwanted.


### Re-verified 2026-08-27 against a FRESH PRODUCTION RESTORE

Dev was refreshed from the most recent production backup, which made possible the one test the
earlier run could not do. On the old dev copy only FY2025/FY2026 were post-Oversight, so only two
years could be gated. **On the restore every ledger year is post-Oversight and was refreshed
within 36h, so all thirteen were compared AND gated.**

The restore also wiped the Phase 2 objects, so this was a clean install from
`sql/FinanceRequisition.sql` — an unintended but useful test of the installer on a virgin database.

| | |
|---|---|
| Rows | **106,410** / 15 fiscal years / 1,644 accounts |
| Build | **11–14s** |
| Reconciled | **22,325** accounts, **0** mismatches |
| `ReconStaleYearDrift` | **0** (was 355 on the pre-Oversight copy) |
| Duplicate grain rows | **0** |

Every fiscal year FRESH (13–25h old) and 0 drifting: FY2026 2,238 accounts, FY2025 2,117,
FY2024–2014 785–1,886 each. **This validates the stale-year carve-out rather than weakening it** —
when the ledger is current across all years, which is production's normal state, every year is
gated and every year passes.

Read back through the views: no fan-out, and **every user/FY ties exactly** across eleven fiscal
years (FY2022/FY2023 have no source rows). FY2026 / `KCHARLES1`:
**Approved TTD 41,936,916.59, Routing TTD 4,512,250.19** — the *production* figures already
recorded in `sql/Phase2ScopeVariants.md`, reproduced to the cent through a different code path.
The scoped view drops exactly the two known off-line-3 accounts.

Agent job end to end on the restored DB: step 1 (24s) → step 2 (23s) → success, 48s.
`ledger:status`: outcome OK, drift 1 min, **exit 0**.

#### ⚠ NEW FINDING — a user-database restore silently breaks the Agent step

The job lives in **msdb**; the Phase 2 objects live in **FinanceAutomationSystem**. After the
restore the job still carried step 2, calling a proc that no longer existed — it would have failed
at 21:30 that night. Observed directly.

**Add to the production runbook: after ANY restore of `FinanceAutomationSystem`, re-run
`sql/FinanceRequisition.sql` and one manual `EXEC dbo.usp_RefreshFinanceRequisition` before the
next 21:30.** The same applies to Phase 1's objects. The failure would be loud (step 2 errors, the
job reports failure, `ledger:status` reports drift) — but better fixed during the restore than
discovered from an alert.

### Phase 2 TODO

14. **Deploy to production.** In order: `sql/FinanceRequisition.sql`, one manual
    `EXEC dbo.usp_RefreshFinanceRequisition` to prove the build, **then**
    `sql/FinanceRequisitionAgentJobStep.sql`. Scheduling a proc that has never run once is how a
    failure first becomes visible at 21:30 to nobody.
15. **Read PRODUCTION's job step 1 before amending it** — §0 of
    `sql/FinanceRequisitionAgentJobStep.sql`. Done on dev 2026-08-27; **production still never
    inspected** (the VPN was down). Dev matching the
    committed script is corroboration, not proof. **More than one step means someone has already
    amended the job and the plan needs rereading.**
16. **Measure the production build** and re-check two thresholds that are both sized off
    pre-2026-08-25 ledger timings and are probably far too loose:
    `@ReconMaxLedgerAgeHours` (36h) and `FINANCE_REQUISITION_MAX_DRIFT_MINUTES` (180).
17. **685 rows have an account number the splitter cannot parse** (unchanged on the production
    restore). Recorded, not gated — Phase 1
    hides the same accounts the same way, so gating here would abort Phase 2 on a condition Phase 1
    tolerates. Worth understanding what those account numbers look like.
18. **Phase 3 is now unblocked** — `vw_FinanceRequisitionDetail`,
    `vw_FinanceRequisitionDetailUnscoped` and `FinanceRequisitionRefresh` all exist on dev. Note
    for Phase 3: the refresh log is run-keyed, so version its filter caches against
    `MAX(RefreshedAt) WHERE Outcome = 'OK'`, not against `FinanceLedgerRefresh`.
