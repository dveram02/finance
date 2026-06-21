# Plan: Fiscal-Year Filtering for Budget Allocations

## Goal
Replace the `Year From` / `Year To` range controls on the Budget Allocations view with a **single fiscal-year focus**: the page loads on the current fiscal year and the user navigates one FY at a time via ◀ Prev / Next ▶ buttons and a dropdown.

## Key facts established
- Budget allocations are **already keyed by a discrete `FinancialYear` value** (e.g. `'2026'`) in the source view `vw_BudgetAllocation`. There are no transaction dates to bucket — fiscal-year filtering is just `WHERE FinancialYear = <fy>`.
- The stored `FinancialYear` value matches the user's definition directly: `2026` = Oct 1 2025 → Sep 30 2026. So the only date math is computing the **current** FY from today's date.
- Current FY rule: `month >= 10 ? calendarYear + 1 : calendarYear`. (Today 2026-06-20 → FY **2026**.)
- Default when current FY has **no data** → fall back to the **latest** FY that does.
- All other filters (cluster, institution, responsibility, department, account) stay exactly as-is.

---

## 1. Backend — `app/Models/BudgetAllocation.php`
- The existing `scopeForYear(Builder $query, string $year)` already does `where('FinancialYear', $year)`. Keep it; the controller will use it instead of the `>=` / `<=` range.

## 2. Backend — `app/Http/Controllers/BudgetAllocationController.php`
Change the `index()` method:

1. **Replace filter keys**: drop `year_from` / `year_to` from `$request->only(...)`; add a single `fy` key.
2. **Build the list of available fiscal years** (unchanged query — still `$years`, the distinct sorted `FinancialYear` list), used both for the dropdown and for resolving the default.
3. **Resolve the active FY** with a small private helper `resolveFiscalYear($request, $years)`:
   - Compute current FY from `now()` using the Oct-boundary rule.
   - If `$request->input('fy')` is present **and** in `$years`, use it.
   - Else if current FY is in `$years`, use it.
   - Else use the **max** of `$years` (latest available). If `$years` is empty, use the current FY (page will simply be empty).
4. **Apply** `->forYear($activeFy)` to the filtered `$query` instead of the two range `where` clauses. All other filters (`cluster`, `institution`, `responsibility`, `department`, `account`) are unchanged.
5. **Compute prev/next** from the sorted `$years` list relative to `$activeFy` (null when at an end / not in list) so the frontend can disable buttons and know the navigation targets.
6. **Pass new props** to the Inertia view:
   - `years` (already passed) — the dropdown options.
   - `activeFiscalYear` — the resolved FY actually being shown.
   - `currentFiscalYear` — today's FY (so the UI can badge "Current").
   - `fyNav` — `{ prev: <fy|null>, next: <fy|null> }`.
   - `filters` now carries `fy` (the resolved value) instead of `year_from` / `year_to`.
7. **Catch block**: mirror the same prop shape (`activeFiscalYear`, `currentFiscalYear`, `fyNav => {prev:null,next:null}`, empty `years`) so the page renders cleanly when SQL Server is unavailable.

> Pattern compliance: read-only controller, single `try/catch` around the SQL Server reads, named connection untouched, no services/validation added, pagination keeps `->paginate(25)->withQueryString()`.

## 3. Frontend — `resources/js/Pages/Budget/All Budget Allocations.vue`
1. **Props**: add `activeFiscalYear`, `currentFiscalYear`, `fyNav`; `filters` no longer has `year_from`/`year_to` but gains `fy`.
2. **Filter state**: remove `year_from` / `year_to` from the `filters` ref; add `fy` (initialised from `props.activeFiscalYear`).
3. **Replace the two year `<select>` blocks** (template lines ~201–225) with a **fiscal-year navigator** in that grid cell:
   - ◀ Prev button → `goToFy(fyNav.prev)`, disabled when `fyNav.prev` is null.
   - Center: a `<select>` bound to `filters.fy` listing all `years` (label e.g. `FY 2026`), `@change` re-applies. A small "Current" pill shows when `activeFiscalYear === currentFiscalYear`.
   - Next ▶ button → `goToFy(fyNav.next)`, disabled when `fyNav.next` is null.
4. **`goToFy(fy)` helper**: sets `filters.fy` and calls `applyFilters()` (existing `router.get` with `preserveState`/`preserveScroll`/`replace`).
5. **`applyFilters` / `clearFilters`**: update the key set — `clearFilters` resets cluster/institution/responsibility/department/account but **keeps `fy`** on the active year (clearing filters shouldn't jump fiscal years). `hasActiveFilters` ignores `fy` so the clear button reflects only the real filters.
6. **Header copy**: update the subtitle to show the active fiscal year, e.g. "Showing fiscal year 2026 (Oct 2025 – Sep 2026)", derived from `activeFiscalYear` so it's always accurate.
7. Keep the KPI cards, table, and pagination unchanged — they already reflect the filtered set.

## 4. Verification
- `./vendor/bin/pint` on the changed controller.
- `npm run build` to confirm the Vue change compiles.
- Manual: load `/budget-allocations` → defaults to FY 2026; Prev goes to 2025, Next disabled at the latest year; dropdown jump works; other filters still cascade and the "Current" pill shows only on the true current FY; with SQL Server down the page renders empty without errors.

## Out of scope
- Dashboard charts (separate `DashboardController` work).
- Any change to the source SQL view or the read-only model contract.
