# Phase 3 — Requisition detail pages

**Status:** outlined, blocked on Phase 2. Nothing here can start until
`dbo.FinanceRequisitionSnapshot` and its views exist on production.

Split out of `financesqlupdate.md` on 2026-08-26. Progress, incidents and open TODOs for **all**
phases live in `financesqlupdateprogress.md` — this file is design, not a running log.

| | |
|---|---|
| **Delivers** | two read-only pages, their controllers, routes and tests |
| **Does not deliver** | any SQL object — those are `financesqlupdatep2.md` |
| **Depends on** | Phase 2 deployed: `vw_FinanceRequisitionDetail`, `vw_FinanceRequisitionDetailUnscoped`, `FinanceRequisitionRefresh` |
| **Risk** | low — no SQL risk, no writes, no new access rules |

---

## Scope — two pages

Drill-downs for the summary's two encumbrance figures. They are **not** new data; they are the
same numbers at requisition-line grain, which is the whole reason Phase 2 enforces reconciliation.

| Page | Source | Shows |
|---|---|---|
| Approved requisitions | `vw_FinanceRequisitionDetail`, `Status IN ('AP','PO')` | committed spend behind the summary's **Approved** |
| Routing requisitions | same view, `Status IN ('RT','HD','PN')` | pre-PO pipeline behind the summary's **Routing** |

Both read-only and FY-scoped, like every other page in this app.

**Open — decide before building:** two pages, or one page with a status toggle. Two matches the
existing five-page structure and the two source scripts; one avoids near-duplicate components.
Recommendation is **two**, because the summary presents Approved and Routing as separate figures
and a drill-down should land on the figure the user clicked.

---

## Controller shape

Follow `.claude/context/controller-patterns.md` exactly — it is authoritative. These are read-only
report controllers, so the flat shape applies: no service layer, no validation, no
`try/catch (ValidationException)`.

From the report-page rules already proven by `DepartmentExpenditureController` and
`BudgetAllocationController`:

* **One query, derive in memory.** The per-user row set is small — measured, the largest single
  user/FY combination is 3,408 Approved rows. Execute once, then derive filter options, stats and
  pagination from the result rather than issuing a dozen queries.
* **Build the `LengthAwarePaginator` by hand** so the Vue prop shape matches the existing pages.
* **Totals over the whole filtered set, before pagination.** A totals row that sums only the
  visible page looks authoritative and is wrong.
* **Only honour a filter value that is a valid option in the active FY**, or a stale filter carried
  across a fiscal-year switch silently empties the table.
* Scope every query by `$request->user()->username`.

A read-only Eloquent model per the `FinanceLedger` pattern: pinned
`$connection = 'FinanceAutomationSystem'`, `$timestamps = false`, `$guarded = ['*']`,
`LogicException` on create/update/delete, with `scopeForUser()` and `scopeForYear()`.

---

## The three states — the part most easily got wrong

`CLAUDE.md`'s rule applies unchanged, and these pages must not conflate them:

| State | Detection | Copy |
|---|---|---|
| Source unavailable | the query threw | flashed warning, "try again later" |
| No department mapping | `ResolvesLedgerAccess::userHasLedgerAccess()` is false | `NoAccessNotice.vue` |
| No rows match | mapped, but empty result | "No requisitions found" for this FY/filters |

Pass `hasAccess` (default **true**), and **hard-code it `true` on the outage path** — if the probe
could not run we do not know, and telling someone they have no permissions during an outage sends
them to chase the wrong fix.

Reuse `ResolvesLedgerAccess`; do **not** write a second access probe. Access here is the same
`vw_WebAppUserAccess` mapping the ledger uses — Phase 2 joins it live precisely so a permission
change still takes effect on the next request without a refresh.

### The `unavailable()` companion

Every ledger-backed `index()` has one; these are no exception. It must log with `username` and
`fy`, flash the warning, and render **the same component with an identical prop shape** — empty
paginator, empty option lists, zeroed stats, `fyNav => ['prev' => null, 'next' => null]`. A prop
the success path sends and this one omits is a Vue error on top of an outage.

---

## Freshness — a new requirement Phase 2 introduces

Phase 2 trades live data for reconciliation: a requisition raised at 09:00 does not appear until
the next refresh. That trade is only honest if the page says so.

* **Display the refresh timestamp** from `dbo.FinanceRequisitionRefresh` on both pages. Do not
  present the figures as live.
* This is the first page in the app to surface a refresh time, so no component exists for it. Keep
  it small and consistent with `FiscalYearHero`.
* If finance asks for fresher data, the answer is running the **whole Agent job** more often, never
  refreshing the detail alone — see `financesqlupdatep2.md`.

---

## Filter caches

Cache the dropdown lists on the dedicated `file` store like the other pages, but **version the key
against the requisition snapshot's `RefreshedAt`, not the ledger's.**
`VersionsLedgerCache::ledgerCacheKey()` versions on `FinanceLedgerRefresh`; these pages are backed
by a different table, refreshed in a different job step, and can be stale relative to it.

Either extend that trait with a second method or add a sibling. **Do not** reuse
`ledgerCacheKey()` unchanged — a step-2-only refresh failure would leave the ledger version
advancing while the requisition data did not, invalidating the lists at the wrong moment. The
table query and stats stay **uncached**.

---

## Frontend

Repo conventions, all of which have bitten before:

* Page components live in `resources/js/Pages/` (**capital P**) and page names **contain spaces** —
  `Inertia::render('Expenditure/Approved Requisitions')` maps to a file of that exact name. A
  mismatch is a blank screen, not an exception.
* The layout is applied globally in `app.js`. A page root is a bare `<div class="space-y-5">` —
  never its own `<main>` or `max-w-7xl` wrapper.
* These are wide tables. Evaluate `composables/useLedgerTable.js` first — but note it is built
  around **12 fiscal-month columns**, and these pages are line-grain with no month axis. Reuse the
  arrow-key and fiscal-year behaviour if it fits; do not force the per-row heat shading, which is
  meaningless without a month axis.
* Gold (`#d97706`/`#f59e0b`) means fiscal-year identity; indigo/cyan means generic interaction.
* Currency is **TTD**, formatted with `Intl.NumberFormat` for the `en-TT` locale, as the dashboard
  already does.
* Style with the CSS custom-property tokens in `resources/css/app.css` and `dark:` variants — do
  not hardcode greys.
* Normalise with `String(...)` on both sides of `v-model` comparisons: `years` come back from SQL
  as strings, `activeFiscalYear` is a PHP int.

---

## Routes and access control

Add to the authenticated group in `routes/web.php` alongside `auth` and `active.user`. **No roles,
no permissions, no `$this->authorize()`** — access in this app is binary, and these pages inherit
the department mapping rather than introducing a rule.

---

## Tests

* Follow `Tests\Feature\Concerns\UsesLedgerData`: find a `UserName` with rows, act as them, and
  `markTestSkipped()` when SQL Server is unreachable or the snapshot is empty. There is no SQL
  Server in CI. **Never** point these at `User::factory()` — a random username returns an empty
  page and turns every `foreach` assertion into a silent no-op that PHPUnit reports as *risky*,
  not failing.
* Guard any assertion needing a particular data shape and skip rather than assume it.
* Anything pure — currency and date formatting, totals arithmetic — belongs in an offline unit
  test, the way `DashboardTransformsTest` keeps `DashboardDataTransforms` DB-free.
* Add a test that the outage path renders the same prop shape as the success path. That bug class
  has appeared before and is invisible until SQL Server is actually down.
* Pint: lint only the files you changed.

---

## Open items

1. **Two pages or one with a toggle** — see Scope. Recommendation: two.
2. **Where these hang in the sidebar.** They are drill-downs, not peers of the existing five pages.
   Whether they get their own nav entries or are reached only from the summary is a UX decision
   nobody has taken.
3. **Whether the unscoped variant is ever exposed.** Phase 2 stores both behaviours as two views.
   The default and the recommendation is the scoped view; exposing the unscoped one to users would
   reintroduce exactly the summary/detail disagreement Phase 2 exists to prevent. If exposed at
   all, it belongs on a diagnostic surface, not a page toggle.
4. **Export.** `barryvdh/laravel-dompdf` and `phpoffice/phpspreadsheet` are in `composer.json` and
   unused. Line-grain detail is the most plausible export candidate in the app — but no export
   feature exists anywhere today, and adding one is its own piece of work, not a Phase 3 freebie.
