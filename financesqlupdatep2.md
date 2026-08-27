# Phase 2 — Requisition-line detail (data layer)

**Status:** designed, not started. Phase 1 (the ledger summary) is live since 2026-08-26.

Split out of `financesqlupdate.md` on 2026-08-26, which now covers Phase 1 only. Progress,
incidents and open TODOs for **all** phases are recorded in `financesqlupdateprogress.md` — this
file is design and rationale, not a running log.

| | |
|---|---|
| **Delivers** | `dbo.FinanceRequisitionSnapshot` + refresh + read views, and a second step in the Agent job |
| **Does not deliver** | any controller, route or page — that is `financesqlupdatep3.md` |
| **Depends on** | Phase 1 deployed (the reconciliation gate reads `FinanceLedgerSnapshot`) |
| **Reference queries** | `sql/Phase2RequisitionDetail_{Routing,Approved}.sql` (+ `_NoScope` variants) |
| **Guard** | `sql/Phase2ReconciliationTest.sql` |
| **Variant comparison** | `sql/Phase2ScopeVariants.md` |

---

## Adopted basis

`SQL Web App Workings E - Approved.sql` and `SQL Web App Workings E - Routing.sql` — requisition
line detail views over `encumberanceDetails`, filtered `Status IN ('AP','PO')` and
`('RT','HD','PN')`, with new pages to render them. They reuse the `ActCost` definition from
step 2c verbatim. Building them is still out of scope for the Phase 1 cutover.

> **DECIDED 2026-08-26 — Phase 2 builds on the corrected scripts, not the drafts.**
> `sql/Phase2RequisitionDetail_Routing.sql` and `sql/Phase2RequisitionDetail_Approved.sql` are the
> Phase 2 basis. The two-way access join in the `sql/source/` drafts is **not** to be shipped in
> any form. Those drafts stay in `sql/source/` as immutable reference copies; the corrected files
> are what the Phase 2 views are derived from.
>
> **DECIDED 2026-08-26 — Phase 2 carries the same goods and services scope as the summary.**
> These are drill-down views for the summary's Approved and Routing figures, so an account
> visible in detail but excluded from the summary would leave the two disagreeing with no way to
> reconcile them. The reporting-line-3 join is applied in both corrected scripts, excluding
> `4-80600-H01-401-0627-00-000` and `4-81500-H01-307-0601-00-000`.

## The two-way access join — measured on production, 2026-08-26

Both scripts were run against production with `EmployeeName = 'KEN CHARLES'` substituted for the
hardcoded `'FRANCIS FIGUERA'` (who now has no mapping at all). `KCHARLES1` / FY2026, read-only:

| Script | Variant | Rows | Distinct lines | ExtendedCost (TTD) | Accounts | Institutions |
|---|---|---|---|---|---|---|
| Routing | as written (2-way) | 5,949 | 3,282 | 131,164,220.53 | 350 | 47 |
| Routing | 2-way, deduped access | 3,282 | 3,282 | 67,112,911.55 | 350 | 47 |
| Routing | **3-way** | **777** | **777** | **4,696,550.19** | **121** | **2** |
| Approved | as written (2-way) | 30,626 | 16,702 | 2,711,349,433.34 | 521 | 48 |
| Approved | 2-way, deduped access | 16,702 | 16,702 | 1,364,855,778.96 | 521 | 48 |
| Approved | **3-way** | **3,452** | **3,452** | **38,080,501.68** | **147** | **2** |

The middle row of each pair separates **two distinct defects** that the two-way form combines:

1. **Fan-out.** The scripts' inline `userAccess` CTE carries no `DISTINCT`, and 32 of KCHARLES1's
   128 `(Responsibility, Department)` pairs span two institutions (160 CTE rows / 128 pairs / 160
   triples, confirmed on production). Every line on those pairs is emitted twice: Routing 2,667
   duplicate rows, Approved 13,924, money inflated 1.95x and 1.99x respectively.
2. **Over-permissiveness.** Comparing deduped-2-way to 3-way, Routing drops 76% of lines and 93%
   of value, Approved 79% and 97%. KCHARLES1 is granted **2** institutions; the two-way join
   returns lines spanning **47-48**.

Combined, shipping Approved as written would report **TTD 2.71bn where the correct figure is
38.1M** — a 71x overstatement.

**Reconciliation against the live summary.** `vw_FinanceLedger` holds 831 accounts for
KCHARLES1/FY2026 (matching the 831 rows in the Decision D table above). The two-way detail touches
654 accounts, **441 of them (67%) absent from the summary**. The three-way detail touches 215, of
which only **2** are absent — `4-80600-H01-401-0627-00-000` and `4-81500-H01-307-0601-00-000`,
both off reporting-line-3. So the access fix reconciles the two pages to within the known goods
and services scope rule, and nothing else.

## Corrected scripts

`sql/Phase2RequisitionDetail_Routing.sql` and `sql/Phase2RequisitionDetail_Approved.sql` — copies
of the two drafts with the inline `userAccess` CTE replaced by `dbo.vw_WebAppUserAccess` joined on
all three access columns, and `'2026'` parameterised. Both verified on production, returning the
3-way figures above. The `sql/source/` originals are untouched.

That substitution fixes four things at once: the three-way scope; the fan-out (the view is
`DISTINCT` on the 4-tuple, verified 160 rows = 160 distinct 4-tuples); the hardcoded
`EmployeeName`; and the `IsActive` filter, which the drafts applied to `0006C` only.

## Snapshot-backed, not live views — decided 2026-08-26

**Phase 2 is snapshot-backed, not live views.** The earlier recommendation was live views on the
grounds that they "read only two small local tables". That was wrong on cost, and — more
importantly — a live view cannot enforce the reconciliation guarantee this phase now depends on.
The pages that consume this are **Phase 3** (`financesqlupdatep3.md`).

### Why snapshot, in order of weight

1. **It makes reconciliation a build-time gate rather than a manual script.** Phase 2's whole
   justification for carrying the reporting-line-3 scope is that detail must agree with the
   summary. On a live view that agreement is asserted by running
   `sql/Phase2ReconciliationTest.sql` by hand and hoping nobody changes anything. As a snapshot it
   becomes a **sanity gate inside the refresh proc**: if per-account detail totals do not tie to
   `FinanceLedgerSnapshot`'s `Approved`/`Routing`, the build aborts and the previous snapshot
   stands — the same shape as Phase 1's existing zero-row and movement gates.
2. **Detail and summary must move together.** They are the same numbers at two grains. If the
   summary refreshes nightly and the detail reads live, the two disagree for most of every day and
   a user drilling in cannot reconcile them — which is precisely the defect this phase exists to
   prevent. Snapshotting in the *same job step* makes lockstep structural rather than hoped for.
3. **Performance.** Approved is ~47s per execution live. Measured attribution: the cost is
   `GROUP BY PONumber, CONVERT(int, POLineID)` over the 250,897-row `0098FPOShipmentDetails`, not
   the scope join. That aggregate is mandatory (183 surplus rows on duplicate keys would otherwise
   fan out). Paying it once per refresh instead of once per page load is the same trade Phase 1
   already made.
4. **It retires the read-time substring problem.** `AccountN` and the three access segments are
   stored as real columns at build time, so the read path joins on indexed columns instead of
   `substring(GLAccount, …)`.

### Sizing — this is a small table, and that shapes the design

Measured 2026-08-26 on `0040DBudgetsEncumbrance`, statuses AP/PO/RT/HD/PN:

| Fiscal year | Rows | Approved | Routing | Accounts |
|---|---|---|---|---|
| 2026 | 20,647 | 17,188 | 3,459 | 697 |
| 2025 | 16,538 | 16,067 | 471 | 606 |
| 2024 | 14,163 | 13,663 | 500 | 450 |
| **all 15 years** | **~106,400** | — | — | — |

**Consequence: rebuild every fiscal year, every run.** Phase 1 branches on day-of-month because a
per-FY build costs minutes; here the whole history is ~106k rows and the dominant cost — the
shipment aggregate — is paid once no matter how many years are built. Phase 2 needs no incremental
logic, no day-of-month branch, and no `--year` option.

Note FY2022 and FY2023 have **no rows at all** in the source. That is source data, not a filter
bug, and any zero-row sanity gate must be per-build rather than per-year or it will abort forever.

### Objects (Phase 2)

All new, all owned by this project — no pre-existing object is written to.

| Object | Role |
|---|---|
| `dbo.FinanceRequisitionSnapshot` | grain `(FinYear, RequisitionNumber, PONumber, LineNbr)`, **user-agnostic** |
| `dbo.FinanceRequisitionSnapshot_Staging` | build target, swapped in on success |
| `dbo.FinanceRequisitionRefresh` | refresh log, mirroring `FinanceLedgerRefresh` |
| `dbo.usp_RefreshFinanceRequisition` | build + gates + swap |
| `dbo.vw_FinanceRequisitionDetail` | read surface, scoped |
| `dbo.vw_FinanceRequisitionDetailUnscoped` | read surface, unscoped |

**The snapshot is user-agnostic and stores the superset.** `UserName` is joined **live** through
`dbo.vw_WebAppUserAccess` on all three access columns, exactly as `vw_FinanceLedger` does, so a
permission change takes effect on the next request with no refresh. Do not denormalise `UserName`
into the snapshot.

**Scope is a stored flag, not a build filter.** The snapshot holds every row and carries
`IsGoodsAndServices bit`, computed once at build against the reporting-line-3 list. The scoped
view filters on it; the unscoped view does not. That keeps both behaviours documented in
`sql/Phase2ScopeVariants.md` available at zero read cost, and removes the runtime scope join
entirely — the reason those two variants currently exist as separate files disappears once Phase 2
lands.

### Refresh — a second step in the existing Agent job, built to the same pattern

Add a **second step to the existing `SWRHA Finance - Ledger Refresh` job**, running after the
ledger step. Not a second job and not a second schedule: the two snapshots must be built from the
same source state, a separate schedule reintroduces the drift this design exists to remove, and
the reconciliation gate depends on the ledger step having completed first.

`php artisan ledger:refresh` gains a sibling for manual runs; **do not** add a Laravel
`Schedule::command()` entry — the standing rule against double-scheduling the Agent job applies
here unchanged.

**Everything below mirrors `sql/FinanceLedgerAgentJob.sql` section by section.** That file is the
pattern; Phase 2 does not invent a new one.

| `FinanceLedgerAgentJob.sql` | Phase 2 equivalent |
|---|---|
| §1 Agent service account | unchanged — same account, already identified |
| §2 / §4 linked-server GATES | **not needed.** Retired for Phase 1 when the COA moved local (2026-08-25); Phase 2 reads only local tables, so it never reintroduces the dependency |
| §3 Grants | extended — see below |
| §5 Create the job | **amended**, not recreated — see the step-ordering note |
| §6 Start once and verify | same shape, reading `FinanceRequisitionRefresh` |
| §7 GL load window | unchanged — same source timing question |
| §8 Rollback | extended to drop step 2 and restore step 1's success action |

**Grants (§3).** The Agent account needs the same rights on the new objects that it has on the
ledger ones:

```sql
GRANT EXECUTE  ON dbo.usp_RefreshFinanceRequisition            TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot         TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot_Staging TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, UPDATE ON dbo.FinanceRequisitionRefresh          TO [NT SERVICE\SQLAgent$SQLEXPRESS];
```

`db_datareader` is already granted and covers reading `0040DBudgetsEncumbrance`,
`0098FPOShipmentDetails` and `FinanceLedgerSnapshot`.

**Step ordering — the one change to the existing job, and it is easy to miss.** Step 1 is created
with `@on_success_action = 1` (*quit reporting success*) at `sql/FinanceLedgerAgentJob.sql:212`.
Left as-is, **a second step would never run.** It must become `3` (*go to the next step*).

> **CONFIRMED ON DEV, STILL TO CONFIRM ON PRODUCTION.** Run on the dev instance 2026-08-26, the
> deployed job matches the committed script exactly — one step, `Refresh snapshot`,
> `on_success_action = 1`, `on_fail_action = 2`, `retry_attempts = 2`, `retry_interval = 20`,
> `database_name = FinanceAutomationSystem`. Production was **not** checked: the corporate VPN was
> down for the rest of that session, so there was no route to the DB server. Dev matching is good
> corroboration, not proof — run this on production before changing anything, because if its
> step 1 differs, so does the change:
>
> ```sql
> SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action,
>        s.retry_attempts, s.retry_interval, s.database_name
> FROM msdb.dbo.sysjobs AS j
> JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
> WHERE j.name = N'SWRHA Finance - Ledger Refresh'
> ORDER BY s.step_id;
> ```
>
> Expect exactly one step, `on_success_action = 1`, `on_fail_action = 2`, `retry_attempts = 2`.
> More than one step means someone has already amended the job and this plan needs rereading.
>
> Run it as an admin login in SSMS on the DB server — the app login (`finance`) is unlikely to
> have msdb rights, so this is not something the application side can check for itself.

```sql
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'SWRHA Finance - Ledger Refresh',
    @step_id  = 1,
    @on_success_action = 3;      -- was 1 (quit with success)
```

Step 1's `@on_fail_action = 2` stays. That is deliberate: if the ledger build trips a sanity gate,
the job quits and the requisition step does **not** run, so both snapshots stay on their previous
contents together rather than the detail advancing past a summary that did not.

**Step 2**, matching step 1's settings exactly — same subsystem, same database, same retry policy,
same failure action:

```sql
EXEC msdb.dbo.sp_add_jobstep
    @job_name   = N'SWRHA Finance - Ledger Refresh',
    @step_name  = N'Refresh requisition detail',
    @subsystem  = N'TSQL',
    @database_name = N'FinanceAutomationSystem',
    @retry_attempts = 2,
    @retry_interval = 20,          -- minutes; transient DB errors
    @on_success_action = 1,        -- quit reporting success (last step)
    @on_fail_action    = 2,        -- quit reporting failure
    @command = N'
SET NOCOUNT ON;
RAISERROR(''Finance requisition detail: full rebuild (all fiscal years).'', 0, 1) WITH NOWAIT;
EXEC dbo.usp_RefreshFinanceRequisition @Force = 0;
';
```

**No day-of-month branch.** Step 1 branches because a per-FY ledger build costs minutes; the whole
requisition history is ~106k rows and the dominant cost is paid once, so step 2 rebuilds every
year every run. The `RAISERROR ... WITH NOWAIT` progress line follows step 1's convention.

**Schedule (§5d).** Untouched — daily 21:30, one schedule, one job.

**`FinanceRequisitionRefresh` mirrors `FinanceLedgerRefresh`**: `RefreshedAt`, `RowsLoaded`,
`DurationSeconds`, `Outcome` (`OK` | `ABORTED`), `Message`, plus the reconciliation totals the
gate compares. Keying it on `FinancialYear` the way the ledger log is keyed makes no sense for a
full rebuild — use a single-row log, or a run-keyed one, and say which in the DDL.

### The divergence window this creates, and how it is monitored

Agent steps cannot share a transaction. So there is one failure mode the design cannot remove: if
**step 1 succeeds and step 2 fails**, the summary advances and the detail does not, and the two
disagree until the next successful run. The reconciliation gate catches it on the next build, but
it does not prevent the window.

That is acceptable — a failed step 2 is visible and self-correcting — but **only if monitoring
looks at both snapshots.** `php artisan ledger:status` and `scripts/check-ledger-health.ps1`
currently read `MAX(RefreshedAt)` and `Outcome` from `FinanceLedgerRefresh` alone, so a
step-2-only failure would be **completely silent** today. Phase 2 must extend the health check to:

1. read `FinanceRequisitionRefresh` for staleness and `Outcome` the same way, and
2. assert the two `RefreshedAt` values are from the **same run** — a drift between them is the
   symptom of exactly this failure, and it is the one thing neither table shows on its own.

That is a Phase 2 deliverable, not a Phase 3 one: it ships with the job change, because the job
change is what creates the failure mode.

### Staleness — the honest cost of this decision

The original live-view argument had one good half: *users expect current state for open
requisitions*. Snapshotting gives that up. A requisition raised at 09:00 will not appear until the
next refresh.

This is accepted deliberately, because a detail page that disagrees with the summary it drills
into is worse than one that is explicitly "as at 21:30 last night". Two things follow, and both
are Phase 3's job:

* the pages must **display the refresh timestamp** from `FinanceRequisitionRefresh`, not present
  the data as live;
* if finance needs fresher than daily, the answer is to run the **whole job** more often — it is
  roughly a minute of work — never to refresh the detail alone.

## The reconciliation test, and the second defect it found

`sql/Phase2ReconciliationTest.sql` is the guard on both decisions. It runs read-only as the user
under test and asserts:

* **TEST 1** — every account reachable through the shipped detail query is on reporting line 3.
  It is built from the same joins the detail scripts use, so removing the scope join breaks it.
  Result 2026-08-26: **PASS**, 0 off-line-3, 213 accounts in scope, 2 excluded by the filter.
* **TEST 2** — Phase 2 amounts, grouped to account grain, tie to Phase 1 `Approved`/`Routing` in
  `vw_FinanceLedger` for the same user, fiscal year and access scope.

**TEST 2 initially failed, and the failure was real.** 16 accounts differed, net
−9,930,333.27 on Approved while Routing tied exactly. The cause was the drafts' `ActCost`, which
differs from Phase 1 in three ways: it is **not floored at zero**, so an over-shipped line carries
a negative commitment that nets off genuine ones (account `4-75600-H01-211-0626-00-000` came out
at −5,945,460.79 against +1,513,488.86 in the summary); it joins the shipment table **without
pre-aggregating**, so a duplicated `(PONumber, POLineID)` fans the line out; and it is **float**
arithmetic rounded afterwards. Routing tying exactly was the diagnostic — RT/HD/PN are pre-PO
statuses that cannot have shipments.

Both corrected scripts now use the Phase 1 `encumbranceData` definition verbatim. **TEST 2 result
after the fix: PASS**, 0 mismatches across 831 accounts, net drift TTD 0.01. This is what the plan
meant by "reuse the `ActCost` definition from step 2c verbatim" — it is not optional, and the
drafts do not satisfy it.

**Shipping figures**, KCHARLES1 / FY2026: Routing 773 rows / TTD 4,512,250.19 (120 accounts);
Approved 3,408 rows / TTD 41,936,916.59 (145 accounts carry AP/PO rows, 141 a non-zero value).
Both tie exactly to `vw_FinanceLedger`.

**Both behaviours are kept runnable.** `sql/Phase2RequisitionDetail_*_NoScope.sql` are the same
scripts without the scope join, and `sql/Phase2ScopeVariants.md` documents the choice, the
measurements and the trade-off. Unscoped: Routing 777 rows / 4,696,550.19, Approved 3,452 rows /
48,010,834.95. The unscoped variants cannot reconcile to the summary — that is the trade-off, and
they are **not** faster.

**Still open for Phase 2**, recorded in each file's header:

* **Performance — and the attribution is not what it first looked like.** Approved runs ~47s;
  Routing ~9s. An earlier reading blamed the goods-and-services join. Four timed configurations
  show otherwise: draft `ActCost` + no scope = 0.5s; draft + scope = 46s; Phase 1 `ActCost` + no
  scope = 48s; both = 47s. **Either correction alone costs the time and applying both adds
  nothing.** Isolating further: keeping the zero-floor and decimal conversion but dropping the
  shipment *pre-aggregation* returns to 0.5s, so the whole ~47s is
  `GROUP BY PONumber, CONVERT(int, POLineID)` over `0098FPOShipmentDetails`. That aggregate is not
  optional — it is what stops the 65 duplicated keys fanning rows out. Phase 1 pays it once per
  refresh in a batch job; a live view pays it per page load. Ruled out by measurement: the 41-row
  `varianceLines` list (87ms alone), hoisting it into a table variable, and a `@flag` +
  `OPTION (RECOMPILE)` toggle. **This should reopen the "live views, not snapshots" recommendation
  in `financesqlupdateprogress.md` item 10.**
* The fixed substring offsets, unchanged from the drafts.
* The `int = varchar` join `A.LineNbr = B.POLineID`. Phase 1 relies on its refresh proc validating
  values and failing closed; a live view has no pre-pass, so a non-numeric `POLineID` errors.

---
