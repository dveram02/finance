/**
 * Fiscal-year label helpers.
 *
 * A fiscal year is named for the year it ENDS in and runs Oct (N-1) → Sep N, so
 * FY2026 is Oct 2025 – Sep 2026.
 *
 * ONE implementation, imported by FiscalYearHero.vue — the banner on all six
 * pages now. Do not re-derive the span inside a component: two copies of the
 * Oct→Sep rule is how they drift.
 *
 * fiscalYearRangeSpan() is the same rule applied across a SET of years, for the
 * two drill-downs' "All Years" state. It is derived here rather than in the
 * component for exactly the reason the single-year version is, and because the
 * off-by-one is the whole difficulty: the span of FY2014–FY2026 is
 * "Oct 2013 – Sep 2026", NOT "Oct 2014 – Oct 2026" — the earliest year STARTS
 * twelve months before it is named for, and the latest ENDS in September.
 *
 * The "All Years" label itself is NOT here — that is page wording, not a span.
 *
 * Covered by fiscalYear.test.js via `node --test` (npm run test:js). PHP never
 * executes this file, so the PHPUnit suite cannot assert anything about it.
 */
export const fiscalYearSpan = (fiscalYear) => {
    const fy = Number(fiscalYear)

    // Number('') is 0 and Number(null) is 0, so the integer-and-positive test
    // covers '', null, 0 and -1 as well as 'abc' (NaN) and '2026x' (NaN).
    if (!Number.isInteger(fy) || fy <= 0) return ''

    // En dash (U+2013), matching the hero.
    return `Oct ${fy - 1} – Sep ${fy}`
}

/**
 * The calendar span covering a SET of fiscal years: the start of the earliest to
 * the end of the latest. Used for the banner's "All Years" state.
 *
 * Order-independent by design — the controllers hand `years` over NEWEST FIRST,
 * and relying on that would break silently the day a list is sorted the other
 * way. An empty or all-invalid list returns '' rather than a span built from
 * nothing: during an outage `years` is empty, and inventing a range would be a
 * fabrication on a financial page.
 *
 * A single-year list agrees with fiscalYearSpan() for that year, by
 * construction, so the banner cannot contradict itself as the filter changes.
 */
export const fiscalYearRangeSpan = (fiscalYears) => {
    if (!Array.isArray(fiscalYears)) return ''

    const valid = fiscalYears
        .map((year) => Number(year))
        .filter((year) => Number.isInteger(year) && year > 0)

    if (valid.length === 0) return ''

    // En dash (U+2013), matching fiscalYearSpan.
    return `Oct ${Math.min(...valid) - 1} – Sep ${Math.max(...valid)}`
}
