# Plan: Wire the Dashboard to live current-fiscal-year budget data

## Goal
Source the Dashboard's budget figures from live `vw_BudgetAllocation` data for the
active fiscal year. The **Total Budget** KPI and the **budget line** in the Budget vs
Actual chart both become `SUM(TotalAllocation)` for the authenticated user in the active
fiscal year. Actuals remain hardcoded until the chart SQL Server is configured.

## Decisions
- **Total Budget** (KPI) and the **budget line** in Budget vs Actual come from
  `vw_BudgetAllocation` — `SUM(TotalAllocation)` for the user, for the active fiscal year.
- **Actuals stay hardcoded** (monthly bars, Actual line, category doughnut) until the
  chart SQL Server exists.
- **Budget line = flat reference line** at the full total allocation across every month.
- **Active FY** = current FY, falling back to the latest FY with data (same
  `resolveFiscalYear` behaviour as the Budget Allocations view).

---

## 1. Extract the fiscal-year helpers (avoid duplication)
`currentFiscalYear()` and `resolveFiscalYear()` currently live as private methods in
`BudgetAllocationController`. Both controllers now need them, so move them into a new
trait `app/Concerns/ResolvesFiscalYear.php` (also moving `fiscalYearNav()` to keep all
three together). `BudgetAllocationController` keeps identical behaviour by `use`-ing the
trait; nothing about its output changes. (A `FiscalYearResolver` service is a reasonable
alternative if more jobs/controllers need this later — but the helpers are pure and
stateless, so a trait is the lighter fit for now.)

## 2. `DashboardController@index` — query the real budget total
Following the read-only SQL-Server pattern (named connection via the model, wrapped in
try/catch, degrade gracefully). Use the **dedicated budget file cache store**, not the
default app cache (`CACHE_STORE=database` locally — keep this query off it):

- Cache handle: `$cache = Cache::store(config('budget.cache.store'))`,
  `$ttl = config('budget.cache.minutes') * 60`. (Matches `BudgetAllocationController` exactly.)
- Resolve the active FY: read the user's distinct `FinancialYear` list by reusing the
  **exact same cache key** the allocations view already populates —
  `budget-allocations:years:{username}` on `config('budget.cache.store')` — then
  `resolveFiscalYear(null, $years, $currentFiscalYear)`.
- Budget total — query is expensive (`vw_BudgetAllocation` joins remote GP linked servers),
  so cache it as a plain numeric value keyed by user + FY:
  `dashboard:budget-total:{username}:{activeFy}` on the same store/TTL.
  ```php
  $totalBudget = (float) $cache->remember(
      "dashboard:budget-total:{$username}:{$activeFy}",
      $ttl,
      fn () => BudgetAllocation::forUser($username)->forYear((string) $activeFy)->sum('TotalAllocation'),
  );
  ```
- On any `\Throwable` (wrapping the FY resolve + sum): `Log::error(...)` with username/FY,
  set `$totalBudget = 0`, `$activeFy = currentFiscalYear()`, and `$budgetAvailable = false`.
  **Do not cache a failed result** — `remember()` does not cache when the closure throws,
  and the catch lives outside it, so a transient outage never poisons the cache with 0.
- Pass **new props**: `totalBudget`, `fiscalYear` (active FY), and `budgetAvailable` (bool).
- The budget dataset in `budgetVsActualData()` becomes a flat line — every month filled
  with `$totalBudget`, labelled **"Annual Budget"** (it is the full-year allocation, not a
  monthly figure). It takes `$totalBudget` as a param. The Actual line and
  `monthlyExpenditureData()` / `expenditureByCategoryData()` stay as-is (hardcoded).

## 3. `Dashboard.vue` — consume the real total
- Add props `totalBudget: Number`, `fiscalYear: Number`, `budgetAvailable: Boolean`.
- Change the `totalBudget` **computed** so it returns `props.totalBudget` directly instead
  of summing the line-chart data. (Critical: the budget line is now flat at the total, so
  summing 6 months would report 6× the real budget. Everything downstream — `variance`,
  `budgetUtilization` — already derives from `totalBudget`, so they start reflecting real
  budget vs hardcoded actuals automatically.)
- **`budgetAvailable === false`**: do not render `TTD 0.00` as if it were a real zero
  budget. Show a subtle "Budget unavailable" state on the Total Budget card (and suppress
  the utilization/variance figures, since they divide by budget), so an outage is never
  mistaken for a genuine zero allocation.
- Budget vs Actual legend reflects the **"Annual Budget"** label from the controller.
- YTD card sub-label: replace `{{ currentYear }} fiscal year` (today's calendar year) with
  the active `fiscalYear` prop so it reads correctly even after the latest-FY fallback.
- Mark **Budget Usage** as provisional (a small "sample data" / "provisional" hint) while
  actuals are hardcoded, so a mixed-source KPI is not read as fully live.

## 4. Verification
- `./vendor/bin/pint` on the two controllers + new trait.
- `npm run build` to confirm the Vue change compiles.
- Manual: `/` shows Total Budget = the same figure as the Budget Allocations "Total
  Allocation" KPI for the current FY; budget line is flat at that value and labelled
  "Annual Budget"; with SQL Server down the dashboard renders the "Budget unavailable"
  state (no fake 0.00, no error surfaced); the cached total is served on repeat loads.

## Notes / scope
- Budget Utilization and YTD Expenditure remain partly placeholder because actuals are
  hardcoded — utilization will be (hardcoded actual ÷ real budget), surfaced as provisional.
  That's expected until the actuals source lands.
- No changes to the SQL view, the read-only model contract, routes, or shared Inertia props.
- **Out of scope (flagged, not fixed here):** local `.env` has `CACHE_STORE=database` and
  `SESSION_DRIVER=database` (can stall when MySQL is slow/unreachable) and a **duplicated
  `QUEUE_CONNECTION=database`** (lines 26 and 68). The dashboard budget caching deliberately
  uses the dedicated `file` store via `config('budget.cache.store')`, so it is unaffected —
  but the `.env` duplication is worth a separate cleanup.
