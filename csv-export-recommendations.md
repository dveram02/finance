# CSV Export Feature Analysis

## Executive recommendation

Add server-generated, streamed CSV exports to the six current finance views. Export the complete filtered result set, never only the 25 rows visible on the current page. Reuse the same user, fiscal-year, filter-validation, and ordering logic as each screen so the CSV and on-screen totals cannot drift.

Do not add CSV export to Login, Profile, legal modals, or error pages. Those screens have no report dataset, and exporting profile data creates unnecessary personal-data handling.

The current exportable surface is:

1. Dashboard (`/dashboard`)
2. Budget Allocations (`/budget-allocations`)
3. Monthly Expenditure (`/monthly-expenditure`) — the renamed former Department Expenditure account-by-month grid
4. Variance (`/variance`) — the renamed former Allocation Line Expenditure view
5. Encumbered Details (`/encumbered-details`)
6. Routing Details (`/routing-details`)

The recommended UX is one consistent **Export CSV** button in the page header, next to the fiscal-year control. On filtered table screens its accessible label should resolve to **Export all N matching rows as CSV**. Disable it for no-access, source-unavailable, loading, and zero-result states. Preserve the active filters and fiscal year in the export request, but omit `page`.

## Why the export must be server-side

Client-side CSV generation is unsuitable here:

- Budget Allocations, Monthly Expenditure, Variance, and both requisition-detail views paginate at 25 rows. Browser export would silently export only the current page.
- Access is enforced through `forUser($username)` against SQL Server views. The server must derive scope from the authenticated session; a username must never be accepted from the request.
- CSV formula injection needs centralized handling.
- Monetary precision, dates, nulls, and fiscal-month ordering need one canonical formatter.
- Streaming avoids assembling a potentially large CSV string in browser or PHP memory.

Use a normal streamed HTTP response rather than Laravel Excel/PhpSpreadsheet. CSV does not need either package. The application deliberately runs no production queue worker, so asynchronous queued exports should not be the first implementation.

## Export contract shared by all views

### Scope

- Default meaning: **all rows matching the current fiscal year and filters**.
- Pagination is presentation state and must not affect export.
- Preserve the screen's deterministic ordering.
- Revalidate all filter values server-side exactly as the index action does. Do not trust arbitrary query values.
- A changed permission mapping must affect the next export immediately, using the existing `forUser()` scope and access probe behavior.
- Never offer or return a file when the source is unavailable or the user has no department mapping.

### CSV format

- UTF-8 with BOM for reliable Microsoft Excel handling on Windows.
- RFC 4180-compatible quoting via `fputcsv`; CRLF line endings.
- A single header row followed immediately by data. Do not place title or metadata rows above the header because that harms importability.
- Raw decimal values without `TTD`, thousands separators, or parentheses. Use two decimal places for currency and sufficient source precision for quantities/unit cost.
- ISO dates (`YYYY-MM-DD`) and ISO timestamps where included.
- Empty string for genuinely missing text; numeric zero must remain `0.00`.
- Human-readable headings, with stable ordering treated as an API contract.
- Prefix dangerous text cells beginning with `=`, `+`, `-`, `@`, tab, or carriage return with an apostrophe to prevent spreadsheet formula execution. Apply this to all user/source-controlled text, including requisition, PO, account, vendor, and description fields.

### Filename

Use a deterministic slug plus fiscal year and UTC/local export timestamp, for example:

`budget-allocations-fy2026-20260828-143501.csv`

Do not put usernames, department names, or filter values in filenames; they can expose sensitive context in downloads and become invalid/overlong.

### Response and auditability

- `Content-Type: text/csv; charset=UTF-8`
- `Content-Disposition: attachment; filename="..."`
- `Cache-Control: private, no-store`
- `X-Content-Type-Options: nosniff`
- Log completion/failure with user ID or username, view, fiscal year, validated filters, row count, and duration. Never log exported row contents.
- For snapshot-backed reports, include `Snapshot Refreshed At` as a column when traceability matters, or record it in the audit log. Repeating it per row is import-friendly and preferable to non-tabular preamble rows.

## Per-view recommendations

### 1. Dashboard

The dashboard is not a table. It combines total budget, expenditure-to-date, monthly expenditure, a cumulative budget-versus-actual series, and a top-category breakdown. A single wide or mixed-record CSV would be awkward to analyze.

Recommended behavior: make **Export CSV** a small menu with two focused datasets.

**Monthly performance CSV** (primary/default):

1. Fiscal Year
2. Period ID
3. Fiscal Month
4. Monthly Net Expenditure
5. Cumulative Net Expenditure
6. Annual Budget
7. Remaining Budget
8. Budget Used Percent

Produce all 12 fiscal periods. Future periods should have blank expenditure/cumulative fields, not zero, matching the dashboard's distinction between “not started” and real zero activity. Annual Budget may repeat on each row because this keeps the file rectangular and pivot-friendly.

**Category breakdown CSV** (secondary):

1. Fiscal Year
2. Category
3. Net Expenditure
4. Share of Net Expenditure Percent

Important: the chart currently exposes only the top categories shaped for display. The export should query the complete category breakdown rather than exporting only the chart's top-eight-plus-other presentation unless the menu explicitly says **Export chart data**. The preferred label is **Export full category breakdown**.

Do not export visual-only values such as chart colors, tooltip strings, card labels, today's date, or the progress-bar cap. Calculate from the same period totals used by the dashboard so KPI and CSV totals reconcile.

### 2. Budget Allocations

Current grain: one allocation line per fiscal year/account/access combination, filtered by cluster, institution, responsibility, department, and account.

Recommended columns, matching the visible table:

1. Financial Year
2. Cluster
3. Institution
4. Responsibility
5. Department
6. Account Description
7. Account Number
8. Total Allocation

Export all matching rows in the same order as the screen. Do not add the KPI totals as a footer row: it breaks row grain and can be double-counted by imports. Users can sum `Total Allocation`; the server should test that the exported sum equals the screen's filtered `stats.totalAllocation`.

This is the easiest and best first implementation because its current query is already SQL-filtered and server-paginated.

### 3. Monthly Expenditure

This is the renamed former Department Expenditure view at `/monthly-expenditure`. The retired per-period view that read `dbo.MonthlyExpenditure` no longer exists and must not receive an export route or implementation.

Current grain: one `dbo.vw_FinanceLedger` account row with 12 fiscal-month columns and YTD, filtered by cluster, institution, responsibility, department, and fiscal year.

Recommended default: preserve the screen's wide financial-report shape.

1. Financial Year
2. Cluster
3. Institution
4. Responsibility
5. Department
6. Account Number
7. Account Description
8. Oct
9. Nov
10. Dec
11. Jan
12. Feb
13. Mar
14. Apr
15. May
16. Jun
17. Jul
18. Aug
19. Sep
20. YTD Net Expenditure

Use fiscal labels with years in the actual headings (for example `Oct 2025`, `Jan 2026`) to prevent ambiguity. Preserve future-month semantics: blank if the UI marks the period as future; zero only where the period is in scope and activity is genuinely zero.

A long-form export (one account/month per row) is easier for BI tools but does not match the view. If analysts request it later, add it as a separately named **Export long format CSV**, not a silent change to the default schema.

### 4. Variance

This is the renamed former Allocation Line Expenditure view at `/variance`.

Current grain: one account/allocation line with allocation, 12 monthly amounts, YTD, approved, routing, actual expenditure, balance, and status. Filters are cluster, institution, department, account description, account number, and fiscal year.

Recommended columns:

1. Financial Year
2. Cluster
3. Institution
4. Responsibility
5. Department
6. Account Number
7. Account Description
8. Allocation
9. Oct through Sep with year-qualified headings
10. YTD Expenditure
11. Approved
12. Routing
13. Actual Expenditure
14. Balance
15. Budget Status

Include every identity field present in the underlying row that is required to distinguish duplicate account numbers across access dimensions—especially responsibility centre if available—even if the frozen screen columns omit it. This avoids producing apparently duplicate CSV rows.

`Actual Expenditure`, `Balance`, and `Budget Status` are derived business values. They should come from the same shared derivation functions as the page, never be reimplemented inside the exporter. Add reconciliation tests for allocation, approved, routing, actual, and balance totals.

### 5. Encumbered Details

Current grain: approved/PO requisition lines. The screen shows 17 columns but its server query reads 25 source/derived fields.

Recommended columns:

1. Financial Year
2. Requisition Number
3. PO Number
4. Status Code
5. Status Name
6. Line Number
7. Item ID
8. Item Description
9. Account Number
10. Account Description
11. Date Created
12. UofM
13. Order Quantity
14. Quantity Received
15. Remaining Quantity
16. Unit Cost
17. Extended Cost
18. Site Location
19. Cluster
20. Institution
21. Department
22. Responsibility Centre
23. Vendor ID
24. Vendor Name

Unlike the screen, the CSV should include ordered and received quantities explicitly. The UI only exposes them in a tooltip, but they explain the derived remaining quantity and make the commitment independently auditable.

Export only AP/PO status rows and apply the page's status filter within that allowed set. Include snapshot timestamp for financial traceability.

### 6. Routing Details

Use the same schema and implementation as Encumbered Details so files can be unioned safely. Restrict rows to RT/HD/PN before applying the optional status filter. PO fields will often be empty and should remain as an empty column; keeping the column preserves schema compatibility.

The filename and UI label must clearly say `routing-details`, since these amounts do not reduce allocation balance or reported expenditure. Include snapshot timestamp.

## Architecture recommendation

### Routes

Add named GET routes inside the existing `['auth', 'active.user']` group, for example:

- `dashboard.export.monthly`
- `dashboard.export.categories`
- `budget-allocations.export`
- `monthly-expenditure.export`
- `variance.export`
- `encumbered-details.export`
- `routing-details.export`

Do not add compatibility export routes for `department-expenditure` or `allocation-line-expenditure`. Those URLs and route names are deliberately retired without redirects, and exports should follow the same boundary.

GET is appropriate because exports are read-only and filter state is already expressed in query parameters. Links should use a normal browser navigation/download, not Inertia, so the response is treated as a file.

### Shared code without a service-layer detour

The controllers currently follow a flat read-only report style. Keep that shape, but extract small reusable pieces where drift would be dangerous:

- Per-view `validatedFilters()` or query-builder method used by both `index()` and `export()`.
- A small `StreamsCsv` concern/helper for headers, BOM, `fputcsv`, safe-cell handling, filename, and response headers.
- Existing fiscal-year resolvers, access scopes, cache versioning, and derivation concerns remain the source of truth.

Avoid one generic “export any model/columns” engine. These reports have different grains, derivations, future-period rules, snapshot provenance, and status restrictions; an over-generic exporter would hide business rules.

### Streaming strategy

- Budget Allocations is already SQL-filtered and server-paginated. Stream with `cursor()` or `lazyById()` only if there is a stable unique key. SQL Server views often lack a primary key, so an ordered `cursor()` is safer than inventing one.
- The current Monthly Expenditure and Variance controllers read a fiscal-year-scoped `dbo.vw_FinanceLedger` collection, validate/filter it in memory, derive totals, and then paginate it. Reuse their row derivation concerns while iterating a lazy/cursor result if the derivation is row-local. Compute no grand-total footer. Do not reintroduce the retired `App\Models\MonthlyExpenditure`/`dbo.MonthlyExpenditure` query shape for the renamed Monthly Expenditure export.
- Requisition detail: the current page intentionally loads at most a measured few thousand rows into memory, but export should not copy the paginated collection or depend on that historical maximum. Build an export iterator from the scoped SQL query and apply `deriveRequisitionRow()` per row. If filter option validation requires the full collection today, refactor validation to distinct SQL option queries or a shared allow-list before export.

Do not call the index action and scrape Inertia props. Build both responses from shared query/filter methods.

### Consistency during refresh

The source snapshots can refresh while an export streams. Capture the relevant refresh version/timestamp before opening the cursor and, after completion, compare it again. If the underlying view swap guarantees statement-level consistency, document that guarantee. Otherwise use a short read-only transaction/snapshot isolation where supported, or fail the download rather than emitting a mixed-version file.

## UX and accessibility recommendations

- Put the action in the same header location on every finance view.
- Use a download icon plus visible **Export CSV** text; do not rely on an icon alone.
- Include result scope beside or below the action: `Exports all 1,248 matching rows`.
- Disable with a visible reason for no access, no results, unavailable data, or while filters/year are reloading.
- On activation, show `Preparing CSV…` and prevent duplicate clicks. Because a native file download does not expose completion reliably, restore the button after response initiation or use a lightweight preflight/count endpoint only if needed.
- Ensure keyboard focus, a minimum practical target size, and an `aria-label` containing the row count/scope.
- Do not show a success toast merely because navigation began; only server errors can be reported reliably without a more elaborate download token flow.
- For large exports, display a warning before starting only after measurements show it is necessary. Do not add speculative confirmation friction.

## Error behavior

- Invalid/stale filters: normalize exactly as the corresponding screen does, or return 422 if silently broadening the export could expose more data than the user expected. For exports, 422 is safer than dropping an invalid filter and exporting a wider dataset.
- No access: return 403 or a small HTML error response; never an empty CSV that looks like a successful report.
- No matching rows: keep the button disabled. If the URL is called directly, return 422/404 with clear copy rather than a header-only file.
- Source failure: return 503 and log the exception. Do not return zero-filled data.
- Mid-stream failure: streaming cannot replace headers after bytes are sent. Minimize pre-stream failure risk by validating access, year, filters, snapshot availability, and initial query execution before sending the BOM. Log truncated streams.

## Testing plan

### Feature tests for every export

- Guest is redirected to login; inactive user behavior matches the rest of the app.
- Authenticated scope always comes from the session user.
- Fiscal year and every filter narrow the file exactly as the screen.
- `page` is ignored and all matching rows export.
- Header order and filename are stable.
- UTF-8/BOM, commas, quotes, newlines, nulls, leading-zero identifiers, negative values, and formula-like cells are safe.
- Empty/no-access/outage states do not return misleading successful CSV files.
- Export row count and numeric sums reconcile with screen stats/totals.
- Encumbered and Routing status sets cannot leak into one another.

### Unit tests

- CSV cell sanitizer, including formula prefixes and whitespace/control-character edge cases.
- Currency/quantity/date serialization.
- Dashboard cumulative series and future-period blanks.
- Wide month headings across the October-to-September year boundary.
- Requisition and Variance derivations reuse existing tested concerns.

## Delivery sequence

1. Build the shared CSV response helper and refactor Budget Allocation query/filter construction for reuse.
2. Ship Budget Allocations export as the reference implementation with security and reconciliation tests.
3. Add Monthly Expenditure and Variance together because they share the ledger source, wide month-axis behavior, and in-memory filtering/pagination pattern.
4. Add the shared requisition-detail export used by both Encumbered and Routing.
5. Add the dashboard's two explicit exports last, because it needs a product decision about “screen/chart data” versus complete analytical data.
6. Measure row counts, response time, SQL duration, and memory on production-like data before setting any warning threshold or considering asynchronous exports.

## Decisions to lock before implementation

Recommended defaults are shown first:

- Export scope: all filtered rows (recommended), not current page.
- Dashboard: two named CSV datasets (recommended), not a mixed-record CSV.
- Monthly Expenditure/Variance: wide screen-parity format (recommended), with long format deferred.
- Detail exports: include audit fields hidden in tooltips (recommended), not only visible columns.
- Empty results: disable action and reject direct export (recommended), not header-only CSV.
- Delivery: synchronous streamed response (recommended), not queued jobs, because production has no queue worker.

## Evidence limits

This analysis is grounded in the Laravel routes/controllers, Eloquent scopes, Vue pages/components, existing pagination/filter behavior, and repository deployment constraints. Live screenshot capture could not be completed because the required browser CLI was unavailable and Docker access was denied in the current environment. Therefore placement and accessibility recommendations are implementation guidance, not claims about visually verified behavior or WCAG compliance.
