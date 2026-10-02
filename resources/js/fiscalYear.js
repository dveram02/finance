/**
 * Fiscal-year label helpers.
 *
 * A fiscal year is named for the year it ENDS in and runs Oct (N-1) → Sep N, so
 * FY2026 is Oct 2025 – Sep 2026.
 *
 * ONE implementation, imported by both FiscalYearHero.vue (the four summary
 * pages' banner) and RequisitionDetailView.vue (the two drill-downs' read-only
 * period chip). Do not re-derive the span inside a component: two copies of the
 * Oct→Sep rule is how they drift.
 *
 * The all-years chip copy is NOT here — that is page wording, not a date span.
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
