# Plan — Monthly Expenditure page (view, controller, filters)

Mirrors the **Budget Allocations** stack (`BudgetAllocationController` + `Budget/All Budget
Allocations.vue`) for the new `MonthlyExpenditure` model, adapted to the monthly /
line-level shape of the data.

Status of prerequisites (already done): SQL view `dbo.MonthlyExpenditure` and the
read-only Eloquent model `App\Models\MonthlyExpenditure` (connection
`FinanceAutomationSystem`, scopes `forUser` / `forYear`, `NetChange` cast `decimal:2`)
exist. This plan covers only the controller, config, route, and Vue page.

---

## 1. Decisions locked in (from review)

| Aspect | Choice |
|---|---|
| **Filters** | FY (hero navigator) + Cluster, Institution (cascade), Responsibility, Account, **Month/Period**, **Expenditure category (MainGroup)** |
| **Table grain** | **Raw line rows** — one row per account × month × report line |
| **KPI cards** | **Total Net Expenditure** (Σ NetChange), **Highest Net Spend Month**, **Top Net Spend Category** — labelled "net" because `NetChange` is netted of correcting entries |

Dropped vs Budget: **Department** (not exposed by the view). Renamed: `ResponsibilityName`
→ **`Responsibility`**. Money column: `TotalAllocation` → **`NetChange`** (⚠ can be
negative — correcting entries).

---

## 2. Column mapping (Budget → MonthlyExpenditure)

| Budget Allocations | Monthly Expenditure | Notes |
|---|---|---|
| `FinancialYear` | `FinancialYear` | same — drives FY navigator |
| `ClusterName` | `ClusterName` | filter + column |
| `InstitutionName` | `InstitutionName` | filter (cascade) + column |
| `ResponsibilityName` | `Responsibility` | **renamed** |
| `DepartmentName` | — | **removed** |
| `AccountNumber` / `AccountDescription` | same | filter + column |
| `TotalAllocation` | `NetChange` | **renamed**, may be negative |
| — | `PeriodID`, `TRXPeriod` | **new** — Month filter + column |
| — | `MainGroup`, `SubGroupA`, `SubGroupB` | **new** — category filter + column |
| — | `LineNumber`, `LineDescription` | **new** — shown in row detail |
| — | `UserName` | used only by `forUser` scope, never displayed |

---

## 3. Controller — `app/Http/Controllers/MonthlyExpenditureController.php`

Structurally identical to `BudgetAllocationController::index()`. Read-only controller per
`.claude/context/controller-patterns.md` (no service, no validation block, no try/catch
around writes — but **keep** the SQL-Server try/catch + graceful empty fallback).

### 3.1 Inputs
```php
$username = $request->user()->username;
$filters  = $request->only(
    'cluster', 'institution', 'responsibility', 'account', 'period', 'group', 'fy'
);
$base = fn () => MonthlyExpenditure::forUser($username);
```
- `period` = **PeriodID** (1–12, stable sort key); label shown is `TRXPeriod`.
- `group`  = **MainGroup** value.

### 3.2 Fiscal year (unchanged from Budget)
- `years` cached `monthly-expenditure:years:{username}` → distinct `FinancialYear`.
- Resolve active FY via `ResolvesFiscalYear` (`currentFiscalYear`, `resolveFiscalYear`,
  `fiscalYearNav`). `$filters['fy'] = $activeFiscalYear`.

### 3.3 Filter option lists (cached on user+FY)
> ⚠ Read cache settings from the **new** config, not budget's: `Cache::store(config(
> 'expenditure.cache.store'))` and `config('expenditure.cache.minutes') * 60`. Since this
> file is cloned from `BudgetAllocationController`, leaving `config('budget...')` in place is
> an easy miss — and all cache keys must use the `monthly-expenditure:` prefix so the two
> features never collide on the shared `file` store.

Cache key `monthly-expenditure:options:{username}:{activeFiscalYear}`. Same `$fyBase()`
helper (base scoped to active FY). Lists:
- `clusters`        — distinct `ClusterName`
- `institutions`    — distinct `ClusterName`+`InstitutionName` (keyed `cluster|institution`
  so the client-side cascade survives institutions shared across clusters)
- `responsibilities`— distinct `Responsibility`
- `accounts`        — distinct `AccountNumber`+`AccountDescription` (unique by number)
- `months`          — distinct `PeriodID`+`TRXPeriod`, **ordered by `PeriodID`**, unique by
  `PeriodID` → `[{ PeriodID, TRXPeriod }]`
- `mainGroups`      — distinct `MainGroup`, ordered, filtered non-null

### 3.4 Validated filtered query
Same pattern as Budget: only apply a selection if it is a valid option in the active FY
(guards against stale filters after an FY switch). `tap()` to set the echoed filter value
and add the `where` in one expression.
```php
$query = $fyBase();
$filters['cluster']        = … in_array($v, $clusters) … where('ClusterName', $v)
$filters['institution']    = … array_column($institutions,'InstitutionName') … where('InstitutionName', $v)
$filters['responsibility'] = … in_array($v, $responsibilities) … where('Responsibility', $v)
$filters['account']        = … array_column($accounts,'AccountNumber') … where('AccountNumber', $v)
$filters['period']         = … in_array((int)$v, array_column($months,'PeriodID')) … where('PeriodID', (int)$v)
$filters['group']          = … in_array($v, $mainGroups) … where('MainGroup', $v)
```

### 3.5 Stats (over the full filtered set, before pagination)
Not cached (depends on live filters). **Two important fixes over the naïve version:**

1. **Aggregate queries return a *model with raw attributes*, not `{label, amount}`.** A
   `->selectRaw('SUM(NetChange) AS total')->groupBy(...)->first()` yields a `MonthlyExpenditure`
   instance exposing `->TRXPeriod` / `->MainGroup` / `->total` (and `total` is **uncast** →
   comes back as a *string* from SQL Server; only `NetChange` itself carries the `decimal:2`
   cast). The controller must **explicitly map** to the `{label, amount}` shape the Vue
   consumes and cast `amount` to float. Do not pass the raw model.
2. **Minimise full scans of an expensive view.** The naïve version fires 4 stat queries
   (count, sum, month group-by, category group-by) *plus* paginate's own count+select — 6
   scans of a linked-server-backed view per request. Collapse them:
   - **Drop `stats.total`** entirely — the paginator already returns the row count as
     `rows.total`; the Vue reads that. (One fewer scan, removes dead data.)
   - **Derive `totalExpenditure` and `highestMonth` from one monthly group-by** (≤12 rows):
     sum the group totals in PHP for the grand total, argmax for the highest month.
   - `topCategory` stays a single top-1 grouped query.

```php
// Q1 — monthly breakdown (≤12 rows): powers BOTH total and highest month.
$byMonth = (clone $query)
    ->select('PeriodID', 'TRXPeriod')
    ->selectRaw('SUM(NetChange) AS total')
    ->groupBy('PeriodID', 'TRXPeriod')
    ->get();

$totalExpenditure = (float) $byMonth->sum(fn ($m) => (float) $m->total);

$top = $byMonth->sortByDesc(fn ($m) => (float) $m->total)->first();
$highestMonth = [
    'label'  => $top?->TRXPeriod,
    'amount' => (float) ($top?->total ?? 0),
];

// Q2 — top category (single row): Σ NetChange by MainGroup, largest first.
$cat = (clone $query)
    ->select('MainGroup')
    ->selectRaw('SUM(NetChange) AS total')
    ->groupBy('MainGroup')
    ->orderByDesc('total')
    ->first();
$topCategory = [
    'label'  => $cat?->MainGroup,
    'amount' => (float) ($cat?->total ?? 0),
];

$stats = [
    'totalExpenditure' => $totalExpenditure,
    'highestMonth'     => $highestMonth,   // { label, amount }
    'topCategory'      => $topCategory,     // { label, amount }
];
```
Net live scans per request: **Q1 + Q2 + paginate(count+select) = 4** (down from 6).
> Note: with negative corrections possible, "highest" = greatest **summed (net)** spend; a
> month/category that nets negative simply ranks low. Because the metric is netted, the
> cards are labelled **Total Net Expenditure / Highest Net Spend Month / Top Net Spend
> Category** so the UI never implies gross expenditure.
> ⚠ A row with a **NULL `MainGroup`** forms its own group in Q2 (label `null`, rendered
> "—"). Acceptable; the dropdown's `mainGroups` list already filters nulls out.

### 3.6 Paginated results (raw rows)
```php
$rows = $query
    ->orderBy('PeriodID')
    ->orderBy('ClusterName')->orderBy('InstitutionName')
    ->orderBy('Responsibility')->orderBy('AccountNumber')
    ->orderBy('LineNumber')
    ->paginate(25)->withQueryString();
```

### 3.7 Render + failure fallback
`Inertia::render('Expenditure/Monthly Expenditure', [...])` with props:
`rows, clusters, institutions, responsibilities, accounts, months, mainGroups, years,
stats, filters, activeFiscalYear, currentFiscalYear, fyNav`.

On `\Throwable` (SQL Server down): flash `warning`, then return **every prop** — the Vue
declares props without defaults, so a missing `months`/`mainGroups`/etc. makes its `v-for`
iterate `undefined` and throw. The catch block must pass:
```php
return Inertia::render('Expenditure/Monthly Expenditure', [
    'rows' => new LengthAwarePaginator([], 0, 25, 1, [
        'path' => $request->url(), 'query' => $request->query(),
    ]),
    'clusters' => [], 'institutions' => [], 'responsibilities' => [],
    'accounts' => [], 'months' => [], 'mainGroups' => [],            // ← all six lists
    'years' => [],
    'stats' => [                                                     // matches §3.5 shape
        'totalExpenditure' => 0,
        'highestMonth' => ['label' => null, 'amount' => 0],
        'topCategory'  => ['label' => null, 'amount' => 0],
    ],
    'filters' => $filters,
    'activeFiscalYear'  => $filters['fy'] ?? $this->currentFiscalYear(),
    'currentFiscalYear' => $this->currentFiscalYear(),
    'fyNav' => ['prev' => null, 'next' => null],
]);
```
The success `stats` payload must use the **same keys** (no `total`).

---

## 4. Config — filter cache

**Decided: A — new file `config/expenditure.php`** mirroring `config/budget.php`, env
`MONTHLY_EXPENDITURE_CACHE_MINUTES` (default 10), store `file`. Monthly expenditure has a
heavier query cost and different option lists, so it should be independently tunable rather
than coupled to budget's TTL/store. `php artisan cache:clear file` (already in CLAUDE.md)
clears both, since both use the `file` store.

---

## 5. Route — `routes/web.php`

Add inside the existing `['auth','active.user']` group:
```php
Route::get('/monthly-expenditure', [MonthlyExpenditureController::class, 'index'])
    ->name('monthly-expenditure.index');
```
Import `use App\Http\Controllers\MonthlyExpenditureController;`.

---

## 6. Vue page — `resources/js/Pages/Expenditure/Monthly Expenditure.vue`

Clone `Budget/All Budget Allocations.vue`; reuse the **entire** FY hero navigator, year
rail, keyboard nav (←/→), loading-coin overlay, pagination, flash blocks, and styles
verbatim. Changes:

### 6.1 Props
`rows` (was `allocations`), `clusters, institutions, responsibilities, accounts, months,
mainGroups, years, stats, filters, activeFiscalYear, currentFiscalYear, fyNav`.
> ⚠ The cloned template references `allocations.*` in ~8 spots (table `v-for`, empty-state
> `colspan`, pagination `from/to/total/last_page/links`). **Rename every `allocations` →
> `rows`** or the page renders blank/throws. Also update the empty-state `colspan` to the new
> column count (8).

### 6.2 Filter state
```js
filters = { cluster, institution, responsibility, account, period, group,
            fy: String(activeFiscalYear) }
```
- **`period` must be a string both ways.** `PeriodID` is numeric, but a `<select>` value is
  always a string. Initialise `period: props.filters.period != null ? String(props.filters.period) : ''`
  and use `:value="String(m.PeriodID)"` on the option, or the echoed-back filter won't
  re-select the active month after a reload. (`fy` already uses this `String(...)` pattern.)
- Keep `onClusterChange` (resets institution) + `filteredInstitutions` cascade — unchanged.
- `activeFilterCount` counts `['cluster','institution','responsibility','account','period','group']`.
- `clearFilters` resets all except `fy`.
- `applyFilters` → `router.get(route('monthly-expenditure.index'), …)`.
- Loading-event URL guard matches `'monthly-expenditure'`.

### 6.3 Filter bar (grid)
Cluster · Institution (cascade) · Responsibility · Account · **Month** · **Category**.
- Month `<select>`: `<option v-for="m in months" :value="String(m.PeriodID)">{{ m.TRXPeriod }}</option>`
  (string value — see §6.2). Options arrive already ordered by `PeriodID` from the controller.
- Category `<select>`: options from `mainGroups`.
- (Account option label keeps `"{{ AccountDescription }} ({{ AccountNumber }})"`.)
- Grid is now **6 selects** (was 5). Confirm the `lg:grid-cols-*` layout still balances, or
  drop to a 3×2 grid.

### 6.4 KPI cards (three)
- **Total Net Expenditure** — `formatCurrency(stats.totalExpenditure)` (coins icon, gold);
  sub-label "Net of corrections".
- **Highest Net Spend Month** — big value `formatCurrency(stats.highestMonth?.amount)`,
  sub-label `stats.highestMonth?.label` (e.g. `OCT, 25`); calendar icon.
- **Top Net Spend Category** — big value `formatCurrency(stats.topCategory?.amount)`,
  sub-label truncated `stats.topCategory?.label` (e.g. `MEDICAL SUPPLIES`); tag/layer icon.
- Apply the negative treatment (§6.5) to every card value — a netted total can be negative.
- ⚠ Budget formatted its money cards via `formatNumber(Number(x).toFixed(2))` with a separate
  "TTD" label, **not** `formatCurrency`. Here we switch the cards to `formatCurrency` (§6.5)
  so negatives show parentheses/red consistently — drop the standalone "TTD" sub-labels to
  avoid a doubled currency marker.

### 6.5 Negative `NetChange` display (accounting style)
`NetChange` includes correcting entries and can be negative, so reversals must be easy to
spot. Add a helper + conditional class, used in both the table cell and the KPI values:
```js
// Accounting style: negatives in parentheses, e.g. ($1,234.56)
const formatCurrency = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' })
        .format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}
const isNegative = (value) => Number(value ?? 0) < 0
```
- Negative values: red text (`text-red-600 dark:text-red-400`) + parentheses.
- Positive/zero: default text colour.
- Apply `:class="{ 'text-red-600 dark:text-red-400': isNegative(row.NetChange) }"` on the
  Net Change `<td>` and on each KPI value that can go negative.
> Note: `row.NetChange` arrives as a **string** (the model's `decimal:2` cast), so always
> wrap in `Number(...)` before comparing/formatting — the helpers above already do.

### 6.6 Results table columns
`Year · Month (TRXPeriod) · Cluster · Institution · Responsibility · Account · Category ·
Net Change (right)` — **8 columns** (set the empty-state `colspan="8"`).
- **Account** cell: `AccountDescription` as primary text, mono `AccountNumber` muted below.
- **Category** cell: `MainGroup` as primary text; muted secondary line below showing
  `SubGroupA › SubGroupB` (skip the arrow/segment when null), with `LineDescription` on the
  cell `title` (tooltip). This keeps the sub-group/line detail available **without** adding
  full columns that would over-widen the table.
- **Net Change** cell: right-aligned, accounting format + red-on-negative per §6.5.
- Empty-state + pagination identical to Budget (update copy: "No expenditure found",
  "Loading expenditure…").

---

## 7. Navigation (optional)

`ASideBar.vue` currently uses placeholder routes and does not list Budget Allocations, so
there is no established nav slot. Out of scope unless desired; if so, add an item pointing
to `route('monthly-expenditure.index')`.

---

## 8. Files

**Create**
- `app/Http/Controllers/MonthlyExpenditureController.php`
- `config/expenditure.php`
- `resources/js/Pages/Expenditure/Monthly Expenditure.vue`

**Modify**
- `routes/web.php` (route + import)
- *(optional)* `.env` / `.env.example` (`MONTHLY_EXPENDITURE_CACHE_MINUTES=10`)

**Reuse unchanged**
- `app/Models/MonthlyExpenditure.php`, `app/Concerns/ResolvesFiscalYear.php`, the SQL view.

---

## 9. Verification

1. **Automated test — implement the page first, test second (and only if cheap).**
   Verified state of `tests/`: there is **no** budget-allocations test, and the existing
   feature tests are largely **stale Breeze scaffolding** — `ProfileTest` exercises
   `PATCH`/`DELETE /profile` and account deletion (all removed per CLAUDE.md), and the auth
   suite covers registration/password-reset routes that don't exist. So there is **no clean
   pattern to clone**, and these tests may already fail. A real `MonthlyExpenditureControllerTest`
   is non-trivial because: (a) the model uses the `FinanceAutomationSystem` SQL Server
   connection — there is no such view in the test MySQL/sqlite DB, so the query must be faked
   (mock the model/connection or bind a fake), and (b) the route sits behind `active.user`,
   which calls SQL Server during reverification. Recommendation: ship the controller + page,
   and add a test **only** if we first stand up a reusable harness for faking the SQL Server
   connection — not by copying ProfileTest. Treat the manual checks below as the primary
   verification for now.
2. Manual: `composer dev`, hit `/monthly-expenditure`, exercise FY nav (←/→), each filter,
   the cluster→institution cascade, a single-month drill-down, and pagination. **Specifically
   confirm:** (a) after selecting a Month and reloading, the Month select still shows the
   chosen month (the string round-trip, §6.2); (b) a known-negative `NetChange` row renders
   red in parentheses; (c) the page renders when SQL Server is unreachable (warning flash +
   empty table, no Vue console error from a missing prop).
3. Confirm stats reconcile: `totalExpenditure` == Σ of all rows' NetChange for the filter
   set; `highestMonth`/`topCategory` match a manual group-by.
4. `php artisan cache:clear file` after schema/data changes to drop stale dropdown lists.

---

## 10. Resolved decisions (the six questions)

All six are now decided and folded into the sections above:

1. **Config** — ✅ New `config/expenditure.php`, env `MONTHLY_EXPENDITURE_CACHE_MINUTES=10`,
   `file` store (independently tunable from budget). See §4.
2. **Category cascade** — ✅ **MainGroup only** for now. No MainGroup→SubGroupA→SubGroupB
   cascading selects — avoids UI/controller complexity until users need that depth. See §6.3.
3. **Sub-group / line detail in the table** — ✅ MainGroup is the visible category; show
   `SubGroupA › SubGroupB` as muted secondary text and `LineDescription` as a tooltip — not
   as separate full columns (keeps the row from over-widening). See §6.5.
4. **Page size** — ✅ **25** (matches Budget; raw monthly rows are heavier, so don't raise it).
5. **Negative NetChange** — ✅ **Accounting style**: parentheses + red for negatives, applied
   in the table cell and KPI values. See §6.6.
6. **Tests** — ✅ Verified: no budget test exists, and existing tests are stale Breeze
   scaffolding (not a clean pattern). Implement first; add a test only after a SQL-Server-fake
   harness exists. See §9.1.

### Extra correctness note (adopted)
Because `NetChange` is **netted of corrections**, the KPI cards are labelled **Total Net
Expenditure / Highest Net Spend Month / Top Net Spend Category** rather than implying gross
expenditure. Applied in §1, §3.5, §6.4.

### Remaining nits (non-blocking — sensible defaults chosen, flag if you disagree)
- Card title wording: using "Total Net Expenditure" with sub-label "Net of corrections". If
  you'd rather keep the shorter "Total Expenditure" title, only the label text changes.
- Tooltip choice: `LineDescription` on the Category cell `title`. Could instead tooltip the
  full `SubGroupA / SubGroupB / LineDescription` chain.

---

## 11. Risk review — weakpoints found in deep analysis

Resolved in-plan (were bugs or omissions in the first draft):

| # | Weakpoint | Severity | Fix | §|
|---|---|---|---|---|
| 1 | Stat queries return an Eloquent **model** (`.TRXPeriod`/`.total`), not the `{label,amount}` the Vue reads; `total` is an **uncast string**. | **Bug** | Explicit map + `(float)` cast. | 3.5 |
| 2 | 6 full scans of an expensive linked-server view per request. | Perf | Drop `stats.total` (use paginator count); fold total+highestMonth into one monthly group-by → **4 scans**. | 3.5 |
| 3 | SQL-down catch passed "empty arrays" but not `months`/`mainGroups`; Vue props have no defaults → `v-for` on `undefined` throws. | **Bug** | Catch enumerates all 6 lists + stats shape. | 3.7 |
| 4 | Cloned controller could keep reading `config('budget…')` and budget cache keys. | Bug | Pin to `config('expenditure…')` + `monthly-expenditure:` key prefix. | 3.3 |
| 5 | `period` numeric vs string-typed `<select>` value → active month wouldn't re-select on reload. | Bug | `String()` both ends. | 6.2/6.3 |
| 6 | Cloned template still references `allocations.*` (~8 spots) + wrong `colspan`. | Bug | Rename all → `rows`; `colspan="8"`. | 6.1/6.6 |
| 7 | Doc had `§6.6` before `§6.5`; table referenced a not-yet-defined section. | Polish | Reordered: 6.5 = negatives, 6.6 = table. | 6.5/6.6 |
| 8 | KPI cards inherited Budget's `formatNumber + "TTD"` pattern, doubling the currency marker once we switch to `formatCurrency`. | Polish | Drop standalone "TTD" sub-labels on cards. | 6.4 |

Accepted residual risks (not fixed — flagged for awareness):

- **Security depends entirely on the `forUser` scope.** The view returns **all users'** rows
  (the per-user filter is no longer baked into the SQL). Every query path here goes through
  `$base = MonthlyExpenditure::forUser($username)`, so this is satisfied — but any future
  query that forgets `forUser` leaks cross-user data. Worth a code-review checklist item and,
  ideally, a global scope on the model later.
- **View cost.** Even at 4 scans, each hits the linked-server-backed view. The 10-min option
  cache covers dropdowns, but the per-request filtered/stat/paginate queries are live. If the
  page feels slow in practice, the next lever is an app-side cache of the filtered result per
  `(user, FY, filter-hash)` — deferred until measured (consistent with the earlier staging
  discussion).
- **Stale dropdowns within the TTL.** A newly-posted month/category won't appear in the
  filters for up to 10 min. Matches Budget; acceptable.
