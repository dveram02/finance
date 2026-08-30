<?php

namespace App\Concerns;

use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;

/**
 * The bits every table-page CSV export shares: filter validation that can
 * report what it rejected, and the failure redirect.
 *
 * Pulls in StreamsCsv, so a controller needs one `use` for the whole feature.
 * The Dashboard uses StreamsCsv directly instead — it has no filters, no row
 * collection and no option lists, so none of this applies to it.
 *
 * WHY EXPORTS REFUSE A STALE FILTER WHILE THE SCREEN DISCARDS IT. On a page,
 * silently dropping a filter that is no longer a valid option is safe and
 * deliberate: the user sees the dropdown snap back to "All Departments" and the
 * row count jump, so the change is self-evident. A CSV carries no such signal.
 * A bookmarked ?department=Radiology that stops matching after a rename would
 * quietly export EVERY department into a file the reader still believes is a
 * Radiology report. The export button can never generate this — it is built
 * from props.filters, which the server has already normalised — so refusing
 * costs real users nothing and only catches hand-edited URLs.
 */
trait ExportsReports
{
    use StreamsCsv;

    protected const EXPORT_UNAVAILABLE = 'The financial data source is unavailable. Please try again later.';

    protected const EXPORT_NO_ACCESS = 'Department access is not configured for your account, so there is nothing to export.';

    protected const EXPORT_STALE_FILTER = 'One or more selected filters are no longer valid. Refresh the report and try again.';

    protected const EXPORT_NO_ROWS = 'No rows match the current filters, so there is nothing to export.';

    /**
     * The requested filter value if it is a valid option in the active fiscal
     * year, otherwise null.
     *
     * A NON-EMPTY value that is not a valid option is recorded in $dropped.
     * index() ignores that list and behaves exactly as it always has; export()
     * refuses on it. An absent or empty parameter is simply "no filter" and is
     * never recorded — it is not stale, it was never set.
     *
     * @param  array<int,string>  $valid
     * @param  array<int,string>  $dropped
     */
    protected function validFilter(Request $request, string $key, array $valid, array &$dropped): ?string
    {
        $value = $request->input($key);

        // Not a string covers ?department[]=x, which would otherwise reach
        // in_array() as an array and compare false rather than throwing.
        if (! is_string($value) || $value === '') {
            return null;
        }

        if (in_array($value, $valid, true)) {
            return $value;
        }

        $dropped[] = $key;

        return null;
    }

    /**
     * Send the user back to the report they exported from, with an explanation.
     *
     * redirect()->route(), not back(): a download link carries no dependable
     * Referer, and back() would land on "/" for anyone whose browser withholds
     * it. Re-using $request->query() keeps the fiscal year and filters, so the
     * page they land on is the page they left.
     *
     * A failed export is a 302, so unlike a successful download it navigates
     * the current tab. That is the accepted cost of a friendly warning over a
     * raw 403/422/503 error page.
     */
    protected function exportRedirect(Request $request, string $indexRoute, string $message): RedirectResponse
    {
        return redirect()->route($indexRoute, $request->query())->with('warning', $message);
    }
}
