# Source scripts — provenance

Hand-written scripts supplied by the finance team. **These are the source of truth for how the
ledger is calculated**; everything in `sql/` is derived from them. Committed here so the derived
objects can be diffed against an immutable copy rather than a Downloads path.

| File | SHA-256 | Acquired | Phase |
|---|---|---|---|
| `SQL Revised Allocation Oversight F.sql` | `9f9f615854ed1ac5394b4b0da519e09d1df0cb8d665dc4d481ac8e5caef1d3ba` | 2026-08-24 | **1 — implemented** |
| `SQL Web App Workings E - Approved.sql` | `72ff150b9749e31f62a501f90cb1cbea2368aa3607102c622fa07eedccf5819d` | 2026-08-24 | 2 — not started |
| `SQL Web App Workings E - Routing.sql`  | `3e93c4937e0087ed31e4143acb7abbf0fddc332438cb90f52754022611802989` | 2026-08-24 | 2 — not started |

Supplied by the finance team, all three timestamped 2026-08-24 15:17.

## Do not run these as-is

They are working drafts and carry their own `--Needs to be filterable` markers (hardcoded
`FinancialYear = '2026'`, `EmployeeName = 'FRANCIS FIGUERA'`). They also reintroduce defects that
`sql/FinanceLedger.sql` corrects — fixed substring offsets, `FORMAT(TRXDate,'MMM')`, an
nvarchar/int join, float arithmetic, and a dropped `IsActive` filter. See `financesqlupdate.md`
for the full list and the reasoning.

## Known inconsistency between them

`SQL Revised Allocation Oversight F` joins user access on **three** columns
(Responsibility + Department + Institution). Both `Workings E` scripts join on **two**
(Responsibility + Department), and their `userAccess` CTE does not select `InstitutionID` at all.

Phase 1 implements the three-way join. **If Phase 2 ships the two-way join as written, the detail
pages will list requisitions for accounts the summary page excludes, and the two will never
reconcile.**

**Measured on production 2026-08-26** (as `KEN CHARLES` / `KCHARLES1`, FY2026, read-only). The
two-way form both over-permits and duplicates:

| Script | as written (2-way) | 3-way | Institutions |
|---|---|---|---|
| Routing | 5,949 rows / TTD 131,164,220.53 | 777 rows / TTD 4,696,550.19 | 47 → 2 |
| Approved | 30,626 rows / TTD 2,711,349,433.34 | 3,452 rows / TTD 38,080,501.68 | 48 → 2 |

The duplication is separate from the access scope: the inline `userAccess` CTE carries no
`DISTINCT`, and 32 of 128 `(Responsibility, Department)` pairs span two institutions, so every
line on them is emitted twice. Against the live summary, two-way detail references 441 accounts
(67%) the summary excludes; three-way references 2, both off reporting-line-3.

**Resolved 2026-08-26 — Phase 2 uses the corrected copies in `sql/`**:
`Phase2RequisitionDetail_Routing.sql` and `Phase2RequisitionDetail_Approved.sql`, with the inline
CTE replaced by `dbo.vw_WebAppUserAccess` joined on all three columns. The drafts in this
directory are unchanged and remain the immutable reference copies — **do not build Phase 2 from
them.** Recorded as Decision E in `financesqlupdatep2.md`.

The corrected copies also apply the reporting-line-3 goods and services scope (decided
2026-08-26) and replace the drafts' `ActCost` with the Phase 1 definition — the drafts' version is
not floored at zero, does not pre-aggregate shipments, and uses float, which put one account at
TTD −5,945,460.79 against +1,513,488.86 in the summary. `sql/Phase2ReconciliationTest.sql` guards
both and passes.
