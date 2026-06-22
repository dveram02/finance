# Budget Allocations View — Build Spec

This document describes how the Budget Allocations feature is built **as it currently exists**.
Use it as the authoritative reference for recreating or modifying this view. It follows the
project's `controller-patterns.md` (read-only controller) and the SQL Server query rules in
`CLAUDE.md`.

---

## Overview

A **read-only**, fiscal-year-scoped listing of approved budget allocations for the
authenticated user. The page is driven by one fiscal year at a time: the controller loads only
the active FY's rows, then derives filter dropdowns, KPI stats, and a paginated table entirely
in memory. Fiscal-year navigation is the hero control; categorical filters refine within the
selected year.

- **Route:** `GET /budget-allocations` → `budget-allocations.index`
- **Controller:** `App\Http\Controllers\BudgetAllocationController@index`
- **Model:** `App\Models\BudgetAllocation`
- **Vue page:** `resources/js/Pages/Budget/All Budget Allocations.vue`
- **Currency:** TTD (`en-TT`)

---

## 1. Route

In `routes/web.php`, inside the authenticated + `active.user` middleware group:

```php
Route::get('/budget-allocations', [BudgetAllocationController::class, 'index'])
    ->name('budget-allocations.index');
```

No write routes exist. This feature is read-only end to end.

---

## 2. Model — `BudgetAllocation`

A read-only Eloquent model bound to a SQL Server **view** on a separate connection.

```php
class BudgetAllocation extends Model
{
    protected $connection   = 'FinanceAutomationSystem';   // NOT the default MySQL connection
    protected $table        = 'vw_BudgetAllocation';
    protected $primaryKey   = 'AccountNumber';
    protected $keyType      = 'string';
    public    $incrementing = false;
    public    $timestamps   = false;
    protected $guarded      = ['*'];

    protected function casts(): array
    {
        return ['TotalAllocation' => 'decimal:2'];
    }

    // Hard-block all writes — the view is read-only.
    protected static function booted(): void
    {
        static::creating(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
        static::updating(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
        static::deleting(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
    }

    public function scopeForUser(Builder $query, string $username): Builder
    {
        return $query->where('UserName', $username);
    }

    public function scopeForYear(Builder $query, string $year): Builder
    {
        return $query->where('FinancialYear', $year);
    }
}
```

**Rules:**
- The connection is `FinanceAutomationSystem` — declared on the model so callers never touch the
  default MySQL connection.
- Columns are **PascalCase** (view convention): `UserName`, `FinancialYear`, `ClusterName`,
  `InstitutionName`, `ResponsibilityName`, `DepartmentName`, `AccountNumber`,
  `AccountDescription`, `TotalAllocation`.
- Rows are scoped per user via `UserName` — always start a query with `forUser($username)`.
- Writes throw `LogicException`. Never add create/update/delete logic.

---

## 3. Controller — `BudgetAllocationController@index`

A flat read-only controller (no service, no validation layer, no `DB::transaction`). One method,
`index()`, returning an Inertia response. `PER_PAGE = 25`.

### Flow

1. **Get the user + filters**
   ```php
   $username = $request->user()->username;
   $filters  = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'fy');
   ```

2. **Resolve available fiscal years (cached 5 min, file store)** — query distinct
   `FinancialYear` for the user so we never load every year's rows just to build the year rail.
   ```php
   $years = Cache::store('file')->remember(
       "budget-allocation-years:{$username}",
       now()->addMinutes(5),
       fn () => BudgetAllocation::forUser($username)
           ->select('FinancialYear')->distinct()
           ->orderBy('FinancialYear')->pluck('FinancialYear')
           ->filter()->values()
   );
   ```

3. **Resolve the active fiscal year** using these helpers:
   - `currentFiscalYear()` — FY rolls over in October: `month >= 10 ? year + 1 : year`.
   - `validFiscalYear($input)` — accepts only a 4-digit string, else `null`.
   - `resolveFiscalYear($requested, $years, $current)` — pick the requested year if it exists in
     `$years`; otherwise the current FY if available; otherwise the max available year. If no
     years exist, fall back to the current FY.
   - `fiscalYearNav($active, $years)` — returns `['prev' => …, 'next' => …]` neighbours on the
     sorted year list (or `null` at the ends).

   Set `$filters['fy'] = $activeFiscalYear` so the frontend repopulates correctly.

4. **Load only the active FY's rows once**, then derive everything in memory (the view joins
   remote GP linked servers, so one load per request is deliberate):
   ```php
   $all = $years->isEmpty()
       ? collect()
       : BudgetAllocation::forUser($username)->forYear((string) $activeFiscalYear)->get();
   ```

5. **Build dropdown sources from `$all`:**
   - `clusters` — distinct sorted `ClusterName`.
   - `institutions` — unique by `ClusterName|InstitutionName`, mapped to
     `['ClusterName', 'InstitutionName']`, sorted by institution (enables the cluster→institution
     cascade on the frontend).
   - `responsibilities` — distinct sorted `ResponsibilityName`.
   - `departments` — distinct sorted `DepartmentName`.
   - `accounts` — unique by `AccountNumber`, mapped to `['AccountNumber', 'AccountDescription']`,
     sorted by description.

   Each pipeline filters out blanks (`->filter()` / `filled(...)`) before deriving.

6. **Apply categorical filters in memory** against `$all` → `$rows`, each guarded by presence:
   `cluster`, `institution`, `responsibility`, `department`, `account`. (Filtering is on the
   loaded collection, not re-querying.)

7. **Compute stats** from the filtered `$rows`:
   ```php
   $stats = [
       'total'           => $rows->count(),
       'totalAllocation' => (float) $rows->sum(fn ($r) => (float) $r->TotalAllocation),
   ];
   ```

8. **Sort and paginate in memory** with a manual `LengthAwarePaginator`:
   - Multi-key sort: `FinancialYear`, `ClusterName`, `InstitutionName`, `DepartmentName`,
     `AccountNumber` (all ascending).
   - Use `LengthAwarePaginator::resolveCurrentPage()`, slice with `forPage($page, self::PER_PAGE)`,
     and pass `['path' => $request->url(), 'query' => $request->query()]` so links keep filters.

9. **Error handling** — wrap the whole flow in `try { … } catch (\Throwable $e)`. On failure
   (SQL Server / linked-server outage):
   - `Log::error(...)` with username, filters, and the exception.
   - `session()->flash('warning', 'Could not connect to the financial data source. Please try again later.')`.
   - Render the page with **empty** datasets (empty paginator, empty arrays, zeroed stats) and a
     sane `activeFiscalYear`/`currentFiscalYear` so the page still renders. **Never expose the
     connection error to the frontend.**

   > Note: this view intentionally catches `\Throwable` because it is the SQL Server boundary
   > (per the SQL Server rules in `CLAUDE.md`). This is the read-only-chart exception to the
   > general controller rule of letting unexpected exceptions bubble.

### Inertia props returned

```php
return Inertia::render('Budget/All Budget Allocations', [
    'allocations'       => $allocations,        // LengthAwarePaginator (data + links + meta)
    'clusters'          => $clusters,           // string[]
    'institutions'      => $institutions,       // [{ ClusterName, InstitutionName }]
    'responsibilities'  => $responsibilities,   // string[]
    'departments'       => $departments,        // string[]
    'accounts'          => $accounts,           // [{ AccountNumber, AccountDescription }]
    'years'             => $years,              // string[] (sorted)
    'stats'             => $stats,              // { total, totalAllocation }
    'filters'           => $filters,           // echo of applied filters incl. fy
    'activeFiscalYear'  => $activeFiscalYear,  // int
    'currentFiscalYear' => $currentFiscalYear, // int
    'fyNav'             => $fyNav,             // { prev, next }
]);
```

---

## 4. Vue page — `Pages/Budget/All Budget Allocations.vue`

`<script setup>` with `@inertiajs/vue3`. Props mirror the controller payload exactly (see prop
list above).

### Structure (top to bottom)

1. **Flash messages** — success (green), error (red), warning (amber) blocks bound to
   `$page.props.flash`.
2. **Page header** — title "Budget Allocations" + subtitle.
3. **Fiscal Year navigator (hero control):**
   - Prev / Next round buttons, disabled at the ends, driven by `fyNav`.
   - Large active-year numeral with an `fyIn` keyframe animation on change (`:key="activeYearStr"`).
   - Fiscal-year span label `Oct (FY-1) – Sep FY` and a pulsing "Current" badge when
     `isCurrentFiscalYear`.
   - **Year rail** — horizontally scrollable tablist of all `years`; active year highlighted in
     amber, current year ringed + dotted. Auto-scrolls the active year into view on mount.
   - **Keyboard nav** — `ArrowLeft`/`ArrowRight` move between FYs (ignored when focus is in a
     `SELECT`/`INPUT`/`TEXTAREA`). Listener added on mount, removed on unmount.
4. **KPI cards** (2-up): Total Records (`stats.total`) and Total Allocation
   (`stats.totalAllocation`, currency-formatted).
5. **Filter bar ("Refine"):** selects for Cluster, Institution, Responsibility, Department,
   Account. Shows an active-filter count badge and a "Clear all" button.
6. **Results table:** columns Year, Cluster, Institution, Responsibility, Department, Account
   (description), Account No., Total Allocation (right-aligned). Empty state row when no data.
7. **Pagination:** "Showing X to Y of Z", Inertia `<Link>` page links rendered from
   `allocations.links` with `preserve-scroll`.

### Key frontend behaviours

- **Local filter state** (`filters` ref) is seeded from props; `fy` comes from `activeFiscalYear`.
- **Cluster → Institution cascade:** `filteredInstitutions` narrows the institution list to the
  chosen cluster; changing cluster (`onClusterChange`) resets institution then re-applies.
- **`applyFilters()`** strips empty values and does `router.get(route('budget-allocations.index'), params, { preserveState: true, preserveScroll: true, replace: true })`.
- **`goToFy(fy)`** sets `filters.fy` and re-applies — fiscal year is navigated separately from the
  categorical filters and is excluded from `activeFilterCount` / `clearFilters` (clearing keeps
  the current FY).
- **Formatting helpers:**
  ```js
  const formatCurrency = v => new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' }).format(v ?? 0)
  const formatNumber   = v => Number(v ?? 0).toLocaleString('en-TT')
  ```

### Styling

Uses the project's design tokens (`text-tx-*`, `bg-surface*`, `border-line*`), a signature gold
accent on the FY navigator, FontAwesome icons, and dark-mode variants throughout. Scoped styles
hold the `fyIn` numeral animation and a slim year-rail scrollbar.

---

## Constraints (do not violate)

- **Read-only.** No create/edit/delete anywhere — model writes throw.
- **Always scope by `UserName`** via `forUser($username)`.
- **Use the `FinanceAutomationSystem` connection** (via the model) — never the default MySQL
  connection for these queries.
- **PascalCase columns** — reference view columns exactly.
- **Wrap the SQL Server access in try/catch** and degrade to empty data with a flashed warning;
  never surface connection errors.
- **Load the active FY once, derive in memory** — do not issue separate queries per dropdown or
  per filter.
- **Currency is TTD** with `en-TT` formatting.
- **Fiscal year rolls over in October** (`month >= 10 → year + 1`).
