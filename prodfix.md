# Production Fix Plan — Finance Ledger

**Status: implemented, and superseded on scheduling.** This is the design rationale — the
measurements and the reasoning behind the snapshot are still the authoritative record of *why*.

**Do not follow its Phase 4 (Scheduling).** It predates two decisions that reversed it:

1. The refresh is a **SQL Server Agent job**, not a Laravel schedule. There is no `schedule:run`
   task, no `withoutOverlapping()` lock, and `FINANCE_LEDGER_REFRESH_TIMEOUT` no longer does
   anything. Every reference below to raising that timeout, to a 4-hour task limit, or to "the two
   Windows Task Scheduler tasks" is obsolete.
2. Production is **two servers** — the app on one Windows box, SQL Server 2022 on another.

For what to actually do: `instructionsforschedule.md` (setup and topology) and
`prodfix-steps.md` (the rollout). For what was built and measured: `prodfixprogress.md`.

---

## 0. Summary for review

Your answers changed the design. **"It is for executives, each department may be on it"** prompted
the measurement I had never taken: how cost scales with how many departments a user can see.

**Live querying is not viable at any breadth.** Even a user seeing a *single* department waits
**6.2 seconds**; ten departments takes **41 seconds**. Scoping executives to only their own
departments does not rescue it — the cost is dominated by work done before the user filter applies.

And **"if it's finance I expect accuracy to be needed"** rules out a plain daily snapshot too,
because encumbrances change intraday.

**Recommendation: a hybrid.** Snapshot the expensive, slow-changing part (the GL pivot and
allocations). Join the cheap, fast-changing part (encumbrances) **live** at read time — measured
at **0.05s**. That gives fast pages for executives *and* intraday-accurate commitments.

This is a **small change to what is already built**, not a rewrite: two columns move out of the
snapshot and into a live join in `vw_FinanceLedger`.

> **I reversed my earlier recommendation.** An hour ago I proposed dropping the snapshot entirely,
> based on a 2.89s measurement. That measurement was a single narrow-access user on a warm cache.
> Measuring breadth and repeating the sample showed both assumptions were unsafe. The reversal is
> below in full.

---

## 1. Evidence

All measured read-only on production (`sqlapp\SQLEXPRESS`, Standard Edition 16.0). **No changes
were made to production.**

### Cost scales steeply with how much a user can SEE

Measured by substituting N real department/responsibility pairs for the user-access join:

| Departments visible | Time | Rows returned |
|---|---|---|
| 1 | **6.22s** | 2 |
| 3 | 11.10s | 69 |
| 10 | **41.40s** | 532 |
| 25 | 48.56s | 625 |
| 50 | 59.25s | 801 |
| 132 (all) | 175.32s | 2,006 |

FY2026 contains **132 distinct department/responsibility pairs**.

**This is the finding that decides the design.** Even the narrowest possible user — one department,
two rows of output — waits over six seconds, because almost all the cost is incurred *before* the
user filter can apply: the GL aggregate, the linked-server segment lookups and the account-base
`UNION` are computed first, then pruned. Restricting executives to their own departments therefore
does not make live querying workable; it only moves them from 175s to 41s.

An earlier organisation-wide sample measured 74.5s against 175.3s here — see the variance note
below. The direction is unambiguous regardless of which sample you take.

### The same query is not reliably fast

The identical narrow query measured **2.89s**, **3.57s** and **16.07s** across the session, and
the organisation-wide case measured **74.5s** then **175.3s**. Production is live under the Access
users, so a web query competes with real work and its latency is unpredictable — a 2.4× spread on
the same statement.

Two consequences: a design whose viability rests on a ~3s best case is unsafe, and **every timing
in this document should be treated as provisional until repeated under representative load.**

### Fiscal-year pushdown

| Shape | Time |
|---|---|
| `GROUP BY`, FY filter inside | 1.57s |
| `GROUP BY`, FY filter outside | 0.94s — pushdown works here |
| Full query, FY inside (parameter) | 2.89s |
| Full query, FY outside (plain view) | **12.60s** |

Pushdown works through a simple `GROUP BY` but only partially through the full query — the
`UNION` base, `CROSS APPLY` splitter and join chain block it, costing 4.4×. **Any live path must
pass the fiscal year as a parameter, never as an outer filter.**

### Component costs

| Component | Production |
|---|---|
| `glData` aggregate, one FY | 0.84s |
| `allocationData` | 0.02s |
| **`encumbranceData` (696 accounts)** | **0.05s** |
| `varianceLines` | 0.01s |
| `GL40200` (linked, 418 real rows) | 0.81s |
| `DBA_Clusters` (linked, 53 real rows) | 0.13s |
| `GL00100` (linked, 9,464 real rows) | 0.35s |
| **Live `dbo.MonthlyExpenditure`** | **80.49s** (410 rows) |
| Live `dbo.vw_BudgetAllocation` | 0.61s |
| Snapshot read (replica) | 0.03s |

The encumbrance figure is what makes the hybrid work.

---

## 2. The three options

| | Pure live | Pure snapshot (as built) | **Hybrid (proposed)** |
|---|---|---|---|
| Executive page load (10–50 depts) | **41–59s** ❌ | 0.03s | **~0.1s** ✅ |
| Single-department page load | **6.2s** ❌ | 0.03s | ~0.1s ✅ |
| Latency predictable | **No** ❌ | Yes | Yes ✅ |
| GL / allocation freshness | live | nightly (= as fresh as the source) | nightly ✅ |
| **Encumbrance freshness** | live ✅ | **up to 24h stale** ❌ | **live** ✅ |
| Refresh job needed | no | yes | yes |
| Survives linked-server outage | no | yes | yes |

GL data only changes when the nightly load runs, so a snapshot refreshed after it is **as fresh
as the source can be** — "nightly" is not a compromise there. Encumbrances are the only thing that
genuinely moves during the day, and they are cheap enough to read live.

---

## 3. Plan

### Phase 0 — Deployability ⚠ first

**The working tree cannot be deployed to production today.** `DepartmentExpenditureController`
and `AllocationLineExpenditureController` read `dbo.vw_FinanceLedger`, which exists only on the
replica. Deploying as-is makes both pages fail into "data source unavailable".

The app is not live, so this is not urgent — but it blocks any deploy.

### Phase 1 — Make encumbrances live (the actual change)

Amend `sql/FinanceLedger.sql`:

1. **Remove `Approved` and `Routing` from `dbo.FinanceLedgerSnapshot`** and from the refresh
   proc's column lists. They become live.
2. **Remove the encumbrance *amounts* from `fn_FinanceLedgerSource`**, keeping the encumbrance
   account numbers in the `UNION` base so encumbrance-only accounts still get a snapshot row.
3. **Redefine `dbo.vw_FinanceLedger`** to join a live encumbrance aggregate onto the snapshot, and
   compute `ActualExpenditure`, `Excess` and `AllocationBalance` from it. Those three are already
   computed in the view rather than stored, so this is a localised change.
4. **Add a live `UNION` for intraday encumbrance-only accounts** (see §5a #3). Step 2 only covers
   accounts that existed at refresh time; an account whose first encumbrance is raised during the
   day has no snapshot row at all. The view must union in encumbrance accounts absent from the
   snapshot, with snapshot columns zero/null for them.

Everything else in `sql/FinanceLedger.sql` — the function, the nine corrections, the snapshot
table, the refresh procs, `vw_WebAppUserAccess` — stays as written and reconciled.

### Phase 1 exit criteria — measure, do not assume

Phase 1 is a **measured experiment**. Before cutover, time each of these against production for an
organisation-wide user, and repeat each three times because this box varies by up to 2.4×:

| Query | Threshold |
|---|---|
| `SELECT COUNT(*) FROM dbo.vw_FinanceLedger WHERE FinancialYear='2026'` | < 1s |
| The Monthly Expenditure page query | < 1s |
| The Allocation Line Expenditure page query | < 1s |
| The two Dashboard queries | < 1s |
| The intraday encumbrance-only `UNION` (step 4) | < 0.5s added |

**Explicit fallback if any threshold is missed:** put `Approved` and `Routing` back into the
snapshot, accept scheduled freshness for encumbrances, and raise the staleness with finance as a
known limitation. Do **not** proceed to cutover with an unmeasured view.

### Phase 2 — Fix `dbo.MonthlyExpenditure` (80s → fast)

Already handled by `sql/FinanceLedgerCutover.sql`, which redefines it as an `UNPIVOT` over
`vw_FinanceLedger`. **This is the single biggest win in the whole plan** and it is already written
and reconciled. Nothing outside the app reads that view (confirmed), so the redefinition is safe.

### Phase 3 — App layer

Mostly already done. Remaining:

1. **`AllocationLineExpenditureController`** — no change needed; it already reads `Approved` and
   `Routing` from the view, which will now be live.
2. **`BudgetAllocationController` (~5 executions) and `MonthlyExpenditureController` (~11)** —
   restructure to one query per request. **Lower priority than under the live design**, because
   against a 0.03s snapshot five executions cost 0.15s rather than 15s. Worth doing for tidiness,
   not correctness.
3. Keep `VersionsLedgerCache`, `config/ledger.php` and the filter caches as built.

### Phase 4 — Scheduling ⚠ SUPERSEDED

> **What was built instead:** the refresh is the SQL Server Agent job
> `SWRHA Finance - Ledger Refresh` on the DB server, daily at 21:30, one step branching on
> day-of-month. `ledger:refresh` survives for manual runs only; `ledger:status` and the health
> check survive unchanged. The Laravel schedule, its per-minute `schedule:run` task and the
> `withoutOverlapping()` lock are all gone. Overlap is prevented by Agent refusing to start a job
> already running. See `instructionsforschedule.md`.

Kept for the reasoning and the timings, both of which still hold:

- **Refresh timing** must follow the GL load into `0098AFinGLMaster` (still unknown — §5 Q1).
- **Full rebuild cost on production is 74–175s per fiscal year.** The organisation-wide query is
  precisely the work the snapshot build does, and it was sampled at both ends of that range. So a
  13-year rebuild is **16–38 minutes** depending on contention.
  - The nightly run touches only the current and prior fiscal year, so it is ~2–6 minutes.
  - ~~The 4-hour Task Scheduler limit~~ and ~~raising `FINANCE_LEDGER_REFRESH_TIMEOUT` to 7200~~
    both belonged to the lock on the deleted schedule. Neither applies. The Agent job has no
    timeout of its own and the config key is retained-but-unused.

### Phase 5 — Verification on production

1. **Reconcile at account grain**, both directions, against the legacy views before switching.
   Keep them as `_Legacy` until signed off.
2. **Confirm the TTD 21,128,414.88 of allocation-only accounts** appear.
3. **Validate cluster and segment names** — impossible on the replica (`LOCAL TEST CLUSTER`
   placeholders), now possible: production has 53 real clusters and 418 real segments.
4. **Verify encumbrance figures change intraday** without a refresh — the point of Phase 1.
5. Walk all five pages as an organisation-wide user and confirm sub-second loads.

---

## 4. Risks

| Risk | Mitigation |
|---|---|
| The live encumbrance join is slower inside the view than measured standalone | Measured at ~0ms on the replica (§5a #2), but re-measure on production against the Phase 1 thresholds. Fallback: return `Approved`/`Routing` to the snapshot |
| Encumbrance-only accounts vanish from the ledger | Keep their account numbers in the `UNION` base; only the amounts move live |
| **An account whose FIRST encumbrance is raised intraday is invisible until the next refresh** | Live `UNION` of encumbrance accounts missing from the snapshot (Phase 1 step 4). **This is the unbudgeted-commitment case finance most wants to see** |
| `MonthlyExpenditure` pays for a join it does not use | Measured indistinguishable (§5a #2). Verify in Phase 1; split surfaces only if it proves otherwise |
| Scheduler stops and nobody notices | `ledger:status` + health-check task already built for exactly this |
| Refresh collides with Nexus (00:00–03:00) or the GL load | Resolve timings together — see `instructionsforschedule.md` |
| Concurrency at rollout is worse than expected | Snapshot reads are ~0.03s regardless of breadth, so **the design is insensitive to how many executives there turn out to be** — the open question about user count does not change it |
| ~~Rebuild runs long enough for the overlap lock to expire~~ | **No longer applicable.** There is no overlap lock — Agent will not start a job that is already running |

---

## 5. Questions still open

1. **When does the GL load into `0098AFinGLMaster` run?** Needed to time the nightly refresh.
   The only genuinely blocking unknown left.
2. **Should allocations also be live?** They are cheap (0.02s) and could join live like
   encumbrances. Do budget allocations change during the working day, or only in budget cycles?
   If they change intraday, I would move them live too.
3. **`GL00100`:** correction (c) removed it because the replica's copy was synthesised and flaky.
   Production has 9,464 real rows reading in 0.35s. I still recommend leaving it out — segments are
   parsed from the account number and it is one fewer linked-server dependency — but the original
   justification no longer applies, so flagging it.

**Answered, recorded here:**
- Nothing outside the app reads `dbo.MonthlyExpenditure` or `dbo.vw_BudgetAllocation` — safe to
  redefine. The Access file uses the base tables and its own query.
- The web app is **not live**; it connects to production only to test query load. No user-facing
  urgency on the 80s Monthly Expenditure page.
- Audience is executives plus departmental users. **Executives see only the departments under
  them** — but the cost curve shows this does not make live querying viable, so it no longer
  affects the design.
- Finance accuracy is expected, hence live encumbrances.

**No longer blocking:** how many executive users there will be. Snapshot reads are ~0.03s
irrespective of breadth or user count, so the design does not depend on that number. It would only
have mattered under the live-query option, which the cost curve rules out.

---

## 5a. External review — verified point by point

An external review of this plan raised seven points. I tested each rather than accepting them.
**Two are adopted, one is rejected on measured evidence, four were already in the plan.**

| # | Review point | Verdict |
|---|---|---|
| 1 | Proceed with snapshot + cutover; the `MonthlyExpenditure` UNPIVOT is the real fix | **Agreed** — already the plan |
| 2 | Guard `MonthlyExpenditure` against live-encumbrance join cost | **Valid, but negligible — measured** |
| 3 | Intraday encumbrance-only accounts still will not appear | **Correct, and I missed it. Adopted** |
| 4 | Treat Phase 1 as a measured experiment with an explicit fallback | **Agreed — now explicit** |
| 5 | Raise the refresh timeout from 1800s | **Agreed** |
| 6 | Take the optional GL index seriously; "the index solves refresh cost" | **REJECTED — measured, saves ~1s** |
| 7 | Do controller consolidation after the SQL cutover | **Agreed** — already low priority |

### On #2 — real concern, negligible magnitude

`dbo.MonthlyExpenditure` selects **no** encumbrance columns (verified), so the question is whether
SQL Server eliminates the LEFT JOIN. Measured on the replica, best of three runs:

| | Time |
|---|---|
| A — no encumbrance join (today) | 0.002s |
| B — join present, encumbrance columns **not** selected | 0.001s |
| C — join present, encumbrance columns selected | 0.001s |

Indistinguishable. Whether or not the optimiser formally eliminates the join, it costs nothing
measurable: the user-access join prunes first, and the encumbrance aggregate is 696 rows.

**Adopted as a verification step, not as a design change.** The review's fallback — splitting into
a snapshot-only monthly surface and a live surface for allocation pages — would add a permanent
second read path to guard against a cost measured at ~0ms. That is not a trade worth making
unless the Phase 1 measurement contradicts this.

### On #3 — correct, and a genuine gap I missed

The plan keeps encumbrance *account numbers* in the snapshot base while moving the *amounts* live.
The review correctly points out that this only covers accounts known **at refresh time**. An
account whose first-ever encumbrance is raised at 10am has no snapshot row, so the live join has
nothing to attach to and the account is invisible until the next refresh.

This matters more than it first appears: an encumbrance-only account is a commitment against an
account with **no budget and no prior spend** — precisely the unbudgeted-commitment case finance
would most want to see the same day.

**Adopted.** `vw_FinanceLedger` gains a live `UNION` of encumbrance accounts absent from the
snapshot, with snapshot columns null/zero for them. Cost is not yet measured (the replica stalled
mid-test) — **it must be measured in Phase 1 alongside the join.**

### On #6 — rejected, and the review was misled by my own stale comment

The review cites the "OPTIONAL INDEX" note in `sql/FinanceLedger.sql`, which claimed the 6.38M-row
scan dominated the build. **That claim was wrong** and has now been corrected in the file. Measured
on production:

| | |
|---|---|
| `COUNT(*)` no filter | 0.95s |
| `COUNT(*) WHERE FinancialYear='2026'` | 0.95s (identical — confirms scan, not seek) |
| Full `glData` aggregate, one FY | 0.84s |
| **Full build, one FY** | **74–175s** |

The index would remove roughly **one second from a 74–175 second build**. It is not worth altering
a source table this application does not own. The ~72 remaining seconds are in the account-base
`UNION`, the `CROSS APPLY` splitter and the join chain — **still unprofiled, and the correct target
if refresh cost ever needs reducing.**

### On #5 — the timeout ⚠ SUPERSEDED

The original concern: `config/ledger.php` defaulted `FINANCE_LEDGER_REFRESH_TIMEOUT` to 1800s and
`routes/console.php` fed it to `withoutOverlapping()`, so against a 16–38 minute rebuild the lock
could expire mid-run.

**Moot.** `routes/console.php` no longer schedules anything, so there is no lock to expire. The
default was raised to 7200 before the move and the key is retained only so an existing production
`.env` entry does not read as a setting that silently stopped working. It is safe to delete from
both once the `.env` files are tidied.

---

## 6. What this changes versus what is already built

| Component | Status |
|---|---|
| `fn_FinanceLedgerSource` + the nine corrections | **Keep** — remove only the encumbrance amounts |
| `FinanceLedgerSnapshot` | **Keep** — drop 2 columns |
| `vw_FinanceLedger` | **Amend** — add the live encumbrance join |
| `MonthlyExpenditure` / `vw_BudgetAllocation` redefinitions | **Keep as written** |
| Refresh procs, `ledger:refresh`, `ledger:status` | **Keep** |
| Task Scheduler tasks, health check, `scripts/` | **Keep** |
| Both rebuilt controllers + tests | **Keep** |
| `BudgetAllocation` / `MonthlyExpenditure` controllers | Restructure (now low priority) |

The net change is small. The earlier proposal to delete the snapshot and the whole scheduler
workstream is **withdrawn**.
