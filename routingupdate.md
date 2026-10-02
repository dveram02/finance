# Fiscal Year becomes an optional filter on Encumbered Details & Routing Details

Plan, **rev 7** (2026-10-01). Branch `feature/ledger-oversight-update`. Nothing here commits, merges,
changes an **existing** SQL object, adds a migration or adds a dependency.

> **Rev 7 incorporates a fifth review round. All twelve findings verified and ACCEPTED** — one a
> concrete redirect bug (§5.7), one a reasoning error that rev 6's own change had invalidated (§3.1).
>
> Earlier revision notes follow, kept for the record.
>
> The headline is an **architectural contradiction in rev 4 that a measurement resolves**. Rev 4's
> refusal told the user to *"narrow it with a department or account filter"* — but the bounded fetch
> runs **before** categorical filters, which are applied in memory afterwards. Those filters never
> reach SQL, so they cannot shrink an oversized scope. The advice was impossible.
>
> **The measurement that settles it:** the largest single-year scope, snapshot-wide, is **18,945 rows**
> (FY2026, AP/PO) against a 25,000 ceiling. So **selecting a year is a real recovery path** — every
> year fits — while department/account filtering is not. Rev 5 offers only the recovery that works,
> and `years` comes from `availableYears()` rather than from the fetched rows, so **the year dropdown
> is still populated in a refusal state** and the recovery is genuinely reachable in the UI.
>
> Rev 5 also drops rev 4's unverified claim that tied rows are "interchangeable to a reader", corrects
> a redirect warning that could state a falsehood, and replaces the chip's row-count copy, which would
> have rendered "All 0 fiscal years" during an outage — where 0 is not known, it is unmeasured.

---

## §0 Review disposition

Measured on local SQL Server (`SQLSRV_HOST=127.0.0.1`), 2026-10-01, user `FFIGUERA1`.

### Round 7 (this revision)

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | Selected-year export refusal redirects to `?fy=0` | ✅ **ACCEPTED — would misbehave** | `$year ?? 0` with `suggestedYear` deliberately null → `?fy=0`, which `validFilter()` drops, so `index()` reads it as all-years and **redirects again to the newest year** — moving the user off the year they asked about, and directly contradicting the sentence below it claiming the requested year is preserved. Two explicit branches now (§5.7) |
| 2 | `memory_limit` was read from **CLI**, not the web SAPI | ✅ **ACCEPTED** | Apache can load a different `php.ini` (`PHPIniDir`, per-vhost `php_admin_value`). At 256M the 25,000 ceiling would not fit (~17,000), so the gap is material. §12 item 2 reopened as **confirmation-pending**; rev 6's "no release blockers remain" was one step too far |
| 3 | The sort-uniqueness reasoning is self-contradictory | ✅ **ACCEPTED — and it SIMPLIFIES the design** | Appending `PONumber` made the sort key a **superset** of the grain key `DuplicateGrainRows` already watches (`+ Department`), and a superset of a unique key is unique. So `DuplicateGrainRows = 0` **does** prove sort-key uniqueness. Verified: both keys return 0 extra rows of 108,435. The old wording was true of rev 5's four-column key and survived the change that falsified it (§3.1) |
| 4 | An integration assertion is unreachable | ✅ **ACCEPTED** | The all-years `SCOPE_TOO_LARGE` variant cannot occur over HTTP — with eligible years it redirects, without them the scope is 0 rows and cannot be refused. Feature test now asserts only the single-year variant; the selector is a unit case (§9.2 case 13) |
| 5 | Test-strategy cross-references contradict rev 6 | ✅ **ACCEPTED** | §7.3h still pointed at "§9.2 cases 13–15" for rendered-HTML checks that had already moved to manual §9.4.1. Replaced with an explicit two-layer table |
| 6 | Parser docs disagree with parser code | ✅ **ACCEPTED** | `trim()` **accepts** `' 25000 '` while the comment said whitespace was rejected, and "optional sign" describes a branch `^\d+$` does not have. Docblock, acceptance table and three new test cases now agree (§6.5, §9.2 cases 12–14) |
| 7 | `MAX_CEILING = 150000` is not justified by the concurrency model | ✅ **ACCEPTED** | The concurrency table only ever modelled the 172 MB default; 150,000 rows is ~875 MB, so ten concurrent would be ~8.75 GB on a 16 GB VM shared with MySQL. Lowered to **50,000** and reframed as an **absolute parser bound, not a certified-safe value** (§6.5) |
| 8 | Pint command omits new files | ✅ ACCEPTED | `RequisitionScopeThresholds.php` and all five changed test files added (§9.5) |
| 9 | §2 measurements table malformed | ✅ ACCEPTED | Orphan pipe rows appeared after intervening prose and would not render as part of the table. Reordered |
| 10 | Heading still said "Rev 5 incorporates…" | ✅ ACCEPTED | Corrected |
| 11 | Export cross-refs point at "§9.4 case 5", which has no numbered cases | ✅ ACCEPTED | Repointed to §9.2 cases 16–17 |
| 12 | Manual checks don't cover both refusal branches | ✅ ACCEPTED | Four-branch walk-through added (§9.6 step 9) — only testing one branch is how the `fy=0` bug survived |

### Round 6 (carried forward; see Round 7 for what it superseded)

Rev 5's prose was sound; its **snippets had drifted out of agreement with each other**. Four of these
would have failed at runtime if implemented literally.

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | Threshold object wired as an array | ✅ **ACCEPTED — would crash** | `[$ceiling, $warnAt] = $this->scopeThresholds()` against a plain readonly class. Not iterable → `Error`. Fixed to property access (§6.1) |
| 2 | `refusedResolution()` called with a missing argument | ✅ **ACCEPTED — would crash** | 6-param signature, 5-arg call → `ArgumentCountError`, firing **exactly when the capacity guard trips** (§5.3) |
| 3 | Two conflicting `index()` snippets | ✅ **ACCEPTED** | §5.2 still passed the bare constant and said "16 props"; §6.3 had the corrected form. Whichever was read first decided whether users saw a literal `FY :year`. §5.2 is now the single canonical copy |
| 4 | `(int) env(...)` casts garbage to 0 **before** validation | ✅ **ACCEPTED — defeats the whole design** | `(int) 'abc' === 0`, and 0 is the explicit opt-out, so an `.env` typo **silently disabled the guard** — the exact failure the fail-closed helper was written to prevent. Raw value now passed through; strict integer-string parsing rejects `'0.5'`, `'00'`, `'1e-9'`, whitespace (§6.5) |
| 5 | `MAX_CEILING = 200000` is not a safe cap | ✅ **ACCEPTED** | ~1.1 GB against an unmeasured limit. Settled in rev 7 at **50,000 as an absolute PARSER bound** (§6.5) — rev 6's 150,000 was ~875 MB/request, which the concurrency model (built only for the 172 MB default) never justified |
| 6 | Capacity evidence internally inconsistent | ✅ **ACCEPTED — my error** | 106 MB and 172 MB both quoted for 25,001 rows. Re-measured: **106 MB was 12 columns with no derive and no totals** — not the real path. The real pipeline is **172 MB total / ~130 MB over a 42 MB baseline**, CLI. Method now recorded in §2 |
| 7 | Not every path told to supply all 17 props | ✅ **ACCEPTED** | `unavailable()` and the test `PROPS` list were told to add only `scopeRefused`, and the normal `resolve()` return was never updated → a 16-vs-17 parity failure for an uninteresting reason. Per-path table added (§5.1) |
| 8 | `(int) $years->first()` yields `0`, not `null` | ✅ **ACCEPTED** | Would make `shouldRedirectToSuggestedYear()` true and redirect to `?fy=0`. Explicit null check added; the unreachable branch is now labelled defensive-only, with the `WHERE 0 = 1` reasoning stated (§5.1) |
| 9 | PHP feature tests cannot verify Vue DOM | ✅ **ACCEPTED — and worse than failing** | **Verified: no Inertia SSR.** A real `GET /login` response is `<div id="app" data-page="…">` with **no `<h1>` at all**. `assertDontSee('TTD 0')` would pass **vacuously** — a green tick for an unverified rule, the silent no-op hazard CLAUDE.md warns about. Moved to manual checks (§9.4.1) |
| 10 | The FY formatter is not tested by PHP | ✅ **ACCEPTED** | PHP never executes `fiscalYear.js`. **Node v24.20.0 verified present** and `package.json` is already ESM, so `node --test` covers it with **no new dependency** (§3.2) |
| 11 | Stale test/file counts | ✅ **ACCEPTED** | 17 cases vs "12"; 11 vs "seven". Corrected (§10) |
| 12 | Refused all-years export is underspecified | ✅ **ACCEPTED** | `exportRedirect()` replays the query → index → **a second redirect** → final flash describes *display* selection, never saying no file was written. Dedicated messages and a direct-to-year target added (§5.7) |
| 13 | Categorical controls described as inert but not disabled | ✅ **ACCEPTED** | They kept live `@change` handlers over empty option lists. Now `:disabled="scopeRefused"` with one line of explanation (§7.3h) |
| 14 | Repository/release-state claims false | ✅ **ACCEPTED** | "only untracked change" was stale (two modified files) and the Vite fix was called "shipped" when it is local and uncommitted. Four-term status vocabulary added (§1) |
| 15 | Carried-forward history contradicts the current decision | ✅ **ACCEPTED** | Round 4's row said `PONumber` was dropped; §3.1 appends it. Row marked **superseded**, and `detailRows()`'s "only change" comment corrected (§0, §5.6) |

### Round 5 (carried forward; see Round 6 for what it superseded)

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | A refused scope would display **false zeros** | ✅ **ACCEPTED — critical** | Verified in the component: the KPI grid (L255) and `ExportCsvButton` (L349) are **unconditional**, and `v-if="rows.data.length === 0"` (L559) fires. A refusal would render **TTD 0 · 0 requisitions · 0 lines · "No requisition lines found" · export disabled as "no matching rows"** — exactly the fake zero CLAUDE.md forbids. Fixed in §7.3h |
| 2 | Recovery/export messages contradict behaviour | ✅ **ACCEPTED ×3** | (a) the single-year refusal said *"Use the CSV export"* while `export()` refuses that same scope (test 11); (b) the redirect said *"Narrow it further"* though categoricals provably cannot help; (c) `:year` was passed as a bare constant, so users would read a literal **"FY :year"**. All three fixed in §6.3 |
| 3 | Threshold normalisation disables the protection it claims | ✅ **ACCEPTED** | `max(0, …)` turns a negative or malformed value into 0, and 0 means *unbounded* — contradicting the comment directly above it. No hard maximum, and `$ceiling + 1` can overflow. Fixed in §6.5 |
| 4 | The refusal prop contract is incomplete | ✅ **ACCEPTED** | Contract B said 16 props, but §7.3h needs a server-supplied `scopeRefusedMessage` — a 17th. `refusedResolution()` was named but never specified. Both fixed in §5.1 |
| 5 | Ordering rests on a temporary observation | ✅ **ACCEPTED — and it costs nothing** | Appending `PONumber` **after** `LineNbr` (not before, which rev 4 wrongly proposed) is **provably inert**: 0 tied groups on the first four keys means it is never consulted, so single-year output stays byte-identical *and* the future tie is guarded without a manual check. Also true: my `CONCAT` uniqueness query was unsafe — **685 NULL `Department`**, 20,648 empty `PONumber` — now `GROUP BY` (§9.7) |
| 6 | The offline threshold test is not implementable as written | ✅ **ACCEPTED** | `scopeThresholds()` was `private` while a unit test claimed to cover it directly. Extracted to a pure class (§6.5) |
| 7 | The headline CSV promise needs a decision | ✅ **ACCEPTED** | §1 promised the CSV "covers every eligible year" while the guard refuses an oversized all-years export. Contract chosen and stated once (§6.6) |

### Round 4 (carried forward — one row SUPERSEDED, see note)

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | Filtering cannot rescue an oversized scope | ✅ **ACCEPTED — critical** | True. The bounded fetch filters by user + year + status only; the six categorical filters are applied **in memory afterwards**, so `?department=X` fetches the same oversized scope and is still refused. The advice was impossible. Resolved by measurement, §6.2 |
| 2 | "Surviving categorical filters" can't be identified at redirect time | ✅ **ACCEPTED** | True — the early return precedes all six `validFilter()` calls, so only raw request values exist. They are now passed through as **requested**, not "surviving", and re-validated by the redirected request (§6.3) |
| 3 | The refusal contracts are architecturally unclear | ✅ **ACCEPTED** | True — rev 4 said `refusedScope()` returns "the same props as `unavailable()`", conflating `resolve()`'s internal array with an Inertia response. Two contracts now defined separately, and `index()`'s decision is shown (§5.1, §5.2) |
| 4 | The redirect warning can be false | ✅ **ACCEPTED** | True — "so FY 2026 is shown" is a lie if FY2026 is itself over the ceiling. Reworded (§6.3) |
| 5 | Tied rows are not necessarily interchangeable | ✅ ACCEPTED — ⚠️ **ITS RESOLUTION IS SUPERSEDED BY REV 6** | The "interchangeable" claim was withdrawn and stays withdrawn. But rev 5 then **dropped `PONumber`**, and rev 6 **appends it after `LineNbr`** instead — provably inert (0 tied groups ⇒ never consulted) while guarding the one future tie without a manual check. `AccountNumber` stays dropped. **§3.1 is canonical; ignore the "dropped as redundant" conclusion recorded in this row.** |
| 6 | "All N fiscal years" has empty/singular problems | ✅ **ACCEPTED** | "All 0 fiscal years" on an outage — where 0 is *unknown*, not measured — and "All 1 fiscal years" ungrammatical. Replaced with "All available fiscal years" (§3.3) |
| 7 | Critical guard tests remain SQL-dependent | ✅ **ACCEPTED** | The refusal/redirect decision is extracted as a pure method with offline unit tests; SQL-backed tests keep the query integration; thresholds computed per route, not hard-coded (§9.2) |
| 8 | Configuration edge cases undefined | ✅ **ACCEPTED** | True — `row_ceiling = 0` returned early, silently disabling warnings too. Invariants defined and clamped (§6.5). Also surfaced: `row_warn = 10000` would fire on **four** normal single-year views for a broadly-mapped user |
| 9 | "Accepted" is not "fixed" | ✅ **ACCEPTED** | Five unresolved operational items moved into a prerequisite table with owner, due point, evidence and blocking status (§12) |

### Rounds 1–3 (carried forward, still in force)

| # | Finding | Evidence |
|---|---|---|
| R1-A | All-years would include forbidden FY2011-13 rows — **critical** | Leak **49 rows / TTD 75,829.66** on today's only mapped user. Fixed in §4 |
| R1-B | Totals test invalid with signed money | `assertGreaterThan` unsound; **16 negative lines in scope** |
| R1-C | Needs all-years reconciliation | Exact invariant: diff **0.00** both sides |
| R1-D | FY2026 "Current" example wrong | `currentFiscalYear()` = **2027**; max selectable 2026, so no year shows "Current" |
| R1-E | Invalid-year manual check contradicts the frontend | §9.6 step 8 splits the two cases |
| R1-F | Cross-year requisition counting | Numbers recur; worst case undercounts **106** of 24,065 |
| R1-G | Stale docs/comments | All paths verified |
| R2-1 | "13 eligible years" wrong | **Encumbered 11**, **Routing 3**; 13 is the ledger boundary |
| R2-4 | Outage accepted any four-digit year | Falls back to All (§5.4) |
| R2-5 | `financesqlupdatep3.md` is a declared authority | L198 *"This section WINS…"*, still describing the hero, old test name, zero floor |
| R2-6 | Export coverage named only one route | Parameterised over both (§9.4) |
| R2-7 | Ordering rested on an observation | Grain declared **including `PONumber`**; index "DELIBERATELY NOT UNIQUE" |
| R2-8 | `animate-ping` ignores reduced motion | `motion-reduce:animate-none` |
| R3-1/5 | Guard bypassable + count/fetch race | Replaced by the bounded fetch (§6.1) |
| R3-7 | Dropdown oldest-first | `orderBy` ascending + `array_intersect` preserves order (§5.5) |

---

## §1 Context

The two Phase 3 drill-downs — **Encumbered Details** (`/encumbered-details`, AP/PO) and **Routing
Details** (`/routing-details`, RT/HD/PN) — currently force a single fiscal year.
`RequisitionDetailController::resolve()` calls `resolveFiscalYear()`, which **can never return null**:
an absent, empty or malformed `?fy` silently becomes the current FY (or the latest year with data). So
a buyer who wants every open commitment a department has ever raised must step through **every eligible
year one at a time** — 11 for Encumbered, 3 for Routing, per user — and the CSV can only describe one.

The September change made the year a select and removed the hero, rail and prev/next stepper — but kept
it **required**, leaving it looking like a filter while behaving like a banner: excluded from
`activeFilterCount`, preserved by "Clear all", always in the query string.

**The outcome:** both pages open on **All Fiscal Years**, meaning every *eligible* year. Rows, option
lists, KPIs, totals, pagination and the CSV all cover that scope — **the CSV subject to the ceiling
contract in §6.6**, which matters only for a hypothetical broad access mapping, never for any real user
today. Choosing a year is an ordinary filter
— it counts in the badge, "Clear all" returns it to All, `fy` disappears from the URL when All is
selected. A **read-only gold period chip** beside the title states the scope in words, so an all-years
table can never be mistaken for a single year's.

### Two terms this plan keeps strictly apart (R2-1)

| Term | Meaning | FFIGUERA1 |
|---|---|---|
| **Ledger-year boundary** | the years `vw_FinanceLedger` has for the user | FY2014–FY2026 (**13**) |
| **Eligible years** (= `props['years']`) | **route-specific**: that page's detail years ∩ the boundary | **Encumbered 11** · **Routing 3** |

Only the second is ever the query scope, the dropdown, or a test's expected set.

### What "drill-down" means, and why it governs everything here

| | Source | Grain | FY2026 example |
|---|---|---|---|
| Summary | `vw_FinanceLedger` | one row **per account** | `4-80400-H01-101-2001-00-000` → `Approved = 129,100.00` |
| **Detail** | `vw_FinanceRequisitionDetail` | one row **per requisition line** | reqs 280693 & 283435, lines 1–8, **summing to exactly 129,100.00** |

Phase 2's reconciliation gate enforces that equality in SQL. It is why **R1-A is critical**: FY2011–13
rows have no summary row to reconcile against, so including them silently breaks the one invariant the
phase exists to protect — measured, by TTD 75,829.66.

### What this change is NOT

- **Not a restoration of the hero.** No `FiscalYearHero`, year rail, prev/next stepper, or page-level
  arrow-key year stepping. Arrows stay scroll-only via `useTableScroll` called without
  `onPrevYear`/`onNextYear`. The chip is not interactive.
- **Not a widening of scope.** "All" is the eligible intersection, enforced in the query (§4).
- **Not a column change.** `sql/Phase2RequisitionDetail_*.sql` stays untouched.
- **Not a SQL-pushdown refactor** — see §6.4 for what that costs us and why it is still deferred.

### Three corrections to the original brief

1. **The FiscalYearHero removal is already committed** — HEAD `79eef8e`. `fyNav` is already gone.
2. **`master` does not contain this work** — `b9dbe6b`, tracking `finance/master`. See §13.
3. **`RequisitionDetailTest` uses `UsesRequisitionData`**, not `UsesLedgerData`.

**Repository state (finding #14 — rev 5's claim here was stale).** Verified:

```
 M resources/views/app.blade.php     ← the Vite fix (§12.1)
 M vite.config.js                    ← the Vite fix (§12.1)
?? routingupdate.md                   ← this plan
```

The fiscal-year change itself is **not started**. Status vocabulary this plan uses precisely, because
"shipped" was doing too much work:

| Term | Means |
|---|---|
| **Implemented locally** | files changed in the worktree |
| **Verified locally** | exercised and measured on this machine |
| **Committed** | in git history |
| **Deployed** | running on production |

The Vite fix is **implemented and verified locally; not committed, not deployed.** Nothing in this plan
is committed — the user commits and merges manually.

---

## §2 Measurements — dated baselines, not acceptance values

⚠️ Every figure is a 2026-10-01 observation of live data. Acceptance is §9.7: *agreement with a
reference query run at deploy time.*

| Fact | Value (2026-10-01) |
|---|---|
| `dbo.FinanceRequisitionSnapshot` total rows | 108,435 |
| **Ledger-year boundary**, `FFIGUERA1` | FY2014–FY2026 (13) |
| **Eligible — Encumbered** | 11 years, **416 lines** |
| **Eligible — Routing** | 3 years, **70 lines** |
| Unbounded Encumbered (the R1-A bug) | 465 lines → **leak 49 rows / TTD 75,829.66** |
| Reconciliation over the **eligible** set | Encumbered **111,089,421.36** = `SUM(Approved)`; Routing **241,553.20** = `SUM(Routing)`; **diff 0.00 both** |
| Same over the 13-year boundary | also 0.00 — **only because FY2022/23 ledger values are zero.** Tests bind `props['years']` |
| Negative `ExtendedCost` lines in scope | 16 |
| **Worst case all-years, unbounded** (user mapped to everything) | 93,336 lines · **558 MB / ~5.1 s** |
| **Same scope, bounded at 25,000 — FULL pipeline** | **25,001 rows · 172 MB peak / 1.29 s** |
| ⚠️ *Superseded figure:* "25,001 rows · 106 MB" | **Do not quote.** That run used **12 columns and skipped `deriveRequisitionRow()` and `requisitionTotals()`** — not the real path. See the method note below |

**Measurement method, since the above was quoted inconsistently in rev 5** (finding #6):

| | Value |
|---|---|
| Metric | `memory_get_peak_usage(true)` — real allocated process memory, **total not incremental** |
| Baseline (process before the query) | **42 MB** |
| So incremental cost at 25,001 rows | **~130 MB**, i.e. **~5.3 KB/row** |
| Context | **PHP CLI** via `artisan tinker`, local SQL Server. **Not** measured through the web worker |
| PHP `memory_limit` at measurement | 2048M (deliberately generous, to measure rather than trip) |
| **Production `memory_limit`** | ✅ **`4096M`, measured 2026-10-01** — safe for ~388,000 rows, vs the 25,000 configured (§12.2) |
| Production RAM | **app VM 16 GB** (shared with MySQL) · database VM 24 GB. 25 concurrent worst-case requests ≈ 4.2 GB; real concurrency 1–3 users |

| 🔑 **Largest SINGLE-YEAR scope, snapshot-wide** | **AP/PO FY2026 = 18,945**; then 16,045 · 14,025 · 13,657. **RT/HD/PN FY2026 = 3,790** |
| → headroom of the 25,000 ceiling over that | **~6,000 rows (24%)**, and FY2026 is *still accumulating* |
| → rows above a 10,000 `row_warn` | **four** AP/PO years would warn on a normal single-year view |
| `DuplicateGrainRows` across 36 refresh runs | **0** — recorded every run, but **nothing acts on it** (§12 item 5) |

These are **CLI** figures, so 172 MB is a **floor**: a web request carries more baseline (session,
middleware, Inertia) than `tinker` does. That matters for precision, not for the decision — the
`memory_limit` is `4096M` on a shared `php.ini`, giving ~15× headroom over the ceiling, so even a
generously larger web baseline leaves the margin intact (§12.2).
| Requisition numbers spanning >1 FY | yes — worst-case KPI undercount **106** of 24,065 |
| `memory_limit` here | 4096M — **and production measured at 4096M too** (§12.2) |

---

## §3 Decisions

### 3.1 Row ordering — minimal deviation, measured (findings R2-7, R3-3, #5)

```
ORDER BY FinancialYear DESC,   -- NEW, and the only key that changes any row today
         Department,            -- \
         RequisitionNumber,     --  > exactly today's ordering, unchanged
         LineNbr,               -- /
         PONumber               -- NEW, and PROVABLY INERT (see below)
```

**This is today's app ordering, with one key prepended and one appended. No row moves today.**

#### Why: the reference query specifies no ordering at all

Checked directly — there is **no `ORDER BY` anywhere** in `sql/Phase2RequisitionDetail_Approved.sql`,
`_Routing.sql`, `Phase2ReconciliationTest.sql`, or the finance team's own drafts in `sql/source/`
(`SQL Web App Workings E - Approved.sql` / `- Routing.sql`). The original query returns rows in
whatever order the engine chooses. So there is no reference ordering to reproduce, and
`Department, RequisitionNumber, LineNbr` is the **application's own** invention, not the query's.

That makes minimal deviation the right standard: prepend `FinancialYear DESC` because the all-years
view needs years in contiguous blocks rather than interleaved, and change nothing else. Within a
single selected year `FinancialYear` is constant, so **single-year ordering is byte-for-byte what it
is today.**

#### `PONumber` goes AFTER `LineNbr`, not before — and that distinction is the whole point

Rev 4 inserted `PONumber` **before** `LineNbr` and added `AccountNumber`. That was wrong: it would
reorder lines within a requisition spanning multiple POs, a gratuitous deviation from current
behaviour. Rev 5 appends it **after** `LineNbr` instead, which is a different proposition entirely:

| Measurement (108,435 rows, 2026-10-01) | Result |
|---|---|
| Tied groups on `(FinancialYear, Department, RequisitionNumber, LineNbr)` — via `GROUP BY … HAVING COUNT(*) > 1` | **0 groups, 0 extra rows** |
| View-level ties on that key for `FFIGUERA1` | **0** |
| Pairs in one `(FY, Department, RequisitionNumber)` group where `LineNbr` asc and `PONumber` asc **disagree** | **0** |

Because there are **zero tied groups on the first four keys, a fifth key can never be consulted**. So
appending `PONumber`:

- **changes no row today** — single-year output stays byte-for-byte identical, which is the
  constraint that matters;
- **guards the one future tie** the declared grain admits, without a manually rerun check;
- moves the ordering closer to the declared snapshot grain.

`AccountNumber` stays dropped — it adds nothing beyond `PONumber` for the tie the grain actually
permits.

> ⚠️ **A method correction.** The earlier uniqueness measurement used
> `COUNT(*) - COUNT(DISTINCT CONCAT(...,'|',...))`. That is unsafe here: **685 rows have a NULL
> `Department`** and `PONumber` has 5 NULLs and 20,648 empty strings, and T-SQL `CONCAT` renders NULL
> as `''`, so a NULL and an empty value collide. It can only manufacture *false* duplicates, never
> hide real ones, so the 0 result stands — but the re-run with `GROUP BY` is the one to trust, and
> §9.7 uses `GROUP BY`.

#### What the ordering does and does not guarantee

This claim has been wrong twice, so stated precisely:

- Rev 3 said "stable by construction" — **false**; the declared grain's index is deliberately
  non-unique.
- Rev 4 said tied rows are "interchangeable to a reader" — **unverified**, and withdrawn. Two rows
  sharing the ordered columns could still differ in `Status`, `VendorName`, `ItemDescription`,
  `Quantity`, `UnitCost` or `ExtendedCost`.
- **What is true, and rev 6's own change makes it stronger than rev 6 claimed.** Appending `PONumber`
  turned the sort key into a **superset of the key the refresh proc already monitors**:

  | | Columns |
  |---|---|
  | `DuplicateGrainRows` watches | `FinancialYear, RequisitionNumber, PONumber, LineNbr` |
  | The sort key is | that **+ `Department`** |

  A superset of a unique key is necessarily unique — adding a column cannot create duplicates. So
  **`DuplicateGrainRows = 0` now PROVES the sort key is unique**, and pagination is stable whenever the
  refresh reports zero. Verified empirically: both keys return 0 extra rows across 108,435.

  ⚠️ **This corrects rev 6's own §3.1 text**, which still said "`DuplicateGrainRows = 0` does not imply
  the sort key is unique". That was true of **rev 5's** four-column key (`FY, Department, ReqNo,
  LineNbr`) — which omitted `PONumber` and so was *not* a superset — and the sentence survived the
  change that made it false. The remaining exposure is therefore not a second unknown key; it is simply
  `DuplicateGrainRows` itself becoming non-zero.
- **The gate is therefore `DuplicateGrainRows`, which already exists** — no separate key to track. The
  §9.7 acceptance query keeps a direct sort-key check as belt-and-braces for the release, but the
  **ongoing** protection must be the refresh log, because that is computed on every run while a manual
  query is not. §12 item 5 is rewritten accordingly: the real gap was never a missing measurement, it
  was that **nothing acts on the one already being taken**.
- The snapshot carries **no surrogate row id** (verified against its DDL). Adding one is the only
  *fully* enforceable fix and is **out of scope**: it means altering `dbo.FinanceRequisitionSnapshot`,
  its staging twin and the refresh proc. Recorded in §12 as the remedy if the gate ever trips.

### 3.2 The shared Oct→Sep formatter

One exported function in a shared module, imported by **both** `FiscalYearHero.vue` and the new chip.

**How it is actually verified** (finding #10 — rev 5 claimed "behaviour by PHP feature tests", which is
impossible: PHP never executes `resources/js/fiscalYear.js`):

- **Node's built-in test runner**, `node --test`. Verified available — this machine runs **Node v24.20.0**
  and `package.json` is already `"type": "module"`, so a `resources/js/fiscalYear.test.js` runs with
  **no new dependency and no config**. Add `"test:js": "node --test resources/js/"` to `scripts`.
- Cases: `2026`/`'2026'` → `Oct 2025 – Sep 2026`; `null`, `undefined`, `''`, `'abc'`, `0`, `-1`, `'2026x'`
  → `''`; en dash is U+2013, not a hyphen.
- That is the whole module — a pure string function with no imports — so this is cheap and complete.
- Compilation of the two components that import it is covered by the production build.

### 3.3 Chip copy — "All available fiscal years" (findings R3-8, #6)

Three attempts, converging:

| Rev | Copy | Problem |
|---|---|---|
| 1–3 | "All fiscal years" | overstates — "All" is the route-specific eligible intersection |
| 4 | "All 11 fiscal years" | renders **"All 0 fiscal years"** on an outage, where 0 is *unknown* rather than measured, and **"All 1 fiscal years"** is ungrammatical |
| **5** | **"All available fiscal years"** | accurate in every state — N, one, none, and unknown — with no pluralisation branch |

"Available" is doing real work: it signals *bounded* without asserting a number the page may not know.
The withheld-years note under the select still names the excluded years.

The chip remains **read-only**: centred wrapping flex row, outside the `<h1>`, no `<button>`, `<a>`,
`tabindex`, handler, hover state or pointer cursor; "Current" only when applicable; respects
`prefers-reduced-motion`.

### 3.4 `PER_PAGE` stays 25 — decided, not overlooked

All-years makes the Encumbered table **17 pages** for today's mapped user (416 rows), with FY2026
filling pages 1-3 and FY2014 landing on page 16. Routing is 3 pages. Measured per-year spans:

| | Eligible years | Rows | Pages @ 25 | Page 1 holds |
|---|---|---|---|---|
| Encumbered | 11 | 416 | 17 | FY2026 only |
| Routing | 3 | 70 | 3 | FY2026 only |

**Reviewed and kept at 25.** The reasoning, so it is not re-opened as an oversight:

- The **KPIs and the totals row already answer the all-years question at a glance** — they cover the
  whole filtered set before pagination, so the headline figures need no paging.
- The **CSV export delivers the entire set in one file**, which is the right tool for reading across
  eleven years.
- Anyone wanting a single year selects it from the filter — the control this whole change adds.
- Keeping it means **single-year views stay byte-identical to today** in page size as well as ordering.

Because `FinancialYear DESC` leads the sort (§3.1), years appear as **contiguous blocks** rather than
interleaved, so paging through is a walk backwards in time rather than a scramble. Two alternatives
were considered and declined: a larger page size when no year is selected, and per-year subtotal rows.
Neither is precluded later; both were judged unnecessary against the numbers above.

---

## §4 🔴 R1-A — the eligible-year boundary must be enforced in the QUERY

Rev 1 proposed simply skipping `forYear()` when the year is null. But `availableYears()` computes
*dropdown options only*; it does not constrain the row query. The default view would have returned
**every** requisition year, contaminating the table, KPIs, totals, option lists, pagination and the
CSV. Measured: **49 extra rows, TTD 75,829.66**, breaking reconciliation by exactly that.

```php
// The eligible-year set, ALWAYS applied. "All" means every year THIS ROUTE's
// detail shares with the ledger — never every year the snapshot holds, and not
// the 13-year ledger boundary either (Routing has only 3 eligible years).
$scopeYears = $requestedYear !== null ? [$requestedYear] : $years->all();
```

and in `detailRows()`, `whereIn('FinancialYear', $scopeYears)` **unconditionally**.

**An empty `$scopeYears` must return zero rows, not all rows.** `whereIn(…, [])` generates
`WHERE 0 = 1`, which is correct: a user with no eligible years has no eligible detail. This is the
no-access-adjacent path — the one place "no filter" must *not* mean "everything".

---

## §5 Backend — `app/Http/Controllers/RequisitionDetailController.php`

### 5.1 The two contracts, stated separately (finding #3)

Rev 4 said `refusedScope()` "returns the same props as `unavailable()`". That conflated two layers:
`resolve()` returns an internal array; `unavailable()` returns an Inertia `Response`. They cannot have
identical keys, and the parity test must sit at the **final prop layer**, not between them.

**Contract A — `resolve()`'s return** (internal; `index()` and `export()` both consume it):

| Key | Normal | Refused |
|---|---|---|
| `rows` | the filtered collection | **empty** (the fetched rows are an arbitrary truncation) |
| `filters` | validated | `fy` only; categoricals as **raw requested** values (§6.3) |
| `droppedFilters` | from six `validFilter()` calls | `[]` — validation never ran |
| `activeFiscalYear` | `?int` (null = all eligible) | same |
| `years`, `unsummarisedYears` | from `availableYears()` | **same — unchanged**, which is what keeps the year dropdown usable |
| `clusters`…`statuses` | derived from rows | **empty** |
| `hasAccess`, `snapshot` | as resolved | same |
| `scopeRefused` | `false` | **`true`** |
| `suggestedYear` | `null` | newest eligible year, or `null` if none |

**Contract B — the final Inertia prop set**, identical across **all three** paths (success, refused,
unavailable): the existing 15 props **plus two new ones — `scopeRefused` and `scopeRefusedMessage` —
making 17.** Rev 4 said 16 and then required a server-supplied message in the component, which would
have been an undeclared prop (finding #4). Exact values per path:

| New prop | Success | Refused | Unavailable |
|---|---|---|---|
| `scopeRefused` | `false` | `true` | `false` |
| `scopeRefusedMessage` | `null` | `SCOPE_TOO_LARGE` (all-years) **or** `SCOPE_TOO_LARGE_SINGLE_YEAR` (a year was selected) | `null` |

**Every path must set both.** Rev 5 only told `unavailable()` to add `scopeRefused`, and only told the
test `PROPS` list the same — which would have produced a 16-prop outage response against a 17-prop
success response, failing the parity assertion for an uninteresting reason. Explicitly:

| Path | Add to its array |
|---|---|
| `resolve()` normal return (Contract A) | `'scopeRefused' => false, 'scopeRefusedMessage' => null, 'suggestedYear' => null` |
| `refusedResolution()` (Contract A) | as specified below |
| `index()` success render (Contract B) | `'scopeRefused' => $r['scopeRefused'], 'scopeRefusedMessage' => $r['scopeRefusedMessage']` |
| `unavailable()` (Contract B) | `'scopeRefused' => false, 'scopeRefusedMessage' => null` |
| `RequisitionDetailTest::PROPS` | **both** new names |

`suggestedYear` lives only in Contract A — it drives the redirect decision and is **not** an Inertia
prop, which is why Contract B is 17 and not 18.

**`refusedResolution()` in full**, since rev 4 named it without specifying it:

```php
/**
 * Contract A, refused. Returns EARLY from resolve(), before the six
 * validFilter() calls — so the categoricals are raw requested values and
 * droppedFilters is empty: validation needs option lists, and option lists need
 * a row set we deliberately did not materialise.
 *
 * rows is EMPTY and totals are never computed from the truncated fetch. The
 * presentation layer gates every quantity on !scopeRefused (§7.3h), so these
 * zeros are never rendered — the one rule this whole state exists to honour.
 */
private function refusedResolution(
    Request $request, Collection $years, array $yearData,
    bool $hasAccess, array $snapshot, ?int $requestedYear,
): array {
    // Which message depends on whether the user can still act. A selected year
    // that is too large has no remedy on this page; all-years does.
    $singleYear = $requestedYear !== null;

    return [
        'rows' => collect(),                       // never the truncated fetch
        'filters' => $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status')
            + ['fy' => $requestedYear],            // raw requested, §6.3
        'droppedFilters' => [],                    // validation never ran
        'activeFiscalYear' => $requestedYear,
        'years' => $years->all(),                  // POPULATED — the recovery control
        'unsummarisedYears' => $yearData['unsummarised'],
        'clusters' => [], 'institutions' => [], 'departments' => [],
        'accounts' => [], 'vendors' => [], 'statuses' => [],
        'hasAccess' => $hasAccess,
        'snapshot' => $snapshot,
        'scopeRefused' => true,
        'scopeRefusedMessage' => $singleYear
            ? self::SCOPE_TOO_LARGE_SINGLE_YEAR
            : self::SCOPE_TOO_LARGE,
        // Explicit null check: (int) $years->first() would be 0 on an empty
        // collection, and 0 is not a fiscal year — it would make
        // shouldRedirectToSuggestedYear() true and redirect to ?fy=0.
        'suggestedYear' => ($singleYear || $years->isEmpty()) ? null : (int) $years->first(),
    ];
}
```

`suggestedYear` is `null` when a year was already selected — which is exactly what stops
`shouldRedirectToSuggestedYear()` from looping (§5.2).

> **The all-years-with-no-eligible-years refusal is unreachable, and deliberately kept.** With
> `$years` empty, `$scopeYears` is `[]`, `whereIn('FinancialYear', [])` compiles to `WHERE 0 = 1`, and
> zero rows cannot exceed any ceiling — so `scopeRefused` is never true on that path. The branch is
> **defensive only**: it exists so that a future change to how `$scopeYears` is built cannot turn an
> empty year list into an unbounded query without also tripping this. Noted rather than removed,
> because silently relying on `WHERE 0 = 1` is the kind of invariant that breaks quietly.

**Raw categoricals stay in `filters` despite empty option lists.** The `<select>`s will render those
values as unmatched and therefore blank, which is acceptable *because the selects are inert in this
state* — the only live control is Fiscal Year. Echoing them back preserves them for the redirect and
for the user's next action rather than silently discarding what they asked for.

### 5.2 `index()` — the redirect decision, shown explicitly

```php
public function index(Request $request): Response|RedirectResponse
{
    $filters = $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status', 'fy');
    $currentFiscalYear = $this->currentFiscalYear();

    try {
        $r = $this->resolve($request);
    } catch (\Throwable $e) {
        return $this->unavailable($request, $filters, $currentFiscalYear, $e);
    }

    // All-years is too large AND there is a year to fall back to: make the URL
    // canonical rather than silently showing a narrower scope than it claims.
    // Only this branch redirects, and only from the all-years path, so the
    // redirect target (a single year) can never redirect again — no loop.
    if ($this->shouldRedirectToSuggestedYear($r)) {
        return redirect()
            ->route($this->routeName(), $this->redirectQuery($request, $r['suggestedYear']))
            // INTERPOLATED. The constant carries a :year placeholder and passing
            // it bare would flash a literal "FY :year".
            ->with('warning', str_replace(':year', (string) $r['suggestedYear'], self::SCOPE_TOO_LARGE_REDIRECT));
    }

    return Inertia::render($this->component(), [/* Contract B — all 17 props, §5.1 */]);
}
```

`shouldRedirectToSuggestedYear()` is the **pure** decision method finding #7 asks for — no container,
no DB — so it is unit-testable offline:

```php
/** Pure: no DB, no request, no container. Unit-tested in tests/Unit. */
protected function shouldRedirectToSuggestedYear(array $r): bool
{
    return $r['scopeRefused']
        && $r['activeFiscalYear'] === null      // we were on all-years
        && $r['suggestedYear'] !== null;        // and there is somewhere to go
}
```

### 5.3 `resolve()` — optional year, enforced scope, bounded fetch

```php
$yearData = $this->availableYears($username);
$years = collect($yearData['years']);          // route-specific ELIGIBLE years, NEWEST FIRST

// FISCAL YEAR IS AN OPTIONAL FILTER, defaulting to every eligible year.
//
// Deliberately NOT ResolvesFiscalYear::resolveFiscalYear(): that helper can
// never return null — it substitutes the current FY, then the latest year with
// data — which is exactly the forcing this page is dropping. It stays untouched
// for the four pages that keep the hero and genuinely want a year always.
$dropped = [];
$requestedYear = $this->validFilter($request, 'fy', $years->all(), $dropped);
$activeFiscalYear = $requestedYear === null ? null : (int) $requestedYear;
$scopeYears = $requestedYear !== null ? [$requestedYear] : $years->all();   // §4

$hasAccess = $this->userHasLedgerAccess($username);
$snapshot = $this->snapshotFreshness();

// §6 — bounded fetch. $rows is NEVER larger than ceiling + 1, whatever the scope.
[$rows, $scopeRefused] = $this->fetchBoundedRows($username, $scopeYears);

if ($scopeRefused) {
    // Contract A (refused). Returns EARLY, before the six validFilter() calls —
    // which is why the categoricals come back as raw requested values and
    // droppedFilters is empty: validation needs option lists, and option lists
    // need a row set we have deliberately not materialised. See §6.3.
    //
    // SIX arguments — $requestedYear is required, and decides both which message
    // is shown and whether a redirect is offered.
    return $this->refusedResolution($request, $years, $yearData, $hasAccess, $snapshot, $requestedYear);
}

// …unchanged from here: option lists from $rows, then the six validFilter calls.
```

- `$dropped = [];` moves up here; delete the declaration at L310.
- Remove the unused `$currentFiscalYear` local at L260.
- `ResolvesFiscalYear` stays — `currentFiscalYear()` is still needed.
- L272's comment → "scoped to the rows in scope — one fiscal year, or every eligible year".

### 5.4 `unavailable()` — fall back to All, not a four-digit guess (R2-4)

```php
// Fall back to ALL FISCAL YEARS, never to the requested value.
//
// The availability query failed, so the eligible-year set is UNKNOWN and no
// requested year can be validated against it. Echoing back a four-digit string
// would let ?fy=9999 paint "FY 9999 · Oct 9998 – Sep 9999" over an empty table.
// Same principle as hasAccess => true below: on an outage, assert nothing you
// cannot establish.
$filters['fy'] = null;
```

Also add BOTH `scopeRefused => false` and `scopeRefusedMessage => null` here, so Contract B's 17
keys hold across all three paths (§5.1) — rev 5 named only the first, which would have failed the
parity assertion for an uninteresting reason.

### 5.5 `availableYears()` — newest first (R3-7)

`orderBy('FinancialYear')` is ascending and `array_intersect` preserves that order, so the dropdown
would read FY2014…FY2026 with the most-wanted year last, while the table is newest-first.

```php
// NEWEST FIRST, matching the table's FinancialYear DESC order and putting the
// year people actually want at the top of the select. Every consumer compares
// these as SETS (reconciliation, the withheld-years note, the tests), so the
// order is presentation only — but it is presentation that is currently wrong.
// It also makes years->first() the newest year, which §6.3's redirect wants.
return [
    'years' => array_values(array_reverse(array_intersect($detailYears, $ledgerYears))),
    'unsummarised' => array_values(array_reverse(array_diff($detailYears, $ledgerYears))),
];
```

### 5.6 `detailRows()` — bind the scope, order per §3.1, accept a cap

```php
private function detailRows(string $username, array $scopeYears, ?int $limit = null): Collection
{
    $query = FinanceRequisition::forUser($username)
        ->whereIn('FinancialYear', $scopeYears)
        ->withStatuses($this->statuses())
        ->select(self::COLUMNS)
        // FinancialYear DESC is the only key that MOVES A ROW today; PONumber is
        // appended as a provably inert tie-break (see below). The reference
        // query (sql/Phase2RequisitionDetail_*.sql and the finance team's drafts
        // in sql/source/) has NO ORDER BY at all, so the three keys below are the
        // application's own and are kept exactly as they are. Within one selected
        // year FinancialYear is constant, so single-year output is byte-for-byte
        // what it is today; with All selected it groups years into contiguous
        // blocks instead of interleaving them.
        //
        // Measured 2026-10-01 (GROUP BY, not CONCAT — 685 rows have a NULL
        // Department): (FinancialYear, Department, RequisitionNumber, LineNbr)
        // has 0 tied groups in 108,435 rows, so it is already a total order.
        //
        // PONumber is appended AFTER LineNbr, never before. With zero tied
        // groups on the four keys above it, it can never be consulted — so it
        // reorders nothing today, while guarding the one further tie the
        // declared snapshot grain permits without relying on a manual check.
        // See routingupdate.md §3.1 for why this uniqueness is NOT the same
        // property as DuplicateGrainRows.
        ->orderByDesc('FinancialYear')
        ->orderBy('Department')
        ->orderBy('RequisitionNumber')
        ->orderBy('LineNbr')
        ->orderBy('PONumber');

    if ($limit !== null) {
        $query->limit($limit);
    }

    return $query->get()
        ->map(fn ($row) => $this->deriveRequisitionRow((array) $row->getAttributes(), self::COLUMNS));
}
```

`scopeForYear()` becomes unused by these pages but stays on the shared model — note it in the docblock.

### 5.7 `export()` — two added guards

- `csvFilename(…, $r['activeFiscalYear'])` already omits `fy` on null; **`StreamsCsv` untouched**.
- Stale-`fy` refusal needs no new branch — `droppedFilters` carries it.
- **New:** if `$r['scopeRefused']`, refuse. Never stream a truncated file — a CSV holding 25,000 of
  93,336 rows reads as complete and is the worst possible outcome.

**The refused-export redirect needs its own target and message** (finding #12). `exportRedirect()`
replays `$request->query()`, so an oversized **all-years** export would otherwise:

1. redirect to the index with no `fy`,
2. which `index()` then redirects again to `?fy=<newest>`,
3. leaving the user on a year page with a flash about *display* selection and **no statement that no
   file was produced**.

Two redirects and a message about the wrong thing. So the export refusal goes **straight to the
suggested year** and says plainly that nothing was exported:

```php
protected const EXPORT_SCOPE_TOO_LARGE = 'No file was created: all available fiscal years is too large to export. FY :year has been selected — export that year instead.';

protected const EXPORT_SCOPE_TOO_LARGE_SINGLE_YEAR = 'No file was created: this fiscal year has too many requisition lines to export. Choose another fiscal year, or contact IT.';

// …in export(), replacing a bare exportRedirect() for this case.
//
// TWO EXPLICIT BRANCHES, never `$year ?? 0`. suggestedYear is deliberately null
// when a year was already selected, and `?? 0` would redirect to ?fy=0 — an
// invalid year that validFilter() drops, so index() would read it as "all years"
// and redirect AGAIN to the newest year, moving the user off the year they
// asked about. That is the opposite of preserving their context.
if ($r['scopeRefused']) {
    if ($r['suggestedYear'] !== null) {
        // All-years was too large. Land on the suggested year and say so.
        return redirect()
            ->route($this->routeName(), $this->redirectQuery($request, $r['suggestedYear']))
            ->with('warning', str_replace(
                ':year', (string) $r['suggestedYear'], self::EXPORT_SCOPE_TOO_LARGE,
            ));
    }

    // A SELECTED year was too large. Keep that year — the user's context is the
    // thing to preserve, and there is no better year to offer them.
    return redirect()
        ->route($this->routeName(), $this->redirectQuery($request, (int) $r['activeFiscalYear']))
        ->with('warning', self::EXPORT_SCOPE_TOO_LARGE_SINGLE_YEAR);
}
```

`redirectQuery()` therefore always receives a real four-digit year, from `suggestedYear` on the
all-years path and from `activeFiscalYear` on the selected-year path. **Tests assert the FINAL url, the
final `fy` value and the final flash for BOTH branches** (§9.2 cases 16–17) — a single-hop assertion is
what would have let both the double redirect and the `fy=0` bug through.

### 5.8 R1-F — `totals.requisitions` keyed on (year, number)

Measured: 23,959 distinct numbers vs 24,065 distinct (year, number) pairs over the eligible years —
**undercounting by 106**. It is 0 for today's user, which is why it needs a test, not an assumption.

```php
// Keyed on (year, number), not number alone: requisition numbers RECUR across
// fiscal years. Identical with one year selected; with All selected, counting
// the number alone silently merges a FY2019 and a FY2024 requisition.
'requisitions' => $filtered
    ->filter(fn ($r) => ($r['RequisitionNumber'] ?? '') !== '')
    ->map(fn ($r) => $r['FinancialYear'].'|'.$r['RequisitionNumber'])
    ->unique()
    ->count(),
```

In the **DB-free trait**, so it gets offline coverage.

---

## §6 Capacity — a bound, and an honest recovery path

### 6.1 The bounded fetch (R3-1, R3-5)

| Rev | Mechanism | Why it failed |
|---|---|---|
| 2 | threshold log after `get()->map()` | ran *after* the allocation it policed — an OOM kills the request first |
| 3 | `COUNT(*)` pre-flight, all-years only | `?fy=2026` with 30k rows **bypassed it**; the fallback year was **never checked**; two statements, with a race |
| **5** | **bounded fetch, every scope** | `LIMIT ceiling + 1`. Getting `ceiling + 1` back *is* the signal. One statement, no race, no bypass |

Measured against the 93,336-row worst case, **through the full pipeline** (25 columns + derive +
totals): **25,001 rows, 172 MB peak, 1.29 s** — against **558 MB** unbounded. See §2 for the method and
for why the earlier "106 MB" figure is superseded.

```php
/**
 * Fetch the scope with a hard row bound.
 *
 * The only reliable guard is one that cannot be outrun by the thing it guards.
 * A COUNT(*) pre-flight predicts the allocation then performs it separately — it
 * can be bypassed and it can be raced (the access mapping is a LIVE view).
 * Fetching ceiling + 1 BOUNDS it instead: PHP never materialises more than that
 * for any scope, and ceiling + 1 rows is itself the too-large signal.
 *
 * @return array{0:Collection<int,array<string,mixed>>,1:bool}
 */
private function fetchBoundedRows(string $username, array $scopeYears): array
{
    // Object, NOT a destructured array — RequisitionScopeThresholds is a plain
    // readonly class and is not iterable.
    $t = $this->scopeThresholds();                       // validated, §6.5

    $rows = $this->detailRows($username, $scopeYears, $t->ceiling > 0 ? $t->ceiling + 1 : null);

    $refused = $t->ceiling > 0 && $rows->count() > $t->ceiling;

    if ($refused) {
        Log::warning('Requisition detail scope exceeds the row ceiling; refusing.', [
            'page' => $this->routeName(), 'username' => $username,
            'years' => $scopeYears, 'ceiling' => $t->ceiling,
        ]);
    } elseif ($t->warnAt > 0 && $rows->count() > $t->warnAt) {
        Log::warning('Requisition detail working set is large; see routingupdate.md §6.', [
            'page' => $this->routeName(), 'username' => $username,
            'rows' => $rows->count(), 'years' => count($scopeYears),
        ]);
    }

    return [$rows, $refused];
}
```

Because the bound applies to **every** call, a selected year over the ceiling and the §6.3 redirect
target are both covered. **No double logging:** the guard lives in `resolve()`, which `index()` and
`export()` each call once.

### 6.2 🔴 Finding #1 — only offer the recovery that works

Rev 4's refusal copy said *"Narrow it with a department or account filter"*. **That is impossible.**
The bounded fetch filters by user + fiscal year + status; the six categorical filters are applied in
memory *after*, so they never reach SQL and cannot shrink the fetched scope. A URL carrying a highly
selective `?department=` is refused identically.

**The measurement that resolves it:**

| Scope | Largest, snapshot-wide | vs 25,000 ceiling |
|---|---|---|
| All eligible years, AP/PO | 93,336 | **over** |
| **One year, AP/PO** | **18,945** (FY2026) | **under** |
| One year, RT/HD/PN | 3,790 (FY2026) | well under |

So **choosing a single fiscal year is a recovery that actually works**, and it is the only one. Two
things make it reachable rather than theoretical:

1. **`years` comes from `availableYears()`, not from the fetched rows** (verified — it is set from
   `$yearData`, independent of `$rows`). So in a refusal state the **Fiscal Year dropdown is still
   fully populated** while every other option list is empty. The user can act.
2. The copy offers only that action:

```php
protected const SCOPE_TOO_LARGE = 'This selection covers too many requisition lines to display. Choose a single fiscal year from the filters above.';
```

**If even one year exceeds the ceiling**, that scope genuinely cannot be shown by this page as built.
Rev 4's wording here was **wrong twice over** (finding #2): it said *"Use the CSV export for a single
year"* — but `export()` refuses exactly that scope (§6.6), so it sent the user to a control that
refuses them — and it implied filtering might help, which §6.2 has just established it cannot:

```php
protected const SCOPE_TOO_LARGE_SINGLE_YEAR = 'This fiscal year has too many requisition lines to display or export. Choose another fiscal year, or contact IT — showing this one needs a change to how this page queries the data.';
```

**Every claim in that sentence is now true:** it does not offer the export (which is refused), does not
suggest filters (which cannot help), and names the only two real options.

That case is **not reachable today** (18,945 < 25,000) but the headroom is only ~24% and FY2026 is
still accumulating, so it is a real near-term risk — tracked in §12, with §6.4 as its remedy.

### 6.3 The redirect: canonical URL, honest wording, *requested* filters (findings #2, #4)

| Situation | Behaviour |
|---|---|
| **All-years** over the ceiling, an eligible year exists | **302** to `?fy=<newest eligible>` + the requested categoricals, with a `warning` |
| **A selected year** over the ceiling, or no eligible year | **Refusal state** — `scopeRefused` true, no rows, year dropdown populated, `SCOPE_TOO_LARGE_SINGLE_YEAR` |

**Wording — three defects, all fixed.** Rev 3's "so FY 2026 is shown" was false when FY2026 is itself
over the ceiling. Rev 4 fixed that but introduced two more: it said *"Narrow it further"*, implying
categorical filters could help when §6.2 establishes they cannot; and it contained a `:year`
placeholder while `index()` passed the bare constant to `->with('warning', …)`, so **users would read a
literal "FY :year"**.

```php
protected const SCOPE_TOO_LARGE_REDIRECT = 'All available fiscal years is too large to display, so FY :year has been selected. If that year is also too large, choose another fiscal year or contact IT.';
```

**It must be interpolated at the call site** — the canonical snippet is the one in **§5.2**, and there
is deliberately no second copy here. Rev 5 carried two versions of `index()`, one of them still passing
the bare constant; whichever an implementer read first decided whether users saw a literal `FY :year`.

It states what was *selected*, not what is *shown* — true whether the target year renders or is itself
refused — and the recovery it names (another year, or IT) is the recovery that exists. **Tests assert
the fully resolved string, including the real year and the absence of `:year`** (§9.2 case 16).

**"Requested", not "surviving" (finding #2).** The early return precedes all six `validFilter()` calls,
so the controller has only raw request input. It cannot know whether a value was valid across all years
or exists in the target year. So `redirectQuery()` passes through **only syntactically safe raw
strings** and the redirected request validates them normally — dropping any that are not options in
that year, exactly as a stale filter is dropped today:

```php
/**
 * Carry the user's requested categoricals to the narrower year.
 *
 * These are REQUESTED, not "surviving": validation needs option lists, option
 * lists need a row set, and we deliberately did not materialise one. Only
 * is_string values pass (so ?department[]=x cannot propagate), and the
 * redirected request validates them like any other — a value valid across all
 * years but absent from this one is dropped there, with the usual visible reset.
 */
private function redirectQuery(Request $request, int $year): array
{
    $carried = array_filter(
        $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status'),
        fn ($v) => is_string($v) && $v !== '',
    );

    return $carried + ['fy' => (string) $year];
}
```

### 6.4 The SQL-pushdown tradeoff — now with a named cost

Rev 2 implied the refactor was structurally impossible. **That was too absolute.** Filter options *can*
come from `DISTINCT` queries and both paths *can* share a query specification. The accurate position is
a deliberate tradeoff, and finding #1 has now priced it:

- **What deferring costs us:** categorical filters cannot rescue an oversized scope, so the recovery is
  year-selection only, and a single oversized year is undisplayable (§6.2).
- **Why it is still deferred:** today's real figure is **416 rows**; the refusal path is unreachable.
  The refactor touches `validFilter()`, the stale-filter contract, `resolve()`'s single-path guarantee
  and all six export routes.
- **`export.md`'s rejection rests on a 3,408-row ceiling this change raises to 93,336**, so the premise
  is re-opened (§8.2) rather than left standing as stale justification.

**Deferred, not dismissed.** The bounded fetch makes deferral *safe* — the worst case is a refusal with
an explanation, not an out-of-memory 500. §12 names the trigger that makes it necessary.

### 6.5 Configuration — invariants, clamping, and a noisy default (finding #8)

Rev 4's `row_ceiling = 0` returned early and silently disabled `row_warn` too. Defined properly:

```php
// config/ledger.php, under 'requisition'
//
// Bounded-fetch guard (routingupdate.md §6). INVARIANTS, enforced by
// scopeThresholds(): row_ceiling >= 0; 0 DISABLES THE GUARD ENTIRELY (both
// refusal and warnings) and is not for production; row_warn is clamped to
// < row_ceiling, and 0 disables warnings alone.
//
// Measured 2026-10-01 (CLI, full pipeline, peak process memory): 416 rows for
// the only mapped user; 93,336 rows / 558 MB unbounded if a user were mapped to
// everything; 25,001 rows / 172 MB bounded; largest SINGLE year 18,945.
//
// 25,000 therefore clears the largest real single year by only ~24%, FY2026 is
// still accumulating, and the figure is CLI — a web worker carries more
// baseline. RE-DERIVE on the production box before trusting it (§12 item 2).
// MAX_CEILING is pinned to this same value until that happens.
// NOT (int) env(...) — that is the hole finding #4 found. `(int) 'abc'` is 0,
// and 0 is the explicit opt-out, so a typo in .env would SILENTLY DISABLE the
// guard. The raw value is passed through and validated in one place.
'row_ceiling' => env('FINANCE_REQUISITION_ROW_CEILING', 25000),

// NOTE: 10,000 would fire on FOUR normal single-year AP/PO views for a
// broadly-mapped user (18,945 / 16,045 / 14,025 / 13,657). It is a
// "watch this" line, not an error — but set it above the largest ordinary
// single year once that is measured on production, or the signal is noise.
'row_warn' => env('FINANCE_REQUISITION_ROW_WARN', 20000),     // raw, as above
```

Rev 4's normalisation **failed open**, which finding #3 caught: `max(0, …)` mapped a negative or
non-numeric value to `0`, and `0` means *unbounded* — so a typo in `.env` silently removed the memory
guard, directly contradicting the comment above it. It also had no upper bound, so `PHP_INT_MAX` both
defeated the guard and overflowed at `$ceiling + 1`.

Extracted to a **pure class** (finding #6 — rev 4 made this `private` while claiming a unit test
covered it directly, which would have needed reflection):

```php
namespace App\Support;

/**
 * Bounded-fetch thresholds, normalised. Pure: no container, no config facade —
 * values are passed in, so tests/Unit can exercise every edge with no DB.
 *
 * FAILS CLOSED. Rev 4 used max(0, …), which mapped a negative or garbage value
 * to 0 — and 0 means UNBOUNDED, so a typo in .env silently disabled the guard.
 * Anything invalid now falls back to the DEFAULT, never to "no limit".
 */
final class RequisitionScopeThresholds
{
    public const DEFAULT_CEILING = 25000;

    /**
     * An ABSOLUTE PARSER BOUND — not a certified-safe operating value.
     *
     * Its job is narrow: stop a typo or a hostile value producing an absurd
     * LIMIT or overflowing $ceiling + 1. It is NOT a statement that 50,000 rows
     * is safe to serve, and nothing here has measured it.
     *
     * Why 50,000 and not 150,000 (rev 6) or 200,000 (rev 5): the only concurrency
     * arithmetic that exists models the DEFAULT request (~172 MB at 25,001 rows).
     * At the measured marginal ~5.3 KB/row, 150,000 rows is ~875 MB per request —
     * ten concurrent would be ~8.75 GB on a 16 GB VM that also runs MySQL and the
     * OS. Presenting that as a safe maximum was unjustified. 50,000 is ~300 MB,
     * so ten concurrent is ~3 GB: defensible under the same arithmetic that was
     * actually done, and still ~2.6x the largest real single year (18,945).
     *
     * RAISING EITHER THIS OR THE CONFIGURED CEILING REQUIRES NEW MEASUREMENTS:
     * web-SAPI memory_limit (§12.2) and a concurrency model for the larger
     * request size. Do not infer one from the other.
     *
     * NOTE the DEFAULT (25,000) is not a memory limit at all — memory would allow
     * far more. It is a USABILITY limit: 93,336 rows is a ~5.1 s response and
     * 3,734 pages of 25.
     */
    public const MAX_CEILING = 50000;

    public function __construct(
        public readonly int $ceiling,
        public readonly int $warnAt,
    ) {}

    public static function fromConfig(mixed $ceiling, mixed $warnAt): self
    {
        // 0 is the ONLY accepted way to disable the guard, and it must be
        // explicit — a deliberate development override, never an accident.
        $c = self::normaliseCeiling($ceiling);
        $w = self::normaliseWarn($warnAt, $c);

        return new self($c, $w);
    }

    /**
     * Only EXACT integer 0 (or the string "0") disables the guard. Everything
     * else that is not a clean positive integer string falls back to the default.
     *
     * is_numeric() + (int) is not enough, and that gap is the point: '0.5',
     * '-0.5', '00', '1e-9' and ' ' are all is_numeric()-or-castable and all
     * truncate to 0 — which would read as "disable the guard" rather than
     * "nonsense, use the default".
     *
     * Accepted:  25000, '25000', ' 25000 '  (surrounding whitespace trimmed)
     * Opt-out:   0, '0'                      (exact, and the ONLY opt-out)
     * Defaulted: '+25000', '-1', '0.5', '00', '1e5', '', ' ', null, [], 'abc'
     */
    private static function normaliseCeiling(mixed $value): int
    {
        if ($value === 0 || $value === '0') {
            return 0;                                   // the ONLY opt-out
        }

        if (is_int($value)) {
            return $value < 0 ? self::DEFAULT_CEILING : min($value, self::MAX_CEILING);
        }

        // Strict: digits only, after trimming. SURROUNDING WHITESPACE IS
        // ACCEPTED (" 25000 " is a realistic .env typo and harmless); a sign is
        // NOT (^\d+$ has no sign branch, so '+25000' and '-5' both fall through
        // to the default). Rejects floats ('0.5'), scientific notation ('1e5'),
        // internal spaces, '', null, arrays.
        if (! is_string($value) || preg_match('/^\d+$/', trim($value)) !== 1) {
            return self::DEFAULT_CEILING;
        }

        $n = (int) trim($value);

        // '00', '000' etc. reach here as 0 — a typo, not an opt-out.
        return $n <= 0 ? self::DEFAULT_CEILING : min($n, self::MAX_CEILING);
    }

    private static function normaliseWarn(mixed $value, int $ceiling): int
    {
        if ($ceiling === 0) {
            return 0;                                   // guard off -> warnings off
        }

        $w = match (true) {
            is_int($value) => max(0, $value),
            is_string($value) && preg_match('/^\d+$/', trim($value)) === 1 => (int) trim($value),
            default => 0,                               // unparseable -> no warning
        };

        // A warn at or above the ceiling can never fire (the ceiling refuses
        // first), so it is clamped rather than left as dead configuration.
        return $w >= $ceiling ? (int) ($ceiling * 0.8) : $w;
    }
}
```

The controller just asks for it, and `$ceiling + 1` is now provably overflow-safe because `$ceiling` is
capped at `MAX_CEILING`:

```php
private function scopeThresholds(): RequisitionScopeThresholds
{
    return RequisitionScopeThresholds::fromConfig(
        config('ledger.requisition.row_ceiling'),
        config('ledger.requisition.row_warn'),
    );
}
```

- **`.env.example` gains both** — plus the pre-existing gap: it documents **no `FINANCE_*` variable at
  all** today, so `FINANCE_LEDGER_CACHE_MINUTES` and the rest are undiscoverable.
- **These are runtime-configurable with a config reload**, not "without a deploy". With
  `config:cache`, an `.env` edit does nothing until `config:clear`/`config:cache` and the FastCGI
  workers recycle. (No `bootstrap/cache/config.php` exists locally; production unverified.)

### 6.6 The CSV contract — stated once (finding #7)

§1 promised the CSV "covers every eligible year" while §6.1 refuses an oversized export. Both appeared
in rev 4; only one can be true. **Decision:**

> **An all-years CSV is guaranteed only below `row_ceiling`.** Above it the export is **refused** with
> the §6.3 warning — never truncated, never a partial file presented as complete.

Why refusal rather than a guaranteed streaming export:

- A streamed all-years CSV means a cursor-based export path, which is the §6.4 refactor — it would
  fork `resolve()`, the one thing `controller-patterns.md` and CLAUDE.md both forbid for exports.
- **A truncated CSV is the worst available outcome.** It carries no row count, no warning and no
  scrollbar: 25,000 of 93,336 rows reads as the complete answer, and would be reconciled against the
  ledger and found wrong — by someone with no way to see why.
- Today the ceiling is unreachable for every real user (416 and 70 rows), so the guarantee holds in
  practice; it is the hypothetical broad mapping that loses it.

Consequences recorded honestly, so §1's promise is qualified rather than quietly false:

| Scope | Screen | CSV |
|---|---|---|
| ≤ ceiling (every real user today) | renders | **full file, all eligible years** |
| All-years > ceiling | redirect to newest year + warning | refused; export the single year instead |
| One year > ceiling | refusal state | **refused — no export path exists for it** (§6.2 copy says so) |

The third row is the real limitation: such a scope has **no route to the data through this page at
all**, screen or file. That is the trigger in §12 item 6.

---

## §7 Frontend

### 7.1 New `resources/js/fiscalYear.js`

```js
/**
 * Fiscal-year label helpers.
 *
 * A fiscal year is named for the year it ENDS in and runs Oct (N-1) → Sep N, so
 * FY2026 is Oct 2025 – Sep 2026.
 *
 * ONE implementation, imported by both FiscalYearHero.vue (the four summary
 * pages' banner) and RequisitionDetailView.vue (the two drill-downs' read-only
 * period chip). Do not re-derive the span inside a component: two copies of the
 * Oct→Sep rule is how they drift.
 *
 * The all-years chip copy is NOT here — it is page wording, not a date span.
 */
export const fiscalYearSpan = (fiscalYear) => {
    const fy = Number(fiscalYear)

    if (!Number.isInteger(fy) || fy <= 0) return ''

    // En dash (U+2013), matching the hero.
    return `Oct ${fy - 1} – Sep ${fy}`
}
```

### 7.2 `FiscalYearHero.vue` — adopt the module

```js
import { fiscalYearSpan as fySpan } from '@/fiscalYear'
const fiscalYearSpan = computed(() => fySpan(props.activeFiscalYear))
```

Template unchanged, so the four hero pages are untouched.

### 7.3 `RequisitionDetailView.vue`

**a. The read-only period chip**, replacing the plain stack at L240-245:

```html
<div class="text-center">
    <div class="flex flex-wrap items-center justify-center gap-x-3 gap-y-2">
        <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">{{ title }}</h1>

        <!-- READ-ONLY period chip. Gold because it carries fiscal-year identity
             (CLAUDE.md's colour rule), NOT because it does anything: no button,
             no link, no tabindex, no handler, no hover state. The year is
             changed in the Filters card below; this only states the scope, so an
             all-years table can never be read as one year's. -->
        <span class="inline-flex items-center gap-2 rounded-full bg-amber-100 ring-1 ring-amber-300/70
                     px-3 py-1 text-[11px] font-semibold uppercase tracking-wider text-amber-800
                     dark:bg-amber-400/15 dark:ring-amber-300/40 dark:text-amber-200">
            <i class="fas fa-calendar-day text-[10px]" aria-hidden="true"></i>
            <template v-if="hasFiscalYear">
                FY {{ activeFiscalYear }}
                <span class="font-normal normal-case tracking-normal">· {{ periodSpan }}</span>
                <span v-if="isCurrentFiscalYear" class="inline-flex items-center gap-1.5">
                    ·
                    <!-- motion-reduce:animate-none — decorative pulse, and some
                         readers are vestibular-sensitive to it (R2-8). -->
                    <span class="relative flex h-1.5 w-1.5" aria-hidden="true">
                        <span class="absolute inline-flex h-full w-full animate-ping motion-reduce:animate-none rounded-full bg-amber-300 opacity-75"></span>
                        <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-amber-300"></span>
                    </span>
                    Current
                </span>
            </template>
            <!-- "available", not a count: accurate for N, one, none, and for an
                 outage where the number is unknown rather than zero (§3.3). -->
            <template v-else>All available fiscal years</template>
        </span>
    </div>

    <p class="text-sm text-tx-subtle mt-1">{{ subtitle }}</p>
    <p class="text-xs text-tx-subtle/80 mt-1">{{ moneyNote }}</p>
    <SnapshotFreshness class="mt-2" :refreshed-at="snapshot?.refreshedAt" :age="snapshot?.age" />
</div>
```

> The "Current" branch is **unreachable today** (R1-D): the current FY is 2027, the newest selectable
> year 2026. Keep it — it becomes reachable when FY2027 data lands.

**b. New computeds:**

```js
import { fiscalYearSpan } from '@/fiscalYear'

const hasFiscalYear = computed(() => props.activeFiscalYear != null && props.activeFiscalYear !== '')
const periodSpan = computed(() => fiscalYearSpan(props.activeFiscalYear))
const isCurrentFiscalYear = computed(() =>
    hasFiscalYear.value && String(props.activeFiscalYear) === String(props.currentFiscalYear)
)
```

`currentFiscalYear` is passed today but never read — this is its first use.

**c. The select gains an All option**, first cell of the `lg:grid-cols-4` grid, identical classes to the
other six — visually equal, no required marker. `years` arrives newest first (§5.5):

```html
<option value="">All Fiscal Years</option>
<option v-for="year in years" :key="year" :value="String(year)">FY {{ year }}</option>
```

The `unsummarisedYears` note stays immediately beneath it.

**d. `activeFilterCount` counts `fy`:**

```js
const CATEGORICAL_FILTERS = ['cluster', 'institution', 'department', 'account', 'vendor', 'status']

const categoricalFilterCount = computed(() =>
    CATEGORICAL_FILTERS.filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

// FY COUNTS now. It is optional and defaults to All, so a chosen year is an
// active filter exactly like a department. (It was excluded while it was
// required, when the badge would have read 1 on a virgin page.)
const activeFilterCount = computed(() =>
    categoricalFilterCount.value + (filters.value.fy ? 1 : 0)
)
```

**e. `clearFilters` resets `fy` to `''`.**

**f. `queryParams` needs no change** — it already drops `''`/`null` (L85-87).

**g. The `watch` already satisfies the requirement** (L122):
`fy: props.activeFiscalYear != null ? String(props.activeFiscalYear) : ''`. With the server reporting
`null` for All it re-seeds `''` and does **not** coerce to a concrete year. Leave it; add a comment so
it is not later "tidied" into `?? currentFiscalYear`.

**h. 🔴 The `scopeRefused` state must SUPPRESS the normal UI, not just add a banner** (finding #1)

Rev 4 added a notice and stopped there. Verified in the component, that is not enough — these regions
render **unconditionally** and would fill with zeros:

| Region | Line | What it would show on a refusal |
|---|---|---|
| KPI card grid | 255 | **TTD 0** committed · **0** requisitions · **0** lines · largest line **TTD 0** |
| `ExportCsvButton` | 349 | disabled, labelled as having **no matching rows** |
| Empty-table row `v-if="rows.data.length === 0"` | 559 | **"No requisition lines found · Nothing in any fiscal year"** |
| `tfoot`, pagination | 639, 658 | correctly hidden already (`rows.total > 0`) |

So an **oversized** result would announce itself as an **empty** one, in four places at once. That
breaks the plan's own "the table scope must never be ambiguous" principle *and* CLAUDE.md's rule that
unavailable data must never be presented as zero. It is the same class of defect as the outage path's
`hasAccess => true`, and the fix is the same shape:

```html
<!-- Everything that reports a QUANTITY is gated on a resolved scope. A refusal
     means "we did not count this", which is not "we counted zero" — the whole
     reason the outage path flashes a warning instead of rendering TTD 0. -->
<div v-if="!scopeRefused" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
    … KPI cards …
</div>

<!-- The export is refused server-side for this scope too (§6.6), so offering it
     would be a dead control that blames the data. -->
<ExportCsvButton v-if="!scopeRefused" … />

<!-- The results card: the refusal replaces the table entirely, rather than
     sitting above an empty one. -->
<div v-if="scopeRefused" class="rounded-xl border border-amber-300/70 bg-amber-50 p-5 text-sm
            text-amber-900 dark:border-amber-300/40 dark:bg-amber-400/10 dark:text-amber-100">
    <i class="fas fa-triangle-exclamation mr-2" aria-hidden="true"></i>
    {{ scopeRefusedMessage }}
</div>
<div v-else>
    … header bar, scroller, table, tfoot, pagination (unchanged) …
</div>
```

**The Filters card stays rendered** — the Fiscal Year select is the recovery (§6.2), and `years` is
populated even in a refusal.

**But the other six selects must be `disabled`, not merely empty** (finding #13). Rev 5 called them
"inert" while leaving them rendered with live `@change` handlers — so a user could pick from an empty
list, fire a visit, and get the same refusal back with no explanation. A control that looks live and
does nothing is worse than one that is visibly off:

```html
<!-- Disabled, not just optionless: with no row set we have no options to offer,
     and changing one of these cannot rescue an oversized scope (§6.2). The
     Fiscal Year select above stays enabled — it is the only recovery. -->
<select :disabled="scopeRefused" …>
```

with one line of explanation under the group when `scopeRefused`:

> *Filters are unavailable until the selection is small enough to display. Choose a fiscal year first.*

Both wrappers forward `scopeRefused` and `scopeRefusedMessage`. The message is **server-supplied** so
the two cases in §6.3 cannot drift from the controller's constants.

**How this is verified, precisely** — because it is the core false-zero protection and the temptation is
to claim more than the suite can deliver:

| Layer | What it checks | Where |
|---|---|---|
| PHPUnit (Inertia **props**) | `scopeRefused` true, `scopeRefusedMessage` set, `rows` empty, `totals` zeroed as padding, `years` populated | §9.2 cases 13–15 |
| **Browser (rendered DOM)** | the KPI grid, export button, table, totals and pagination are **absent**; the six selects are **disabled**; no `TTD 0`; no "No requisition lines found" | **§9.4.1 — manual** |

PHPUnit **cannot** see the second row: there is no Inertia SSR, so the response carries no Vue markup
and an `assertDontSee('TTD 0')` would pass vacuously. Rev 6 pointed this paragraph at feature-test case
numbers that no longer assert any of it.

**i. Empty-state copy** (L567-570) must not read "Nothing in FY null":

```html
<p v-if="hasAccess" class="text-xs text-tx-muted mt-1">
    Nothing
    <template v-if="hasFiscalYear">in <span class="font-semibold">FY {{ activeFiscalYear }}</span></template>
    <template v-else>in any fiscal year</template>
    <template v-if="categoricalFilterCount"> matching your filters</template>.
</p>
```

**j. Comments and copy that now state the opposite of the truth:**

| Line | Says today | Must say |
|---|---|---|
| L63-67 | "always set (no 'All Years' option) … `activeFilterCount` excludes it and `clearFilters` preserves it" | optional, defaults to All, **counts**, and `clearFilters` resets it |
| L247-252 | "a **required** select in the Filters card below" | an **optional** select defaulting to All; the chip states the scope. Keep every "do not reintroduce the hero / no prev-next / no page-level arrow-key stepping" clause verbatim |
| L368-372 | "Required — there is no 'All Years' option…" | Optional, defaulting to All. "All" is the **route-specific eligible** set, enforced in the query |
| **L542** | tooltip: "ActBalance — ordered less received, **floored at zero**" | **R1-G.** False since Access parity — signed. All-years surfaces more negatives |

Unchanged: scoped styles, the 17 columns, colgroup, frozen columns, `useTableScroll` usage.

---

## §8 Documentation

### 8.1 `CLAUDE.md`

1. **Deployment-state FY bullet** — drop "(working tree, uncommitted)"; replace "a **required select**"
   with the optional/All-default behaviour plus the chip. Keep "Do not 'restore' the hero here."
2. **Phase 3 "fiscal-year rail is bounded…"** — reword to "option list"; add that **"All" is that same
   bound, enforced in the query (`whereIn`)**, and is **route-specific** (Encumbered 11, Routing 3 —
   not the 13-year ledger boundary).
3. **Colour rule** — the two drill-downs have no rail; the gold **period chip** carries FY identity.
4. **"Fiscal-year arrow keys…"** — add the third case (neither callback set).
5. **L182 and L226 "floored at zero"** — both false since Access parity; signed.
6. **New Phase 3 lines** — all-years default; an all-years `sum(Extended Cost)` ties to the ledger
   **over the eligible set** but not to any one FY; `totals.requisitions` keyed on (year, number);
   ordering is **today's ordering with `FinancialYear DESC` prepended and nothing else** — the
   reference query has no `ORDER BY` at all, and the sort key is already unique, so single-year output
   is unchanged; the **bounded-fetch ceiling** exists,
   refuses rather than truncates, and **cannot be rescued by categorical filters** — year selection is
   the only recovery.
7. **Reference table** — add `finance_sep_update_deployment.md`, currently absent.

### 8.2 `export.md`

- **§57, §80, §702** rest on a "3,408-row ceiling" now raised to a measured 93,336. Dated note: the
  ceiling is superseded; the in-memory decision **stands for now** (§6.4) and is made safe by the
  bounded fetch; the SQL-cursor alternative is **re-opened pending §12**, and is a scope tradeoff.
- **§460** "floored at zero" — correct it.
- Record that requisition filenames may omit the `fy` segment, and that an export can be refused for
  **scope size** as well as a stale filter.

### 8.3 `financesqlupdatep3.md` — a declared authority (R2-5)

L198 says *"This section WINS wherever it and the [plan] disagree"*, and CLAUDE.md repeats that. Its
As-built text still describes the **hero** (L222), the **old test name** (L226), **"floored at zero"**
(L327) and **"distinct requisition numbers"** (L337). Add a dated supersession block and correct all
four.

### 8.4 `finance_sep_update_deployment.md`

The **active runbook**. Its step-5.5 table tells the operator to verify a "**required** Fiscal Year
select" and that "'Clear all' keeps the selected year" — both inverted here, so someone following it
would log a correct build as a failure. Update both rows, and add the §6.5 config-reload step.

### 8.5 `financeupdatesep.md` / `financeupdatesepprogress.md`

Dated entry: the year became optional 2026-10-01; the hero removal is `79eef8e`; **and copy §12's
prerequisite table in, since that is the project's status record.**

### 8.6 `.env.example`

Add `FINANCE_REQUISITION_ROW_CEILING` / `_ROW_WARN`, plus the undocumented `FINANCE_*` set (§6.5).

### 8.7 `RequisitionDetailController.php` L37, L191

"largest measured single user/FY set is 3,408 rows" and "floored at zero" are both false.

---

## §9 Tests and verification

### 9.1 `tests/Feature/RequisitionDetailTest.php`

Already `#[DataProvider('pages')]` over both routes (R2-6). **Premise guards must be route-specific** —
Routing has 3 eligible years to Encumbered's 11.

- **`PROPS`**: add BOTH `scopeRefused` and `scopeRefusedMessage` (17 total, §5.1); comment
  "required select" → "optional, defaulting to All".
- **🔴 NEW `test_all_years_never_includes_an_unsummarised_year`** — the R1-A regression test. Rev 1's
  version inspected `rows.data`, i.e. **page 1**; with `FinancialYear DESC` the unsummarised years sort
  *last* and would never appear there. Assert **unpaginated**: `rows.total` equals an independently
  computed eligible-only count, and is strictly less than the unbounded count when
  `unsummarisedYears !== []`.
- **🔴 NEW `test_all_years_reconciles_to_the_ledger_across_the_eligible_set`** — R1-C. Bind
  **`props['years']` on both sides**: today the two agree over the 13-year boundary only because
  FY2022/23 ledger values are zero (§2).
- **NEW** `test_the_eligible_year_set_is_route_specific` (R2-1);
  `test_the_year_options_are_newest_first` (R3-7); `test_the_outage_path_falls_back_to_all_years`
  (R2-4); `test_no_fy_parameter_covers_every_eligible_year`; `test_selecting_a_year_narrows_the_set`.
- **REWRITE** `test_an_unusable_fy_falls_back_to_a_year_that_has_data` → `…is_dropped_to_all_years…`.
- **ADJUST** `test_the_fy_parameter_selects_that_year` — default is now null; take `$props['years'][0]`
  (now the **newest**) and assert every row carries it.
- **REPLACE the assertion in** `test_totals_cover_the_whole_filtered_set_not_the_visible_page` (R1-B):
  `assertGreaterThan` is unsound with signed money. Keep the line-count assertion; use an **exact
  independent sum**.
- Fix the stale skip message "…to bound the **rail** against" → "dropdown".

### 9.2 🔴 The guard — offline unit tests plus SQL integration (finding #7)

Rev 4 put every guard case behind SQL Server, so on a machine without it the most safety-critical tests
would skip — the same hazard that made `DerivesRequisitionDetail` a DB-free trait.

**`tests/Unit/RequisitionScopeDecisionTest.php` — no DB, always runs.** Covers the pure
`shouldRedirectToSuggestedYear()` and `App\Support\RequisitionScopeThresholds` (a real class, so no
reflection — finding #6):

| # | Case | Expected |
|---|---|---|
| 1 | refused, `activeFiscalYear` null, `suggestedYear` set | redirect |
| 2 | refused, a year **was** selected | **no** redirect → refusal state |
| 3 | refused, `suggestedYear` null (no eligible years) | **no** redirect → refusal state |
| 4 | not refused | no redirect |
| 5 | ceiling `0` / `'0'` | guard fully disabled — **and warnings disabled too**, stated not implied |
| 6 | `warn >= ceiling` | clamped to 80% of the ceiling, not left dead |
| 7 | **negative ceiling** (`-1`) | **`DEFAULT_CEILING`, NOT 0** — fails closed (the rev-4 defect) |
| 8 | **non-numeric** (`'abc'`, `null`, `[]`) | `DEFAULT_CEILING` |
| 9 | **`PHP_INT_MAX`** | clamped to `MAX_CEILING`; `ceiling + 1` cannot overflow |
| 10 | above `MAX_CEILING` | clamped to `MAX_CEILING` |
| 11 | negative warn | `0`, never negative |
| 12 | **`'0.5'`, `'-0.5'`, `'00'`, `'1e5'`, `''`, `' '`** | **all `DEFAULT_CEILING`** — never 0. These all truncate to 0 under `(int)`, which would read as the opt-out; the strict parser is what separates "nonsense" from "deliberately disabled" |
| 13 | **`'+25000'`** | `DEFAULT_CEILING` — `^\d+$` has no sign branch |
| 14 | **`' 25000 '`** | **accepted as 25,000** — surrounding whitespace is trimmed on purpose |

Cases 12–14 exist because rev 6's docblock and its code disagreed: the comment claimed whitespace was
rejected while `trim()` accepted it, and claimed an "optional sign" the regex has no branch for. The
table above is now the contract, and the docblock states the same three lists.

**`tests/Feature/RequisitionScopeCeilingTest.php` — SQL-backed integration**, both routes, thresholds
**computed per route at runtime** (ceiling below that route's all-years count but at or above its
newest-year count) so the cases keep distinguishing what they mean as the data grows:

| # | Case | Expected |
|---|---|---|
| 1 | ceiling above everything | All stays All; `scopeRefused` false |
| 2 | warn below, ceiling above | renders; **one** warning per request |
| 3 | ceiling below all-years, eligible year exists | **302** to `?fy=<newest>`, `warning` flash |
| 4 | follow that redirect | renders; **no second redirect** |
| 5 | **a filter valid across all years but absent from the target year** | carried on the redirect, then **dropped there** with the normal visible reset. **Follow the whole chain** and assert the FINAL url and FINAL flash, never just the first hop (finding #12) |
| 6 | `?department[]=x` (array) on the redirect path | **not** propagated |
| 7 | ceiling below a **selected** year | refusal state, no 302 |
| 8 | ceiling below the fallback year too | refusal state, not a loop |
| 9 | empty eligible-year list | no rows via `WHERE 0 = 1`; not a refusal, not everything |
| 10 | **year dropdown is populated in a refusal state** | `years` non-empty — the recovery is reachable (§6.2) |
| 11 | export with a refused scope | **302 + warning**; `Content-Type` not `text/csv`; nothing streamed |
| 12 | **final-prop parity** | all three paths carry identical prop keys — **17** (Contract B, §5.1) |
| 13 | **the refusal props are exactly right** | `scopeRefused` true; `scopeRefusedMessage` is the **single-year** variant; `rows.data` empty and `rows.total` 0; `years` **non-empty** so the recovery control can render. ⚠️ Assert **only** the single-year variant here — the all-years variant is **unreachable over HTTP** (all-years over the ceiling redirects; with no eligible years the scope is 0 rows and cannot be refused). Its selection is covered as a pure-function case in the unit suite instead |
| 14 | **totals are not presented as an answer** | `totals` equals `emptyRequisitionTotals()` — structural padding only. The *rendering* rule is verified in §9.4.1, not here |
| 15 | **exact interpolated warning** | the flash contains the real year (e.g. "FY 2026 has been selected") and **does not contain `:year`** (finding #2c) |

> 🔴 **Rev 5 had three impossible cases here, and they would have been worse than failing.** They
> asserted on *rendered HTML* — "no `TTD 0`", "no 'No requisition lines found'", "the `<select>` is
> present". **Verified: this app has no Inertia SSR.** A page response is
> `<div id="app" data-page="{json}">` and contains **no Vue markup whatsoever** — a real `GET /login`
> response has no `<h1>` in it at all. So `assertDontSee('TTD 0')` would have passed **vacuously**,
> because *nothing* is rendered, handing back a green tick for an unverified rule. That is precisely the
> silent no-op hazard CLAUDE.md flags for the ledger tests. DOM-level checks move to §9.4.1.

### 9.3 `tests/Unit/DerivesRequisitionDetailTest.php` — offline

**NEW**: `requisitions` counts distinct **(FinancialYear, RequisitionNumber)** — two rows sharing a
number across two years count **2** (R1-F); a same-year duplicate counts 1; blanks ignored.

### 9.4 `tests/Feature/CsvExportTest.php` — both routes (R2-6)

- all-years → `/<page>-\d{8}-\d{6}\.csv/`, **no `fy` segment**; `?fy=<valid>` →
  `/<page>-fy\d{4}-\d{8}-\d{6}\.csv/`.
- `?fy=9999` → **302 + `warning`**, not `text/csv`, on **both** routes.
- the all-years file's **distinct `Financial Year` set equals `props['years']`** — equality, not "more
  than one", which is what makes it meaningful for Routing's 3 years and the only check that inspects
  every exported row rather than page 1.
- each file carries **only its own status set** across all years.

### 9.4.1 🔴 What ONLY a browser can verify (finding #9)

No Inertia SSR means the PHP suite can verify the **server contract** and nothing about the rendered
page. These are therefore **manual acceptance checks**, recorded here as a checklist rather than
pretended into the test suite. Run them with `FINANCE_REQUISITION_ROW_CEILING=10` (+ `config:clear`) on
both pages:

| # | Must be true on a refusal | Why it matters |
|---|---|---|
| 1 | **No "TTD 0"** anywhere; the KPI grid is **absent**, not zeroed | the fake zero CLAUDE.md forbids |
| 2 | **No** "No requisition lines found" / "Nothing in any fiscal year" | an oversized result must not read as an empty one |
| 3 | The **export button is absent**, not a disabled control blaming the data | it would be a dead control |
| 4 | The **Fiscal Year select is present, populated, and enabled** | it is the only recovery |
| 5 | The **other six selects are disabled** with the explanatory note (§7.3h) | they are inert; a live-looking control that does nothing is worse than a disabled one |
| 6 | The warning names a real year, never `:year` | the interpolation bug |
| 7 | Totals row and pagination absent | they would describe nothing |

If these ever need to be automated, the options are a Vue component test runner or a real browser
driver — both new toolchains, and **out of scope here**. Until then they are explicitly manual, which is
honest; asserting them in PHPUnit would be false comfort.

### 9.5 Commands

```bash
SQLSRV_HOST=127.0.0.1 php artisan test --filter=RequisitionDetailTest
SQLSRV_HOST=127.0.0.1 php artisan test --filter=RequisitionScopeCeilingTest
php artisan test --filter=RequisitionScopeDecisionTest        # offline, no SQL needed
php artisan test --filter=DerivesRequisitionDetailTest        # offline
npm run test:js                                              # node --test, the FY formatter
SQLSRV_HOST=127.0.0.1 php artisan test --filter=CsvExportTest

# Lint ONLY the files this change touches — a sweep reformats ~nine unrelated ones.
./vendor/bin/pint \
  app/Http/Controllers/RequisitionDetailController.php \
  app/Concerns/DerivesRequisitionDetail.php \
  app/Support/RequisitionScopeThresholds.php \
  config/ledger.php \
  tests/Feature/RequisitionDetailTest.php \
  tests/Feature/RequisitionScopeCeilingTest.php \
  tests/Feature/CsvExportTest.php \
  tests/Unit/RequisitionScopeDecisionTest.php \
  tests/Unit/DerivesRequisitionDetailTest.php
```

**On "0 skipped".** Some skips are legitimate premise guards — `FFIGUERA1` sees one department, so "a
filter narrows the set" correctly skips. I will report the exact count **with each reason**, and treat a
skip as a problem only when its cause is an unreachable SQL Server or an empty snapshot.

**Front-end build.** `npm run build` now succeeds and produces a deployable manifest (§12.1), so this is
an ordinary check rather than a gate. Two traps when verifying it by hand:

```bash
# A build is NOT verified while public/hot exists — Laravel bypasses the manifest
# entirely and serves from the dev server, which is how the old fault stayed
# invisible locally. Stop the dev server (or move the file) first, and restore it
# afterwards if a server is still listening.
mv public/hot /tmp/hot.bak        # only if no dev server is running
npm run build
# …then render something, NOT just inspect the manifest:
php artisan tinker --execute="view('errors.404')->render(); echo 'error layout OK';"
```

`.env`'s `DB_HOST` may be `mysql` (the Docker service name). From the Windows host that is
unresolvable, and with `SESSION_DRIVER=database` **every** request 500s at session start — nothing to
do with assets. Override per process (`DB_HOST=127.0.0.1 …`) rather than editing `.env`.

### 9.6 Manual checks

`composer dev`, as a mapped user, on **both** pages:

1. Opens on **All available fiscal years** — chip reads it, no `fy` in the URL, no filter badge.
2. Row count equals the §9.7 reference query for that route — **not a number copied from this plan**.
3. `Fin Year` shows **no year listed in `unsummarisedYears`**; the note under the select names them.
4. The dropdown offers **only that route's eligible years, newest first** — Routing noticeably fewer.
5. Pick a year → chip reads `FY 2026 · Oct 2025 – Sep 2026`, badge 1, URL `?fy=2026`. **No "Current"**
   (current FY is 2027, not selectable).
6. "Clear all" returns the year to All and clears the badge.
7. Export with All → `<page>-<timestamp>.csv`; with a year → `<page>-fy2026-<timestamp>.csv`.
8. **Two distinct cases, easily conflated (R1-E):**
   - *Load the page* at `?fy=9999` → shows **All**; the export button exports **all eligible years with
     no warning** (the server normalised `fy` to null; the link omits it).
   - *Request the export URL directly*, `/<page>/export?fy=9999` → **302 + stale-filter warning**.
9. **Set `FINANCE_REQUISITION_ROW_CEILING=10` + `php artisan config:clear`**, then walk **both refusal
   branches** — they produce different URLs and different messages, and only testing one is how the
   `fy=0` bug survived to rev 6:

   | Branch | Start at | Expect |
   |---|---|---|
   | **all-years refused** | `/<page>` (no `fy`) | 302 → `?fy=<newest>`; flash names that year as **selected**, not shown; page then shows the refusal block |
   | **selected year refused** | `/<page>?fy=<newest>` | **no** redirect; refusal block; Fiscal Year select still usable |
   | **all-years export refused** | `/<page>/export` | 302 → `?fy=<newest>`; flash **"No file was created…"**; **nothing downloads** |
   | **selected-year export refused** | `/<page>/export?fy=<newest>` | 302 → `?fy=<newest>` (**the same year, never `fy=0`**); flash is the single-year variant; nothing downloads |

   Also confirm the six categorical selects are **disabled** and the KPI grid, export button, totals row
   and pagination are **absent** (§9.4.1). Restore the ceiling afterwards.
10. Arrows only scroll columns. The chip is not focusable or clickable.
11. Narrow the window — the chip wraps onto its own centred line. Dark mode on both.
12. With `prefers-reduced-motion: reduce`, the "Current" dot does not animate.

### 9.7 Acceptance by reference query, not frozen numbers

Add `sql/Phase3AllYearsReconciliation.sql` (reference only, never in a request path) producing, per user
and per status set:

| Output | Must equal on screen |
|---|---|
| eligible year list (detail ∩ ledger, that status set) | the Fiscal Year dropdown, exactly |
| row count over those years | `rows.total` with All selected |
| `SUM(ExtendedCost)` over those years | the totals row's money, to the cent |
| ledger `SUM(Approved)` / `SUM(Routing)` over the **same** year list | the same figure |
| distinct `(FinancialYear, RequisitionNumber)` | the Requisitions KPI |
| unsummarised years (detail − ledger) | the note under the select |
| **largest single-year row count** | compare against `row_ceiling` — if it approaches it, §12 item 2 |
| **sort-key uniqueness** — `GROUP BY FinancialYear, Department, RequisitionNumber, LineNbr, PONumber HAVING COUNT(*) > 1` must return **no rows** | pagination is not stable otherwise (§3.1). **`GROUP BY`, not `CONCAT`** — 685 rows have a NULL `Department` and 20,648 an empty `PONumber`, and T-SQL `CONCAT` renders NULL as `''`, so a concatenated key collides. Checked **directly**, never inferred from `DuplicateGrainRows`, which watches a different key |

§2's figures are **dated baselines** — useful for spotting an order-of-magnitude surprise, not pass/fail.

---

## §10 Files touched

| File | Change |
|---|---|
| `routingupdate.md` | this document |
| `vite.config.js` | ✅ **ALREADY DONE 2026-10-01** — declare `resources/css/app.css` as an input (§12.1) |
| `resources/views/app.blade.php` | ✅ **ALREADY DONE 2026-10-01** — `@vite(['resources/js/app.js'])` (§12.1) |
| `app/Http/Controllers/RequisitionDetailController.php` | `index()` (+redirect), `resolve()`, `fetchBoundedRows()`, `scopeThresholds()`, `shouldRedirectToSuggestedYear()`, `refusedResolution()`, `redirectQuery()`, `detailRows()`, `availableYears()`, `unavailable()`, `export()`, stale comments L37/L191 |
| `app/Concerns/DerivesRequisitionDetail.php` | `requisitions` keyed on (year, number) |
| `app/Support/RequisitionScopeThresholds.php` | **new in rev 5** — pure, fail-closed threshold normalisation with a hard maximum |
| `config/ledger.php` | ceiling + warn, with documented invariants |
| `.env.example` | both new vars + the undocumented `FINANCE_*` set |
| `resources/js/fiscalYear.js` | **new** — shared `fiscalYearSpan()` |
| `resources/js/Components/FiscalYearHero.vue` | import the shared formatter (template unchanged) |
| `resources/js/Components/RequisitionDetailView.vue` | chip, All option, filter-count/clear, **refusal state that SUPPRESSES the KPI grid, export button and table** (not merely a banner — finding #1), empty state, comments, L542 tooltip |
| `resources/js/Pages/Expenditure/{Encumbered,Routing} Details.vue` | forward `scopeRefused`, `scopeRefusedMessage` |
| `tests/Feature/RequisitionDetailTest.php` | 2 replaced, 1 adjusted, 7 new |
| `tests/Unit/RequisitionScopeDecisionTest.php` | **new** — 11 offline cases: 4 redirect-decision + 7 threshold-normalisation (negative, non-numeric, `'00'`, `'0.5'`, `PHP_INT_MAX`, `MAX_CEILING`, warn-clamp) |
| `tests/Feature/RequisitionScopeCeilingTest.php` | **new** — 15 integration cases, both routes. **Server contract only** — DOM-level checks are manual (§9.4.1) |
| `resources/js/fiscalYear.test.js` | **new in rev 6** — `node --test`, zero new dependency (Node v24 verified) |
| `package.json` | **new in rev 6** — add `"test:js": "node --test resources/js/"` |
| `tests/Unit/DerivesRequisitionDetailTest.php` | cross-year requisition count |
| `tests/Feature/CsvExportTest.php` | 4 new cases, both routes |
| `sql/Phase3AllYearsReconciliation.sql` | **new** reference/acceptance query |
| `CLAUDE.md` | 7 edits incl. the two "floored" rules + missing runbook reference |
| `export.md` | row-ceiling premise, floor claim, filename + refusal notes |
| `financesqlupdatep3.md` | dated supersession of 4 As-built passages |
| `finance_sep_update_deployment.md` | step-5.5 rows + config-reload step |
| `routes/web.php` | export comment only |
| `financeupdatesep.md`, `financeupdatesepprogress.md` | dated entry + §12 copied in |

**Deliberately untouched:** `StreamsCsv`, `ExportsReports`, `ResolvesFiscalYear`,
`VersionsRequisitionCache`, `FinanceRequisition` (beyond a docblock note), both subclass controllers,
`ExportCsvButton.vue`, `useTableScroll.js`, `useLedgerTable.js`, `useFiscalYearNav.js`, every other
`sql/` file, all four hero pages. **No commit, no merge, no existing SQL object changed, no migration,
no new dependency.**

---

## §12 🔴 Prerequisites — accepted is not fixed (finding #9)

These were documented in rev 4 but not resolved. None is solved by writing code in this change.

| # | Item | Owner | Due | Evidence required | Blocking? |
|---|---|---|---|---|---|
| 1 | **Vite manifest** — ✅ **RESOLVED 2026-10-01.** See §12.1 below for the fix, the trap in it, and the evidence | Claude | done | clean build + production-mode render, both recorded in §12.1 | ✅ **no longer blocks** |
| 2 | **Production capacity** — ✅ **RESOLVED 2026-10-01.** App VM **16 GB** (25 worst-case requests ≈ 4.2 GB; real concurrency 1–3) and **`memory_limit = 4096M`**, which **applies to the web SAPI as well: the server uses a single shared `php.ini`** (confirmed by the user), so the CLI reading is the web reading. ~15× headroom over the 25,000 ceiling; the whole snapshot is 108,435 rows | user | done | `php -i` → `4096M`; RAM supplied; shared-ini confirmed | ✅ **no longer blocks** |
| 3 | **Capacity-log owner** — until monitoring exists these warnings land in an unwatched file. Needs a named person to check `storage/logs` for `row ceiling` / `working set is large` after any access-mapping change | **unassigned** | at release | name recorded in `financeupdatesepprogress.md` | 🟠 non-blocking, but the guard is unobserved without it |
| 4 | **Monitoring** — no Database Mail, no health-check task; CLAUDE.md's largest open item, open since 2026-08-26. The §6 tripwire cannot alert anyone | existing open item | — | task registered + mail configured | 🟠 non-blocking here |
| 5 | **`DuplicateGrainRows` is recorded but nothing ACTS on it.** Since the sort key is a superset of the grain key (§3.1), `DuplicateGrainRows = 0` proves pagination is stable — so the measurement already exists and is taken every run. The gap is enforcement: a non-zero value is written to `FinanceRequisitionRefresh` and then ignored, and a manual query "after every refresh" is not a control anyone will actually run nightly | **unassigned** | at release | **`ledger:status` treats `DuplicateGrainRows > 0` on the latest OK run as unhealthy** (it already exits non-zero for staleness and run-drift, so this is one more condition in a command that exists). Surrogate row id scoped only if it ever trips | 🟠 non-blocking at 0, but this is the **durable** fix the earlier revisions kept describing as a manual re-run |
| 6 | **SQL-pushdown refactor** — the remedy if item 2 shows a single year cannot fit, or if categorical filters must be able to rescue a scope (§6.2, §6.4) | — | on trigger | — | ⚪ deferred, triggered |

### §12.2 Production capacity — RAM known, one unknown left

**Supplied by the user 2026-10-01** (recorded here because the plan previously treated all of this as
unmeasured):

| VM | RAM | Runs |
|---|---|---|
| Database VM | **24 GB** | SQL Server 2022 (`sqlapp\SQLEXPRESS`) + SQL Server Agent |
| **App VM** | **16 GB** | Apache24, `C:\php\php.exe`, the Laravel app, **and MySQL** (sessions/cache/queue) |

#### The concurrency half: settled, comfortably

The 24 GB database VM is **not relevant to PHP memory** — it bears the query cost, not the row
hydration. The 16 GB app VM is the one that matters, and the bounded worst case is cheap against it:

| Concurrent worst-case requests × 172 MB | Total |
|---|---|
| 5 | 0.8 GB |
| 10 | 1.7 GB |
| 25 | 4.2 GB |
| 50 | 8.4 GB |

Even 25 simultaneous oversized requests take ~4.2 GB of 16 GB, alongside MySQL and the OS. And real
concurrency is far below that: `0006AWebAppControls` holds **three** users, of whom **one** is mapped,
so the realistic figure is 1–3. **This half of the gate passes.**

#### ✅ Per-process `memory_limit`: `4096M`, and it applies to the web SAPI

```
memory_limit => 4096M => 4096M
```

**The server uses a single shared `php.ini`** (confirmed by the user, 2026-10-01), so this CLI reading
*is* the Apache reading — there is no second configuration to check.

> Why this was briefly treated as an open question: PHP can load a different `php.ini` per SAPI (CLI vs
> Apache, via `PHPIniDir` or per-vhost `php_admin_value`), so a CLI-only reading is not automatically
> evidence about the runtime that serves pages. On a shared-ini server that distinction does not exist.
> Recorded because the *general* caution is sound and will come up again; it simply does not apply here.

Against the measured
marginal cost (5.3 KB/row over an ~80 MB web baseline, holding 50% in reserve):

| `memory_limit` | Safe row ceiling | Verdict |
|---|---|---|
| 128M | ~4,600 | 🔴 would have forced the ceiling **down** |
| 256M | ~17,000 | 🔴 ditto |
| 512M | ~41,700 | ✅ 25,000 fits |
| 1024M | ~91,200 | ✅ fits |
| **4096M — actual (shared ini, so web too)** | **~388,000** | ✅ **25,000 fits with ~15× headroom** |

For scale: the **entire snapshot** is 108,435 rows. Even an unbounded all-years fetch for a user mapped
to every department (93,336 rows ≈ 525 MB) would fit inside 4096M. **Memory is no longer the binding
constraint on this page.**

#### What that changes — and what it deliberately does not

The `row_ceiling` **stays at 25,000**, but its justification changes, and that distinction matters for
whoever tunes it later:

| | Before this measurement | After |
|---|---|---|
| Why 25,000? | **memory safety** — an unmeasured limit might not survive more | **usability** — memory would allow far more, but 93,336 rows is a ~5.1 s response and **3,734 pages of 25**, which is not a usable table. Refusing with "choose a fiscal year" is a better answer than delivering that |
| `MAX_CEILING` | pinned to 25,000 (could not justify more) | **50,000 — an absolute PARSER bound, not a certified-safe value.** ~300 MB/request, so 10 concurrent ≈ 3 GB. Rev 6 briefly proposed 150,000 (~875 MB; ~8.75 GB at 10 concurrent on a 16 GB shared VM), which no concurrency model here justified |

So an operator *can* now raise the ceiling knowingly; the default simply reflects that a vast table is a
poor deliverable even when it fits in RAM. **The bounded fetch remains** — it is what makes the page's
cost bounded by configuration rather than by how broad someone's access mapping happens to be.

#### Still worth capturing (non-blocking)

The Apache PHP SAPI and worker/child count were not reported. Not needed for the decision — at 4096M
per process and 1–3 real users the concurrency arithmetic above holds under any plausible worker model
— but worth recording in `financeupdatesepprogress.md` when convenient.

### §12.1 ✅ The Vite manifest blocker — IMPLEMENTED AND VERIFIED LOCALLY, 2026-10-01

⚠️ **Not "shipped".** Implemented and verified on this machine; **not committed, not deployed** (§1).
Its own change, independent of the fiscal-year work. Two files:

| File | Change |
|---|---|
| `vite.config.js` | `input: 'resources/js/app.js'` → `input: ['resources/css/app.css', 'resources/js/app.js']` |
| `resources/views/app.blade.php` | `@vite(['resources/css/app.css', 'resources/js/app.js'])` → `@vite(['resources/js/app.js'])` |

#### The trap: the "obvious" fix would have made it worse

Of the two candidate fixes this plan listed, **dropping the CSS entry from `@vite()` — the pattern the
sibling inventory-app uses — is wrong for finance.** The reason is a second `@vite()` call the earlier
revisions had not found:

```
resources/views/errors/_layout.blade.php:7   @vite(['resources/css/app.css'])
```

It asks for the stylesheet **alone, with no JS entry** — correctly, because six Blade error views
(`403, 404, 419, 429, 500, 503`) extend it and an error page must not boot the Vue app. Dropping the
declaration would have left all six throwing, **and because a `ViteException` renders the 500 page,
which extends that same layout, the failure recurses.**

So the CSS entry is declared as a real input (for the error layout), and `app.blade.php` is trimmed to
the JS entry — which also removes a duplicate Tailwind download, since `app.js` does
`import '../css/app.css'` and its manifest entry already carries the stylesheet in `css[]`.

The per-page `"resources/js/Pages/{$page['component']}.vue"` entry in the commented-out line was
verified to be broken for the same reason (`ViteException`), and is not restored — Inertia resolves
components through the eager `import.meta.glob` in `app.js`.

#### Why it was invisible locally — two independent causes, not one

1. The **stale manifest**: this machine's gitignored `public/build` kept a `resources/css/app.css` key
   from an older build.
2. 🆕 A **live Vite dev server** (port 5174, `public/hot` present). **While `public/hot` exists Laravel
   bypasses the manifest entirely**, so no amount of local browsing could reveal the fault. The first
   verification attempt was invalid for exactly this reason — it resolved to `http://[::1]:5174/…`
   rather than `/build/assets/…`.

Plus the suite, which cannot see it at all: `Tests\TestCase` calls `withoutVite()`.

#### Evidence (pass condition met)

`public/build` deleted entirely, `npm run build` from scratch (7.29s, clean), `public/hot` moved aside
to force production manifest mode:

- manifest contains **both** entries — `resources/css/app.css` and `resources/js/app.js` (the latter
  with `css: ["assets/app-BJI0fqbU.css"]`);
- all **six** Blade error views render, each linking a real built stylesheet;
- `GET /login` through the full HTTP kernel → **200**, Inertia root present, **no `ViteException`**, and
  exactly **one** CSS file emitted (no duplicate);
- **counter-test:** deleting the `resources/css/app.css` key from the manifest — precisely what the old
  single-input config produced — makes `errors.404` throw
  `Unable to locate file in Vite manifest: resources/css/app.css`. The fix is therefore load-bearing,
  not cosmetic.

`public/hot` was **restored** afterwards (a dev server was genuinely listening on 5174), so the running
HMR session is unaffected. Note the dev server predates the config change; restart `composer dev` if
HMR misbehaves.

#### Incidental, untouched

Verification also hit the documented `DB_HOST=mysql` hazard — unresolvable from the Windows host, and
with `SESSION_DRIVER=database` every request 500s at session start. **Not changed**, per CLAUDE.md's
rule that this is a deliberate developer switch and not a typo to fix silently; a per-process
`DB_HOST=127.0.0.1` override was used for the render tests instead.

---

## §13 Open questions

1. **§3.3 chip copy** — now "All available fiscal years", twice revised. Settles the overstatement and
   the "All 0 / All 1" problems in one phrase, but it is not the originally agreed wording.
2. ~~§12 item 1 (the Vite manifest) blocks release~~ — ✅ **RESOLVED 2026-10-01, see §12.1.** The fix
   was not the one this plan expected: the sibling inventory-app's pattern (drop the CSS entry) would
   have broken all six Blade error views, and recursed through the 500 page. Declared as a Vite input
   instead, verified against a from-scratch build in production manifest mode.
3. ✅ **§12 item 2 (production capacity) — RESOLVED 2026-10-01.** App VM 16 GB; `memory_limit = 4096M`
   on a **shared `php.ini`**, so the figure applies to Apache as well as CLI — ~15× headroom over the
   25,000 ceiling. **No release blockers remain.** Four non-blocking follow-ups stay in §12: the
   capacity-log owner, monitoring, the `DuplicateGrainRows` gate in `ledger:status`, and the deferred
   SQL-pushdown refactor.
4. **`master`** is at `b9dbe6b` and does **not** contain the nine commits on
   `feature/ledger-oversight-update`. Was the **branch** pushed to the `finance` remote rather than
   merged, or has a merge happened somewhere this clone has not fetched? That CLAUDE.md bullet stays
   untouched until settled.
