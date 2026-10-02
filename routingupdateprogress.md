# Routing / Encumbered — fiscal year as an optional filter · PROGRESS

**THE STATUS RECORD for `routingupdate.md` (rev 7).** Where this file and the plan disagree about
*what is true now*, this file wins; the plan remains the authority on *why*.

- **Opened / implemented:** 2026-10-01.
- **Branch:** `feature/ledger-oversight-update`. **Nothing here is committed.** The user commits and
  merges manually.
- **State: IMPLEMENTED AND VERIFIED LOCALLY. Not committed, not deployed.**
- **Addenda:** §6 (2026-10-02, the page header) and **§7 (2026-10-02, the banner restored
  display-only, plus arrow-key year stepping removed app-wide)**. §7 supersedes §6.2.

**Status vocabulary**, kept precisely because "shipped" was doing too much work:

| Term | Means |
|---|---|
| **Implemented locally** | files changed in the worktree |
| **Verified locally** | exercised and measured on this machine |
| **Committed** | in git history |
| **Deployed** | running on production |

---

## 1 What the change does

Both drill-downs — **Encumbered Details** (AP/PO) and **Routing Details** (RT/HD/PN) — now open on
**All Fiscal Years**, meaning every year *that route's* detail shares with the ledger. Rows, option
lists, KPIs, totals, pagination and the CSV all cover that scope. Choosing a year is an ordinary
filter: it counts in the badge, "Clear all" returns it to All, and `fy` leaves the URL when All is
selected. The scope is stated in words beside the title — first as a read-only gold chip, and
since 2026-10-02 as the headline of the **context strip** that replaced it. See §6.2.

**No hero came back.** No `FiscalYearHero`, no year rail, no prev/next stepper, no page-level
arrow-key year stepping — `useTableScroll` is still called with neither `onPrevYear` nor
`onNextYear`, so the arrows scroll columns and nothing else.

---

## 2 What was built

Every item below is implemented. ✅ = also verified by a test or a measurement recorded in §3.

| # | Item | Plan § | State |
|---|---|---|---|
| 1 | `app/Support/RequisitionScopeThresholds.php` — **new**. Pure, fail-closed threshold normalisation with a hard parser maximum | §6.5 | ✅ |
| 2 | `config/ledger.php` — `row_ceiling` / `row_warn`, passed as **raw env values** (not `(int) env(...)`, which would cast a typo to 0 and silently disable the guard) | §6.5 | ✅ |
| 3 | `.env.example` — both new vars, **plus the nine previously undocumented `FINANCE_*` / `MONTHLY_EXPENDITURE_*` settings** | §8.6 | implemented |
| 4 | `DerivesRequisitionDetail` — `requisitions` keyed on **(FinancialYear, RequisitionNumber)** | §5.8 | ✅ |
| 5 | `RequisitionDetailController` — optional year, eligible-year scope bound in the query, bounded fetch, redirect decision, refusal resolution, both export guards, `availableYears()` newest-first, `detailRows()` year list + order + cap, `unavailable()` falls back to All | §4, §5, §6 | ✅ |
| 6 | `resources/js/fiscalYear.js` — **new** shared `fiscalYearSpan()`, adopted by `FiscalYearHero.vue` (template untouched, so the four hero pages are unaffected) | §3.2, §7.1-2 | ✅ |
| 7 | `RequisitionDetailView.vue` — period chip (**superseded by the context strip, §6.2**), All option, filter count + clear, refusal state, empty-state copy, six disabled selects, corrected comments and the `Quantity` tooltip | §7.3 | implemented · DOM = §5 |
| 8 | Both page wrappers forward `scopeRefused` / `scopeRefusedMessage` | §10 | ✅ |
| 9 | Five test files (2 new, 3 amended) | §9 | ✅ |
| 10 | `sql/Phase3AllYearsReconciliation.sql` — **new** reference/acceptance query | §9.7 | ✅ **run** |
| 11 | Documentation — 8 files | §8 | implemented |

### Deviations from the plan, and why

| Plan said | Built | Why |
|---|---|---|
| `"test:js": "node --test resources/js/"` | `node --test "resources/js/**/*.test.js"` | The directory form **fails on this machine** (`MODULE_NOT_FOUND`, Node v24.20.0, verified both with and without the trailing slash). The glob form works, still picks up future test files anywhere under `resources/js`, and needs no dependency either |
| §9.2 case 12 asserts "17 props" by count | Asserts the **exact set**, after subtracting the six globals | `viewData('page')['props']` carries `auth`, `flash`, `appName`, `appVersion`, `errors`, `ziggy` too, so the raw count is 22. An exact-set assertion is also stronger: it catches a prop added to one path only, which a count does not |
| §9.1 lists `test_the_outage_path_falls_back_to_all_years` under `RequisitionDetailTest` | Lives in `RequisitionScopeCeilingTest` | It sits beside the other outage-path case there, and duplicating it would mean two tests to keep in step |
| §5.7's export refusal branches on `suggestedYear !== null` first | Branches on **`activeFiscalYear !== null`** first | Same two outcomes, but it makes the `(int)` cast *provably* a real four-digit year rather than relying on `suggestedYear` and `activeFiscalYear` never both being null. The third, unreachable combination now has an explicit arm instead of falling through to an uninterpolated message |
| §5 passes `?int $requestedYear` the string from `validFilter()` | Passes the already-cast `$activeFiscalYear` | Avoids depending on PHP's coercion of `'2026'` to `2026` at the call boundary |

### Also true, and worth recording

- **`vite.config.js` and `resources/views/app.blade.php` are now COMMITTED**, in `45652ae`
  ("added routing and encumberance update plan") along with `routingupdate.md` itself. The plan's §1
  and §10 describe them as "implemented locally, not committed" — that was accurate when written and
  is no longer. §12 item 1 is fully closed.
- **No SQL object was altered, no migration added, no dependency added, nothing committed or
  merged.** The only new `sql/` file is a reference query that must never sit behind a request path.
- `FinanceRequisition::scopeForYear()` is now unused by these two pages (the scope is a `whereIn`).
  It stays on the shared model, with a docblock saying so.

---

## 3 Verification

### 3.1 Tests — `268 passed, 7 skipped, 0 failed, 3,087 assertions, 60.5 s`

> ⚠️ Superseded by §6.4 — after the 2026-10-02 addendum the suite is
> **275 passed, 7 skipped, 0 failed, 3,097 assertions**. The per-suite table below
> is the 10-01 run.

Full suite, `SQLSRV_HOST=127.0.0.1 php artisan test`. The baseline in `CLAUDE.md` was
**199 passed / 6 skipped** before this change.

| Suite | Result |
|---|---|
| `RequisitionScopeDecisionTest` — **new, fully offline** | **16 passed**, 40 assertions |
| `DerivesRequisitionDetailTest` — **offline** (2 new cases) | **18 passed**, 51 assertions |
| `RequisitionScopeCeilingTest` — **new**, SQL-backed, both routes | **30 passed, 0 skipped**, 194 assertions |
| `RequisitionDetailTest` — 2 rewritten, 1 adjusted, 7 new | **49 passed, 3 skipped**, 502 assertions |
| `CsvExportTest` — 4 new cases × both routes | **26 passed, 1 skipped**, 1,281 assertions |
| `npm run test:js` — **new**, `node --test`, no new dependency | **5 passed** |
| Pint, on the eleven changed files only | `pass` |
| `npm run build` | clean, 6.3 s, both CSS entries emitted |

**Every one of the 7 skips is a legitimate premise guard, not an unreachable database.** Six are
"this user sees one department, so a filter cannot narrow anything" — `FFIGUERA1` is mapped to a
single department, which `CLAUDE.md` documents as the current and permanent access state — and one
is "Routing has no unsummarised years", where the eligible and unbounded counts legitimately agree
and the case cannot distinguish the bug from correct behaviour. **0 skips were caused by SQL Server
being unreachable or a snapshot being empty**, which is the only skip reason that would mean the
ledger-bound cases had not actually run.

### 3.2 The reference query — `sql/Phase3AllYearsReconciliation.sql`, run against local SQL Server

Run as `FFIGUERA1`, AP/PO. **This is the acceptance evidence; the figures are a 2026-10-01
observation, not a pass/fail target.**

| Check | Result |
|---|---|
| Eligible years (the dropdown) | **11** — 2026, 2025, 2024, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014 |
| Withheld years (named under the select) | **FY2011, FY2012, FY2013** |
| Row count | **416** |
| `SUM(ExtendedCost)` | **TTD 111,089,421.36** |
| Ledger `SUM(Approved)` over the same years | **TTD 111,089,421.36** — **diff 0.00** |
| Ledger `SUM(Routing)`, for contrast | TTD 241,553.20 |
| Distinct `(FinancialYear, RequisitionNumber)` | **121** (and 121 on the number alone — the cross-year undercount is **0** for this user, which is precisely why it is covered by a unit test rather than assumed) |
| Largest single year, this user | 138 rows (FY2020) — nowhere near the 25,000 ceiling |
| **Sort-key uniqueness**, 5 keys, `GROUP BY … HAVING COUNT(*) > 1` | **NO ROWS** |
| `DuplicateGrainRows`' key, 4 keys, same form | **NO ROWS** |

The snapshots were from 2026-09-30 (requisition 12:54, ledger 10:25).

### 3.3 Real HTTP, production manifest mode

`public/hot` moved aside (a dev server was genuinely listening on 5174) so Laravel used the built
manifest rather than bypassing it, with a per-process `DB_HOST=127.0.0.1` override for the
documented `DB_HOST=mysql` hazard. **`public/hot` was restored afterwards and `.env` was not
touched.** All three renders were **200** with real `/build/assets/` URLs.

| Request | Result |
|---|---|
| `/encumbered-details` | `activeFiscalYear` **null**, 416 rows, 11 years, `scopeRefused` false, committed **111,089,421.36**, 121 requisitions |
| year option order | **2026, 2025, 2024, 2021** — newest first |
| withheld years prop | 2013, 2012, 2011 |
| `/encumbered-details?fy=2026` | 55 rows, `activeFiscalYear` 2026 |
| `/routing-details` | 200 |
| **ceiling 10, `/encumbered-details`** | **302 → `?fy=2026`**, flash reads *"All available fiscal years is too large to display, so **FY 2026** has been selected…"* — a real year, **no literal `:year`** |
| **ceiling 10, `?fy=2026`** | **no redirect**; `scopeRefused` true, 0 rows, **`years` still 11** (the recovery is reachable), `departments` 0, the single-year message |

### 3.4 What the PHP suite CANNOT verify, by construction

**This app has no Inertia SSR** — a page response is `<div id="app" data-page="{json}">` with no Vue
markup — so an `assertDontSee('TTD 0')` would pass **vacuously** and hand back a green tick for an
unverified rule. Everything about the *rendered* refusal is therefore a manual check. It is written
up as **step 5.7 of `finance_sep_update_deployment.md`**, with all four refusal branches, rather
than pretended into the test suite.

---

## 4 Documentation updated

| File | What changed |
|---|---|
| `CLAUDE.md` | The overview's "all FY-scoped" claim; the year bound reworded to "option list" with the query-enforced All added; **both "floored at zero" rules corrected** (L182, L226 — false since Access parity); eight new Phase 3 rules; the colour rule gains the chip and the shared formatter; the arrow-key rule gains its **third** case; the deployment-state bullet; three documents added to the reference table, including `finance_sep_update_deployment.md`, which was missing |
| `export.md` | A dated supersession note at the top: the **3,408-row premise is now 93,336**, the floor claim is corrected, requisition filenames may omit `fy`, and an export can now be refused for **scope size**. The in-memory decision **stands** but its justification changed, and the SQL-cursor alternative is **re-opened** rather than left resting on a stale premise |
| `financesqlupdatep3.md` | A dated supersession block — it is a *declared authority*, so where it is wrong it is wrong loudly. Four passages corrected: the hero, where the withheld-years line sits, "floored at zero", and "distinct requisition numbers" |
| `finance_sep_update_deployment.md` | Step 5.5's two **inverted** rows fixed (someone following them would have logged a correct build as a failure); the filename-shape table in 5.6; **new step 5.7**, the four-branch row-ceiling walkthrough plus the DOM checks from §3.4 |
| `financeupdatesep.md` | A note that its workstream 2 made the select *required* and this change makes it *optional*, with the four parity-adjacent consequences |
| `financeupdatesepprogress.md` | Workstream 2's row marked superseded; a dated entry carrying the measurements, test results and the outstanding list |
| `routes/web.php` | The export block's comment: `?fy` is optional on the two requisition exports, and they are the only two that can be refused for scope size |
| `app/Models/FinanceRequisition.php` | `scopeForYear()` docblock — no longer used by these pages, and why it must not come back there |

---

## 5 Still outstanding

### Before release

| # | Item | Owner |
|---|---|---|
| 1 | **The browser checks** — step 5.7 of `finance_sep_update_deployment.md`, both pages, both refusal branches, dark mode, reduced motion, narrow window. Unavoidably manual (§3.4) | — |
| 2 | **Re-run `sql/Phase3AllYearsReconciliation.sql` on PRODUCTION** and compare against the screen. §3.2's figures are local, dated observations — acceptance is agreement **at deploy time**, never a number copied from a document | — |
| 3 | **A named owner for the capacity log.** The `row ceiling` / `working set is large` warnings land in `storage/logs` and, with no monitoring, nobody is watching | **unassigned** |

### Deliberately not done in this change

| # | Item | Why |
|---|---|---|
| 4 | **Monitoring** — no Database Mail, no health-check task; open since 2026-08-26 and the project's largest open item. The §6 tripwire cannot alert anyone | pre-existing, outside this change |
| 5 | **`DuplicateGrainRows` is recorded every refresh and nothing acts on it.** Since the sort key is a *superset* of that key, `DuplicateGrainRows = 0` **proves** pagination is stable — so the measurement already exists and is taken every run. The gap is enforcement: the durable fix is one more condition in `ledger:status`, which already exits non-zero for staleness and run-drift | `ledger:status` is outside the plan's §10 file list. **Not implemented**; 0 today |
| 6 | **SQL-pushdown refactor** — the remedy if a single fiscal year ever exceeds the ceiling, or if categorical filters must be able to rescue a scope | ⚪ deferred, with a named trigger (plan §6.4, §12 item 6) |

### Closed before implementation started

- **§12 item 1, the Vite manifest** — fixed, verified, and now **committed** in `45652ae`.
- **§12 item 2, production capacity** — app VM 16 GB; `memory_limit = 4096M` on a **shared
  `php.ini`**, so the figure applies to Apache as well as CLI. ~15× headroom over the 25,000
  ceiling, which makes that ceiling a **usability** limit rather than a memory one.

### Open question the plan raised and this change does not settle

`master` is at `b9dbe6b` and does not contain this branch's work. Whether the branch was pushed to
the `finance` remote rather than merged, or a merge happened somewhere this clone has not fetched,
is still unanswered — so the `CLAUDE.md` bullet about it stays untouched.

---

## 6 Addendum — 2026-10-02: the page header

Three follow-on changes after the fiscal-year work, all asked for directly —
including one that was built and then reverted on the user's call (§6.2).

### 6.1 The Account filter is one cell wide

`RequisitionDetailView.vue` — dropped `sm:col-span-2 lg:col-span-2`. Seven equal
controls in a 4-column grid, so the second row now ends in one empty cell. That
trailing gap is **accepted deliberately**; the layout comment that claimed the
span existed to avoid it has been replaced, or the next person reads it as a rule
and puts the span back. Account carries the longest option labels
(`MEDICAL SUPPLIES (4-80400-H01-107-1157-00-000)`), so the closed select now
truncates — the open dropdown still shows each option in full.

### 6.2 No hero — and no strip either. The header is plain text.

> WARNING: **SUPERSEDED by §7 (2026-10-02, later the same day): the banner WAS put back,
> display-only.** Kept unedited because its four objections are why the banner is shaped the way
> it is — see §7.1 for the disposition of each. Do not act on this section.

**The question asked was whether these two pages need a hero section now the
year band is gone. The answer is no, and twice over.**

`FiscalYearHero` is not a page title — it is a **year navigator** (5xl numeral,
prev/next stepper, year rail) that sits between the title block and the KPI
cards. The `<h1>` + subtitle block is identical on all six pages and was never
removed from these two. So nothing was missing from the title; what was absent
was an interactive control, and restoring it would be wrong on four counts
independent of any style preference:

1. **There is no honest way to render "All" as a year numeral**, and no meaning
   for "previous" from it.
2. It would put **two controls on one value** — the band and the Filters select —
   which is precisely the ambiguity the September and October changes removed.
3. It needs `fyNav` back on both controllers, deliberately dropped.
4. On these pages the arrow keys scroll **17 table columns**; the hero's contract
   is that arrows step years. That conflict is why `useTableScroll` was split out
   of `useLedgerTable` in the first place.

#### A "context strip" was then tried in that slot, and REVERTED the same day

A bordered strip was built there — gold left rule, three cells (scope, the
summary column drilled into, snapshot state). **The user rejected it and it was
removed.** The reason is sound and worth keeping, because it is a trap anyone
filling this slot will hit: the strip was a bordered card with a shadow sitting
directly above **four more bordered cards**, with the Filters card and the table
card below them. The page is already a stack of cards, and the strip read as a
fifth KPI card rather than as a statement of provenance. The
`frontend-design` skill names this exact failure — *"content chopped into
identical rounded cards, one border-radius on everything regardless of
hierarchy"* — and the strip was a clean instance of it.

**Nothing was lost in the revert, because every fact the strip carried is still
on the page:**

| Fact | Where it lives now |
|---|---|
| The scope | the gold period chip beside the `<h1>` — restored |
| Which summary column this drills into | `moneyNote`, which already says *"the summary's **Approved** column, net of receipts…"*. The strip's `summaryColumn` prop was redundant with it and has been removed from both wrappers |
| When the snapshot was built | `SnapshotFreshness`, one quiet centred line |
| Whether that build is stale or failed | `SnapshotFreshness` — **kept**, see §6.3 |

**The header is therefore back to plain centred text**, and `CLAUDE.md` now
records that nothing goes in that slot, naming both failed attempts so neither is
retried.

### 6.3 Stale and failed refreshes are now surfaced

This was the one requirement not in the original plan, and it needed a
server-side judgement that did not exist. **It SURVIVED the strip's removal** —
it was always a separate requirement, and it lives in `SnapshotFreshness`, not in
any banner. **Four states, never conflated**, in
`snapshotState()`:

| State | Detected by | Rendered |
|---|---|---|
| `ok` | a good build inside the limit | **quiet.** A night old is the DESIGNED state; amber here would train people to ignore amber everywhere else |
| `stale` | last good build older than the limit | **amber alert.** Names the time the figures are correct as at, so they stay usable, and says to contact IT |
| `failed` | the **newest** run's `Outcome` is not `OK` | **amber alert.** Invisible to the timestamp, which reads only `OK` rows — the log is run-keyed, so an aborted run appends a row while the previous snapshot stands |
| `unknown` | the probe could not run, or it has never built | **quiet grey, never amber.** We do not know, and asserting a fault we cannot establish sends someone to chase the wrong thing — the same rule as the outage path's `hasAccess => true` |

`failed` is checked **before** `stale`: a run that aborted tonight is not yet 36h
old, so reporting only the age would hide it until tomorrow.

**The threshold has one definition.** `ledger.requisition.max_age_hours` (36h,
because the Agent job runs daily at 21:30) is read by both the pages and
`ledger:status`, whose `--max-age-hours` default now comes from config instead of
a literal. A page that reassures a user while the health check is alerting is
worse than either signal alone. This is the one place the work reached outside
the plan's file list — `ledger:status` is the production health signal, so the
change is the minimum: same value, same behaviour unless the new env var is set.

`snapshotState()` takes the threshold as an **argument** rather than calling
`config()`, matching `RequisitionScopeThresholds` — that is what keeps it
container-free and lets the offline suite cover all four states.

### 6.4 Verification

| Check | Result |
|---|---|
| Full suite, `SQLSRV_HOST=127.0.0.1` | **275 passed, 7 skipped, 0 failed**, 3,097 assertions, 61.8 s |
| `RequisitionScopeDecisionTest` (7 new state cases, **offline**) | **23 passed**, 50 assertions |
| `npm run build` | clean |
| Pint, changed files | `pass` |
| `ledger:status` on the shared threshold | runs; reports the requisition snapshot 35.3h old, outcome OK, drift 149 min |
| Real HTTP, production manifest mode | `/encumbered-details`, `/routing-details` and `?fy=2026` all **200**; `snapshot` = `{refreshedAt, age:"1 day ago", state:"ok", ageHours:35.3}`. **Re-run after the strip was reverted: all three still 200, state still `ok`** |

The 7 skips are the same premise guards as §3.1 — none is an unreachable
database.

⚠️ **Note for anyone testing on this dev box:** the snapshot was 35.3h old when
measured, against a 36h limit. It will tip into `stale` within the hour, so the
amber alert will appear on both pages without anything being wrong with the code
— run `php artisan requisition:refresh` to reset it, or expect to see the stale
state. That is the strip working.

### 6.5 Still outstanding from this addendum

- **The browser pass on the header** — the chip, and `SnapshotFreshness`'s three
  renderings (quiet line, amber stale, amber failed), in dark mode, plus reduced
  motion on the "Current" dot. Same constraint as §3.4: no Inertia SSR, so
  PHPUnit can verify the `snapshot` prop but nothing about how it renders.
- **The `failed` state has never been seen against real data** — it needs a row
  in `dbo.FinanceRequisitionRefresh` whose newest `Outcome` is not `OK`. The
  logic is covered offline; the rendering is not.

---

## 7 Addendum — 2026-10-02 (later the same day): the banner came back, display-only

**§6.2 above is SUPERSEDED. Read this section instead.** It is kept unedited because its four
objections are the reason this version of the banner is shaped the way it is — three of them were
answered rather than overruled, and the fourth stopped existing.

The user asked for it directly: remove the all-years chip and the nightly-refresh line from the
header, and "put back the all years banner we had initially like the other views — we still show
fiscal year on the top left of it, but for the actual years, we show something like All Years, and
then the next line will be relevant fiscal month start and month end".

### 7.1 What §6.2's four objections did next

| §6.2's objection | Disposition |
|---|---|
| 1. No honest way to render "All" as a year **numeral**, and no meaning for "previous" from it | **Answered.** `FiscalYearHero` gained `allYearsLabel`, which fills the numeral slot with the *words* "All Years". Nothing has to pick a year, and nothing claims a "previous" |
| 2. It would put **two controls on one value** | **Answered.** `:controls="false"` strips the prev/next stepper and the year rail. The band is a read-only statement of scope; the Filters card remains the only control |
| 3. It needs `fyNav` back on both controllers | **Not needed.** `fyNav` is still not passed, there is still no `@select` handler, and no controller changed |
| 4. On these pages the arrow keys scroll 17 columns, which conflicts with the hero's contract | **Moot.** Arrow-key year stepping was removed from the whole app later the same day (§7.4), so the hero no longer has that contract to conflict with |

The one objection with no technical answer was the look, and that is what sank the *previous*
attempt (§7.5) — not this one.

### 7.2 The banner

`RequisitionDetailView.vue` now renders the **shared `FiscalYearHero`**, not a copy, in the same
page position the four summary pages use: centred `<h1>` + subtitle + `moneyNote`, then the band,
then the KPI grid.

- **`all-years-label="All Years"`** — the numeral slot, when no fiscal year is selected.
- **The line beneath it is the span across the ELIGIBLE years**, from new
  `fiscalYearRangeSpan(years)` in `resources/js/fiscalYear.js`.
- **`:controls="false"`** — no stepper, no rail.
- **The gold period chip beside the `<h1>` was REMOVED**, and with it `periodSpan` and
  `isCurrentFiscalYear` in `RequisitionDetailView`: the band derives both, and two statements of one
  scope invite the two to disagree. `hasFiscalYear` stayed — the table's empty-state copy uses it.
- **Both new hero props default to the old behaviour**, which is what leaves the four summary pages
  untouched: `controls` is `true`, and with no `allYearsLabel` an absent year still renders an em
  dash. `isAllYears` requires an absent year **and** a declared label, because an absent year is
  also what an outage looks like, and an outage must not read as a deliberate "All Years" scope.

**The span is `Oct <earliest − 1> – Sep <latest>`, and the user's own example was not.** The request
said "oct 2014 - oct 2026"; FY2014–FY2026 actually spans **Oct 2013 – Sep 2026**, because the
earliest year starts twelve months before it is named for and the latest ends in September. Taken
literally the line would have been 12 months late at one end and 13 at the other, and would have
contradicted the single-year line rendered by the same component. Raised, and the corrected form
chosen. A one-year list agrees with `fiscalYearSpan()` by construction.

### 7.3 The span tracks the filter, and the year list has GAPS

The band is passed `:years="years"` and the Fiscal Year select renders `v-for="year in years"` —
**one array**, so the span follows the user's access automatically and no code knows the year list
ahead of time. Measured 2026-10-02 for `FFIGUERA1`:

| Route | Eligible years | Span |
|---|---|---|
| Encumbered | 11 — `2026, 2025, 2024, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014` (**no FY2022, no FY2023**) | Oct 2013 – Sep 2026 |
| Routing | **3** — `2026, 2021, 2014` | Oct 2013 – Sep 2026 |

So both pages render the identical line while holding 11 and 3 years of data, and on Routing it
describes a 13-year window covering three years. **This was raised and the decision was to report
endpoints only** — a trailing "· N fiscal years" count was offered and declined. Do not add a count,
do not list the years, do not switch format on the size of the set, and **do not read the two pages'
identical lines as a bug**. (Encumbered's FY2013/2012/2011 are a different thing — *withheld* years
the detail holds but the ledger does not. They are excluded from both the dropdown and the span, and
already named under the select by `unsummarisedYears`.)

### 7.4 §6.3 survives, but only its alarm — and arrow keys stopped changing the year

**`SnapshotFreshness` is now rendered `faults-only` on these two pages.** The quiet "as at … rebuilt
nightly, not live" line is gone; the amber `stale` / `failed` strips are not. §6.3's four-state table
is unchanged and still correct.

Those are **different decisions and only the first was taken**: the quiet line was cosmetic, while
the amber strip is the only signal a user gets that the nightly job has stopped — monitoring item #2
in §5 has been open since 2026-08-26, so nothing else would notice. `faultsOnly` is a **prop on the
component**, not a `v-if` in the page, so `isFault` stays the one definition of what counts as a
fault. `snapshot.refreshedAt` / `age` / `ageHours` / `state` are therefore *more* load-bearing now,
not less — `RequisitionDetailTest::test_the_snapshot_state_reaches_the_page_so_a_stale_build_can_alarm`
asserts the whole shape, and was renamed from `test_the_page_says_when_the_snapshot_was_last_built`
because the page no longer says it.

**Separately, on the user's instruction — "the user presses the left or right arrows, the years
change for the view, i do not want this behaviour" — arrow-key year stepping was removed from EVERY
page.** It had three independent sources, and leaving any one would have kept the behaviour on two
pages:

1. `composables/useFiscalYearNav.js` — **deleted**; calls dropped from `Dashboard.vue` and
   `All Budget Allocations.vue`.
2. `useTableScroll`'s `onPrevYear` / `onNextYear` params and the year branch of `handleKeydown` —
   **gone**.
3. `useLedgerTable` no longer accepts or forwards them; `Monthly Expenditure.vue` and `Variance.vue`
   no longer pass them.

`useTableScroll` is now the **only** arrow-key listener in the app (the three others are Escape
handlers for modals and dropdowns). It acts on one condition — pointer or focus inside a table with
somewhere to scroll — and returns early otherwise, leaving the event to the browser. **The case
easiest to miss:** the old handler also stepped the year when the pointer was *inside* a table that
could not scroll (a wide screen where everything fits), because `arrowsScrollTable` is
`canScroll && (pointerInTable || tableFocused)`. `fyNav` still drives the hero's prev/next
**buttons** on the four summary pages; only the keyboard path went, and the tooltips lost their
"(←)" / "(→)" hints so the UI does not advertise a dead shortcut. Nothing server-side changed.

### 7.5 One attempt in between, built and reverted

Between §6.2 and §7.2 a **shared `PageHero` shell** was built: `FiscalYearHero`'s chrome extracted
into a props-free component with `eyebrow` / `main` / `footnote` slots, the hero rebuilt on it, and
the drill-downs given the same shell holding their `<h1>`, the chip, `SnapshotFreshness` and
`moneyNote`. It answered every objection in §6.2 and was **reverted on the look alone** — "lets
revert i do not like this". `PageHero.vue` was deleted and `FiscalYearHero` still owns its own
chrome. Counting it, this slot has now been through four attempts; the one that stands is the shared
component, display-only, with an honest all-years state.

### 7.6 Verification

- **Suite** (`SQLSRV_HOST=127.0.0.1 php artisan test`): **275 passed, 7 skipped, 0 failed, 3,105
  assertions**. Zero DNS-timeout skips, so the ledger was genuinely exercised. The banner change
  alone measured **274 passed / 8 skipped / 3,098 assertions** before the arrow-key removal; the skip
  count moves with the access mapping, not with this code.
- **`npm run test:js`: 12 passed**, up from 5 — six new cases for `fiscalYearRangeSpan` covering the
  off-by-one, order-independence (controllers send years newest-first), agreement with
  `fiscalYearSpan()` on a one-year list, and `''` for an empty or unusable list rather than
  "Oct NaN".
- **`npm run build` clean**, and no live references remain to `useFiscalYearNav`, `onPrevYear` or
  `onNextYear` — only comments recording their removal.
- **Pint** pass on the one PHP file touched (`tests/Feature/RequisitionDetailTest.php`).
- **No PHP changed by the banner or the arrow-key removal.** Nine Vue/JS files and one test file.

### 7.7 Still outstanding from this addendum

- **The browser pass, still not done** — now covering: the "All Years" label at its two sizes
  (`text-4xl sm:text-5xl`, stepped down so nine characters do not wrap mid-word), the span line, the
  band in dark mode, and **that the four summary pages still render identically** after the hero
  gained two props. Nothing automated covers any of it: there is no Inertia SSR.
- **§6.5's `failed`-state item is unchanged** and now matters more, since the amber strip is the only
  snapshot signal these pages render.
- Items 1–5 in §5 are untouched by this addendum.
