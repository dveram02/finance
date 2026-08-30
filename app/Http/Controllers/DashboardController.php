<?php

namespace App\Http\Controllers;

use App\Concerns\DashboardDataTransforms;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\StreamsCsv;
use App\Concerns\VersionsLedgerCache;
use App\Models\BudgetAllocation;
use App\Models\MonthlyExpenditure;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;

class DashboardController extends Controller
{
    use DashboardDataTransforms;
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;

    // StreamsCsv directly, not ExportsReports: this page has no filters and no
    // row collection, so none of that trait's guards apply to it.
    use StreamsCsv;
    use VersionsLedgerCache;

    private const EXPORT_UNAVAILABLE = 'The financial data source is unavailable. Please try again later.';

    private const EXPORT_NO_ACCESS = 'Department access is not configured for your account, so there is nothing to export.';

    private const EXPORT_NOT_STARTED = 'This fiscal year has not started yet, so there is nothing to export.';

    public function index(Request $request): Response
    {
        $username = $request->user()->username;

        // Does this user map to any department at all? Without this the page
        // cannot tell "nothing is assigned to you" from "the source is down",
        // and the KPI cards claim an outage that is not happening.
        $hasAccess = $this->hasLedgerAccess($username);

        // The budget total drives the Total Budget KPI and the flat "Annual
        // Budget" reference line. It comes from vw_BudgetAllocation (the same
        // source as the Budget Allocations view) for the active fiscal year.
        //
        // The fiscal year the user asked for is passed straight through as raw
        // input; budgetTotal() takes it as mixed and validates it. Coercing it
        // to ?string here would throw on `?fy[]=x` before any try/catch runs.
        [
            'fiscalYear' => $fiscalYear,
            'totalBudget' => $totalBudget,
            'available' => $budgetAvailable,
            'years' => $years,
            'fyNav' => $fyNav,
        ] = $this->budgetTotal($username, $request->input('fy'));

        // The expenditure window is "up to the current fiscal month" for the
        // active FY (whole year for a past FY, nothing for a future FY).
        $cutoff = $this->resolveCutoff($fiscalYear);

        $expenditure = $this->expenditureData($username, $fiscalYear, $cutoff);

        return Inertia::render('Dashboard', [
            'userName' => $request->user()->name,
            'hasAccess' => $hasAccess,
            // fiscalYear and activeFiscalYear are the same value under two
            // names: the dashboard's own copy has always read `fiscalYear`,
            // while FiscalYearHero and every sibling page expect
            // `activeFiscalYear`. The alias is what lets the shared control
            // drop in with no prop mapping.
            'fiscalYear' => $fiscalYear,
            'activeFiscalYear' => $fiscalYear,
            'currentFiscalYear' => $this->currentFiscalYear(),
            'years' => $years,
            'fyNav' => $fyNav,
            'totalBudget' => $totalBudget,
            'budgetAvailable' => $budgetAvailable,
            'expenditureAvailable' => $expenditure['available'],
            'expenditureWindowStarted' => $cutoff > 0,
            'ytdExpenditure' => $expenditure['ytd'],
            'latestPeriodLabel' => $expenditure['latestPeriodLabel'],
            'monthlyExpenditure' => $this->monthlyBarData($fiscalYear, $cutoff, $expenditure['periodTotals']),
            'budgetVsActual' => $this->budgetVsActualData(
                $totalBudget,
                $budgetAvailable,
                $expenditure['available'],
                $fiscalYear,
                $cutoff,
                $expenditure['periodTotals']
            ),
            'expenditureByCategory' => $expenditure['byCategory'],
        ]);
    }

    // =========================================================================
    // Export — 12 fiscal periods, on its own code path
    // =========================================================================

    /**
     * The dashboard's monthly performance as CSV.
     *
     * DELIBERATELY NOT the shared table-export shape in App\Concerns\
     * ExportsReports: this page has no row collection, no filter options and no
     * row count, so those guards would have nothing to act on. It is built from
     * budgetTotal(), expenditureData() and cumulativeSeries() — the same three
     * the page itself uses — so the file and the KPI cards reconcile by
     * construction rather than by a second implementation agreeing.
     *
     * There is no "category breakdown" CSV: expenditureData() caches only the
     * topCategories(..., 8) DISPLAY shape (top eight plus Other), so exporting
     * it would be a picture of the chart rather than data.
     */
    public function export(Request $request): StreamedResponse|RedirectResponse
    {
        $username = $request->user()->username;

        if (! $this->hasLedgerAccess($username)) {
            return $this->exportRedirect($request, self::EXPORT_NO_ACCESS);
        }

        [
            'fiscalYear' => $fiscalYear,
            'totalBudget' => $totalBudget,
            'available' => $budgetAvailable,
        ] = $this->budgetTotal($username, $request->input('fy'));

        $cutoff = $this->resolveCutoff($fiscalYear);
        $expenditure = $this->expenditureData($username, $fiscalYear, $cutoff);

        // Both of these are the "never present a fake zero" rule, applied to a
        // download: a file of 0.00 during an outage is indistinguishable from a
        // real answer, and a fiscal year that has not started has nothing in it.
        if (! $expenditure['available']) {
            return $this->exportRedirect($request, self::EXPORT_UNAVAILABLE);
        }

        if ($cutoff === 0) {
            return $this->exportRedirect($request, self::EXPORT_NOT_STARTED);
        }

        Log::info('CSV export started.', [
            'page' => 'dashboard',
            'username' => $username,
            'fy' => $fiscalYear,
            'rows' => 12,
        ]);

        return $this->streamCsv(
            $this->csvFilename('dashboard-monthly-performance', $fiscalYear),
            ['Financial Year', 'Period ID', 'Fiscal Month', 'Monthly Net Expenditure',
                'Cumulative Net Expenditure', 'Annual Budget'],
            fn () => $this->exportRows(
                $fiscalYear,
                $cutoff,
                $expenditure['periodTotals'],
                $totalBudget,
                $budgetAvailable,
            ),
            ['page' => 'dashboard', 'username' => $username],
        );
    }

    /**
     * All 12 periods, so the file is a complete fiscal year.
     *
     * A FUTURE PERIOD LEAVES BOTH EXPENDITURE COLUMNS BLANK — "not started" and
     * "genuinely zero activity" are different facts, and the dashboard already
     * distinguishes them (cumulativeSeries() returns null past the cutoff). A
     * HISTORICAL month with no rows keeps a numeric 0.00, because that is a
     * real measurement.
     *
     * @param  array<int,array{PeriodID:int,TRXPeriod:string,total:float}>  $periodTotals
     * @return \Generator<int,array<int,string>>
     */
    private function exportRows(
        int $fiscalYear,
        int $cutoff,
        array $periodTotals,
        float $totalBudget,
        bool $budgetAvailable,
    ): \Generator {
        // The same series the burn-up chart draws — reused, not recomputed.
        $cumulative = $this->cumulativeSeries($cutoff, $periodTotals);
        $headings = $this->fiscalMonthHeadings($fiscalYear);

        $byPeriod = [];
        foreach ($periodTotals as $row) {
            $byPeriod[$row['PeriodID']] = $row['total'];
        }

        for ($periodId = 1; $periodId <= 12; $periodId++) {
            $future = $periodId > $cutoff;

            yield [
                $this->csvText((string) $fiscalYear),
                $this->csvText((string) $periodId),
                $this->csvText($headings[$periodId - 1]),
                $future ? '' : $this->csvMoney($byPeriod[$periodId] ?? 0.0),
                $future ? '' : $this->csvMoney($cumulative[$periodId - 1] ?? 0.0),
                // No fake budget line when the budget source is unavailable.
                $budgetAvailable ? $this->csvMoney($totalBudget) : '',
            ];
        }
    }

    private function exportRedirect(Request $request, string $message): RedirectResponse
    {
        return redirect()->route('dashboard', $request->query())->with('warning', $message);
    }

    /**
     * The access probe, defaulting to TRUE when it cannot run.
     *
     * "I could not check" must never render as "you have no permissions" — that
     * sends a user to chase an administrator over what is actually an outage,
     * which the budget/expenditure states below already report correctly.
     */
    private function hasLedgerAccess(string $username): bool
    {
        try {
            return $this->userHasLedgerAccess($username);
        } catch (\Throwable $e) {
            Log::warning('Dashboard access probe failed; assuming the user has access.', [
                'username' => $username,
                'exception' => $e->getMessage(),
            ]);

            return true;
        }
    }

    // =========================================================================
    // Live budget total — from vw_BudgetAllocation (current fiscal year)
    // =========================================================================

    /**
     * Resolve the active fiscal year and its total allocation for the user.
     * The source view joins remote GP linked servers, so both the year list
     * and the SUM are cached on the dedicated budget file store. A SQL Server
     * outage degrades to an unavailable state — never a fake zero budget. A
     * successful query that returns no years for the user is also treated as
     * unavailable (no budget configured ≠ a real zero allocation).
     *
     * The dashboard's fiscal-year rail is scoped to years with BUDGET data
     * rather than every year with expenditure. This page is budget-vs-actual:
     * a year with spend but no allocation baseline would draw a burn-up chart
     * with no budget line and leave two KPI cards dead. It also means the year
     * list reuses the exact cache key the Budget Allocations page writes, so
     * navigation costs no extra queries. FY2014-2024 expenditure history stays
     * reachable from the Monthly Expenditure page, which reads the ledger and
     * therefore covers years this rail does not offer.
     *
     * $requestedFy is raw request input (mixed, possibly an array).
     *
     * @return array{fiscalYear:int, totalBudget:float, available:bool,
     *               years:array<int,string>, fyNav:array{prev:?int, next:?int}}
     */
    private function budgetTotal(string $username, mixed $requestedFy = null): array
    {
        $cache = Cache::store(config('budget.cache.store'));
        $ttl = config('budget.cache.minutes') * 60;
        $currentFiscalYear = $this->currentFiscalYear();
        $noNav = ['prev' => null, 'next' => null];

        try {
            // Reuse the exact cache key the Budget Allocations view populates.
            $years = collect($cache->remember(
                $this->ledgerCacheKey("budget-allocations:years:{$username}"),
                $ttl,
                fn () => BudgetAllocation::forUser($username)
                    ->select('FinancialYear')
                    ->distinct()
                    ->orderBy('FinancialYear')
                    ->pluck('FinancialYear')
                    ->filter()
                    ->values()
                    ->all()
            ));

            if ($years->isEmpty()) {
                // Query succeeded but this user has no budget data — not a real zero.
                return [
                    'fiscalYear' => $currentFiscalYear,
                    'totalBudget' => 0.0,
                    'available' => false,
                    'years' => [],
                    'fyNav' => $noNav,
                ];
            }

            $activeFiscalYear = $this->resolveFiscalYear($requestedFy, $years, $currentFiscalYear);

            $totalBudget = (float) $cache->remember(
                $this->ledgerCacheKey("dashboard:budget-total:{$username}:{$activeFiscalYear}"),
                $ttl,
                fn () => BudgetAllocation::forUser($username)
                    ->forYear((string) $activeFiscalYear)
                    ->sum('TotalAllocation')
            );

            return [
                'fiscalYear' => $activeFiscalYear,
                'totalBudget' => $totalBudget,
                'available' => true,
                'years' => $years->all(),
                'fyNav' => $this->fiscalYearNav($activeFiscalYear, $years),
            ];
        } catch (\Throwable $e) {
            Log::error('Dashboard budget total query failed.', [
                'username' => $username,
                // The year that actually failed, not the current one — during an
                // outage those differ whenever the user was browsing history.
                'fy' => $requestedFy,
                'exception' => $e->getMessage(),
            ]);

            return [
                // Stay on the year the user asked for. Snapping back to the
                // current FY during an outage moves the page under them and
                // reads as "that year vanished" rather than "try again later".
                'fiscalYear' => $this->fallbackFiscalYear($requestedFy, $currentFiscalYear),
                'totalBudget' => 0.0,
                'available' => false,
                'years' => [],
                'fyNav' => $noNav,
            ];
        }
    }

    /**
     * The fiscal year to display when the source could not be reached.
     *
     * resolveFiscalYear() validates a requested year against the list of years
     * that have data; on this path there is no list, so the gate is repeated
     * here against a plausible range instead. Same regex-before-cast rule:
     * (int) '2025abc' is 2025, and is not a request for FY2025.
     */
    private function fallbackFiscalYear(mixed $requested, int $currentFiscalYear): int
    {
        if (! is_string($requested) || ! preg_match('/^\d{4}$/', $requested)) {
            return $currentFiscalYear;
        }

        $year = (int) $requested;

        return ($year >= 2000 && $year <= $currentFiscalYear + 1) ? $year : $currentFiscalYear;
    }

    // =========================================================================
    // Live expenditure — from dbo.MonthlyExpenditure (active FY, up to cutoff)
    // =========================================================================

    /**
     * Per-month net expenditure for the active FY up to $cutoff, plus the YTD
     * total and a net-by-category breakdown. Read-only SQL Server source, so it
     * is wrapped in try/catch and degrades to an unavailable state. Cached on the
     * dedicated expenditure file store — the dashboard takes no per-request
     * filters, so the only cache dimensions are (user, FY, cutoff).
     *
     * @return array{available:bool, ytd:float, latestPeriodLabel:?string,
     *               periodTotals:array<int,array{PeriodID:int,TRXPeriod:string,total:float}>,
     *               byCategory:array{labels:array<int,string>, data:array<int,float>}}
     */
    private function expenditureData(string $username, int $fiscalYear, int $cutoff): array
    {
        $cache = Cache::store(config('expenditure.cache.store'));
        $ttl = config('expenditure.cache.minutes') * 60;

        try {
            // $cutoff is in the key so the cache rolls forward when the fiscal
            // month advances; stale keys expire on their own TTL.
            return $cache->remember(
                $this->ledgerCacheKey("dashboard:expenditure:{$username}:{$fiscalYear}:{$cutoff}"),
                $ttl,
                function () use ($username, $fiscalYear, $cutoff) {
                    $base = fn () => MonthlyExpenditure::forUser($username)
                        ->forYear((string) $fiscalYear)
                        ->where('PeriodID', '<=', $cutoff);

                    // Per-month net (≤ cutoff rows): powers YTD, the bar chart,
                    // and the cumulative Actual line.
                    $byMonth = $base()
                        ->select('PeriodID', 'TRXPeriod')
                        ->selectRaw('SUM(NetChange) AS total')
                        ->groupBy('PeriodID', 'TRXPeriod')
                        ->orderBy('PeriodID')
                        ->get();

                    // Net by category (MainGroup); negatives allowed (bar chart).
                    $byCat = $base()
                        ->select('MainGroup')
                        ->selectRaw('SUM(NetChange) AS total')
                        ->groupBy('MainGroup')
                        ->orderByDesc('total')
                        ->get();

                    // SUM(NetChange) is uncast → comes back a string; cast to float.
                    $periodTotals = $byMonth->map(fn ($m) => [
                        'PeriodID' => (int) $m->PeriodID,
                        'TRXPeriod' => $m->TRXPeriod,
                        'total' => (float) $m->total,
                    ])->all();

                    return [
                        'available' => true,
                        'ytd' => (float) array_sum(array_column($periodTotals, 'total')),
                        // The CURRENT fiscal month (not the last row) — so "through
                        // JUN, 26" is correct even before the current month posts.
                        'latestPeriodLabel' => $this->fiscalMonthLabels($fiscalYear)[$cutoff] ?? null,
                        'periodTotals' => $periodTotals,
                        'byCategory' => $this->topCategories($byCat, 8),
                    ];
                }
            );
        } catch (\Throwable $e) {
            Log::error('Dashboard expenditure query failed.', [
                'username' => $username,
                'fy' => $fiscalYear,
                'exception' => $e->getMessage(),
            ]);

            return [
                'available' => false,
                'ytd' => 0.0,
                'latestPeriodLabel' => null,
                'periodTotals' => [],
                'byCategory' => ['labels' => [], 'data' => []],
            ];
        }
    }

    // =========================================================================
    // Chart shaping — budget burn-up (flat annual budget + cumulative actual)
    // =========================================================================

    private function budgetVsActualData(
        float $totalBudget,
        bool $budgetAvailable,
        bool $expenditureAvailable,
        int $fiscalYear,
        int $cutoff,
        array $periodTotals
    ): array {
        $labels = array_values($this->fiscalMonthLabels($fiscalYear));   // 12 labels, period order

        // Blank the actual line entirely when the source is down (all null) so it
        // is never mistaken for genuine zero spend. A real new FY with no rows yet
        // still shows a legitimate cumulative 0 because $expenditureAvailable is true.
        $actual = $expenditureAvailable
            ? $this->cumulativeSeries($cutoff, $periodTotals)
            : array_fill(0, 12, null);

        $datasets = [];
        // No fake budget line when the budget source is unavailable — omit it.
        if ($budgetAvailable) {
            $datasets[] = ['label' => 'Annual Budget', 'data' => array_fill(0, 12, $totalBudget)];
        }
        $datasets[] = ['label' => 'Actual (cumulative)', 'data' => $actual];

        return ['labels' => $labels, 'datasets' => $datasets];
    }
}
