<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Inertia\Inertia;
use Inertia\Response;

/**
 * Annual expenditure report — one row per account for a fiscal year, with the
 * 12 fiscal months across and a YTD total.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SCAFFOLD: every figure here is HARDCODED. Nothing touches SQL Server yet.
 *
 * The shape is deliberately identical to what dbo.vw_FinanceLedger will return
 * (see financeupdate.php plan), so going live means replacing sampleRows() with
 * a FinanceLedger query and deleting the in-memory filtering below. The prop
 * contract passed to the page does not change.
 * ─────────────────────────────────────────────────────────────────────────────
 */
class DepartmentExpenditureController extends Controller
{
    use ResolvesFiscalYear;

    /** Fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = ['Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep'];

    public function index(Request $request): Response
    {
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'fy');

        $years = collect([2023, 2024, 2025, 2026]);

        $currentFiscalYear = $this->currentFiscalYear();
        $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
        $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
        $filters['fy'] = $activeFiscalYear;

        $rows = $this->sampleRows((int) $activeFiscalYear);

        // ── Filter option lists (scoped to what the active FY actually contains) ──
        $clusters = $rows->pluck('ClusterName')->filter()->unique()->sort()->values()->all();

        $institutions = $rows
            ->map(fn ($r) => ['ClusterName' => $r['ClusterName'], 'InstitutionName' => $r['InstitutionName']])
            ->unique(fn ($i) => $i['ClusterName'].'|'.$i['InstitutionName'])
            ->sortBy('InstitutionName')
            ->values()
            ->all();

        $responsibilities = $rows->pluck('Responsibility')->filter()->unique()->sort()->values()->all();
        $departments = $rows->pluck('DepartmentName')->filter()->unique()->sort()->values()->all();

        // ── Apply filters ────────────────────────────────────────────────────────
        // Only honour a selection that is a valid option in the active FY, so a
        // stale filter carried across an FY switch never silently empties the table.
        $filtered = $rows;

        $filters['cluster'] = ($v = $request->input('cluster')) && in_array($v, $clusters, true) ? $v : null;
        if ($filters['cluster']) {
            $filtered = $filtered->where('ClusterName', $filters['cluster']);
        }

        $filters['institution'] = ($v = $request->input('institution')) && in_array($v, array_column($institutions, 'InstitutionName'), true) ? $v : null;
        if ($filters['institution']) {
            $filtered = $filtered->where('InstitutionName', $filters['institution']);
        }

        $filters['responsibility'] = ($v = $request->input('responsibility')) && in_array($v, $responsibilities, true) ? $v : null;
        if ($filters['responsibility']) {
            $filtered = $filtered->where('Responsibility', $filters['responsibility']);
        }

        $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true) ? $v : null;
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        $filtered = $filtered->values();

        // ── Stats and column totals over the whole filtered set ──────────────────
        // Deliberately computed before pagination: a totals row that only summed
        // the visible 25 rows would look authoritative and be wrong.
        $monthTotals = [];
        foreach (self::MONTHS as $m) {
            $monthTotals[$m] = round((float) $filtered->sum($m), 2);
        }

        // Ranked on a copy — sorting $monthTotals itself would destroy the fiscal
        // month ordering the totals row depends on.
        $highestMonthKey = null;
        if ($filtered->isNotEmpty()) {
            $ranked = $monthTotals;
            arsort($ranked);
            $highestMonthKey = array_key_first($ranked);
        }

        $grandTotal = round((float) $filtered->sum('YTDTotal'), 2);

        $stats = [
            'totalExpenditure' => $grandTotal,
            'highestMonth' => [
                'label' => $highestMonthKey ? $this->monthLabel($highestMonthKey, (int) $activeFiscalYear) : null,
                'amount' => $highestMonthKey ? $monthTotals[$highestMonthKey] : 0.0,
            ],
            'accountCount' => $filtered->count(),
        ];

        $totals = [
            'months' => $monthTotals,
            'ytd' => $grandTotal,
        ];

        // ── Paginate ─────────────────────────────────────────────────────────────
        $perPage = 25;
        $page = LengthAwarePaginator::resolveCurrentPage();

        $paginated = new LengthAwarePaginator(
            $filtered->forPage($page, $perPage)->values(),
            $filtered->count(),
            $perPage,
            $page,
            ['path' => $request->url(), 'query' => $request->query()],
        );

        return Inertia::render('Expenditure/Department Expenditure', [
            'rows' => $paginated,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
            'years' => $years->all(),
            'months' => $this->monthHeadings((int) $activeFiscalYear),
            'stats' => $stats,
            'totals' => $totals,
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
            'isScaffold' => true,
        ]);
    }

    // =========================================================================
    // Month headings
    // =========================================================================

    /**
     * Column headings for the 12 fiscal months, e.g. ['key' => 'Oct',
     * 'label' => 'OCT', 'year' => '25', 'future' => false]. `future` lets the
     * page mute months that have not happened yet in the active fiscal year.
     *
     * @return array<int,array{key:string,label:string,year:string,future:bool,quarterStart:bool}>
     */
    private function monthHeadings(int $fiscalYear): array
    {
        $cutoff = $this->resolveCutoff($fiscalYear);
        $labels = $this->fiscalMonthLabels($fiscalYear);   // keyed 1..12, "OCT, 25"

        $out = [];
        foreach (self::MONTHS as $i => $key) {
            $periodId = $i + 1;
            [$abbr, $yy] = explode(', ', $labels[$periodId]);

            $out[] = [
                'key' => $key,
                'label' => $abbr,
                'year' => $yy,
                'future' => $periodId > $cutoff,
                'quarterStart' => $periodId % 3 === 1 && $periodId > 1,
            ];
        }

        return $out;
    }

    private function monthLabel(string $key, int $fiscalYear): string
    {
        $periodId = array_search($key, self::MONTHS, true) + 1;

        return $this->fiscalMonthLabels($fiscalYear)[$periodId] ?? strtoupper($key);
    }

    // =========================================================================
    // Hardcoded sample data — REPLACE WITH FinanceLedger QUERY
    // =========================================================================

    /**
     * Deterministic sample rows for a fiscal year.
     *
     * Values are derived from a CRC of the account key, NOT random, so figures
     * stay identical across pagination and filter changes — a random source
     * would make the table appear to change under the user.
     *
     * Months after the fiscal-year cutoff are zero, matching how a real
     * in-progress year looks (see ResolvesFiscalYear::resolveCutoff).
     */
    private function sampleRows(int $fiscalYear): Collection
    {
        $cutoff = $this->resolveCutoff($fiscalYear);

        $accounts = [
            ['80400', 'MEDICAL SUPPLIES AND DRUGS'],
            ['80410', 'PHARMACEUTICALS'],
            ['80500', 'SURGICAL SUNDRIES'],
            ['81200', 'LABORATORY REAGENTS'],
            ['82100', 'OFFICE SUPPLIES AND STATIONERY'],
            ['83000', 'REPAIRS AND MAINTENANCE - BUILDING'],
            ['83100', 'REPAIRS AND MAINTENANCE - EQUIPMENT'],
            ['84200', 'ELECTRICITY'],
            ['84300', 'WATER AND SEWERAGE'],
            ['85100', 'CONTRACT CLEANING SERVICES'],
            ['86200', 'SECURITY SERVICES'],
            ['87400', 'TRAVELLING AND SUBSISTENCE'],
        ];

        $units = [
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'MEDICAL SERVICES', '107', 'PHARMACY', '1157'],
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'MEDICAL SERVICES', '107', 'RADIOLOGY', '1162'],
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'NURSING SERVICES', '112', 'ACCIDENT AND EMERGENCY', '1204'],
            ['SOUTH WEST', 'POINT FORTIN AREA HOSPITAL', 'H04', 'MEDICAL SERVICES', '107', 'PHARMACY', '1158'],
            ['SOUTH WEST', 'POINT FORTIN AREA HOSPITAL', 'H04', 'SUPPORT SERVICES', '131', 'FACILITIES MAINTENANCE', '1442'],
            ['CENTRAL', 'PRINCES TOWN DISTRICT HEALTH FACILITY', 'H07', 'NURSING SERVICES', '112', 'OUTPATIENT CLINIC', '1219'],
            ['CENTRAL', 'COUVA DISTRICT HEALTH FACILITY', 'H09', 'SUPPORT SERVICES', '131', 'FACILITIES MAINTENANCE', '1447'],
            ['SOUTH EAST', 'SIPARIA DISTRICT HEALTH FACILITY', 'H12', 'ADMINISTRATION', '145', 'CORPORATE SERVICES', '1503'],
            ['SOUTH EAST', 'RIO CLARO DISTRICT HEALTH FACILITY', 'H14', 'NURSING SERVICES', '112', 'OUTPATIENT CLINIC', '1221'],
        ];

        $rows = collect();

        foreach ($units as $u) {
            [$cluster, $institution, $instId, $responsibility, $respId, $department, $deptId] = $u;

            // A deterministic slice of the account list per unit, so the report is
            // varied without every department carrying every account.
            $take = 4 + (crc32($institution.$department) % 4);

            foreach (array_slice($accounts, crc32($department) % 5, $take) as [$acctSeg, $acctDesc]) {
                $accountNumber = "4-{$acctSeg}-{$instId}-{$respId}-{$deptId}-00-000";

                $row = [
                    'FinancialYear' => (string) $fiscalYear,
                    'ClusterName' => $cluster,
                    'InstitutionName' => $institution,
                    'Responsibility' => $responsibility,
                    'DepartmentName' => $department,
                    'AccountNumber' => $accountNumber,
                    'AccountDescription' => $acctDesc,
                ];

                $ytd = 0.0;
                foreach (self::MONTHS as $i => $month) {
                    $periodId = $i + 1;

                    if ($periodId > $cutoff) {
                        $row[$month] = 0.0;

                        continue;
                    }

                    $seed = crc32($accountNumber.$month.$fiscalYear);
                    $base = 4_000 + ($seed % 46_000);

                    // A small deterministic minority of months are credit
                    // corrections, so negative-value rendering is exercised.
                    $value = round($seed % 23 === 0 ? -($base / 6) : $base, 2);

                    $row[$month] = $value;
                    $ytd += $value;
                }

                $row['YTDTotal'] = round($ytd, 2);
                $rows->push($row);
            }
        }

        return $rows->sortBy([
            ['ClusterName', 'asc'],
            ['InstitutionName', 'asc'],
            ['DepartmentName', 'asc'],
            ['AccountNumber', 'asc'],
        ])->values();
    }
}
