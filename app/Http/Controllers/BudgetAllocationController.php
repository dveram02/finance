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
        $filters  = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'year_from', 'year_to');

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

            // ── Filtered query ────────────────────────────────────────────────
            $query = $base();

            if ($v = $request->input('cluster'))        $query->where('ClusterName',       $v);
            if ($v = $request->input('institution'))    $query->where('InstitutionName',    $v);
            if ($v = $request->input('responsibility')) $query->where('ResponsibilityName', $v);
            if ($v = $request->input('department'))     $query->where('DepartmentName',     $v);
            if ($v = $request->input('account'))        $query->where('AccountNumber',      $v);
            if ($v = $request->input('year_from'))      $query->where('FinancialYear', '>=', $v);
            if ($v = $request->input('year_to'))        $query->where('FinancialYear', '<=', $v);

            // ── Stats (full filtered set, before pagination) ──────────────────
            $stats = [
                'total'           => (clone $query)->count(),
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

            return Inertia::render('Budget/All Budget Allocations', [
                'allocations'      => new LengthAwarePaginator([], 0, 25, 1, [
                    'path'  => $request->url(),
                    'query' => $request->query(),
                ]),
                'clusters'         => [],
                'institutions'     => [],
                'responsibilities' => [],
                'departments'      => [],
                'accounts'         => [],
                'years'            => [],
                'stats'            => ['total' => 0, 'totalAllocation' => 0],
                'filters'          => $filters,
            ]);
        }

        return Inertia::render('Budget/All Budget Allocations', [
            'allocations'      => $allocations,
            'clusters'         => $clusters,
            'institutions'     => $institutions,
            'responsibilities' => $responsibilities,
            'departments'      => $departments,
            'accounts'         => $accounts,
            'years'            => $years,
            'stats'            => $stats,
            'filters'          => $filters,
        ]);
    }
}
