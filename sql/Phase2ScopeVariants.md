# Phase 2 detail scripts — scoped vs unscoped

Two runnable variants of each Phase 2 requisition-detail script, so either behaviour can be used
deliberately. All measurements are from **production**, `KCHARLES1` / FY2026, 2026-08-26,
read-only.

| File | Scope | Status |
|---|---|---|
| `Phase2RequisitionDetail_Routing.sql` | reporting-line-3 applied | **adopted** (Decision E) |
| `Phase2RequisitionDetail_Approved.sql` | reporting-line-3 applied | **adopted** (Decision E) |
| `Phase2RequisitionDetail_Routing_NoScope.sql` | none | alternative |
| `Phase2RequisitionDetail_Approved_NoScope.sql` | none | alternative |

The four files are otherwise identical: same CTE chain, same three-way access join via
`dbo.vw_WebAppUserAccess`, same Phase 1 `ActCost` definition, same `@FinancialYear` / `@UserName`
parameters. **The only difference is two lines:**

```sql
INNER JOIN (SELECT DISTINCT AccountNumber FROM varianceLines) AS gs
       ON gs.AccountNumber = A.AccountN
```

---

## The numbers

| | Rows | Accounts | ExtendedCost (TTD) | Runtime |
|---|---|---|---|---|
| **Routing** — unscoped | 777 | 121 | 4,696,550.19 | ~9s |
| **Routing** — scoped | 773 | 120 | 4,512,250.19 | ~9s |
| *difference* | −4 | −1 | **−184,300.00** | — |
| **Approved** — unscoped | 3,452 | 147 | 48,010,834.95 | ~48s |
| **Approved** — scoped | 3,408 | 145 | 41,936,916.59 | ~47s |
| *difference* | −44 | −2 | **−6,073,918.36** | — |

The scoped figures tie **exactly** to `vw_FinanceLedger` for the same user and fiscal year:
`SUM(Routing)` = 4,512,250.19 and `SUM(Approved)` = 41,936,916.59.

> **Every figure in this file is from PRODUCTION on 2026-08-26. Dev will not reproduce them.**
> The dev instance is a restore of the 2026-08-25 backup, so it is a day behind. Run on dev the
> same day, the scoped Routing count is 777 / TTD 4,300,785.01 and scoped Approved is 3,388 /
> TTD 41,901,433.34. The filter is working in both — the 2 excluded Approved accounts and their
> TTD 6,073,918.36 are identical on dev — the totals simply differ because the data does.
> A dev run that does not match this table is not evidence of a defect. Reconcile dev against
> dev's own `vw_FinanceLedger`, never against these numbers.

Two accounts are excluded, both genuinely off the 41-code reporting-line-3 list:

- `4-80600-H01-401-0627-00-000`
- `4-81500-H01-307-0601-00-000`

(Account counts differ by presentation: 145 accounts carry AP/PO *rows*, 141 carry a *non-zero*
Approved value once over-shipped lines floor to zero. Both are correct; they count different
things.)

---

## Which to use

### Use the scoped files (recommended, and the adopted basis) when

the detail pages are **drill-downs for the summary's Approved and Routing figures** — which is
what Phase 2 is for. Without the scope, a user drilling from a summary figure into detail sees a
total larger by TTD 6,073,918.36 on Approved, with nothing on either page explaining the gap. The
excluded accounts are payroll-adjacent data the app excludes by design everywhere else; detail
would be the only surface leaking outside that boundary.

Only the scoped files can be proven correct: `Phase2ReconciliationTest.sql` compares Phase 2 to
Phase 1 per account, and the excluded accounts have no row in `vw_FinanceLedger` at all.

### Use the unscoped files when

you genuinely want **every account with requisition activity**, including those the summary
excludes — for example a procurement-side view that is not presented as a drill-down of the
finance summary, or a one-off investigation into activity outside the reported scope.

**Do not choose them for speed.** See below.

---

## Performance — the attribution, because the obvious reading is wrong

Approved, four configurations timed:

| ActCost | Scope join | Runtime | |
|---|---|---|---|
| draft | none | **0.5s** | both wrong |
| draft | applied | 46s | ActCost wrong |
| Phase 1 | none | 48s | scope wrong |
| Phase 1 | applied | **47s** | ← the adopted file |
| floor + decimal, no pre-aggregation | none | 0.5s | diagnostic only — output is incorrect |

**The scope join is not the cost.** Either correction alone pushes the query to ~47s, and
applying both adds nothing. The last row isolates it: keep the zero-floor and the decimal
conversion but drop the shipment **pre-aggregation**, and it returns to 0.5s.

So the whole ~47s is `GROUP BY PONumber, CONVERT(int, POLineID)` over
`0098FPOShipmentDetails`. That aggregate is not optional — without it a duplicated
`(PONumber, POLineID)` key fans the encumbrance line out, and Phase 1 records 65 such keys.
Phase 1 pays this once per refresh in a batch job; a live view pays it on every page load.

Ruled out by measurement, so do not re-try: `varianceLines` is 41 rows / 41 distinct accounts and
builds in 87ms alone; hoisting it into a table variable changed nothing; and a `@flag` +
`OPTION (RECOMPILE)` toggle did not restore the fast path either — which is why these are separate
files rather than one parameterised script.

Routing is ~9s in every correct configuration.

### This is now resolved — Phase 2 is snapshot-backed

**Decided 2026-08-26** (`financesqlupdateprogress.md` item 10, design in `financesqlupdatep2.md`):
Phase 2 builds `dbo.FinanceRequisitionSnapshot` in the same Agent job step as the ledger, and the
pages read the snapshot. The ~47s shipment aggregate is paid once per refresh instead of once per
page load.

**That changes what these four files are for.** In the snapshot design, scope is a stored
`IsGoodsAndServices` flag computed at build time, and the two behaviours become two read views
over one table — both free. So:

* these scripts remain the **reference queries** the snapshot is built from, and the record of the
  measurements and reasoning behind it;
* the `_NoScope` files stop being an operational choice and become the definition of the unscoped
  view;
* once Phase 2 lands, **nothing should be running these four scripts directly** in a page path.

---

## Running the reconciliation test against each

`Phase2ReconciliationTest.sql` is written against the **scoped** behaviour.

| | TEST 1 | TEST 2 |
|---|---|---|
| Scoped | **PASS** — 0 off-line-3, 213 in scope, 2 excluded | **PASS** — 0 mismatches over 831 accounts, net drift TTD 0.01 |
| Unscoped | **FAIL** — `off_reportline3` = 2 | mismatches on those accounts |

For the unscoped variants that failure is the **expected** result, not a defect — it is the
trade-off itself, made visible.

---

## Maintenance warning

The four scripts duplicate their CTE chain, access join and `ActCost` definition. **A correction
to any of those must be applied to all four**, or they silently diverge. Nothing enforces this.
If the unscoped variants stop being needed, delete them rather than let them rot — they are the
copies most likely to be missed.
