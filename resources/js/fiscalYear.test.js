import { test } from 'node:test'
import assert from 'node:assert/strict'

import { fiscalYearSpan } from './fiscalYear.js'

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
    // answer: the chip renders its own "All available fiscal years" copy
    // instead, and a span of unknown years would be a fabrication.
    for (const value of [null, undefined, '', 0, -1]) {
        assert.equal(fiscalYearSpan(value), '', `expected '' for ${String(value)}`)
    }
})

test('a malformed year renders nothing', () => {
    for (const value of ['abc', '2026x', NaN, {}, [], '20.26']) {
        assert.equal(fiscalYearSpan(value), '', `expected '' for ${String(value)}`)
    }
})
