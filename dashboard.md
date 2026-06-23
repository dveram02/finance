# Plan — Dashboard live data (Budget Usage, YTD Expenditure, Budget vs Actual + all charts)

Wire the Dashboard's KPIs and all charts to **live** data. Today the budget total is live
(`vw_BudgetAllocation`), but every expenditure figure is a hardcoded placeholder inside
`DashboardController`. This plan replaces those placeholders with real `MonthlyExpenditure`
data for the active fiscal year, up to the current fiscal month.

Source of truth for expenditure = `App\Models\MonthlyExpenditure` (view
`dbo.MonthlyExpenditure`, connection `FinanceAutomationSystem`). The money column is
`NetChange` (`decimal:2`, **net of correcting entries — can be negative**). The fiscal
month is `PeriodID` (1 = Oct … 12 = Sep) with display label `TRXPeriod` (e.g. `OCT, 25`).

> Supersedes the previous dashboard.md (wiring the live budget total — already shipped in
> commit `5981392`). This plan is the next layer: live expenditure.

---

## 1. Decisions locked in (from two rounds of review)

| Aspect | Choice |
|---|---|
| **Scope** | Wire **all** dashboard data live: Budget Usage, YTD Expenditure, Budget vs Actual, Monthly Expenditure (bar), Expenditure by Category. No placeholder data remains. |
| **"Up to current date"** | Data is **fiscal-month grain** (no day-level date). "Up to current date" = **up to and including the current fiscal month**. Cutoff `PeriodID <= currentFiscalPeriod` for the current FY; a past FY shows all 12 months. |
| **Net vs gross** | **Net** — sum `NetChange` as-is (consistent with the Monthly Expenditure page). A net-negative month/category is possible and simply ranks low. |
| **Budget vs Actual shape** | **Cumulative burn-up**: flat `Annual Budget` line at the full total across **all 12 fiscal months** + an `Actual (cumulative)` line = running `SUM(NetChange)` through each month; **future months = `null`**. (Round 2 — supersedes the earlier "monthly actual, months-up-to-now" choice for *this* chart.) |
| **Monthly Expenditure (bar)** | Stays **non-cumulative**: per-month `SUM(NetChange)`, months up to now. Distinct purpose from the burn-up line, so the two no longer duplicate. |
| **Category chart** | **Replace the doughnut with a horizontal bar** (titled "Net Categories" — round 5) so negative net totals render correctly. (Round 2.) |

### What each requested metric means (precisely)
- **Budget Usage** = `ytdExpenditure / totalBudget` (as a %), **capped at 100 %** for display
  (an overspend reads as `100%`, not `118%`); the progress-bar fill matches. The exceeded
  amount is surfaced in TTD on the sub-label instead: when `ytdExpenditure > totalBudget` it
  shows the overage (`TTD 1,234.56 over budget`), otherwise `TTD X remaining`. Numerator is the
  **YTD prop**, never the chart sum. (A net-negative utilisation stays signed and is treated
  neutrally.)
- **YTD Expenditure** = `SUM(NetChange)` for the active FY where `PeriodID <= currentFiscalPeriod`.
  (Equals the final point of the cumulative Actual line — a useful built-in cross-check.)
- **Budget vs Actual** = burn-up (see table above).

### Round-2 corrections folded in (from the second review)
1. **Apples-to-oranges fixed** — flat annual budget vs *monthly* actual was visually skewed;
   replaced with cumulative actual vs annual budget (a burn-up). §3.4 / §4.5.
2. **Doughnut → horizontal bar** — a doughnut can't draw negative arcs; a horizontal bar can.
   §3.3 / §4.5.
3. **Duplicate `Other` bug fixed** — null `MainGroup` now maps to **`Unclassified`**
   (a real wedge), and overflow folds into **`Other`** — never two `Other`s. §3.3.
4. **No fake budget line** — when the budget source is unavailable, the `Annual Budget`
   dataset is **omitted** entirely rather than drawn flat at 0. §3.4 / §4.5.
5. *(Verification note)* The claim "Budget vs Actual axis was decided as 12 months earlier"
   in the second review was **incorrect** — the earlier decision was "months up to now," and
   it applied to a *monthly* actual line. Choosing the cumulative burn-up in round 2 is what
   moves this chart to a 12-month axis.

### Round-3 refinements (from the third review)
6. **No fake-zero actuals when expenditure is down** — distinguish "source unavailable"
   (blank the actual line, all `null`) from "genuinely no spend yet this FY" (cumulative 0).
   `budgetVsActualData()` now takes `$expenditureAvailable`. §3.4.
7. **Net YTD can be negative** → clamp the progress-bar width to `[0,100]` and use a neutral
   colour below 0 (the displayed % stays signed/honest). §4.2/4.3.
8. **Materiality sorting for categories** — select the top-N by **`abs(net)`** so a large
   *negative* correction can't be silently folded into `Other`; display the chosen set by
   signed value (positives top → negatives bottom). §3.3.
9. **Clearer labelling** — category card subtitle calls out corrections + what `Other` means;
   the burn-up card is retitled to avoid implying monthly budget phasing. §4.5.
10. **Focused unit tests** for the pure transforms (no SQL Server needed). §6a.

### Round-4 refinements (from the fourth review)
11. **Monthly bar pads missing months** — a zero-row month no longer drops off the axis; the
    bar spans `1..cutoff` with gaps filled at 0. §3.4.
12. **`latestPeriodLabel` = the current fiscal month**, sourced from `fiscalMonthLabels()[$cutoff]`
    (not the last row), so "through …" is correct even before the current month posts. §3.2.
13. **No-budget-rows ≠ zero budget** — `budgetTotal()` now returns `available => false` when
    the user has *no* budget rows (`$years` empty), instead of a misleading `TTD 0.00`. §3.6.
14. **Negative-YTD copy** — a net-negative YTD shows "Net credits exceed expenditure", not a
    nonsensical "more-than-budget remaining". §4.3.
15. **Pure transforms moved to a `DashboardDataTransforms` trait** — `cumulativeSeries`,
    `monthlyBarData`, `topCategories` no longer live in the fiscal-year trait. §2a.
16. **`Other` ordered with the rest** — the final category set (incl. `Other`) is sorted by
    signed value, so `Other` isn't stranded out of order. §3.3.

### Round-5 refinements (from the fifth review)
17. **Future-FY cutoff** — a displayed FY *after* the current one (possible when next year's
    budget is loaded early) now gets cutoff `0` (not the current period), via a centralised
    `resolveCutoff()` helper that also clamps to `0..12`. §2 / §3.1.
18. **Neutral "no budget" copy** — the Total Budget unavailable text no longer claims the
    source "could not be reached" (wrong when the source is up but the user simply has no
    budget rows). §3.6 / §4.3a.
19. **Category title doesn't overpromise "Top"** — since `Other` can sort high, the card is
    retitled "Net Categories" with an honest subtitle. §4.5.
20. **`ArcElement` removal caveat** — safe here (the doughnut is the only Arc chart in
    Dashboard.vue), noted explicitly. §4.5.

### Round-6 refinements (from the sixth review)
21. **Reconciliation is "to the cent"** — exact in real arithmetic (the view stores `NetChange`
    pre-rounded to 2dp), so any difference is float drift / the rounded `Other`; tests assert
    within `< 0.01`. §6 / §6a.
22. **Future-FY empty state** — pass `expenditureWindowStarted = ($cutoff > 0)` so a not-yet-
    started FY shows "Fiscal year has not started" instead of a blank chart. §3.1 / §4.5.
23. **Category bar density** — truncate long y-axis labels (full name in tooltip) and give the
    card height for ~9 bars. §4.5.
24. **Empty-years cache note** — after a budget import the cached empty year-list persists till
    TTL; `php artisan cache:clear file` forces it. §3.6.

---

## 2. Fiscal helpers — `app/Concerns/ResolvesFiscalYear.php`

Two additions beside `currentFiscalYear()`. FY runs Oct→Sep, `PeriodID` 1 = Oct (confirmed
by the view's `CASE MONTH(TRXDate)` map).

```php
/**
 * The fiscal period (1–12) for today. PeriodID 1 = October … 12 = September,
 * matching dbo.MonthlyExpenditure. Oct–Dec → month-9; Jan–Sep → month+3.
 */
protected function currentFiscalPeriod(): int
{
    $month = now()->month;

    return $month >= 10 ? $month - 9 : $month + 3;
}

/**
 * The 12 fiscal-month labels for a year, matching the view's TRXPeriod format
 * ("OCT, 25"). PeriodID 1 = Oct of (FY-1) … 12 = Sep of FY. Generated (not read
 * from data) so the burn-up axis can show future months that have no rows yet.
 *
 * @return array<int,string>  keyed by PeriodID 1..12, in period order
 */
protected function fiscalMonthLabels(int $fiscalYear): array
{
    $map = [
        1  => ['OCT', $fiscalYear - 1], 2  => ['NOV', $fiscalYear - 1], 3  => ['DEC', $fiscalYear - 1],
        4  => ['JAN', $fiscalYear],     5  => ['FEB', $fiscalYear],     6  => ['MAR', $fiscalYear],
        7  => ['APR', $fiscalYear],     8  => ['MAY', $fiscalYear],     9  => ['JUN', $fiscalYear],
        10 => ['JUL', $fiscalYear],     11 => ['AUG', $fiscalYear],     12 => ['SEP', $fiscalYear],
    ];

    $labels = [];
    foreach ($map as $pid => [$abbr, $year]) {
        $labels[$pid] = $abbr.', '.substr((string) $year, -2);
    }

    return $labels;
}
```

> ⚠ This must match `dbo.MonthlyExpenditure.TRXPeriod` **exactly** (the view builds it from
> `MONTH/YEAR(TRXDate)` as `ABBR + ', ' + RIGHT(year,2)`). For FY2026, period 1 is Oct 2025 →
> `OCT, 25`; period 4 is Jan 2026 → `JAN, 26`. The `FY-1` for Oct–Dec is what produces the
> correct two-digit year. Verify against a real row when implementing.

> **Scope of this trait (round 4):** only the genuinely fiscal-year helpers live here —
> `currentFiscalYear`, `currentFiscalPeriod`, `fiscalMonthLabels`, and the existing
> resolve/nav methods. The dashboard's running-total / padding / category transforms moved to
> a separate `DashboardDataTransforms` trait (§2a) so this trait isn't a grab-bag.

Cutoff for a displayed FY — a small, testable helper (round 5) covering all three relations
to today and clamping defensively so the transforms can trust `0..12`:
```php
/**
 * The last fiscal period to include for a displayed FY:
 *   past FY    → 12 (complete year)
 *   current FY → current fiscal period (months elapsed so far)
 *   future FY  → 0  (not started — nothing elapsed)
 */
protected function resolveCutoff(int $fiscalYear): int
{
    $current = $this->currentFiscalYear();

    if ($fiscalYear < $current) {
        return 12;
    }
    if ($fiscalYear > $current) {
        return 0;
    }

    return max(0, min(12, $this->currentFiscalPeriod()));
}
```
> The Dashboard has **no FY navigator** — it renders the FY `budgetTotal()` resolves. Normally
> that's the current FY, so `$cutoff` is `currentFiscalPeriod()`. The `past FY → 12` branch
> applies when the current FY has no budget rows and the dashboard falls back to a prior year;
> the `future FY → 0` branch applies in the rarer case where only a *later* year has budget
> rows (e.g. next year's budget loaded early) — without it, a future FY would render a fake
> zero burn-up for months that haven't happened.

---

## 2a. Dashboard transforms trait — `app/Concerns/DashboardDataTransforms.php`

The dashboard's **pure** data shaping (no DB, no dates beyond the passed-in FY/cutoff) lives
here so it can be unit-tested in isolation (§6a) and kept out of both the controller body and
the fiscal-year trait. `DashboardController` uses both traits; a test double can `use` both
too (the monthly-bar padding calls `fiscalMonthLabels()`).

> Both `monthlyBarData()` and `cumulativeSeries()` assume `$cutoff` is in `0..12` (guaranteed
> by `resolveCutoff()`, §2). At `$cutoff = 0` (a future FY) they naturally return an empty bar
> / all-`null` cumulative — the loops simply don't iterate / mark every period future.

```php
namespace App\Concerns;

trait DashboardDataTransforms
{
    /**
     * Non-cumulative per-month series, padded across periods 1..$cutoff so a
     * month with no rows still shows a 0 bar (keeps the x-axis uniform).
     *
     * @param  array<int,array{PeriodID:int,TRXPeriod:string,total:float}>  $periodTotals
     */
    protected function monthlyBarData(int $fiscalYear, int $cutoff, array $periodTotals): array
    {
        $labels = $this->fiscalMonthLabels($fiscalYear);   // from ResolvesFiscalYear

        $byPid = [];
        foreach ($periodTotals as $row) {
            $byPid[$row['PeriodID']] = $row['total'];
        }

        $outLabels = [];
        $data      = [];
        for ($pid = 1; $pid <= $cutoff; $pid++) {
            $outLabels[] = $labels[$pid];
            $data[]      = round($byPid[$pid] ?? 0.0, 2);
        }

        return [
            'labels'   => $outLabels,
            'datasets' => [['label' => 'Expenditure (TTD)', 'data' => $data]],
        ];
    }

    /**
     * 12-element cumulative running total in PeriodID order. Months 1..$cutoff
     * carry the running sum (missing months cumulate as 0); months beyond $cutoff
     * are null (future — leaves a gap so the burn-up line ends at the cutoff).
     *
     * @param  array<int,array{PeriodID:int,total:float}>  $periodTotals
     * @return array<int,float|null>
     */
    protected function cumulativeSeries(int $cutoff, array $periodTotals): array
    {
        $byPid = [];
        foreach ($periodTotals as $row) {
            $byPid[$row['PeriodID']] = $row['total'];
        }

        $series  = [];
        $running = 0.0;
        for ($pid = 1; $pid <= 12; $pid++) {
            if ($pid <= $cutoff) {
                $running += $byPid[$pid] ?? 0.0;
                $series[] = round($running, 2);
            } else {
                $series[] = null;
            }
        }

        return $series;
    }

    /**
     * Top categories for the horizontal bar. Selects by materiality (|net|) so a
     * large negative correction isn't buried in Other; folds the remainder into a
     * single Other; then sorts the whole set (incl. Other) by signed value so the
     * bar reads cleanly top→bottom. null/blank MainGroup → 'Unclassified'.
     */
    protected function topCategories($rows, int $limit): array
    {
        $byLabel = $rows
            ->groupBy(fn ($r) => $r->MainGroup ?: 'Unclassified')
            ->map(fn ($g) => (float) $g->sum(fn ($r) => (float) $r->total));

        $top  = $byLabel->sortByDesc(fn ($v) => abs($v))->take($limit);
        $rest = (float) $byLabel->diffKeys($top)->sum();

        $final = $top->all();                       // [label => value]
        if ($byLabel->count() > $limit) {
            $final['Other'] = round($rest, 2);
        }

        // Order the whole set (Other included) by signed value for a clean bar.
        arsort($final);   // value DESC, preserves keys

        return [
            'labels' => array_keys($final),
            'data'   => array_values($final),
        ];
    }
}
```
> `arsort()` orders `Other` among the real categories by its signed value (round-4 fix). Sum
> of all returned bars still equals the YTD net total — reconciliation holds (`Other` =
> `diffKeys` remainder). `$limit = 8` is a readable horizontal-bar height.

---

## 3. Controller — `app/Http/Controllers/DashboardController.php`

### 3.1 `index()` — resolve FY + cutoff once, feed budget and expenditure

```php
public function index(Request $request): Response
{
    $username = $request->user()->username;

    ['fiscalYear' => $fiscalYear, 'totalBudget' => $totalBudget, 'available' => $budgetAvailable]
        = $this->budgetTotal($username);

    $cutoff = $this->resolveCutoff($fiscalYear);   // 0..12 (see §2)

    $expenditure = $this->expenditureData($username, $fiscalYear, $cutoff);

    return Inertia::render('Dashboard', [
        'userName'              => $request->user()->name,
        'fiscalYear'            => $fiscalYear,
        'totalBudget'           => $totalBudget,
        'budgetAvailable'       => $budgetAvailable,
        'expenditureAvailable'  => $expenditure['available'],
        'expenditureWindowStarted' => $cutoff > 0,   // false only for a future FY (§4.5 empty state)
        'ytdExpenditure'        => $expenditure['ytd'],
        'latestPeriodLabel'     => $expenditure['latestPeriodLabel'],   // e.g. "JUN, 26"
        'monthlyExpenditure'    => $this->monthlyBarData($fiscalYear, $cutoff, $expenditure['periodTotals']),
        'budgetVsActual'        => $this->budgetVsActualData(
            $totalBudget, $budgetAvailable, $expenditure['available'],
            $fiscalYear, $cutoff, $expenditure['periodTotals']
        ),
        'expenditureByCategory' => $expenditure['byCategory'],          // { labels, data } — horizontal bar
    ]);
}
```

### 3.2 `expenditureData(string $username, int $fiscalYear, int $cutoff): array`

Read-only, SQL-Server-backed → try/catch + graceful degrade with an `available` flag (mirror
`budgetTotal()`; never fake a zero into a "real" state). Cached on the dedicated expenditure
store (`config/expenditure.php`) — the dashboard has no per-request filters, so caching is
safe and spares the linked-server view on every load.

```php
private function expenditureData(string $username, int $fiscalYear, int $cutoff): array
{
    $cache = Cache::store(config('expenditure.cache.store'));
    $ttl   = config('expenditure.cache.minutes') * 60;

    try {
        // $cutoff is in the key so the cache rolls forward when the fiscal month
        // advances; stale keys expire on their own TTL.
        return $cache->remember(
            "dashboard:expenditure:{$username}:{$fiscalYear}:{$cutoff}",
            $ttl,
            function () use ($username, $fiscalYear, $cutoff) {
                $base = fn () => MonthlyExpenditure::forUser($username)
                    ->forYear((string) $fiscalYear)
                    ->where('PeriodID', '<=', $cutoff);

                // Q1 — per-month net (≤ cutoff rows): powers YTD, the bar chart,
                // and the cumulative Actual line.
                $byMonth = $base()
                    ->select('PeriodID', 'TRXPeriod')
                    ->selectRaw('SUM(NetChange) AS total')
                    ->groupBy('PeriodID', 'TRXPeriod')
                    ->orderBy('PeriodID')
                    ->get();

                // Q2 — net by category (MainGroup); negatives allowed (horizontal bar).
                $byCat = $base()
                    ->select('MainGroup')
                    ->selectRaw('SUM(NetChange) AS total')
                    ->groupBy('MainGroup')
                    ->orderByDesc('total')
                    ->get();

                $periodTotals = $byMonth->map(fn ($m) => [
                    'PeriodID'  => (int) $m->PeriodID,
                    'TRXPeriod' => $m->TRXPeriod,
                    'total'     => (float) $m->total,
                ])->all();

                return [
                    'available'         => true,
                    'ytd'               => (float) array_sum(array_column($periodTotals, 'total')),
                    // The CURRENT fiscal month (not the last row) — so "through JUN, 26"
                    // is correct even if the current month hasn't posted any rows yet.
                    'latestPeriodLabel' => $this->fiscalMonthLabels($fiscalYear)[$cutoff] ?? null,
                    'periodTotals'      => $periodTotals,           // raw per-month — bar + burn-up
                    'byCategory'        => $this->topCategories($byCat, 8),
                ];
            }
        );
    } catch (\Throwable $e) {
        Log::error('Dashboard expenditure query failed.', [
            'username' => $username, 'fy' => $fiscalYear, 'exception' => $e->getMessage(),
        ]);

        return [
            'available'         => false,
            'ytd'               => 0.0,
            'latestPeriodLabel' => null,
            'periodTotals'      => [],
            'byCategory'        => ['labels' => [], 'data' => []],
        ];
    }
}
```

> ⚠ `SUM(NetChange) AS total` is **uncast** (only `NetChange` carries `decimal:2`) → comes
> back a **string**. Every `->total` read is wrapped in `(float)` above. Don't pass raw models.
> ⚠ Use `config('expenditure.…')` (not `budget.…`). Both use the `file` store, so
> `php artisan cache:clear file` clears the new `dashboard:expenditure:*` keys too.
> Note: `remember()` doesn't cache when the closure throws and the `catch` is outside it, so a
> transient outage never poisons the cache (same guarantee as `budgetTotal()`).

### 3.3 Category + monthly transforms

`topCategories()` and `monthlyBarData()` live in the **`DashboardDataTransforms` trait (§2a)**,
not on the controller. `expenditureData()` calls `$this->topCategories($byCat, 8)`; `index()`
calls `$this->monthlyBarData($fiscalYear, $cutoff, ...)`. Key behaviours (full code in §2a):
- **Categories** — select top-N by `abs(net)` (materiality), fold the rest into `Other`, then
  `arsort()` the whole set so `Other` sits in signed-value order; null/blank `MainGroup` →
  `Unclassified`. `Other` = `diffKeys` remainder, so all bars sum to YTD (reconciles), though
  `Other` blends small positives and non-top items of either sign — the card says so (§4.5).
- **Monthly bar** — padded across periods `1..cutoff`; a month with no rows shows a 0 bar
  (uniform axis), rather than being dropped.

### 3.4 `budgetVsActualData()` (burn-up)

```php
// Burn-up: flat annual budget (all 12 months) + cumulative actual (null beyond cutoff).
private function budgetVsActualData(
    float $totalBudget, bool $budgetAvailable, bool $expenditureAvailable,
    int $fiscalYear, int $cutoff, array $periodTotals
): array {
    $labels = array_values($this->fiscalMonthLabels($fiscalYear));   // 12 labels, period order

    // Blank the actual line entirely when the source is down (all null) so it is
    // never mistaken for genuine zero spend. A real new FY with no rows yet still
    // shows a legitimate cumulative 0 because $expenditureAvailable is true.
    $actual = $expenditureAvailable
        ? $this->cumulativeSeries($cutoff, $periodTotals)   // DashboardDataTransforms (§2a)
        : array_fill(0, 12, null);

    $datasets = [];
    // No fake budget line when the budget source is down — omit the dataset entirely.
    if ($budgetAvailable) {
        $datasets[] = ['label' => 'Annual Budget', 'data' => array_fill(0, 12, $totalBudget)];
    }
    $datasets[] = ['label' => 'Actual (cumulative)', 'data' => $actual];

    return ['labels' => $labels, 'datasets' => $datasets];
}
```
> Both sources down → only an all-`null` Actual dataset (chart renders empty, no error).
> Budget down, expenditure up → cumulative Actual with no budget reference line.
> Budget up, expenditure down → flat budget line, blank (null) Actual.

### 3.5 Delete the placeholder methods
Remove `monthlyExpenditureData()` and `expenditureByCategoryData()`; the old
`budgetVsActualData(float $totalBudget)` is replaced by the 6-arg version above.

### 3.6 `budgetTotal()` — one fix: no rows ≠ zero budget

Today `budgetTotal()` resolves the FY and degrades to `available => false` on SQL failure,
and `expenditureData()` has its **own** try/catch, so the two sources are reported
independently. **One change (round 4):** when the user has **no budget rows at all**
(`$years->isEmpty()`), the query *succeeds* but `sum()` is 0 — currently returned as
`available => true, totalBudget => 0`, which renders a misleading `TTD 0.00` indistinguishable
from a genuine zero allocation. Treat "no rows" as unavailable:

```php
$years = collect($cache->remember(/* …distinct FinancialYear… */));

if ($years->isEmpty()) {
    // Query succeeded but this user has no budget data — not a real zero budget.
    return ['fiscalYear' => $currentFiscalYear, 'totalBudget' => 0.0, 'available' => false];
}
// …resolve active FY, sum TotalAllocation, return available => true as before…
```
> A year that *exists* but sums to 0 (a real zero allocation) still returns `available => true`
> — only the truly-empty case flips to `false`.
>
> ⚠ **Copy (round 5):** since `available => false` now covers *both* "source down" and "no
> budget rows," the Total Budget card's current sub-text ("Financial data source could not be
> reached") is inaccurate for the no-rows case. Switch it to a neutral message (§4.3a). If you
> later want to distinguish the two, return a tri-state `budgetStatus: 'available' |
> 'unavailable' | 'empty'` instead of the boolean and branch the copy on it.
>
> Cache caveat: the empty year-list is cached under `budget-allocations:years:{username}` (the
> key the Budget page also populates), so right after a **first** budget import the dashboard
> may keep showing "unavailable" until the TTL lapses. Acceptable at the 10-min TTL; run
> `php artisan cache:clear file` after an import to force it.

---

## 4. Frontend — `resources/js/Pages/Dashboard.vue`

### 4.1 Props
```js
const props = defineProps({
  userName: String,
  fiscalYear: Number,
  totalBudget: Number,
  budgetAvailable: { type: Boolean, default: true },
  expenditureAvailable: { type: Boolean, default: true },        // NEW
  expenditureWindowStarted: { type: Boolean, default: true },    // NEW (false → future FY)
  ytdExpenditure: Number,                                        // NEW
  latestPeriodLabel: String,                                     // NEW (sub-label)
  monthlyExpenditure: Object,
  budgetVsActual: Object,
  expenditureByCategory: Object,
})
```

### 4.2 KPI computeds — YTD from the prop (single source of truth)
```js
const totalExpenditure = computed(() => props.ytdExpenditure ?? 0)
const totalBudget      = computed(() => props.totalBudget ?? 0)
const variance         = computed(() => totalBudget.value - totalExpenditure.value)
const overBudget       = computed(() => totalBudget.value > 0 && totalExpenditure.value > totalBudget.value)
const overage          = computed(() => Math.max(0, totalExpenditure.value - totalBudget.value))

// Capped at 100% — an overspend reads as 100%, with the exceeded amount shown in
// TTD on the sub-label (overBudget / overage). Net YTD can be negative (corrections
// outweigh spend); that stays signed and is treated neutrally.
const budgetUtilization   = computed(() => {
  if (!totalBudget.value) return 0
  return Math.min(100, Math.round((totalExpenditure.value / totalBudget.value) * 100))
})
const utilizationBarWidth = computed(() => Math.max(0, budgetUtilization.value))

const utilizationColor = computed(() => {
  if (budgetUtilization.value < 0) return '#64748b'                       // neutral — net negative
  if (overBudget.value || budgetUtilization.value >= 90) return '#ef4444'
  if (budgetUtilization.value >= 75) return '#f59e0b'
  return '#10b981'
})
```

### 4.3 Budget Usage card
- The displayed % and the progress-bar fill both cap at 100% (`utilizationBarWidth`); the
  overspend is communicated via the sub-label's TTD overage, not a `>100%` number.
- Sub-label (first match wins — the negative branch sits **above** "remaining" so a net-credit
  YTD never reports more-than-the-full-budget as remaining):
  ```
  !budgetAvailable                 → "Awaiting budget data"
  !expenditureAvailable            → "Awaiting expenditure data"
  totalExpenditure < 0             → "Net credits exceed expenditure"
  overBudget                       → "TTD {formatAmount(overage)} over budget"
  else                             → "TTD {formatAmount(variance)} remaining"
  ```
- Gate the value/bar on `budgetAvailable && expenditureAvailable`; show the existing `—`
  treatment otherwise (usage needs both numerator and denominator).
- **Remove** the italic `Provisional — actuals are sample data` note — actuals are now live.

### 4.3a Total Budget card — neutral unavailable copy
The existing `budgetAvailable === false` branch reads "Budget unavailable" / "Financial data
source could not be reached." Since `false` now also means "user has no budget rows" (§3.6),
neutralise the sub-text so it's accurate either way:
```
heading : "Budget data unavailable"
sub-text: "No budget allocation could be loaded for this fiscal year."
```
(No logic change — copy only. Adopt a tri-state `budgetStatus` later if the two cases ever
need distinct wording.)

### 4.4 YTD Expenditure card
- Renders `formatAmount(totalExpenditure)` — now live.
- Sub-label: `FY {{ fiscalYear }}<span v-if="latestPeriodLabel"> · through {{ latestPeriodLabel }}</span>`.
- When `expenditureAvailable === false`, show an "Expenditure unavailable" treatment mirroring
  the Total Budget card's `budgetAvailable` branch.
- **Independent of budget**: if budget is down but expenditure is up, YTD still renders
  (the props are sourced separately).

### 4.5 Charts
**Monthly Expenditure (Bar)** — unchanged binding; receives the non-cumulative monthly
series, **padded across periods 1..cutoff** (a zero-row month shows a 0 bar, so the axis stays
uniform — round 4). Negative months draw a downward bar — correct.

**Budget vs Actual (Line)** — now burn-up. Changes:
- **Retitle the card** to avoid implying phased monthly budget: heading `Cumulative Spend vs
  Budget`, subtitle `Cumulative actual vs annual allocation (TTD)` (was "Budget vs Actual" /
  "Planned vs realised"). Avoids "Utilisation/Usage" so it doesn't collide with the Budget
  Usage KPI; "burn-up" elsewhere in this doc refers to the chart *type*, not the UI title.
- Build `lineData` **generically from `props.budgetVsActual.datasets`**, styling by label
  (`Annual Budget` → dashed grey; `Actual (cumulative)` → teal, `fill: true`). This way, when
  the budget dataset is omitted (source down), only the Actual line renders — no index-based
  `datasets[0]`/`[1]` assumptions.
- `null` future points create a gap; set `spanGaps: false` so the Actual line **ends at the
  current month** instead of bridging to nothing. The tooltip callback must skip `null`
  (`if (ctx.parsed.y == null) return ''`).
- Labels are the 12 generated `TRXPeriod` strings (`OCT, 25` … `SEP, 26`).

**Expenditure by Category (replace Doughnut → horizontal Bar):**
- **Retitle** heading `Net Categories`, subtitle `Top material categories + Other · net of
  corrections (TTD)`. Avoids overpromising "Top N" now that `Other` is sorted inline by value
  (round 5) and can rank high, while still signalling that `Other` blends the remainder.
- Remove the `Doughnut` import/usage and the `ArcElement` registration. **Safe here**: the
  doughnut is the *only* Arc-based chart in Dashboard.vue (the other two are Bar/Line) — but
  confirm no other pie/doughnut remains in this component before dropping `ArcElement`.
- Add `categoryBarData` + `categoryBarOptions` with `indexAxis: 'y'`, single dataset from
  `props.expenditureByCategory.{labels,data}`, palette reused from the old doughnut.
- Tooltip + x-axis ticks format as TTD; for a horizontal bar the value is `ctx.parsed.x`.
- Negative categories extend left of zero — the honest rendering this change is for. Consider
  a zero baseline grid line so the sign is obvious.
- **Label density** — `MainGroup` names can be long (e.g. "MEDICAL SUPPLIES AND DRUGS").
  Truncate the y-axis ticks (Chart.js `ticks.callback` → slice to ~24 chars + `…`) and keep the
  full name in the tooltip; give the card enough height for ~9 bars so none compress to an
  unreadable sliver.
- Swap `<Doughnut .../>` for `<Bar :data="categoryBarData" :options="categoryBarOptions" />`
  in chart card #2.

**Empty / not-started states (all charts):**
- `expenditureWindowStarted === false` (a future FY) → show "Fiscal year has not started" in
  each chart card instead of an empty axis. Distinct from `expenditureAvailable === false`
  (source down → "Expenditure data unavailable") and from an available-but-genuinely-empty
  current FY (renders a real 0 line/bar).

### 4.6 Currency helpers
`formatAmount` / `formatCurrency` already render negatives (`toLocaleString` emits `-`). No
accounting-parentheses styling requested for the dashboard. Leave as-is.

---

## 5. Files

**Create**
- `app/Concerns/DashboardDataTransforms.php` — `monthlyBarData()`, `cumulativeSeries()`,
  `topCategories()` (pure; §2a).

**Modify**
- `app/Http/Controllers/DashboardController.php` — `use ResolvesFiscalYear, DashboardDataTransforms;`
  + `use App\Models\MonthlyExpenditure;`; add `expenditureData()`; rewrite `budgetVsActualData()`
  (**6 args**, incl. `$expenditureAvailable`); add the `$years->isEmpty()` guard to `budgetTotal()`;
  delete `monthlyExpenditureData()` + `expenditureByCategoryData()`; extend `index()`.
- `app/Concerns/ResolvesFiscalYear.php` — add `currentFiscalPeriod()`, `fiscalMonthLabels()`,
  and `resolveCutoff()`.
- `resources/js/Pages/Dashboard.vue` — new props; reworked Budget Usage + YTD cards;
  generic burn-up line; doughnut → horizontal bar; remove "sample data" note.

**Reuse unchanged** — `app/Models/MonthlyExpenditure.php`, `config/expenditure.php`, the view.
**No new** routes, config, or migrations.

---

## 6. Verification

1. **Manual (primary).** `composer dev`, open `/`:
   - **YTD Expenditure** = `SUM(NetChange)` for the active FY, `PeriodID <= currentFiscalPeriod`
     (cross-check vs the Monthly Expenditure page, same FY, months up to now).
   - **Budget Usage** = `YTD / totalBudget`. Force an overspend and confirm `>100%`, full
     (non-overflowing) bar, red colour, `TTD … over budget`; confirm within-budget still says
     `TTD … remaining`.
   - **Budget vs Actual (burn-up)**: x-axis shows all 12 fiscal months (`OCT, 25` … `SEP, 26`);
     the Actual line rises cumulatively and **stops at the current month** (no line into future
     months); the dashed Annual Budget line is flat across all 12. The **final cumulative point
     equals the YTD KPI**.
   - **Monthly Expenditure (bar)**: per-month values padded across `1..cutoff` (a zero-row
     month shows a 0 bar, not a missing one); a net-negative month draws downward.
   - **Net Categories (horizontal bar)**: top 8 by materiality (`abs`) + `Other`; any negative
     category extends left of zero; `Unclassified` (not a second `Other`) holds null `MainGroup`.
2. **Reconciliation** (holds for *every* surface, since nothing is dropped) — equal **to the
   cent**: `YTD ≈ Σ(monthly bar) ≈ final cumulative point ≈ Σ(category bars incl. Other)`.
   It is exact in real arithmetic (the view stores `NetChange` pre-rounded to 2dp); any
   residual is float drift or the rounded `Other`, so compare with a `< 0.01` tolerance, never
   strict `==`.
3. **Resilience** — simulate SQL Server unreachable:
   - Budget down only → Total Budget "unavailable", Budget Usage "Awaiting budget data",
     Budget vs Actual renders the Actual line **without** a budget line, **YTD still shows**.
   - Expenditure down only → YTD/Budget Usage "unavailable", charts blank, no `NaN`/`Infinity%`,
     no Vue console error (props arrive empty).
4. `./vendor/bin/pint` on controller + trait; `npm run build` to confirm the Vue compiles.
5. `php artisan cache:clear file` after data changes to drop cached `dashboard:expenditure:*`.

> Reconciliation (verification 2) only holds when **expenditure is available**. When the
> source is down, all surfaces show their unavailable/blank state and there is nothing to
> reconcile.

## 6a. Focused unit tests (cheap — no SQL Server)

The money-shaping logic is **pure** and lives where it can be tested without the
`FinanceAutomationSystem` connection or the `active.user` SQL round-trip (the blockers noted
in `monthlyexp.md` §9). Test these directly; the live SQL query path stays manual.

Use `Illuminate\Support\Carbon::setTestNow()` for the date-dependent fiscal helpers. The
transforms are `protected` on the `DashboardDataTransforms` trait — exercise them via a tiny
test double that `use`s **both** `DashboardDataTransforms` and `ResolvesFiscalYear` (the
monthly-bar padding calls `fiscalMonthLabels()`).

| Target | Cases |
|---|---|
| `currentFiscalPeriod()` (ResolvesFiscalYear) | Oct → 1, Dec → 3, Jan → 4, Jun → 9, Sep → 12 (set `Carbon::setTestNow` per case). |
| `fiscalMonthLabels(2026)` (ResolvesFiscalYear) | period 1 = `OCT, 25`, period 4 = `JAN, 26`, period 12 = `SEP, 26` (the `FY-1` boundary). |
| `resolveCutoff($fy)` (ResolvesFiscalYear) | past FY → 12; current FY → `currentFiscalPeriod()`; future FY → 0; result always `0..12` (set `Carbon::setTestNow`). |
| `monthlyBarData(2026, $cutoff, …)` | labels span `1..cutoff`; a **missing** month yields a 0 bar (not dropped); labels match `fiscalMonthLabels`. |
| `cumulativeSeries($cutoff, …)` | running sum; a missing middle month cumulates flat; months `> cutoff` are `null`; a negative month dips the running total. |
| `topCategories($rows, $limit)` | null `MainGroup` → `Unclassified` (not a 2nd `Other`); a large **negative** outside top-N still surfaces via `abs` selection; `Σ(bars incl. Other) ≈ Σ(all rows)` within `< 0.01` (reconciliation — use a tolerance, not strict `==`); whole set incl. `Other` ordered by signed value. |

Because these moved to a dedicated trait (round 4), no controller subclass/reflection is
needed — the test double is the natural seam. (Still no full controller HTTP test: it needs
the SQL-Server-fake harness that doesn't exist yet — same conclusion as `monthlyexp.md` §9.)

---

## 7. Risk review

| # | Risk | Severity | Mitigation | § |
|---|---|---|---|---|
| 1 | `SUM(NetChange)` is uncast → string from SQL Server. | **Bug** | `(float)` every `->total`; YTD via `array_sum` of floats. | 3.2 |
| 2 | Over-budget % overflowing the track. | **Bug** | `budgetUtilization` capped at 100% (display + fill); overspend shown as a TTD overage on the sub-label, not a `>100%` number. | 4.2/4.3 |
| 3 | Division by zero (`totalBudget == 0`) → `Infinity%`/`NaN`. | **Bug** | `totalBudget ? … : 0`; gate the card on both availability flags. | 4.2/4.3 |
| 4 | `fiscalMonthLabels()` not matching the view's `TRXPeriod` → burn-up labels mismatch the data join. | **Bug** | Format mirrors the view (`ABBR + ', ' + RIGHT(year,2)`, Oct–Dec use `FY-1`); verify against a real row. | 2 |
| 5 | `null` future points bridging across the gap (line drawn into the future). | **Bug** | `spanGaps: false` + tooltip null-guard. | 4.5 |
| 6 | Omitted budget dataset breaking index-based `datasets[0]/[1]` in `lineData`. | **Bug** | Build `lineData` generically, styling by dataset **label**. | 4.5 |
| 7 | Duplicate `Other` wedges (null MainGroup + overflow both labelled `Other`). | **Bug** | null → `Unclassified`; aggregate by label; single `Other` overflow. | 2a/3.3 |
| 8 | Expenditure-down rendered as **fake zero** spend (cumulative 0 vs genuinely no data). | **Bug** | Blank the Actual line (all `null`) when `!expenditureAvailable`; a real empty FY still shows cumulative 0. | 3.4 |
| 9 | Net YTD negative → negative `%` and **negative bar width**. | **Bug** | Clamp `utilizationBarWidth` to `[0,100]`; neutral colour below 0; displayed % stays signed. | 4.2/4.3 |
| 10 | Material **negative** category buried in `Other` (net-DESC sort). | **Bug** | Select top-N by `abs(net)`; `Other` labelled as a net-of-remainder blend. | 3.3/4.5 |
| 11 | Cloned-from-budget cache reading `config('budget…')` / key collision. | Bug | Pin to `config('expenditure…')` + `dashboard:expenditure:` prefix. | 3.2 |
| 12 | Negative net month/category: downward bar, line dip, left-extending category bar. | Accepted | Intended — net reversals should be visible; horizontal bar renders negatives honestly. | 3.3/4.5 |
| 13 | Budget FY and expenditure FY both follow the budget-resolved year. | Accepted | `index()` resolves once and passes the FY + cutoff into `expenditureData`. See §8 for the edge. | 3.1 |
| 14 | Stale dashboard within the cache TTL. | Accepted | Matches Budget/Monthly pages; `cache:clear file` forces refresh. | 3.2 |
| 15 | **Cross-user leakage** depends entirely on `forUser`. | Watch | Every path goes through `MonthlyExpenditure::forUser($username)`; code-review checklist item. | 3.2 |
| 16 | Monthly bar **drops zero-row months** → non-uniform, misleading x-axis. | **Bug** | Pad `monthlyBarData` across `1..cutoff`; missing month → 0 bar. | 2a/3.3 |
| 17 | `latestPeriodLabel` from the **last row** understates the period when the current month hasn't posted. | **Bug** | Source it from `fiscalMonthLabels()[$cutoff]`. | 3.2 |
| 18 | **No budget rows** rendered as a real `TTD 0.00` (vs source down / genuine zero). | **Bug** | `$years->isEmpty()` → `available => false` in `budgetTotal()`. | 3.6 |
| 19 | `Other` appended last, out of the value-sorted order. | Polish | `arsort()` the final set incl. `Other`. | 2a/3.3 |
| 20 | **Future FY** displayed (next year's budget loaded early) → fake zero burn-up for un-elapsed months. | **Bug** | `resolveCutoff()` returns `0` for a future FY (empty bar, all-null cumulative); clamps `0..12`. | 2/3.1 |
| 21 | Unavailable-budget copy ("source could not be reached") wrong when source is up but no budget rows exist. | Polish | Neutral copy: "No budget allocation could be loaded…"; optional tri-state `budgetStatus`. | 3.6/4.3a |
| 22 | "Top Net Categories" title overpromises once `Other` sorts inline and can rank high. | Polish | Retitle "Net Categories" + honest subtitle. | 4.5 |
| 23 | Reconciliation asserted as strict `==` → fails on float drift / rounded `Other`. | Polish | Reconcile **to the cent**; tests use `< 0.01` tolerance. | 6/6a |
| 24 | Future FY renders blank but `available => true` → looks like missing data. | Polish | `expenditureWindowStarted` flag → "Fiscal year has not started" empty state. | 3.1/4.5 |
| 25 | Long `MainGroup` labels overflow / compress the category bar. | Polish | Truncate y-ticks (full name in tooltip); size the card for ~9 bars. | 4.5 |

---

## 8. Open / deferred (non-blocking)

- **FY resolution is budget-led.** If the **current** FY has expenditure but **no budget**
  rows, `budgetTotal()` falls back to the latest FY *with budget* and the dashboard would query
  expenditure for that older year — hiding current-FY expenditure. Accepted for now (the
  dashboard is budget-centric and this is an unlikely data state). If it becomes real, resolve
  the active FY from the **union** of budget + expenditure years. *(Round-2 reviewer's point —
  the independent-query fix already covers the common "budget down, expenditure up" case; this
  residual is only the rarer "budget never existed for this FY" case.)* **Mitigation already in
  place:** the active `fiscalYear` is shown on the YTD card sub-label, so any fallback to an
  older year is visible rather than silent; consider also surfacing it in the welcome header.
- **Monthly bar axis** — spans `1..cutoff` (months elapsed so far, gaps zero-filled), **not**
  the full 12. The bar shows monthly movement to date; the burn-up line shows the full-year
  horizon. Flag if you want the bar padded to all 12 months for visual symmetry with the line.
- **Category limit (8 + Other)** — sized for a readable horizontal bar; change the
  `topCategories($byCat, 8)` argument freely.
- **Day-level "up to current date"** — not possible; the view is monthly-grain. Requires a
  schema change to `dbo.MonthlyExpenditure` if ever needed.
- **Even budget spread** — the burn-up budget line is the flat annual total (the only budget
  figure available). If a phased/monthly budget is ever exposed, the line could ramp instead.
