import { test } from 'node:test'
import assert from 'node:assert/strict'

import { fiscalYearSpan, fiscalYearRangeSpan } from './fiscalYear.js'

/**
 * Node's BUILT-IN test runner — `npm run test:js`, i.e. `node --test`.
 *
 * No new dependency and no config: package.json is already `"type": "module"`
 * and this machine runs Node v24. The alternative was claiming PHP feature
 * tests cover it, which is false — PHP never executes fiscalYear.js.
 *
 * This is the whole module (a pure string function with no imports), so the
 * coverage here is complete. Compilation of the two components that import it
 * is covered by `npm run build`.
 */

test('a fiscal year renders its Oct→Sep span', () => {
    assert.equal(fiscalYearSpan(2026), 'Oct 2025 – Sep 2026')
    assert.equal(fiscalYearSpan(2014), 'Oct 2013 – Sep 2014')
})

test('a numeric string is accepted — SQL returns years as strings', () => {
    assert.equal(fiscalYearSpan('2026'), 'Oct 2025 – Sep 2026')
})

test('the separator is an en dash, not a hyphen', () => {
    assert.ok(fiscalYearSpan(2026).includes('–'))
    assert.ok(!fiscalYearSpan(2026).includes('-'))
})

test('an absent year renders nothing, never "Oct NaN"', () => {
    // null/undefined/'' are the All Fiscal Years state on the two drill-downs,
    // and the outage path sends null as well. Empty string is the only safe
    // answer: the banner renders "All Years" plus fiscalYearRangeSpan() instead,
    // and a span of one unknown year would be a fabrication.
    for (const value of [null, undefined, '', 0, -1]) {
        assert.equal(fiscalYearSpan(value), '', `expected '' for ${String(value)}`)
    }
})

test('a malformed year renders nothing', () => {
    for (const value of ['abc', '2026x', NaN, {}, [], '20.26']) {
        assert.equal(fiscalYearSpan(value), '', `expected '' for ${String(value)}`)
    }
})

// ── fiscalYearRangeSpan: the "All Years" state ──────────────────────────────

test('a range spans the START of the earliest year to the END of the latest', () => {
    // The off-by-one this function exists for. FY2014 begins Oct 2013 and
    // FY2026 ends Sep 2026, so neither endpoint is the year it is named for.
    assert.equal(fiscalYearRangeSpan([2014, 2026]), 'Oct 2013 – Sep 2026')
    assert.notEqual(fiscalYearRangeSpan([2014, 2026]), 'Oct 2014 – Oct 2026')
})

test('a range is order-independent — controllers send years NEWEST FIRST', () => {
    const newestFirst = ['2026', '2025', '2024', '2023', '2022']
    assert.equal(fiscalYearRangeSpan(newestFirst), 'Oct 2021 – Sep 2026')
    assert.equal(
        fiscalYearRangeSpan([...newestFirst].reverse()),
        fiscalYearRangeSpan(newestFirst),
    )
})

test('a one-year range agrees with the single-year span', () => {
    // The banner must not contradict itself as the fiscal-year filter changes.
    for (const year of [2014, 2026, 2010]) {
        assert.equal(fiscalYearRangeSpan([year]), fiscalYearSpan(year))
    }
})

test('the two routes legitimately span different lengths', () => {
    // Encumbered offers 11 eligible years and Routing 3 — route-specific by
    // design, so the two banners are expected to disagree.
    assert.equal(fiscalYearRangeSpan(['2026', '2025', '2024']), 'Oct 2023 – Sep 2026')
})

test('an empty or unusable list renders nothing, never a fabricated range', () => {
    // During an outage `years` is empty. "Oct NaN – Sep NaN" on a financial
    // page is worse than no span at all.
    for (const value of [[], null, undefined, 'abc', {}, [null, '', 0, -1, 'abc']]) {
        assert.equal(fiscalYearRangeSpan(value), '', `expected '' for ${JSON.stringify(value) ?? String(value)}`)
    }
})

test('a range ignores unusable entries but keeps the usable ones', () => {
    assert.equal(fiscalYearRangeSpan([2026, 'abc', null, 2020]), 'Oct 2019 – Sep 2026')
})

test('the range separator is an en dash too', () => {
    assert.ok(fiscalYearRangeSpan([2014, 2026]).includes('–'))
    assert.ok(!fiscalYearRangeSpan([2014, 2026]).includes('-'))
})
