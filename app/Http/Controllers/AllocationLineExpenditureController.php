<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use App\Concerns\SampleLedgerFixtures;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Inertia\Inertia;
use Inertia\Response;

/**
 * Allocation Line Expenditure — allocation against actual spend, per account
 * line, for a fiscal year.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SCAFFOLD: every figure here is HARDCODED. Nothing touches SQL Server yet.
 * Replacing sampleRows() with a FinanceLedger query is the whole migration; the
 * prop contract does not change.
 * ─────────────────────────────────────────────────────────────────────────────
 */
class AllocationLineExpenditureController extends Controller
{
    use ResolvesFiscalYear;
    use SampleLedgerFixtures;

    /** Fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = ['Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep'];

    public function index(Request $request): Response
    {
        $filters = $request->only('cluster', 'institution', 'department', 'description', 'account', 'fy');

        $years = collect([2023, 2024, 2025, 2026]);

        $currentFiscalYear = $this->currentFiscalYear();
        $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
        $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
        $filters['fy'] = $activeFiscalYear;

        $rows = $this->sampleRows((int) $activeFiscalYear);

        // ── Filter option lists (scoped to what the active FY contains) ──────────
        $clusters = $rows->pluck('ClusterName')->filter()->unique()->sort()->values()->all();

        $institutions = $rows
            ->map(fn ($r) => ['ClusterName' => $r['ClusterName'], 'InstitutionName' => $r['InstitutionName']])
            ->unique(fn ($i) => $i['ClusterName'].'|'.$i['InstitutionName'])
            ->sortBy('InstitutionName')
            ->values()
            ->all();

        $departments = $rows->pluck('DepartmentName')->filter()->unique()->sort()->values()->all();
        $descriptions = $rows->pluck('AccountDescription')->filter()->unique()->sort()->values()->all();

        // Account numbers are shown with their description, since the number
        // alone is unreadable. Ordered by description so the list is scannable.
        $accounts = $rows
            ->map(fn ($r) => ['AccountNumber' => $r['AccountNumber'], 'AccountDescription' => $r['AccountDescription']])
            ->unique('AccountNumber')
            ->sortBy(fn ($a) => $a['AccountDescription'].$a['AccountNumber'])
            ->values()
            ->all();

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

        $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true) ? $v : null;
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        $filters['description'] = ($v = $request->input('description')) && in_array($v, $descriptions, true) ? $v : null;
        if ($filters['description']) {
            $filtered = $filtered->where('AccountDescription', $filters['description']);
        }

        $filters['account'] = ($v = $request->input('account')) && in_array($v, array_column($accounts, 'AccountNumber'), true) ? $v : null;
        if ($filters['account']) {
            $filtered = $filtered->where('AccountNumber', $filters['account']);
        }

        $filtered = $filtered->values();

        // ── Totals over the whole filtered set, before pagination ────────────────
        // A totals row that only summed the visible page would look authoritative
        // and be wrong.
        $monthTotals = [];
        foreach (self::MONTHS as $month) {
            $monthTotals[$month] = round((float) $filtered->sum($month), 2);
        }

        $totalAllocation = round((float) $filtered->sum('Allocation'), 2);
        $totalYtd = round((float) $filtered->sum('YTDTotal'), 2);
        $exceededCount = $filtered->where('StatusKey', 'over')->count();

        $totals = [
            'allocation' => $totalAllocation,
            'months' => $monthTotals,
            'encumbered' => round((float) $filtered->sum('Encumbered'), 2),
            'ytd' => $totalYtd,
            // Summed per line, not derived from the totals: an account that has
            // overspent contributes zero balance, and netting it against another
            // account's headroom would overstate what is actually available.
            'balance' => round((float) $filtered->sum('AllocationBalance'), 2),
            'exceededCount' => $exceededCount,
        ];

        $stats = [
            'totalAllocation' => $totalAllocation,
            'totalExpenditure' => $totalYtd,
            'balance' => $totals['balance'],
            'exceededCount' => $exceededCount,
            'accountCount' => $filtered->count(),
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

        return Inertia::render('Expenditure/Allocation Line Expenditure', [
            'rows' => $paginated,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'departments' => $departments,
            'descriptions' => $descriptions,
            'accounts' => $accounts,
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

    // =========================================================================
    // Allocation outcome — the rule the page exists to show
    // =========================================================================

    /**
     * Classify a line's spend against its allocation.
     *
     * Balance floors at zero: once spending passes the allocation there is no
     * such thing as a negative balance, the overspend is reported separately as
     * the status amount. Returning a negative balance here would let it net off
     * another line's headroom in the totals row and overstate available funds.
     *
     * Only the classification and the amounts are decided here. The wording is
     * composed client-side, where the currency formatter already lives.
     *
     * @return array{balance:float, statusKey:string, statusAmount:float}
     */
    private function allocationOutcome(float $allocation, float $ytd): array
    {
        $delta = round($ytd - $allocation, 2);

        // Both sides are rounded to 2dp, but comparing floats for exact equality
        // is still unsafe — half a cent of tolerance decides "fully spent".
        if (abs($delta) < 0.005) {
            return ['balance' => 0.0, 'statusKey' => 'exact', 'statusAmount' => 0.0];
        }

        if ($delta > 0) {
            return ['balance' => 0.0, 'statusKey' => 'over', 'statusAmount' => $delta];
        }

        return ['balance' => abs($delta), 'statusKey' => 'under', 'statusAmount' => abs($delta)];
    }

    // =========================================================================
    // Hardcoded sample data — REPLACE WITH FinanceLedger QUERY
    // =========================================================================

    /**
     * Deterministic sample rows. Values derive from a CRC of the account key,
     * NOT from randomness, so figures stay identical across pagination and
     * filter changes — a random source would make the table appear to change
     * under the user.
     *
     * Allocations are seeded to produce all three status outcomes, so the page
     * can be reviewed against every branch rather than only the common one.
     */
    private function sampleRows(int $fiscalYear): Collection
    {
        $cutoff = $this->resolveCutoff($fiscalYear);
        $accounts = $this->sampleAccounts();
        $rows = collect();

        foreach ($this->sampleUnits() as [$cluster, $institution, $instId, $responsibility, $respId, $department, $deptId]) {
            $take = 4 + (crc32($institution.$department) % 4);

            foreach (array_slice($accounts, crc32($department) % 5, $take) as [$acctSeg, $acctDesc]) {
                $accountNumber = $this->sampleAccountNumber($acctSeg, $instId, $respId, $deptId);

                $row = [
                    'FinancialYear' => (string) $fiscalYear,
                    'ClusterName' => $cluster,
                    'InstitutionName' => $institution,
                    'Responsibility' => $responsibility,
                    'DepartmentName' => $department,
                    'AccountNumber' => $accountNumber,
                    'AccountDescription' => $acctDesc,
                ];

                // ── Monthly spend; months past the cutoff have not happened ──
                $ytd = 0.0;
                foreach (self::MONTHS as $i => $month) {
                    if ($i + 1 > $cutoff) {
                        $row[$month] = 0.0;

                        continue;
                    }

                    $seed = crc32($accountNumber.$month.$fiscalYear);
                    $base = 4_000 + ($seed % 46_000);
                    $value = round($seed % 23 === 0 ? -($base / 6) : $base, 2);

                    $row[$month] = $value;
                    $ytd += $value;
                }

                $ytd = round($ytd, 2);
                $allocSeed = crc32($accountNumber.'allocation'.$fiscalYear);

                if ($ytd <= 0) {
                    // A future or not-yet-started year: budgeted, nothing spent.
                    $allocation = round(50_000 + ($allocSeed % 400_000), 2);
                } elseif ($allocSeed % 9 === 0) {
                    $allocation = $ytd;                                        // exactly consumed
                } elseif ($allocSeed % 5 === 0) {
                    $allocation = round($ytd * 0.82, 2);                       // overspent
                } else {
                    $allocation = round($ytd * (1.15 + ($allocSeed % 40) / 100), 2);
                }

                $outcome = $this->allocationOutcome($allocation, $ytd);

                $row['Allocation'] = $allocation;
                $row['Encumbered'] = round(($allocSeed % 7 === 0) ? 0.0 : ($allocSeed % 28_000), 2);
                $row['YTDTotal'] = $ytd;
                $row['AllocationBalance'] = $outcome['balance'];
                $row['StatusKey'] = $outcome['statusKey'];
                $row['StatusAmount'] = $outcome['statusAmount'];

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
