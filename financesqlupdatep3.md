# Phase 3 — Requisition detail pages

**Status: UNBLOCKED.** Phase 2 went live in production on 2026-08-27 —
`dbo.FinanceRequisitionSnapshot`, `vw_FinanceRequisitionDetail`,
`vw_FinanceRequisitionDetailUnscoped` and `dbo.FinanceRequisitionRefresh` all exist and are
refreshed nightly by step 2 of the Agent job.

> **Two things measured during that deployment that Phase 3 must handle. Read them before
> designing the fiscal-year rail.**
>
> 1. **FY2010-2013 exist in the detail with NO summary counterpart.** The requisition snapshot
>    holds FY2010-FY2026; the ledger holds FY2014-FY2026. That is 9,174 rows across four fiscal
>    years a user could select and then be unable to drill back to anything. It is correct source
>    behaviour, not a defect — the reconciliation gate deliberately skips years the ledger never
>    built — and it mirrors `vw_BudgetAllocation` (FY2025+) vs `dbo.MonthlyExpenditure` (FY2014+).
>    **Decide deliberately: bound the rail to years the ledger has, or label those years.**
> 2. **Version the filter caches against `dbo.FinanceRequisitionRefresh`**, never
>    `FinanceLedgerRefresh` — different Agent job steps, and they can legitimately diverge. Note
>    that log is **run-keyed**, so "fresh" is `MAX(RefreshedAt) WHERE Outcome = 'OK'`, not a
>    per-year lookup.

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

---

# As built — 2026-08-27

> ### ⚠️ Dated supersession — 2026-10-01, four passages
>
> This section is a declared authority, and CLAUDE.md repeats that — so where it is now wrong it
> is wrong loudly. `routingupdate.md` made fiscal year an **optional** filter on both pages.
>
> | Below | Correction |
> |---|---|
> | the **fiscal-year hero** and its year rail | **Gone**, committed `79eef8e`. The year is a select in the Filters card, and since 2026-10-01 an OPTIONAL one defaulting to **All Fiscal Years**. A read-only gold period chip beside the `<h1>` states the scope. Do not restore the hero |
> | the withheld-years line sits "under the fiscal-year hero" | It sits under the fiscal-year **select** |
> | `Quantity` is `ActBalance` "floored at zero" | **SIGNED, not floored** — the Access-parity change removed that floor, so an over-received line is negative. `ExtendedCost` likewise |
> | the Requisitions KPI counts "distinct requisition numbers" | Keyed on **(FinancialYear, RequisitionNumber)**. Numbers recur across years, and with All selected the number alone merges a FY2019 and a FY2024 requisition |
>
> Also changed, and not contradicted anywhere below because it did not exist: the all-years scope
> is bounded in the QUERY to the route's eligible years, and the read is bounded by a **row
> ceiling** that refuses rather than truncates. See `routingupdate.md` §4 and §6.

**Implemented; all tests passing against real data on dev.** This section WINS wherever it and the
design above disagree — the design was written before the code existed.

**Naming.** The two pages are **Encumbered Details** (`/encumbered-details`) and **Routing
Details** (`/routing-details`), not the "Approved / Routing Requisitions" the design above used.
The underlying ledger columns are still named `Approved` and `Routing`, and the status sets are
unchanged (AP/PO and RT/HD/PN); only the user-facing names differ, and each page says which summary
column it drills into.

## The open items, decided

| # | Open item | Decision |
|---|---|---|
| 1 | Two pages or one with a toggle | **Two.** The near-duplication the plan worried about is avoided by putting the whole implementation in ONE Vue component (`Components/RequisitionDetailView.vue`) and ONE abstract controller (`RequisitionDetailController`); the two page files and the two concrete controllers are thin. Inertia resolves components by file name, which is the only reason the page files exist at all. |
| 2 | Where they hang in the sidebar | **In the Finance section, last, beside the five summary pages.** A first cut gave them a separate "Requisitions" section on the reasoning that they are a different grain and a different snapshot; that was overruled — they read as the finest grain of the same finance data, and a two-item section for it is noise. The freshness line on each page carries the "different snapshot" point where it is actually useful. |
| 3 | Whether the unscoped variant is exposed | **No.** `vw_FinanceRequisitionDetailUnscoped` is not referenced anywhere in the application. `App\Models\FinanceRequisition`'s class comment says why, at the point where someone would be tempted to repoint it. |
| 4 | Export | **Not delivered.** Out of scope, as the plan said; `dompdf` and `phpspreadsheet` remain unused. |

## The FY2010–2013 problem, resolved

**The rail is BOUNDED to fiscal years the ledger also has, and the withheld years are NAMED.**

`RequisitionDetailController::availableYears()` reads two year lists — the user's requisition years
and the user's ledger years — and returns their intersection as `years` plus the difference as
`unsummarisedYears`. The page renders a line under the fiscal-year **select** (it was the hero when this was written — see the supersession note above): *"FY 2010, 2011, 2012,
2013 have requisition detail but no budget ledger, so they are not offered here."*

Bounding alone would have been indistinguishable from lost data; naming them costs one prop.
`RequisitionDetailTest::test_the_fiscal_year_rail_is_bounded_to_years_the_ledger_has` asserts both
halves — every offered year exists in `vw_FinanceLedger` for that user, and every withheld one does
not.

Note this is a **per-user** intersection, not a global FY2014 floor. A user whose access mapping
gives them no ledger rows in some year gets that year withheld too, which is the same rule for the
same reason.

## Cache versioning

`App\Concerns\VersionsRequisitionCache` — a sibling of `VersionsLedgerCache`, not an extension of
it. `requisitionCacheKey()` stamps keys with `md5(MAX(RefreshedAt) WHERE Outcome = 'OK')` from
**`dbo.FinanceRequisitionRefresh`**, honouring the run-keyed shape.

`requisitionRefreshedAt()` is deliberately shared between the version stamp and the on-page
freshness line, so a user can never be told the data is fresher than the cache they are being
served from.

The controller reads the LEDGER's version too, for the ledger-years key only, and does so with a
private method rather than by also using `VersionsLedgerCache`. Mixing both traits into one class
gives two near-identical method names and invites versioning the requisition lists against the
wrong table — the single mistake this document warns about. That key deliberately matches the one
`AllocationLineExpenditureController` writes, the way `DashboardController` shares the budget years
key.

New config in `config/ledger.php`: `ledger.requisition.cache_minutes` (10) and
`ledger.requisition.version_seconds` (60), each with its own env var. The table query and the
totals stay **uncached**.

## Freshness

`Components/SnapshotFreshness.vue`, under the page header on both pages: *"Requisition detail as at
27 Aug 2026, 12:58 (21 hours ago) · rebuilt nightly, not live."* Rendered in the page's normal
type, **not** as an amber warning — being a night old is the designed state, and amber here would
train people to ignore amber everywhere else.

The relative age is computed **server-side**. The DB server writes `RefreshedAt` with
`SYSDATETIME()`; computing "ago" in the browser would introduce a third clock into a system that
already has to keep two in step.

## Files

**New application code**

| File | What |
|---|---|
| `app/Models/FinanceRequisition.php` | Read-only model over `vw_FinanceRequisitionDetail`; `APPROVED_STATUSES` / `ROUTING_STATUSES`, `forUser` / `forYear` / `withStatuses` |
| `app/Concerns/VersionsRequisitionCache.php` | Version stamp + the shared `RefreshedAt` probe |
| `app/Concerns/DerivesRequisitionDetail.php` | Pure row shaping and totals — DB-free, so CI has a net |
| `app/Http/Controllers/RequisitionDetailController.php` | The whole shared body; abstract on status set, component and route name |
| `app/Http/Controllers/EncumberedDetailsController.php` | AP/PO |
| `app/Http/Controllers/RoutingDetailsController.php` | RT/HD/PN |
| `resources/js/Components/RequisitionDetailView.vue` | The entire page |
| `resources/js/composables/useTableScroll.js` | Wide-table scrolling and the arrow keys, **extracted from `useLedgerTable`**, which now consumes it |
| `resources/js/Components/SnapshotFreshness.vue` | "As at …" |
| `resources/js/Pages/Expenditure/Encumbered Details.vue` | Thin wrapper |
| `resources/js/Pages/Expenditure/Routing Details.vue` | Thin wrapper |

**Modified:** `routes/web.php` (two routes in the existing `auth` + `active.user` group),
`resources/js/Components/SideBar.vue` (two entries in the Finance section),
`resources/js/composables/useLedgerTable.js` (now built on `useTableScroll`), `config/ledger.php`.

**Tests:** `tests/Unit/DerivesRequisitionDetailTest.php` (12, fully offline),
`tests/Feature/RequisitionDetailTest.php` (16 = 8 × 2 pages),
`tests/Feature/Concerns/UsesRequisitionData.php` (new), and both pages added to
`LedgerAccessStateTest::ledgerPages()` (4 more).

## Frontend decisions

* **The table scrolls exactly like Department Expenditure** — frozen header, frozen totals row,
  frozen identity columns, a scroll hint that says what the arrow keys are currently pointed at,
  and arrow keys that scroll by exactly one column while the pointer or focus is in the table and
  step fiscal years otherwise. This is **shared, not copied**: the `ledger-table` CSS already in
  `app.css`, plus a new `composables/useTableScroll.js`.
* **`useTableScroll` was extracted OUT of `useLedgerTable`**, which now consumes it. The first cut
  of this page used `useFiscalYearNav` and a plain `overflow-x-auto`, on the reasoning that
  `useLedgerTable` is built around twelve fiscal-month columns. That reasoning holds for the half
  of it that *is* month-shaped — the column crosshair and the per-row heat scaled to a row's own
  peak month, neither of which means anything without a month axis — but not for the scroll
  measurement and the context-sensitive arrows, which are about a table being wider than its
  container. Splitting there leaves **one scroll implementation** for every wide table in the app
  rather than two that can drift.
* **The columns ARE the reference query's final projection, in its order.** Both
  `sql/Phase2RequisitionDetail_Approved.sql` / `_Routing.sql` and the finance team's own drafts in
  `sql/source/SQL Web App Workings E - *.sql` end with the identical seventeen-column SELECT:

      RequisitionNumber, PONumber, StatusName, LineNbr, ItemDescription, AccountDescription,
      ReqDateCreated, UofM, ActBalance AS Quantity, UnitCost, ActCost AS ExtendedCost,
      Cluster, Institution, Department, ResponsibilityCentre, VendorName, FinYear

  The page renders exactly that, in exactly that order. **Do not add, drop or reorder a column
  without changing the reference queries too** — these pages exist to show that result set, and a
  divergence between them is the same class of defect the reconciliation gate exists to catch, only
  invisible because nothing checks it.

  A first cut invented its own column list: it dropped `Cluster`, `Institution`,
  `ResponsibilityCentre`, `UofM` and `FinYear` — which the view has carried since Phase 2 and the
  controller was already selecting — and added `OrderQuantity`, `QtyShipped` and `AccountNumber`,
  which the projection does not have. `Cluster` and `Institution` were reachable only as filter
  dropdowns, so a user could filter by an institution the table never named.
* **`OrderQuantity` and `QtyShipped` survive as a tooltip on the Quantity cell**, not as columns.
  `Quantity` is `ActBalance` — ordered less received, **signed and NOT floored at zero** since the Access-parity change — so a reader comparing it
  against a purchase order needs to know why the two differ, but the projection has no place for
  them. A partially received line still tints its quantity.
* **Only Requisition and PO are frozen.** `ExtendedCost` is the eleventh of seventeen columns, with
  six more after it, so it cannot also be pinned to the right edge the way Department Expenditure
  pins YTD. It keeps the gold rule instead, which is what makes it findable while scrolling.
* The `<tfoot>` totals row sums the **whole filtered set**, and says so: *"Total · N lines"*. It is
  frozen with the rest of the table, so the total stays with the reader.
* Filters: cluster (cascading into institution), institution, department, account, vendor, status.
  Status is offered only within the page's own set and only for values present in the active FY.
* The Requisitions KPI counts **distinct requisitions**, not lines — a nine-line requisition
  is one requisition, and a card that said otherwise would disagree with anything finance counts by
  hand.

## Measured on dev, 2026-08-27

* **28 new tests, 266 assertions, all passing** against real SQL Server data — the feature tests
  ran rather than skipping.
* `npm run build` clean; Pint clean on the changed files only.
* The outage test forces a real connection failure (loopback port 1, `login_timeout` 1) after
  flushing the `file` store, and asserts the outage prop key list is **identical** to the healthy
  one. Without the cache flush a warm filter cache serves the page straight past the broken
  connection and the test proves nothing.

## Not done

* **Not deployed.** No production step is required — Phase 3 adds no SQL object — but the code is
  unreleased and uncommitted along with Phases 1 and 2 (progress log item 23).
* **No link from the summary into these pages.** The Allocation Line Expenditure page shows
  Approved and Routing per account and could deep-link into the matching filtered detail
  (`?fy=…&account=…`). That is the obvious next increment and is deliberately not in this change.
* **No export**, per open item 4.
