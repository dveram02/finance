<?php

namespace App\Http\Controllers;

use App\Models\BudgetAllocation;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Inertia\Inertia;
use Inertia\Response;

class BudgetAllocationController extends Controller
{
    public function index(Request $request): Response
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'fy');

        $base = fn () => BudgetAllocation::forUser($username);

        try {
            // ── Filter option lists ───────────────────────────────────────────
            $clusters = $base()
                ->select('ClusterName')
                ->distinct()
                ->orderBy('ClusterName')
                ->pluck('ClusterName')
                ->filter()
                ->values();

            $institutions = $base()
                ->select('ClusterName', 'InstitutionName')
                ->distinct()
                ->orderBy('InstitutionName')
                ->get()
                ->unique('InstitutionName')
                ->values();

            $responsibilities = $base()
                ->select('ResponsibilityName')
                ->distinct()
                ->orderBy('ResponsibilityName')
                ->pluck('ResponsibilityName')
                ->filter()
                ->values();

            $departments = $base()
                ->select('DepartmentName')
                ->distinct()
                ->orderBy('DepartmentName')
                ->pluck('DepartmentName')
                ->filter()
                ->values();

            $accounts = $base()
                ->select('AccountNumber', 'AccountDescription')
                ->distinct()
                ->orderBy('AccountDescription')
                ->get()
                ->unique('AccountNumber')
                ->values();

            $years = $base()
                ->select('FinancialYear')
                ->distinct()
                ->orderBy('FinancialYear')
                ->pluck('FinancialYear')
                ->filter()
                ->values();

            // ── Resolve the active fiscal year ────────────────────────────────
            $currentFiscalYear = $this->currentFiscalYear();
            $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
            $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
            $filters['fy'] = $activeFiscalYear;

            // ── Filtered query ────────────────────────────────────────────────
            $query = $base();

            if ($v = $request->input('cluster')) {
                $query->where('ClusterName', $v);
            }
            if ($v = $request->input('institution')) {
                $query->where('InstitutionName', $v);
            }
            if ($v = $request->input('responsibility')) {
                $query->where('ResponsibilityName', $v);
            }
            if ($v = $request->input('department')) {
                $query->where('DepartmentName', $v);
            }
            if ($v = $request->input('account')) {
                $query->where('AccountNumber', $v);
            }
            if ($activeFiscalYear !== null) {
                $query->forYear((string) $activeFiscalYear);
            }

            // ── Stats (full filtered set, before pagination) ──────────────────
            $stats = [
                'total' => (clone $query)->count(),
                'totalAllocation' => (float) (clone $query)->sum('TotalAllocation'),
            ];

            // ── Paginated results ─────────────────────────────────────────────
            $allocations = $query
                ->orderBy('FinancialYear')
                ->orderBy('ClusterName')
                ->orderBy('InstitutionName')
                ->orderBy('DepartmentName')
                ->orderBy('AccountNumber')
                ->paginate(25)
                ->withQueryString();

        } catch (\Throwable $e) {
            session()->flash('warning', 'Could not connect to the financial data source. Please try again later.');

            $currentFiscalYear = $this->currentFiscalYear();
            $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

            return Inertia::render('Budget/All Budget Allocations', [
                'allocations' => new LengthAwarePaginator([], 0, 25, 1, [
                    'path' => $request->url(),
                    'query' => $request->query(),
                ]),
                'clusters' => [],
                'institutions' => [],
                'responsibilities' => [],
                'departments' => [],
                'accounts' => [],
                'years' => [],
                'stats' => ['total' => 0, 'totalAllocation' => 0],
                'filters' => $filters,
                'activeFiscalYear' => $filters['fy'],
                'currentFiscalYear' => $currentFiscalYear,
                'fyNav' => ['prev' => null, 'next' => null],
            ]);
        }

        return Inertia::render('Budget/All Budget Allocations', [
            'allocations' => $allocations,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
            'accounts' => $accounts,
            'years' => $years,
            'stats' => $stats,
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
        ]);
    }

    // =========================================================================
    // Fiscal-year helpers
    // =========================================================================

    /**
     * The fiscal year for today. A fiscal year runs Oct 1 → Sep 30 and is
     * named for the calendar year it ends in (e.g. Oct 2025 – Sep 2026 = 2026).
     */
    private function currentFiscalYear(): int
    {
        $now = now();

        return $now->month >= 10 ? $now->year + 1 : $now->year;
    }

    /**
     * Pick the fiscal year to display: the requested one if it has data,
     * otherwise the current FY if present, otherwise the latest FY with data.
     */
    private function resolveFiscalYear(?string $requested, $years, int $currentFiscalYear): ?int
    {
        if ($years->isEmpty()) {
            return $currentFiscalYear;
        }

        $available = $years->map(fn ($y) => (int) $y);

        if ($requested !== null && $available->contains((int) $requested)) {
            return (int) $requested;
        }

        if ($available->contains($currentFiscalYear)) {
            return $currentFiscalYear;
        }

        return (int) $available->max();
    }

    /**
     * Previous / next fiscal years that have data, relative to the active one.
     */
    private function fiscalYearNav(?int $activeFiscalYear, $years): array
    {
        $available = $years->map(fn ($y) => (int) $y)->sort()->values();
        $index = $available->search($activeFiscalYear, true);

        if ($index === false) {
            return ['prev' => null, 'next' => null];
        }

        return [
            'prev' => $index > 0 ? $available[$index - 1] : null,
            'next' => $index < $available->count() - 1 ? $available[$index + 1] : null,
        ];
    }
}
