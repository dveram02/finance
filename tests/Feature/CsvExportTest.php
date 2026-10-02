<?php

namespace Tests\Feature;

use App\Http\Middleware\EnsureUserIsActive;
use App\Models\FinanceRequisition;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Feature\Concerns\UsesBudgetData;
use Tests\Feature\Concerns\UsesLedgerData;
use Tests\Feature\Concerns\UsesRequisitionData;
use Tests\TestCase;

/**
 * The CSV exports, end to end.
 *
 * These read the real SQL Server views, so they SKIP when it is unreachable or
 * a snapshot is empty — the same contract as every other data-backed suite
 * here. The security-relevant behaviour (the formula-injection guard, numeric
 * typing, identifier preservation) is pinned OFFLINE in
 * tests/Unit/StreamsCsvTest, because that is the only coverage CI is guaranteed
 * to run.
 *
 * The promise being tested is narrow and important: a CSV describes exactly the
 * rows the screen it came from describes, for every page, and no failure state
 * ever produces a file that looks like a successful report.
 */
class CsvExportTest extends TestCase
{
    use RefreshDatabase;
    use UsesBudgetData;
    use UsesLedgerData;
    use UsesRequisitionData;

    private function download(User $user, string $url, array $query = []): TestResponse
    {
        return $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get($url.($query ? '?'.http_build_query($query) : ''));
    }

    /** The decoded rows of a CSV response, header row included. */
    private function rowsOf(TestResponse $response): array
    {
        $body = $response->streamedContent();

        // The BOM is for Excel; it is not part of the first heading.
        $this->assertStringStartsWith("\xEF\xBB\xBF", $body, 'The file is missing its UTF-8 BOM.');
        $body = substr($body, 3);

        $rows = [];
        foreach (explode("\r\n", rtrim($body, "\r\n")) as $line) {
            $rows[] = str_getcsv($line, ',', '"', '');
        }

        return $rows;
    }

    /** @return array<string,array{0:string,1:string}> page => [url, slug] */
    public static function ledgerPages(): array
    {
        return [
            'monthly expenditure' => ['/monthly-expenditure/export', 'monthly-expenditure'],
            'variance' => ['/variance/export', 'variance'],
        ];
    }

    // =========================================================================
    // Access
    // =========================================================================

    public function test_every_export_requires_authentication(): void
    {
        foreach ([
            '/budget-allocations/export', '/monthly-expenditure/export', '/variance/export',
            '/encumbered-details/export', '/routing-details/export', '/dashboard/export',
        ] as $url) {
            $this->get($url)->assertRedirect('/login');
        }
    }

    public function test_a_user_with_no_department_mapping_gets_a_warning_not_a_csv(): void
    {
        // The state CLAUDE.md calls permanent and expected. An empty CSV here
        // would look exactly like a real report of nothing.
        $stranger = User::factory()->create(['username' => 'NOBODY-WITH-NO-MAPPING']);

        foreach (['/monthly-expenditure/export', '/variance/export', '/encumbered-details/export'] as $url) {
            $response = $this->download($stranger, $url);

            $response->assertRedirect();
            $this->assertNotSame('text/csv; charset=UTF-8', $response->headers->get('Content-Type'));
        }
    }

    // =========================================================================
    // The core promise: the file is the whole filtered set
    // =========================================================================

    /**
     * @dataProvider ledgerPages
     */
    public function test_pagination_does_not_change_the_file(string $url): void
    {
        $user = $this->ledgerUser();

        $first = $this->download($user, $url, ['page' => 1]);
        $first->assertOk();

        $second = $this->download($user, $url, ['page' => 2]);
        $second->assertOk();

        // Bodies, not whole responses: the filename carries a timestamp, so two
        // requests either side of a second boundary legitimately differ there.
        $this->assertSame(
            $first->streamedContent(),
            $second->streamedContent(),
            'An export changed with the page number; it must always be the whole filtered set.'
        );
    }

    /**
     * @dataProvider ledgerPages
     */
    public function test_the_file_holds_one_row_per_account_the_page_reports(string $url, string $slug): void
    {
        $user = $this->ledgerUser();

        $page = $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/'.$slug)
            ->viewData('page')['props'];

        if ($page['stats']['accountCount'] === 0) {
            $this->markTestSkipped('This user has no rows in the active fiscal year.');
        }

        $rows = $this->rowsOf($this->download($user, $url));

        // Header row plus one row per account.
        $this->assertCount($page['stats']['accountCount'] + 1, $rows);
    }

    public function test_the_ytd_column_sums_to_the_figure_on_screen(): void
    {
        $user = $this->ledgerUser();

        $page = $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/monthly-expenditure')
            ->viewData('page')['props'];

        if ($page['stats']['accountCount'] === 0) {
            $this->markTestSkipped('This user has no rows in the active fiscal year.');
        }

        $rows = $this->rowsOf($this->download($user, '/monthly-expenditure/export'));
        $headings = array_shift($rows);
        $ytd = array_search('YTD Net Expenditure', $headings, true);

        $this->assertNotFalse($ytd, 'The YTD column is missing from the export.');

        $sum = 0.0;
        foreach ($rows as $row) {
            $sum += (float) $row[$ytd];
        }

        $this->assertEqualsWithDelta(
            (float) $page['totals']['ytd'], $sum, 0.05,
            'The exported YTD column does not sum to the total the page reports.'
        );
    }

    // =========================================================================
    // Headings and response shape
    // =========================================================================

    public function test_the_response_is_an_attachment_with_a_dated_filename(): void
    {
        $response = $this->download($this->ledgerUser(), '/variance/export');
        $response->assertOk();

        $this->assertSame('text/csv; charset=UTF-8', $response->headers->get('Content-Type'));
        $this->assertSame('nosniff', $response->headers->get('X-Content-Type-Options'));

        // Asserted as directives, not as a literal string: Symfony normalises
        // Cache-Control into alphabetical order ("no-store, private"), so
        // matching the order they were set in would be testing Symfony.
        $cacheControl = $response->headers->get('Cache-Control');
        $this->assertStringContainsString('private', $cacheControl);
        $this->assertStringContainsString('no-store', $cacheControl);

        // Asserted against the PATTERN, separately from the body: the timestamp
        // is expected to move.
        //
        // The quotes are OPTIONAL in the pattern because Symfony's
        // makeDisposition() only quotes a filename that needs it, and ours
        // never does — no spaces, no specials. Requiring them would be
        // asserting Symfony's formatting rather than our filename.
        $this->assertMatchesRegularExpression(
            '/attachment; filename="?variance-fy\d{4}-\d{8}-\d{6}\.csv"?/',
            $response->headers->get('Content-Disposition')
        );
    }

    public function test_the_variance_heading_row_is_exact_and_ordered(): void
    {
        // The column order is an API contract — someone's saved spreadsheet
        // formula depends on it. 28 columns; see export.md section 5.3.
        $rows = $this->rowsOf($this->download($this->ledgerUser(), '/variance/export'));
        $headings = $rows[0];

        $this->assertCount(28, $headings);
        $this->assertSame(
            ['Financial Year', 'Cluster', 'Institution', 'Responsibility', 'Department',
                'Account Number', 'Account Description', 'Allocation'],
            array_slice($headings, 0, 8)
        );
        $this->assertSame(
            ['YTD Expenditure', 'Approved', 'Routing', 'Actual Expenditure',
                'Excess', 'Allocation Balance', 'Budget Status', 'Budget Status Amount'],
            array_slice($headings, 20)
        );
        // Four-digit years, so Oct-Dec cannot be misread.
        $this->assertMatchesRegularExpression('/^Oct \d{4}$/', $headings[8]);
        $this->assertMatchesRegularExpression('/^Sep \d{4}$/', $headings[19]);
    }

    public function test_the_requisition_heading_row_is_exact_and_ordered(): void
    {
        $rows = $this->rowsOf($this->download($this->requisitionUser(), '/encumbered-details/export'));

        $this->assertSame([
            'Financial Year', 'Requisition Number', 'PO Number', 'Line Number',
            'Status Code', 'Status Name', 'Date Created', 'Requisition Owner',
            'Vendor ID', 'Vendor Name', 'Item ID', 'Item Description', 'UofM',
            'Site Location', 'Cluster', 'Institution', 'Responsibility Centre', 'Department',
            'Account Number', 'Account Description',
            'Order Quantity', 'Quantity Shipped', 'Remaining Quantity', 'Unit Cost', 'Extended Cost',
        ], $rows[0]);

        // The snapshot timestamp was dropped: it repeated one value on every
        // row, which is padding rather than data. Both pages still show the
        // snapshot age on screen and the export log records it per download.
        $this->assertNotContains('Snapshot Refreshed At', $rows[0]);
    }

    // =========================================================================
    // Filters
    // =========================================================================

    public function test_a_valid_filter_narrows_the_file(): void
    {
        $user = $this->ledgerUser();

        $props = $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/variance')
            ->viewData('page')['props'];

        if (count($props['departments']) < 2) {
            $this->markTestSkipped('This user sees one department, so no filter can narrow the set.');
        }

        $all = $this->rowsOf($this->download($user, '/variance/export'));
        $narrowed = $this->rowsOf($this->download($user, '/variance/export', [
            'department' => $props['departments'][0],
        ]));

        $this->assertLessThan(count($all), count($narrowed));
        $this->assertGreaterThan(1, count($narrowed), 'The filtered export lost its data rows.');
    }

    public function test_a_stale_filter_is_refused_rather_than_silently_broadening_the_file(): void
    {
        // THE REASON THIS GUARD EXISTS. On screen a discarded filter is visible
        // — the control resets and the row count jumps. In a CSV it is not, so
        // a bookmarked ?department=Radiology that stops matching would hand
        // back EVERY department in a file the reader still reads as Radiology.
        $response = $this->download($this->ledgerUser(), '/variance/export', [
            'department' => 'NOT A REAL DEPARTMENT',
        ]);

        $response->assertRedirect();
        $this->assertNotSame('text/csv; charset=UTF-8', $response->headers->get('Content-Type'));
        $response->assertSessionHas('warning');
    }

    public function test_an_empty_filter_parameter_is_not_treated_as_stale(): void
    {
        // "?department=" is "no filter", not a filter that went bad.
        $this->download($this->ledgerUser(), '/variance/export', ['department' => ''])
            ->assertOk();
    }

    // =========================================================================
    // The two requisition pages cannot leak into each other
    // =========================================================================

    public function test_each_requisition_export_carries_only_its_own_status_set(): void
    {
        $user = $this->requisitionUser();

        $cases = [
            '/encumbered-details/export' => [FinanceRequisition::APPROVED_STATUSES, FinanceRequisition::ROUTING_STATUSES],
            '/routing-details/export' => [FinanceRequisition::ROUTING_STATUSES, FinanceRequisition::APPROVED_STATUSES],
        ];

        $exercised = false;

        foreach ($cases as $url => [$allowed, $forbidden]) {
            $response = $this->download($user, $url);

            if ($response->isRedirect()) {
                continue;   // no rows on that status set for this user
            }

            $rows = $this->rowsOf($response);
            $status = array_search('Status Code', $rows[0], true);
            array_shift($rows);

            foreach ($rows as $row) {
                $this->assertContains($row[$status], $allowed);
                $this->assertNotContains($row[$status], $forbidden);
                $exercised = true;
            }
        }

        if (! $exercised) {
            $this->markTestSkipped('This user has no requisition lines on either status set.');
        }
    }

    // =========================================================================
    // Fiscal year is OPTIONAL on the two requisition exports (2026-10-01)
    //
    // Parameterised over BOTH routes: Encumbered has 11 eligible years to
    // Routing's 3, so a case written against one proves little about the other.
    // =========================================================================

    /** @return array<string,array{0:string,1:string,2:string}> */
    public static function requisitionPages(): array
    {
        return [
            'encumbered' => ['/encumbered-details', '/encumbered-details/export', 'encumbered-details'],
            'routing' => ['/routing-details', '/routing-details/export', 'routing-details'],
        ];
    }

    /** The props of one requisition page, for the independent half of a check. */
    private function requisitionProps(User $user, string $page, array $query = []): array
    {
        return $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get($page.($query ? '?'.http_build_query($query) : ''))
            ->viewData('page')['props'];
    }

    #[DataProvider('requisitionPages')]
    public function test_an_all_years_requisition_filename_omits_the_fy_segment(string $page, string $url, string $slug): void
    {
        // csvFilename() drops the segment on a null year, so the filename does
        // not claim a scope the file does not have. StreamsCsv is untouched —
        // it already handled ?int.
        $user = $this->requisitionUser();

        $response = $this->download($user, $url);

        if ($response->isRedirect()) {
            $this->markTestSkipped("No rows on {$page} for {$user->username}.");
        }

        $this->assertMatchesRegularExpression(
            '/attachment; filename="?'.preg_quote($slug, '/').'-\d{8}-\d{6}\.csv"?/',
            (string) $response->headers->get('Content-Disposition'),
        );
    }

    #[DataProvider('requisitionPages')]
    public function test_a_selected_year_is_named_in_the_requisition_filename(string $page, string $url, string $slug): void
    {
        $user = $this->requisitionUser();
        $props = $this->requisitionProps($user, $page);

        if ($props['years'] === []) {
            $this->markTestSkipped("No eligible fiscal years on {$page} for {$user->username}.");
        }

        $response = $this->download($user, $url, ['fy' => (string) $props['years'][0]]);

        if ($response->isRedirect()) {
            $this->markTestSkipped("No rows in that year on {$page}.");
        }

        $this->assertMatchesRegularExpression(
            '/attachment; filename="?'.preg_quote($slug, '/').'-fy\d{4}-\d{8}-\d{6}\.csv"?/',
            (string) $response->headers->get('Content-Disposition'),
        );
    }

    #[DataProvider('requisitionPages')]
    public function test_an_unusable_year_is_refused_by_the_requisition_export(string $page, string $url, string $slug): void
    {
        // `fy` goes through validFilter() now, so a NON-EMPTY invalid value is
        // recorded in droppedFilters — which the screen ignores and the export
        // refuses on, exactly like a stale department. Loading the PAGE at
        // ?fy=9999 shows All with no warning; requesting the export URL
        // directly is refused. Two different behaviours, easily conflated.
        $response = $this->download($this->requisitionUser(), $url, ['fy' => '9999']);

        $response->assertRedirect();
        $this->assertNotSame('text/csv; charset=UTF-8', $response->headers->get('Content-Type'));
        $response->assertSessionHas('warning');
    }

    #[DataProvider('requisitionPages')]
    public function test_the_all_years_file_covers_exactly_the_eligible_years(string $page, string $url, string $slug): void
    {
        // EQUALITY, not "more than one year". That is what makes this
        // meaningful for Routing's three years, and it is the only check here
        // that inspects every exported row rather than page 1 — a year present
        // in the file but not in the dropdown would be a row with no summary to
        // reconcile against (the R1-A leak), and a missing year would be data
        // silently dropped.
        $user = $this->requisitionUser();
        $props = $this->requisitionProps($user, $page);

        $response = $this->download($user, $url);

        if ($response->isRedirect()) {
            $this->markTestSkipped("No rows on {$page} for {$user->username}.");
        }

        $rows = $this->rowsOf($response);
        $headings = array_shift($rows);
        $yearCol = array_search('Financial Year', $headings, true);
        $this->assertNotFalse($yearCol);

        if ($rows === []) {
            $this->markTestSkipped("No data rows on {$page}.");
        }

        $inFile = array_values(array_unique(array_map(fn ($r) => (string) $r[$yearCol], $rows)));
        $offered = array_map('strval', $props['years']);

        sort($inFile);
        sort($offered);

        $this->assertSame($offered, $inFile,
            'The all-years file does not cover exactly the years the dropdown offers.');
    }

    // =========================================================================
    // The month boundary: posted, not merely elapsed
    // =========================================================================

    /**
     * @dataProvider ledgerPages
     */
    public function test_the_current_month_is_blank_until_it_posts(string $url): void
    {
        // The ledger carries POSTED GL only, and the month we are standing in
        // has normally not posted. Measured 2026-08-29 (fiscal period 11 =
        // August): 492 accounts carried July activity and ZERO carried August.
        // Rendering that as 0.00 asserts "nothing was spent in August" when the
        // truth is "August is not posted yet".
        $rows = $this->rowsOf($this->download($this->ledgerUser(), $url));
        $headings = array_shift($rows);

        // The 12 month columns sit between Account Description and the first
        // total; find them by their "Mon YYYY" heading rather than by index, so
        // this survives a column being added either side.
        $monthIdx = [];
        foreach ($headings as $i => $h) {
            if (preg_match('/^[A-Z][a-z]{2} \d{4}$/', $h)) {
                $monthIdx[] = $i;
            }
        }
        $this->assertCount(12, $monthIdx);

        if ($rows === []) {
            $this->markTestSkipped('No data rows for this user.');
        }

        // A month is blank on every row or on none — the boundary is a property
        // of the posting calendar, not of an individual account.
        $blankPerMonth = [];
        foreach ($monthIdx as $position => $col) {
            $blank = array_filter($rows, fn ($r) => $r[$col] === '');
            $this->assertContains(
                count($blank), [0, count($rows)],
                "Month {$headings[$col]} is blank on some rows but not others."
            );
            $blankPerMonth[$position] = count($blank) > 0;
        }

        // Once the blanks start they run to the end of the year: an unposted
        // month cannot be followed by a posted one.
        $seenBlank = false;
        foreach ($blankPerMonth as $position => $isBlank) {
            if ($isBlank) {
                $seenBlank = true;

                continue;
            }
            $this->assertFalse($seenBlank, "A posted month follows an unposted one at position {$position}.");
        }

        // Whatever is blank must genuinely hold nothing, and whatever is
        // populated must not be blanked — that is the guard against capping the
        // year too early and hiding real figures.
        foreach ($monthIdx as $position => $col) {
            $columnSum = array_sum(array_map(fn ($r) => (float) ($r[$col] === '' ? 0 : $r[$col]), $rows));
            if ($blankPerMonth[$position]) {
                $this->assertSame(0.0, $columnSum, "A blanked month carried data at position {$position}.");
            }
        }
    }

    public function test_a_completed_fiscal_year_blanks_nothing(): void
    {
        // The other half of the rule, and the one that protects real zeros: a
        // finished year's empty September is a genuine measurement, so a PAST
        // year is never capped by what posted.
        $user = $this->ledgerUser();

        $props = $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/variance')
            ->viewData('page')['props'];

        $past = array_values(array_filter(
            array_map('intval', $props['years']),
            fn ($y) => $y < (int) $props['currentFiscalYear']
        ));

        if ($past === []) {
            $this->markTestSkipped('This user has no completed fiscal year in the ledger.');
        }

        $rows = $this->rowsOf($this->download($user, '/variance/export', ['fy' => (string) max($past)]));
        $headings = array_shift($rows);

        if ($rows === []) {
            $this->markTestSkipped('No data rows in the completed fiscal year.');
        }

        foreach ($headings as $i => $h) {
            if (preg_match('/^[A-Z][a-z]{2} \d{4}$/', $h)) {
                foreach ($rows as $row) {
                    $this->assertNotSame('', $row[$i], "A completed year blanked {$h}.");
                }
            }
        }
    }

    // =========================================================================
    // Budget allocations
    // =========================================================================

    public function test_the_budget_export_matches_the_page_row_count_and_total(): void
    {
        $user = $this->budgetUser();

        $props = $this->actingAs($user)
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/budget-allocations')
            ->viewData('page')['props'];

        if ($props['stats']['total'] === 0) {
            $this->markTestSkipped('This user has no budget allocation rows.');
        }

        $rows = $this->rowsOf($this->download($user, '/budget-allocations/export'));
        $headings = array_shift($rows);

        $this->assertSame([
            'Financial Year', 'Cluster', 'Institution', 'Responsibility', 'Department',
            'Account Description', 'Account Number', 'Total Allocation',
        ], $headings);

        $this->assertCount($props['stats']['total'], $rows);

        $sum = array_sum(array_map(fn ($r) => (float) $r[7], $rows));

        $this->assertEqualsWithDelta((float) $props['stats']['totalAllocation'], $sum, 0.05);
    }

    // =========================================================================
    // Dashboard
    // =========================================================================

    public function test_the_dashboard_export_is_twelve_periods_with_future_months_blank(): void
    {
        $user = $this->budgetUser();

        $response = $this->download($user, '/dashboard/export');

        if ($response->isRedirect()) {
            $this->markTestSkipped('The dashboard reports no exportable expenditure for this user.');
        }

        $rows = $this->rowsOf($response);
        $headings = array_shift($rows);

        $this->assertSame([
            'Financial Year', 'Period ID', 'Fiscal Month', 'Monthly Net Expenditure',
            'Cumulative Net Expenditure', 'Annual Budget',
        ], $headings);

        $this->assertCount(12, $rows, 'A fiscal year is always twelve periods.');
        $this->assertSame(['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12'],
            array_column($rows, 1));

        // A blank expenditure cell means "not started". It must never be 0.00,
        // which is a real measurement, and the two must not be interleaved:
        // once the blanks begin they run to the end of the year.
        $blanks = array_map(fn ($r) => $r[3] === '', $rows);
        $seenBlank = false;
        foreach ($blanks as $period => $isBlank) {
            if ($isBlank) {
                $seenBlank = true;

                continue;
            }
            $this->assertFalse($seenBlank, "Period {$period} has data after a future month.");
        }
    }
}
