# Retire the old Monthly Expenditure page; rename two ledger pages

## Context

The app has seven pages. Three of them are being reorganised:

- **Monthly Expenditure** (`/monthly-expenditure`) is the last page still reading `dbo.MonthlyExpenditure` — the `UNPIVOT` view that produces one row per account *per period*. It is no longer needed.
- **Department Expenditure** (`/department-expenditure`) already shows the same money at a better grain: one row per account with the 12 fiscal months across, from `dbo.vw_FinanceLedger`. It inherits the name.
- **Allocation Line Expenditure** (`/allocation-line-expenditure`) becomes **Variance**, which is what the page actually reports — allocation against actual, with excess and balance per line.

Outcome: six pages, names that match what each one shows, and one fewer read surface in the app.

**This is an app-only release.** No SQL object changes, so no runbook and no rollback script — the same shape as the Phase 3 release that is still pending deployment.

## Decisions taken

| Question | Decision |
|---|---|
| The Dashboard's use of `MonthlyExpenditure` | **Keep the model and `dbo.MonthlyExpenditure` untouched.** Only the page goes. |
| URLs | The renamed pages **take the new URLs**: `/monthly-expenditure` and `/variance`. |
| Rename depth | Full rename of controllers, Vue pages, tests and route names — **except `DerivesAllocationLines`**, which keeps its name (it describes the allocation *line* row grain, still accurate). |
| Old URLs | **No redirects.** `/department-expenditure` and `/allocation-line-expenditure` are removed and return 404. |

## Naming map

| Now | After |
|---|---|
| `MonthlyExpenditureController` (reads `dbo.MonthlyExpenditure`) | **deleted** |
| `Pages/Expenditure/Monthly Expenditure.vue` (period rows) | **deleted** |
| `DepartmentExpenditureController` | `MonthlyExpenditureController` |
| `/department-expenditure` · `department-expenditure.index` | `/monthly-expenditure` · `monthly-expenditure.index` |
| `Pages/Expenditure/Department Expenditure.vue` | `Pages/Expenditure/Monthly Expenditure.vue` |
| `tests/Feature/DepartmentExpenditureTest.php` | `tests/Feature/MonthlyExpenditureTest.php` |
| `AllocationLineExpenditureController` | `VarianceController` |
| `/allocation-line-expenditure` · `allocation-line-expenditure.index` | `/variance` · `variance.index` |
| `Pages/Expenditure/Allocation Line Expenditure.vue` | `Pages/Expenditure/Variance.vue` |
| `tests/Feature/AllocationLineExpenditureTest.php` | `tests/Feature/VarianceTest.php` |
| `App\Concerns\DerivesAllocationLines` | **unchanged** (docblock reworded) |

## Step 1 — Delete the old page (do this first, in the same commit)

The class name and the Vue file name must both be free before step 2 renames into them.

- Delete `app/Http/Controllers/MonthlyExpenditureController.php` and `resources/js/Pages/Expenditure/Monthly Expenditure.vue`.
- `routes/web.php` — drop the import and the route line (line 30). The route *name* is re-registered in step 2.
- `resources/js/Components/SideBar.vue` — the old entry (line 110) is removed; step 2 supplies the replacement.
- **Keep** `app/Models/MonthlyExpenditure.php` and the SQL view. `DashboardController::expenditureData()` (`app/Http/Controllers/DashboardController.php:238`) still reads it for the monthly bar chart, the YTD KPI and the category breakdown. Do not "tidy it away".
- **Keep** `config/expenditure.php`, but rewrite its header comment: it no longer configures a page's filter lists, it configures the Dashboard's `dashboard:expenditure:*` cache. `MONTHLY_EXPENDITURE_CACHE_MINUTES` keeps its name and default.
- The deleted page's cache keys (`monthly-expenditure:years:*`, `monthly-expenditure:options:*`, `file` store) simply stop being written and expire on their own 10-minute TTL. **No cache clear is required at deploy** — the renamed pages reuse their existing keys unchanged, and `cache:clear file` would also evict the live budget and ledger lists, buying a burst of avoidable queries. Optional cleanup only.
- Reword the stale cross-reference in `app/Http/Controllers/BudgetAllocationController.php:184` ("See MonthlyExpenditureController — …").

## Step 2 — Department Expenditure → Monthly Expenditure

Mechanical rename; the page's behaviour, props, filters and table do not change.

- `git mv` the controller to `app/Http/Controllers/MonthlyExpenditureController.php`, rename the class, and update the class docblock (it currently opens "Department expenditure — one row per account…").
- `routes/web.php` — `Route::get('/monthly-expenditure', [MonthlyExpenditureController::class, 'index'])->name('monthly-expenditure.index')`.
- Both `Inertia::render('Expenditure/Department Expenditure', …)` calls (success path ~line 130 and `unavailable()` ~line 282) → `'Expenditure/Monthly Expenditure'`.
- `git mv` the Vue page to `Pages/Expenditure/Monthly Expenditure.vue` and update, in that file: `route('department-expenditure.index')` (line 42), the loading-overlay URL guard `includes('department-expenditure')` (line 98), `<Head title>` (line 148), the `<h1>` (line 173) and the subtitle beneath it.
- `SideBar.vue` — one entry: name `Monthly Expenditure`, `routeName: 'monthly-expenditure.index'`, `activeWhen: { any: ['monthly-expenditure.*'] }`. Keep the `fa-table-columns` icon; it describes the twelve-month grid.
- Its table `aria-label` (line 337) already reads "Monthly expenditure table, scrollable horizontally" — a pre-existing mismatch that the rename simply resolves. Leave it.
- Rename the test class and file, and its three touch points: the `/department-expenditure` URLs (lines 34, 79), the `->component('Expenditure/Department Expenditure')` assertion (line 58), and `DepartmentExpenditureController::MONTHS` (lines 96, 115).

**Trap — do not rename the cache key.** This controller caches its year list under `finance-ledger:years:{username}` (line 161) and that exact key is *deliberately shared* with the Variance page (`AllocationLineExpenditureController:168`) and read again by `RequisitionDetailController::availableYears()`. Changing it triples the query load and breaks the sharing `RequisitionDetailController` documents.

## Step 3 — Allocation Line Expenditure → Variance

- `git mv` the controller to `app/Http/Controllers/VarianceController.php`, rename the class, keep `use DerivesAllocationLines;` and the whole allocation-rule docblock (the rule is unchanged; only the page name moves).
- `routes/web.php` — `/variance`, name `variance.index`.
- Both `Inertia::render('Expenditure/Allocation Line Expenditure', …)` calls (~lines 136 and 272) → `'Expenditure/Variance'`.
- `git mv` the Vue page to `Pages/Expenditure/Variance.vue`; update `route('allocation-line-expenditure.index')` (line 44), the URL guard `includes('allocation-line-expenditure')` (line 113), `<Head title>` (line 195) and the `<h1>` (line 220). The existing subtitle — "Allocation against actual spend, line by line, across the fiscal year" — already describes Variance accurately and stays unchanged.
- Also in that file: the table's `aria-label` (line 412, "Allocation line expenditure table, scrollable horizontally") and the scoped-style comment at line 680 ("matches Department Expenditure") — the latter should now say Monthly Expenditure.
- **Keep the domain vocabulary.** "Allocation line", "allocation", "Balance of Allocation" and the empty-state "No allocation lines found" (line 492) describe the DATA, not the page, and stay. Only the page's own name changes.
- `SideBar.vue` — name `Variance`, `routeName: 'variance.index'`, `activeWhen: { any: ['variance.*'] }`. Keep `fa-scale-balanced`.
- Rename the test class and file; update the `/allocation-line-expenditure` URLs (lines 40, 89), the component assertion (line 64) and `AllocationLineExpenditureController::MONTHS` (line 105).
- `DerivesAllocationLines` keeps its name and method names; add one line to its docblock saying it backs the **Variance** page.

## Step 4 — Shared tests and prose that name the pages

**`tests/Feature/LedgerAccessStateTest.php:36-42`** — the `ledgerPages()` provider goes from seven rows to six. Both renamed pages KEEP their coverage; only the deleted page's row goes:

| Row | Action |
|---|---|
| `monthly expenditure` → `['/monthly-expenditure', 'Expenditure/Monthly Expenditure']` | **delete** (it covered the page being removed) |
| `department expenditure` → | **repoint** to `['/monthly-expenditure', 'Expenditure/Monthly Expenditure']`, rekey as `monthly expenditure` |
| `allocation line expenditure` → | **repoint** to `['/variance', 'Expenditure/Variance']`, rekey as `variance` |

Line 121 (`->get('/department-expenditure')` in `test_the_no_access_state_does_not_flash_an_outage_warning`) moves to `/monthly-expenditure`.

**New regression cases** — the removed routes deserve an assertion, since nothing else proves they are gone:

- an authenticated `GET /department-expenditure` returns **404**;
- an authenticated `GET /allocation-line-expenditure` returns **404**;
- and note the unauthenticated case is *also* 404, **not** a redirect to `/login` — the routes no longer exist, so the `auth` middleware never runs. Do not copy the `assertRedirect('/login')` pattern from the existing page tests here.

**Stale code reference:** `app/Http/Controllers/RequisitionDetailController.php:201` documents the shared years key as the one "AllocationLineExpenditureController writes" — that becomes `VarianceController`.

**Comment-only updates, no behaviour:** `tests/Feature/Concerns/UsesLedgerData.php:11`, `resources/js/composables/useTableScroll.js:7`, `useFiscalYearNav.js:7`, `resources/js/Components/RequisitionDetailView.vue` (lines 19, 96, 417, 635, 702), `app/Concerns/DerivesRequisitionDetail.php:9`, `DashboardController.php:125` ("…stays reachable from the Monthly Expenditure page" — still true of the renamed page, but the sentence should name the ledger source).

## Step 5 — Documentation and memory

- `CLAUDE.md`: the seven-page list at the top becomes six; drop the `dbo.MonthlyExpenditure` page bullet and keep the model documented as **Dashboard-only**; update the filter-cache section (`MONTHLY_EXPENDITURE_CACHE_MINUTES` now serves the Dashboard), the frontend/composable prose, the controller/model table in `.claude/context/controller-patterns.md`, and the ledger-page names throughout.
- `Overview.md` — renumber, headings **and** the table-of-contents anchors (lines 17-21): §5 becomes the new **Monthly Expenditure** (the current §6 content), §6 becomes **Variance** (current §7), §7 **Login and Profile**, §8 **Frequently asked questions**. The old §5 (the retired page) is deleted. There are no other internal section cross-references to chase.
- Memory vault: `projects/finance/HOME.md` pages table, and a new `state.md` entry recording the retirement and the two renames.
- Root design docs (`monthlyexp.md`, `dashboardupdate.md`, `financesqlupdate*.md`, `csv-export-recommendations.md`) are historical records — leave them, since CLAUDE.md already rules that where they disagree with the code they are wrong.

## Verification

1. `./vendor/bin/pint` on the changed PHP files only (never across `app/ routes/ config/` — it reformats ~nine unrelated files).
2. `php artisan route:list` — expect `monthly-expenditure.index` and `variance.index` present, `department-expenditure.index` and `allocation-line-expenditure.index` gone.
3. `npm run build` — **not** for Ziggy: routes are injected at runtime by the `@routes` directive in `resources/views/app.blade.php:30`, so the route list is never baked into the bundle. The build is still required to compile the renamed `.vue` files, catch JavaScript/import errors and include the renamed pages in the eager `import.meta.glob('./Pages/**/*.vue')` map. It does **not** validate string route names inside `route()` calls; `route:list`, the executable-leftover sweep below and the click-through cover those.
4. `php artisan test` with `SQLSRV_HOST` reachable. Baseline measured 2026-08-28 was **134 passed / 0 failed / 0 skipped / 247.6s**. Expect **134** when the two old-URL assertions above are implemented as two test methods: `LedgerAccessStateTest` loses one provider row, and that row feeds two parameterised methods (`test_a_user_with_no_department_mapping_is_told_so`, `test_a_user_with_a_mapping_is_not_shown_the_no_access_state`), so −2; the two new 404 cases add +2. Any *skip* means SQL Server was unreachable and the ledger pages were not actually exercised — re-run before believing a green result.
5. Click through: sidebar shows five Finance items; `/monthly-expenditure` renders the twelve-month grid with its frozen header, totals row and arrow-key month scrolling; `/variance` renders the allocation table; both fiscal-year rails and filters work.
6. Old URLs: `/department-expenditure` and `/allocation-line-expenditure` return **404**. Note *which* 404 — `bootstrap/app.php` only swaps in `Pages/Error.vue` when `$request->inertia()` is true, so an in-app navigation gets the styled Inertia error page while a **direct browser bookmark gets Laravel's standard 404**. That is correct for a removed route; making every direct 404 render `Error.vue` is a separate global error-handling change and is **not** in this scope.
7. Dashboard still draws the monthly bars, YTD KPI and category breakdown — that is the proof the `MonthlyExpenditure` model was left intact.
8. Final sweep, in two passes, because "allocation line" is legitimate domain language that must survive:
   - **Must return nothing** in runtime code: `rg -n "department-expenditure|allocation-line-expenditure|DepartmentExpenditureController|AllocationLineExpenditureController|Expenditure/Department Expenditure|Expenditure/Allocation Line Expenditure" app routes config resources`
   - Run the same search over `tests`; the old URL strings may appear **only** in the two intentional 404 regression cases. Old controller names and old Inertia component names must not appear.
   - **Read and classify by hand** (display copy vs. data vocabulary): `rg -n "Department Expenditure|Allocation Line" app routes tests resources`

## Not in scope

- No change to any SQL object, the Agent job, or either snapshot.
- No redirects for the old URLs (decided).
- No commit or merge — the user commits manually.

---

# As built — 2026-08-29

**Implemented.** This section WINS wherever it and the plan above disagree.

Everything in the plan landed as written. What is worth knowing after the fact:

- **Retired:** `MonthlyExpenditureController` and `Pages/Expenditure/Monthly Expenditure.vue` (the
  per-period pair). `app/Models/MonthlyExpenditure.php` and `dbo.MonthlyExpenditure` are untouched
  and now have exactly one reader, `DashboardController::expenditureData()` — recorded in the
  rewritten header of `config/expenditure.php`.
- **Renamed** with `git mv`, so history follows: `DepartmentExpenditureController` →
  `MonthlyExpenditureController`, `AllocationLineExpenditureController` → `VarianceController`, both
  Vue pages, and both feature tests. `DerivesAllocationLines` kept its name, with a docblock line
  saying why.
- **New:** `tests/Feature/RetiredRoutesTest.php` — five cases, fully offline, asserting both old URLs
  404 for a signed-in user *and* a guest, that the old route names are unregistered, and that
  `monthly-expenditure.index` / `variance.index` are.

## Deviations and extras

| # | What | Why |
|---|---|---|
| 1 | The **Variance subtitle was left as it was** — "Allocation against actual spend, line by line, across the fiscal year." | The plan expected to adjust its lead-in; read back after the `<h1>` changed, it already describes the page exactly. |
| 2 | The Monthly Expenditure subtitle dropped the word "departmental" | "Full-year departmental expenditure by account…" under a heading that no longer says Department was redundant; it now reads "Expenditure by account, month by month across the fiscal year." |
| 3 | Fixed `resources/css/app.css:127`, a comment naming both old pages | Missed by the plan's file list; caught by the second verification sweep. |
| 4 | Fixed two **stale balance-rule statements in `Overview.md`** (§ Dashboard note and the FAQ) that still described balance as `YTDTotal + Approved + Routing` | Pre-existing errors from before the 2026-08-25 rule change, sitting in the exact sections being renamed. Now: balance is `YTDTotal` alone, `Approved` is reported but deducts nothing, `Routing` neither. |
| 5 | Fixed a stale perf note in the memory vault claiming `MonthlyExpenditureController` issues ~11 executions | That was the retired controller. Every remaining page is one query. |

## Measured

- **`php artisan test` → 137 passed, 30,850 assertions, 0 skipped, 0 failed.** Exactly the predicted
  132 + 5 new `RetiredRoutesTest` cases. `VarianceTest` and `MonthlyExpenditureTest` both green
  against real ledger data, and **0 skipped** means SQL Server was reachable throughout, so the
  ledger pages were genuinely exercised.
- **Wall clock was 1,321.6s against a 247.6s baseline the day before** — a 5.3x slowdown with the
  same suite on the same machine. It is **SQL Server latency, not this change**: every ledger-bound
  case moved together (`RequisitionDetailTest` ~5s → ~25s per case) and nothing here altered how any
  page queries. Worth watching, and worth re-measuring before quoting a runtime.
- `php artisan route:list` — `monthly-expenditure.index` → `MonthlyExpenditureController@index`,
  `variance.index` → `VarianceController@index`; neither old name present.
- `npm run build` — 638 modules, clean.
- `./vendor/bin/pint` on the changed files only — no code reformatting beyond line endings.
- Verification sweep 1 (executable leftovers) returns **only** `RetiredRoutesTest.php`, which is the
  file whose job is to name those dead URLs. Sweep 2 returns four deliberate "formerly" notes.
