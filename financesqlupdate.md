# Phase 1 — Adopt "SQL Revised Allocation Oversight F" as the ledger source

> Revision 2. Revised after external review. Changes from revision 1 are summarised in
> [Appendix A](#appendix-a--response-to-review), including the three points where I did not adopt
> the reviewer's recommendation and why.

## Context

The production Finance Automation portal derives every page from one snapshot,
`dbo.FinanceLedgerSnapshot`, built by `dbo.fn_FinanceLedgerSource(@FY)`. That function was
written against `SQL Revised Web App.sql` (kept in the repo root) with nine documented
corrections.

The finance team has revised the source query. The new version is **now the source of truth** for
how the ledger is calculated. It changes three things materially — where the chart of accounts
comes from, how encumbrance cost is measured, and how allocation balance is measured — and
narrows user access by institution.

Two companion scripts (`SQL Web App Workings E - Approved.sql`, `... - Routing.sql`) are
**Phase 2** — requisition-line detail views built on an `encumberanceDetails` CTE. They remain
out of scope for the Phase 1 cutover, but **their access join is no longer an open question**:
as of 2026-08-26 Phase 2 builds on the corrected copies in `sql/`, not on the drafts. See
*Phase 2 — adopted basis*. The `ActCost` definition settled in Phase 1 must be reused verbatim.

**Intended outcome:** `fn_FinanceLedgerSource` and `vw_FinanceLedger` reproduce the new script's
numbers, the app renders them honestly, and the ledger stops touching the linked server.

### Step 0 — Version-control the source before anything else

The script currently lives only at a Downloads path, which is not a durable reference.

```powershell
New-Item -ItemType Directory -Force -Path 'sql/source'
Copy-Item -LiteralPath 'C:\Users\bharathramkissoon\Downloads\Finance App\SQL Revised Allocation Oversight F (1).sql' `
          -Destination 'sql/source/SQL Revised Allocation Oversight F.sql'
Get-FileHash -Algorithm SHA256 -LiteralPath 'sql/source/SQL Revised Allocation Oversight F.sql'
```

Record in the file header: acquisition date, SHA-256, and who supplied it. Every reference in
this plan and in `CLAUDE.md` points at the committed copy, never the Downloads path.

---

## What actually changed

Diffed against the current `sql/FinanceLedger.sql`, not against the old root script.

### Adopt — genuine new behaviour

| # | Change | Impact |
|---|---|---|
| **A** | **COA moves off the linked server.** `coaData` reads local `[dbo].[0030ADGPCOA]` (AccountSegment1–7, AccountNumber, ResponsibilityName, Cluster, InstitutionName, DepartmentName) LEFT JOIN `[0030AEAccountNameCorrections]` on `AccountSegment2 = AccountNumber`. | Drops `GL40200`, `DBA_Clusters`, `0000CSegmentControls` and the whole `segName`/`clusterLookup` chain. **Also retires the Agent job's linked-server gate** — see below. Account descriptions become the finance team's curated names. |
| **B** | **Encumbrance nets off shipped quantity.** `ActCost = (Quantity − QtyShipped) × UnitCost` via `[0098FPOShipmentDetails]` on `LineNbr = POLineID AND PONumber = PONumber`, replacing raw `ExtendedCost`. | `Approved` and `Routing` fall — a received PO line is no longer double-counted against the GL actual that replaced it. |
| **C** | **Balance maths changes.** `AcutalYTDExpense = YTDTotal + Approved`; excess and balance measured against **`YTDTotal` alone**. Routing displayed, deducts nothing. | Contradicts the current documented rule. See *Decisions*. |
| **D** | **Access join gains InstitutionID.** | Narrows visibility. **Risk accepted knowingly — see below.** |
| **E** | **Phase 2 adopts the three-way access join** (decided 2026-08-26). The two `Workings E` drafts join on two columns; corrected copies in `sql/Phase2RequisitionDetail_*.sql` join on three via `dbo.vw_WebAppUserAccess`. | Brings the detail views into line with Phase 1. Measured: removes a 71x overstatement on Approved and reconciles detail to summary. See *Phase 2 — adopted basis*. |

**Unplanned upside from (A):** `sql/FinanceLedgerAgentJob.sql` Section 2 is a hard deployment gate
on linked-server login mapping, justified at line 62 by `fn_FinanceLedgerSource` reading GL40200
and DBA_Clusters, and described at line 11 as "the one failure this hits." Once (A) lands, the
ledger refresh has **no linked-server dependency at all**, that gate becomes obsolete, and a
recurring class of production failure disappears. This must be reflected in the job script and the
runbooks, or the next operator will chase a gate that no longer guards anything.

### Reject — regressions against corrections already in production

The new script is written in the same loose style as the original and reintroduces defects that
`sql/FinanceLedger.sql` corrected. **Do not port these:**

- `substring(AccountNumber, 3,5)/(9,3)/(13,3)/(17,4)` — keep the `CHARINDEX` splitter. 15 rows of
  6.38M are 26 chars, not 27; fixed offsets slide and file spend into the **wrong department**.
- `FORMAT(TRXDate,'MMM')` + `PIVOT` — keep `MONTH()` conditional `SUM`. `FORMAT` is
  culture-dependent and yields silent zeros under a non-English session language.
- `FinYear` int vs `FinancialYear` nvarchar — keep the sargable `DATEFROMPARTS` bounds.
- Float arithmetic — keep `CONVERT(decimal(19,4), …)` before aggregating.
- Driving access off the chart of accounts — keep it in `vw_FinanceLedger`, off the user-agnostic
  snapshot. The account base stays the UNION of GL + allocation + encumbrance accounts; this is
  what keeps the 1,117 allocation-only accounts (TTD 21.1M, FY2026) in the ledger.
- **`userAccess` drops the `0006A.IsActive = 'TRUE'` filter** — the new script filters only
  `B.DepartmentID IS NOT NULL` and a hardcoded employee name. Treat as a draft slip; **keep both
  `IsActive` filters**. Dropping them grants deactivated accounts data access.
- Hardcoded `FinancialYear = '2026'` / `EmployeeName = 'FRANCIS FIGUERA'` — these carry the
  script's own `--Needs to be filterable` markers.

### Not needed

`AccountID`, `LineID` from `0030ADGPCOA`, and the unused `encumberanceDetails` CTE (Phase 2).

---

## Decisions taken (confirmed with the user)

**Balance rule (C) — implement the new script exactly as written:**

```
ActualExpenditure = YTDTotal + Approved
Excess            = MAX(0, YTDTotal - Allocation)
AllocationBalance = MAX(0, Allocation - YTDTotal)
Routing           = carried and displayed, deducted from nothing
```

**Access (D):** add InstitutionID. **CONFIRMED PRESENT and 100%% populated** on current production
data (2026-08-25). It is not a visibility preference but an over-permissive access fix — measured at
TTD 99.1M of allocation currently visible to a user who was never granted it. See below.
**COA (A):** adopt; remove the linked server from the ledger source entirely.
**Encumbrance (B):** pre-aggregate shipments and floor the balance at zero.

### Consequence that must be communicated, not discovered

Under the new rule `Excess` means *GL spend alone exceeds allocation*. Approved and Routing no
longer push a line over. **The "over" count on the Allocation Line Expenditure page will fall,
possibly to zero**, and both `AllocationBalance` and the Balance KPI will rise. That is the
intended effect of the change, but to a user it looks like overspending vanished overnight.
Capture the before/after `exceededCount` per user in the deployment reconciliation (step 7) and
tell the finance team the number before they notice it themselves.

---

## Probe results — VERIFIED on the 2026-08-25 production backup

Re-run 2026-08-25 against the current production backups (restore history: all three databases
restored 10:27–10:33 today). The ledger objects are present and the snapshot is populated —
22,324 rows, FY2014–2026, FY2026 last refreshed 2026-08-24 21:38 — so this is **post-rollout
production**, one day old.

**Every ✅ below was identical across three independent snapshots** (May replica, 2026-07-31,
2026-08-25). These are stable properties of the data, not artifacts.

| Probe | Result | Verdict |
|---|---|---|
| **P1** COA grain | 9,463 rows / 9,463 distinct accounts | ✅ clean |
| **P2** Correction grain | 190 rows / 168 accounts, **0 conflicting descriptions** | ✅ `DISTINCT` collapses safely |
| **P3** COA name columns | all four exist, **0 NULL/blank of 9,463** | ✅ **step 2a viable** |
| **P4** Shipment grain | 65 multi-row PO lines of 250,897; none touch a live encumbrance row | ✅ resolved |
| **varchar hazard** | `QTYShipped` / `POLineID` varchar; **0 non-numeric** of 250,897 | ⚠️ fail-closed `TRY_CONVERT` guard mandatory |
| **P5** Encumbrance hygiene | 104,643 rows, 0 NULL/negative `Quantity`/`UnitCost` | ✅ clean |
| **P6** Over-shipped | 4,365 lines, TTD 118,656,213.96 floored | ⚠️ zero floor load-bearing |
| **P7** `InstitutionID` | **EXISTS on `0006CWebAppPostControls`, 160/160 populated** | ✅ **RESOLVED — see below** |
| **P8** Access | `0006A`: 3 users. `0006C`: **160 rows, all active, all PositionID 10038** | ⚠️ **completely changed** |
| **CHECK 7** varianceLines | 41 rows / 41 distinct accounts | ✅ cannot fan out |

**P9 remains a required production preflight:** anti-join every normalized active
`(UserName, InstitutionID, ResponsibilityID, DepartmentID)` grant to the current snapshot and list
grants matching no ledger combination. Also list active users with no active grant separately;
those users are an access-administration state, not proof that the new join failed. Record the P9
result alongside the per-user before/after reconciliation.

### Money impact — FY2026, whole table, unscoped

| Figure | Old (`ExtendedCost`) | New (netted `ActCost`) | Change |
|---|---|---|---|
| Approved | 1,307,659,013.55 | 1,288,452,730.24 | **−19,206,283.31 (−1.47%)** |
| Routing | 125,619,041.88 | 125,619,041.88 | unchanged |

Routing is untouched because RT/HD/PN are pre-PO statuses with no shipments — a good sanity signal.
`ExtendedCost = Quantity × UnitCost` for all 104,643 rows, and `Received` is **0 on every row**
while `Remaining` is stale: the table's own receipt tracking is dead, which is exactly why the
shipment join is needed. **Decision (B) is justified independently of the script.**

### The shipment gate — resolved

P4 returned 65, which would normally stop the work. It does not: none of those PO lines has an open
requisition, so additive-vs-cumulative cannot move a dollar. `POLNENUM` (GP's real line sequence)
differs while `POLineID` collides, so these are **distinct PO lines flattening onto one
`POLineID`**, not partial shipments. Pre-aggregation is safe for the current intersecting data,
but the permanent 4d guard must abort if a future open encumbrance touches a collision. At that
point establish a genuinely unique key involving `POLNENUM`; do not sum distinct lines together.

### Defect found by probing — neither review caught it

`QTYShipped` and `POLineID` are **`varchar`**; `LineNbr` is `int`. The draft's join is an implicit
conversion and `SUM(CONVERT(decimal, QTYShipped))` parses text. Every value converts cleanly today,
but `CONVERT` on one future non-numeric value **throws and aborts the nightly refresh**. Use
a fail-closed `TRY_CONVERT` validation guard (step 4d), followed by normal `CONVERT` in the source.
Both reviews reasoned about the join's semantics; neither checked types.

---

## Decision D — RESOLVED, and bigger than "narrowing visibility"

**`InstitutionID` exists on `0006CWebAppPostControls` and is populated on all 160 rows** (114 `H01`,
46 `H03`, zero blank or NULL). It was added between 2026-07-31 and 2026-08-25 — the earlier absence
was schema drift, exactly as predicted. Decision D is unblocked and testable locally.

### What it actually fixes

This is **not** a visibility preference. The current two-way join grants a user any snapshot row
matching their `(ResponsibilityID, DepartmentID)` pair **in any institution** — and department codes
repeat across institutions. Measured on current production data:

- **32 of 128** active `(Responsibility, Department)` pairs span more than one institution.
- The snapshot carries **50 distinct institutions**.

So today a user sees financial data for departments in institutions they were never granted. That is
an over-permissive access-control defect, and it is almost certainly **why the finance team added
the column**.

### Measured impact — FY2026, `KCHARLES1` (the only user with any access)

| | 2-way (production today) | 3-way (proposed) | Change |
|---|---|---|---|
| Rows | 2,070 | 831 | **−1,239 (−60%)** |
| Allocation | 227,404,246.21 | 128,258,284.14 | **−99,145,962.07 (−43.6%)** |
| YTD | 229,419,981.95 | 139,994,304.59 | **−89,425,677.36 (−39.0%)** |

**Read the direction carefully.** The 3-way figures are not a loss of legitimate visibility — they
are the removal of TTD 99.1M of allocation the user should never have been able to see. Page totals
drop by roughly 44%, and that is the change being *correct*, not *damaging*. Tell the finance team
the number before they see it, and frame it as a confidentiality fix, not a reduction in scope.

**This retires the earlier rollback trigger** "an active user's accessible account count drops to
zero" as written: a large drop is now the expected outcome. Only a drop to **zero** still signals
failure.

### Consequence for `vw_WebAppUserAccess` — now load-bearing, not theoretical

With `InstitutionID` present, `(UserName, ResponsibilityID, DepartmentID)` is **no longer unique** in
the source: 32 pairs now appear twice, differing only by institution. The current view's `DISTINCT`
on the triple silently collapses them. Extending `DISTINCT` to the 4-tuple (step 1) is therefore
**mandatory, not tidy** — without it, adding `InstitutionID` to the join fans those 32 pairs out and
**doubles every money figure on them**. This is the exact hazard `CLAUDE.md` warns about, and it has
just become live.

---

## The user base has changed completely — this breaks assumptions across the repo

`0006C` no longer resembles anything documented. Current production:

| | Documented (`CLAUDE.md`, 2026-08-06) | Current (2026-08-25) |
|---|---|---|
| `0006A` users | 2 | **3** — `SBHIM1`, `FFIGUERA1`, `KCHARLES1` |
| `0006C` rows | 6, all PositionID 10108 | **160, all active, all PositionID 10038** |
| User with access | `FFIGUERA1` (3 mappings) | **`KCHARLES1` (160 mappings)** |
| `FFIGUERA1` | the only user who could see anything | **now has NO mappings — sees nothing** |

Consequences for implementation:

- **`CLAUDE.md` is materially wrong.** "As of 2026-08-06 only PositionID 10108 (FFIGUERA1) is
  mapped" would send the next session diagnosing the wrong user entirely. Update it, and date it.
- **Every reconciliation query in this plan must target `KCHARLES1`.** Run as written against
  `FFIGUERA1` they now return zero rows and look like a broken build.
- **The test concern resolves the user dynamically** — `UsesLedgerData` finds a `UserName` that has
  rows in `vw_FinanceLedger`, so it adapts on its own. Do **not** hardcode a username to "fix" it.
- **The access surface grew ~50x** (3 mappings to 160). Pages that were near-empty for the
  documented user now return real volume, so pagination, totals and performance get exercised for
  the first time — a genuine chance to catch what an almost-empty dataset was hiding.
- **The script's `EmployeeName = 'FRANCIS FIGUERA'` filter is a dead end today.** It is one of the
  `--Needs to be filterable` markers and becomes the live `UserName` join, but do not use it to
  hand-check the script: it returns nothing.

---

## Rollback record — preserve until the release is accepted

The original behavior must remain recoverable:

```sql
-- Original balance rule in dbo.vw_FinanceLedger
s.YTDTotal + s.Approved + s.Routing AS ActualExpenditure,
CASE WHEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing) < 0
     THEN ABS(s.Allocation - (s.YTDTotal + s.Approved + s.Routing))
     ELSE CONVERT(decimal(19,4), 0) END AS Excess,
CASE WHEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing) > 0
     THEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing)
     ELSE CONVERT(decimal(19,4), 0) END AS AllocationBalance;

-- Original access predicate
ua.ResponsibilityID = s.ResponsibilityID
AND ua.DepartmentID = s.DepartmentID;
```

Original encumbrance is `SUM(CONVERT(decimal(19,4), ExtendedCost))`, with no shipment join.

Create `sql/FinanceLedgerOversightBackup.sql` and `sql/FinanceLedgerOversightRestore.sql`; do not
leave rollback as manual notes. The backup script must:

- abort if `FinanceLedgerSnapshot_PreOversight` or `FinanceLedgerRefresh_PreOversight` already
  exists, so an earlier good backup cannot be overwritten;
- copy both tables and verify source/backup row counts and per-FY Allocation/YTD checksums;
- script the function, both views, both refresh procedures, and the installed SQL Agent job into
  versioned files under `sql/backup/`; and
- record the application commit/build identifier and backup timestamp.

The restore script must run with `SET XACT_ABORT ON`, use explicit column lists, and restore the
snapshot and refresh metadata transactionally. Restore only the column intersection for
`FinanceLedgerRefresh`, because the pre-change backup lacks the new additive metrics. Reapply the
old function, procedures and the two mutually compatible old views, restore the old Agent job and
application artifact, clear the application cache, and verify `ledger:status` plus per-FY
checksums. Additive metadata columns may remain nullable; dropping them is a separate DDL change.

Never use `sql/FinanceLedgerRollback.sql` for this release: it tears down the ledger subsystem.

Rollback triggers, agreed with the release owner before deployment:

- any user with at least one active four-part grant has zero matching ledger rows;
- Allocation, YTD or account count changes outside the documented reference-query differences;
- Approved/Routing movement cannot be reconciled account-by-account to shipped quantity;
- duplicated user/account rows appear after the access cutover;
- label coverage exceeds the measured staging threshold; or
- the new views/application fail smoke tests and cannot be corrected within the release period.

Large reductions from the old two-way access totals are **not** by themselves rollback triggers;
the measured KCHARLES1 reduction is the intended confidentiality correction.

**Release/rollback owner:** assign a named person before step 1 of deployment.

---

## Implementation

### Step 1 — `sql/FinanceLedger.sql`: access view

**`dbo.vw_WebAppUserAccess`:**

- Add `UPPER(LTRIM(RTRIM(P.InstitutionID))) COLLATE Latin1_General_CI_AS AS InstitutionID`.
- Extend `DISTINCT` to the 4-tuple `(UserName, ResponsibilityID, DepartmentID, InstitutionID)`.
  The existing comment explaining why DISTINCT covers the full tuple — a user holding two positions
  mapping to the same department would otherwise double every money figure — stays correct and must
  be updated to name four columns, not three.
- Guard with `NULLIF(LTRIM(RTRIM(P.InstitutionID)), '') IS NOT NULL`, **not** `IS NOT NULL`. A blank
  string passes the weaker test and then matches nothing, producing an empty app with no error.
  Apply the same tightening to the existing Responsibility/Department guards — worth doing on its
  own merit regardless of D.
- **Keep** `U.IsActive = 'TRUE' AND P.IsActive = 'TRUE'`.

*After the three-way ledger predicate is installed*, widening DISTINCT cannot fan out the join. A user with two positions sharing
(Resp, Dept) but differing in Institution previously collapsed to one access row matching both
institutions' rows once each; now there are two access rows, each matching its own institution's
rows once. Same row count either way. **Before that predicate is installed, however, the widened
access view joined on only Resp/Dept duplicates those rows. Therefore the access view and
`vw_FinanceLedger` must cut over in the same transaction; never deploy the access view in the
prepare phase.**

Develop and rehearse this against the same-day production backup that contains `InstitutionID`.
If the live-production preflight unexpectedly shows the column absent, stop the release; do not
silently fall back to the known-over-permissive two-way access rule.

### Step 2 — `sql/FinanceLedger.sql`: `fn_FinanceLedgerSource`

**2a. Replace the segment-name chain with `coaData`.** Delete `segControl`, `segGP`, `segName`,
`clusterLookup` and their five joins. Add:

```sql
corrections AS (
    -- Grain enforced by the refresh proc (step 4a) AND collapsed here, so a
    -- duplicate row cannot multiply money even if the guard is ever bypassed.
    -- Measured 2026-08-24: 190 rows / 168 accounts - duplicates DO exist, but
    -- every duplicate set agrees on the description, so this collapses cleanly.
    -- The IsDuplicate column is present but unused (0 rows flagged); do NOT
    -- treat it as a tie-break without confirming with the finance team.
    SELECT UPPER(LTRIM(RTRIM(AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountSeg,
           MIN(COALESCE(NULLIF(LTRIM(RTRIM(EditedAccountDescription)), ''),
                        NULLIF(LTRIM(RTRIM(AccountDescription)), ''))) AS CorrectedDescription
    FROM [FinanceAutomationSystem].[dbo].[0030AEAccountNameCorrections]
    GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
),
coaData AS (
    -- Sentinels are normalised to NULL HERE so the final ISNULL(...,'UNDEFINED')
    -- is the single place a missing label is named. Measured 2026-08-25:
    -- 24 DepartmentName and 1 ResponsibilityName carry REMOVE/UNDEFINED;
    -- InstitutionName and Cluster carry none.
    SELECT UPPER(LTRIM(RTRIM(c.AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
           NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.Cluster)), ''),            'REMOVE'), 'UNDEFINED') AS ClusterName,
           NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.InstitutionName)), ''),    'REMOVE'), 'UNDEFINED') AS InstitutionName,
           NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.ResponsibilityName)), ''), 'REMOVE'), 'UNDEFINED') AS ResponsibilityName,
           NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.DepartmentName)), ''),     'REMOVE'), 'UNDEFINED') AS DepartmentName,
           -- 100%% populated (9,463/9,463, measured) - the last-resort name for an
           -- allocation-only account that has neither a correction nor GL activity.
           NULLIF(LTRIM(RTRIM(c.AccountDescription)), '') AS CoaAccountDescription
    FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA] AS c
)
```

The `MIN` is a **defence-in-depth collapse, not a business rule**. The business rule is that P2
returns zero and the refresh proc aborts if it does not. If P2 ever returns non-zero, the fix is
to clean the source or agree a deterministic tie-break (effective date / correction ID) with the
finance team — not to let `MIN` silently pick one.

**Join both LEFT, explicitly**, and on the normalised account number:

```sql
LEFT JOIN coaData     AS c  ON c.AccountNumber = b.AccountNumber
LEFT JOIN corrections AS cr ON cr.AccountSeg   = seg.AccountSeg
```

A LEFT join is load-bearing: a missing COA row must cost a *label*, never a row and never money.
This is correction (b) and it is what protects the allocation-only accounts.

**2b. Label contract — implement exactly this chain, no other:**

| Column | Resolution order |
|---|---|
| `AccountDescription` | non-blank correction → non-blank GL master description → non-blank COA `AccountDescription` → `'UNDEFINED'` |
| `ClusterName`, `InstitutionName`, `ResponsibilityName`, `DepartmentName` | non-blank COA value → `'UNDEFINED'` |

Blank and whitespace-only are normalised to NULL by the `NULLIF(LTRIM(RTRIM(…)),'')` above and
therefore fall through. Sentinel normalisation happens in `coaData` (above), not here, so `ISNULL(..., 'UNDEFINED')` in the
final SELECT remains the single place a missing label is named.
Keep every `CONVERT(nvarchar(255), …)` wrapper: the snapshot column types
must not drift, and the proc's drift guard compares **names only**, so a type change would pass
unnoticed and be implicitly converted on INSERT.

**Keep the `CROSS APPLY` splitter.** Segments still come from the account *number*, never from
`coaData`, so an account missing from the COA mirror still resolves to the right department.

**2c. Rewrite `encumbranceData`.** P4 returned 65 duplicate `(PONumber, POLineID)` keys. They are
distinct GP lines colliding on an insufficient key, not partial shipments. None intersects a live
encumbrance today, but summing them is **not** a generally safe structural guard. Add permanent
refresh guards before this CTE that:

1. abort if `POLineID` or `QTYShipped` is NULL/blank or cannot be converted; and
2. abort if a duplicate converted `(PONumber, POLineID)` shipment key intersects an in-scope open
   encumbrance for `@FinancialYear`.

The second condition prevents a future ambiguous PO line from silently combining shipments from
different GP lines. The durable fix, if it ever fires, is to establish the correct unique key
(likely involving `POLNENUM`) with finance/GP and update both sides of the join. Do not continue by
blindly summing the collision.

```sql
-- QTYShipped and POLineID are varchar (measured). The permanent pre-guard above
-- validates them first; CONVERT then fails closed if data changes between the guard
-- and this read. Never turn malformed financial data into a zero or silently drop it.
encumbranceShipped AS (
    SELECT PONumber,
           CONVERT(int, POLineID) AS POLineID,
           SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
    FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
    GROUP BY PONumber, CONVERT(int, POLineID)
),
encumbranceData AS (
    SELECT
        UPPER(LTRIM(RTRIM(e.GLAccount))) COLLATE Latin1_General_CI_AS AS AccountNumber,
        CONVERT(decimal(19,4), SUM(CASE WHEN e.Status IN ('AP','PO')      THEN a.ActCost ELSE 0 END)) AS Approved,
        CONVERT(decimal(19,4), SUM(CASE WHEN e.Status IN ('RT','HD','PN') THEN a.ActCost ELSE 0 END)) AS Routing
    FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS e
    LEFT JOIN encumbranceShipped AS s
           ON s.PONumber = e.PONumber AND s.POLineID = e.LineNbr
    -- NULL Quantity/UnitCost would make ActCost NULL, which SUM ignores: a silent
    -- understatement rather than an error. ISNULL makes it an explicit zero.
    CROSS APPLY (SELECT CASE WHEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0) > 0
                             THEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0)
                             ELSE CONVERT(decimal(19,4), 0) END AS ActBalance) AS b
    CROSS APPLY (SELECT CONVERT(decimal(19,4),
                     b.ActBalance * CONVERT(decimal(19,4), ISNULL(e.UnitCost, 0))) AS ActCost) AS a
    WHERE e.Status IN ('AP','PO','RT','HD','PN')
      AND e.GLAccount IS NOT NULL
      AND e.ReqDateCreated >= DATEFROMPARTS(CONVERT(int, @FinancialYear) - 1, 10, 1)
      AND e.ReqDateCreated <  DATEFROMPARTS(CONVERT(int, @FinancialYear),     10, 1)
    GROUP BY UPPER(LTRIM(RTRIM(e.GLAccount)))
)
```

The explicit `CONVERT(decimal(19,4), …)` on `ActCost` matters: `decimal(19,4) × decimal(19,4)`
infers `decimal(38,8)`, and letting that propagate changes the function's inferred return type
while the name-only drift guard stays silent. Phase 2's detail views must reuse this `ActCost`
expression verbatim.

**2d. Rewrite the header comment block.** Correction (c) and the "Naming" paragraph are now wrong
— GL40200 / DBA_Clusters / 0000CSegmentControls are gone and the linked server is not read at
all. Name the committed source script and its SHA-256. Mark the measured timings stale pending
step 8.

### Step 3 — `sql/FinanceLedger.sql`: `vw_FinanceLedger`

```sql
CONVERT(decimal(19,4), s.YTDTotal + s.Approved) AS ActualExpenditure,
CASE WHEN s.YTDTotal > s.Allocation THEN s.YTDTotal - s.Allocation
     ELSE CONVERT(decimal(19,4), 0) END AS Excess,
CASE WHEN s.Allocation > s.YTDTotal THEN s.Allocation - s.YTDTotal
     ELSE CONVERT(decimal(19,4), 0) END AS AllocationBalance
```

…and add `AND ua.InstitutionID = s.InstitutionID` to the access join.

**Keep the app-side column names** (`ActualExpenditure`, `Excess`, `AllocationBalance`) rather
than the script's `AcutalYTDExpense` / `ExcessTotals` / `TrueBalanceOfAllocation` — only the
*definitions* change, so no PHP or Vue rename cascades, and the typo in "Acutal" is not
propagated into production. Document the mapping in the view's comment block so the next reader
can line the two up.

### Step 4 — `usp_RefreshFinanceLedgerSnapshot`: new gates

The existing gates measure `TotalAllocation` and `TotalYTD`, neither of which this change moves.
They will not catch the two ways this change can fail silently. Add, alongside the schema-drift
guard:

**4a. Source-grain guards — abort before building** (the P1/P2 conditions, enforced permanently):

```sql
IF EXISTS (SELECT 1 FROM dbo.[0030ADGPCOA]
           GROUP BY UPPER(LTRIM(RTRIM(AccountNumber))) HAVING COUNT(*) > 1)
    THROW 51004, 'Refresh aborted: 0030ADGPCOA has duplicate account numbers; the COA join would multiply every money column.', 1;

IF EXISTS (SELECT 1 FROM dbo.[0030AEAccountNameCorrections]
           GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
           HAVING COUNT(DISTINCT UPPER(COALESCE(NULLIF(LTRIM(RTRIM(EditedAccountDescription)), ''),
                                                 NULLIF(LTRIM(RTRIM(AccountDescription)), '')))) > 1)
    THROW 51005, 'Refresh aborted: 0030AEAccountNameCorrections holds conflicting descriptions for one account segment. Resolve in the source or agree a tie-break rule.', 1;
```

**4b. Label-coverage gate.** If `0030ADGPCOA` is stale, truncated or repointed, every name becomes
`'UNDEFINED'` and **no money gate would notice** — the figures stay perfect while the page turns
into a wall of UNDEFINED. Compute the UNDEFINED share of `DepartmentName` in staging and abort
above a threshold. **P3 measured the baseline at 0% NULL/blank across all 9,463 COA rows**, so set
the threshold at **2%** — comfortably above the 24 rows carrying a `REMOVE`/`UNDEFINED` sentinel
(0.25%), and far below anything that would indicate a stale or truncated mirror. Honours `@Force`.

Before fixing 2% in code, run the hardened source for every fiscal year and measure the percentage
on the **staging result**, not the whole 9,463-row COA table. Missing full-account joins and the
41-account reporting filter can produce a different baseline. Set 2% only if every current year
passes with headroom; otherwise document a measured threshold that still detects a broken mirror.

**4c. Encumbrance zero-collapse gate.** Do **not** add a percentage-movement gate on
`Approved`/`Routing` — this change is *designed* to move them, and a 25% gate would abort every
refresh from now on. Instead catch only the pathological case: previous load had materially
non-zero `Approved` and this load has exactly zero (the encumbrance or shipment table joined
away entirely). Honours `@Force`.

**4d. Shipment conversion and key-ambiguity guards — never bypassed by `@Force`.** Before reading
the function, throw if any `POLineID`/`QTYShipped` is NULL/blank or fails `TRY_CONVERT`. Also throw if an
in-scope active encumbrance joins a shipment `(PONumber, TRY_CONVERT(int, POLineID))` group having
`COUNT(*) > 1`. These are correctness failures, not legitimate financial movements, so `@Force`
must not suppress them. Include the affected PO/line count in the error message or a preceding
diagnostic result.

To support 4b/4c, add `TotalApproved`, `TotalRouting` and `UndefinedLabelPct` columns to
`dbo.FinanceLedgerRefresh` (an additive `ALTER TABLE`; the app reads only `MAX(RefreshedAt)` and
`Outcome`, so nothing downstream is affected).

Make that DDL idempotent with `COL_LENGTH` checks, define types/default/nullability, and update
both the `WHEN MATCHED` and `WHEN NOT MATCHED` branches of every refresh-metadata `MERGE` to write
the three values. Extend the refresh-status verification query to display them. Without these
details the columns exist but the proposed gates have no durable baseline.

**Expect `@Force` to be unnecessary on first deployment** — rows, Allocation and YTD are all
unchanged by this work. If a gate does fire, that is information: investigate it, do not
reflexively re-run with `@Force = 1`.

### Step 5 — Indexes: measure, then decide

Both snapshot indexes lead `(FinancialYear, ResponsibilityID, DepartmentID, AccountNumber)`, and
the access predicate now has a fourth column. **I do not recommend reordering them by default**
— reasoning in [Appendix A, point 4](#4-index-reordering--partially-adopted). Instead, after the
refresh, capture the actual plan:

```sql
SET STATISTICS IO, TIME ON;
WITH proposed_access AS (
    SELECT DISTINCT
        LTRIM(RTRIM(U.UserName)) AS UserName,
        UPPER(LTRIM(RTRIM(P.InstitutionID)))    COLLATE Latin1_General_CI_AS AS InstitutionID,
        UPPER(LTRIM(RTRIM(P.ResponsibilityID))) COLLATE Latin1_General_CI_AS AS ResponsibilityID,
        UPPER(LTRIM(RTRIM(P.DepartmentID)))     COLLATE Latin1_General_CI_AS AS DepartmentID
    FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS U
    INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS P
            ON P.PositionID = U.PositionID
    WHERE U.IsActive = 'TRUE' AND P.IsActive = 'TRUE'
)
SELECT s.*
FROM dbo.FinanceLedgerSnapshot AS s
INNER JOIN proposed_access AS ua
        ON ua.InstitutionID = s.InstitutionID
       AND ua.ResponsibilityID = s.ResponsibilityID
       AND ua.DepartmentID = s.DepartmentID
WHERE s.FinancialYear = '2026' AND ua.UserName = 'KCHARLES1';
```

Measure this direct proposed shape because `vw_FinanceLedger` deliberately remains on the old
two-way access predicate until cutover; benchmarking that live view would answer the wrong index
question.

Reorder **only if** the plan shows InstitutionID as a residual predicate discarding a material
number of rows. If it does, both live and staging indexes must change together, idempotently:

```sql
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'CIX_FinanceLedgerSnapshot'
             AND object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot'))
    DROP INDEX CIX_FinanceLedgerSnapshot ON dbo.FinanceLedgerSnapshot;
CREATE CLUSTERED INDEX CIX_FinanceLedgerSnapshot ON dbo.FinanceLedgerSnapshot
    (FinancialYear, InstitutionID, ResponsibilityID, DepartmentID, AccountNumber);
-- repeat for CIX_FinanceLedgerSnapshot_Staging
```

### Step 6 — Application code

**`app/Http/Controllers/AllocationLineExpenditureController.php`:**

- Update the class docblock (line 22) to the new rule, including that Routing is displayed but
  deducted from nothing.
- Remove the `Encumbered = Approved + Routing` derivation (line 227). Under the new rule the two
  are no longer interchangeable — Approved counts into `ActualExpenditure`, Routing does not — so
  one combined column would be actively misleading. Carry `Approved` and `Routing` as separate
  row keys and surface `ActualExpenditure`.
- `totals`: replace `'encumbered'` with `'approved'`, `'routing'` and `'actual'`. Keep
  `'balance'` summed **per line** — the comment on lines 128–130 explains why and stays correct.
- **`unavailable()` must change in lockstep** (~line 348): it returns the same prop shape, so the
  new totals keys need zeroed entries or an outage becomes a Vue error on top of an outage.
- `classify()` needs no change — it reads `Excess`/`AllocationBalance`, which still floor at zero
  with exactly one non-zero.
- **Extract the row shaping into a `DerivesAllocationLines` trait** — the pure part: building the
  row array, passing through `Approved`/`Routing`/`ActualExpenditure`, `classify()`, and computing the
  totals array from a collection. This follows the established `DashboardDataTransforms`
  precedent (kept DB-free precisely so it is unit-testable) and is what makes step 7's offline
  tests possible.

**`resources/js/Pages/Expenditure/Allocation Line Expenditure.vue` — final column contract, no
further options:**

```
Institution │ Department │ Account Description │ Allocation │ …12 months… │
YTD Expenditure │ Approved Commitments │ Routing │ YTD + Approved │ Balance of Allocation │ Status
```

- `Balance of Allocation` gets a footnote / `title` tooltip: **"Allocation − YTD Expenditure.
  Approved Commitments and Routing are shown for information and do not reduce this balance."**
  Without it, users will reasonably expect the "YTD + Approved" column to reconcile to the
  balance, and conclude the page is broken.
- "YTD + Approved" is deliberately literal rather than the script's "Actual YTD Expense" — an
  "actual" that includes commitments and is then ignored by the balance beside it invites exactly
  the wrong reading.
- Update the `<tfoot>` cells, the `summary-edge` class placement across the widened frozen block,
  and the empty-state `:colspan` from `months.length + 8` to `months.length + 10`.
- Update the frozen-summary comment (~line 650), which names the Encumbered column.

**`app/Models/FinanceLedger.php`** — no change; the three casts still apply.

**Untouched:** `DashboardController`, `DepartmentExpenditureController`,
`BudgetAllocationController`, `MonthlyExpenditureController`, `ResolvesLedgerAccess` (its
`exists()` probe is unaffected by an added column), and both views in `FinanceLedgerCutover.sql`.

### Step 7 — Tests

**Offline unit tests** on the new `DerivesAllocationLines` trait (`tests/Unit/`) — these run in CI
with no SQL Server and are the regression net for the rule itself:

- the SQL-supplied `ActualExpenditure`, `Excess` and `AllocationBalance` values pass through
  unchanged; do not recompute them in PHP merely to make them unit-testable, because SQL is the
  single source of truth;
- `Approved` and `Routing` stay separate, and no `Encumbered` key is emitted;
- `classify()` boundary cases at the 0.005 tolerance, and that exactly one of excess/balance is
  non-zero;
- the totals payload key set is **identical** to `unavailable()`'s — assert the two key sets
  match, so a future prop added to one and not the other fails a test instead of a page.

**Integration tests** (`tests/Feature/AllocationLineExpenditureTest.php`) — update the docblock
(line 20) and the four assertion groups named in the rollback record. These keep the
`UsesLedgerData` skip behaviour: they must `markTestSkipped()` when SQL Server is unreachable,
never fail, and never be repointed at `User::factory()`.

**SQL-level assertions that genuinely need a database** — institution isolation, duplicate
position mappings not duplicating rows, multi-shipment and over-shipment fixtures. Write these as
skipping integration tests. Do not fake them: per `CLAUDE.md`, megabytes of derived financial data
cannot be meaningfully faked, and a green suite built on invented ledger rows is worse than a
skipped one.

The SQL integration assertions must include `ActualExpenditure = YTDTotal + Approved`, balance
and excess derived from YTD alone, and proof that changing Routing affects none of those derived
values. An offline test that recomputes the same formula in PHP would only test the duplicate
implementation, not the database object used in production.

### Step 8 — Documentation

- **`CLAUDE.md`** — the file that will mislead the next session if not updated:
  - Rewrite the "Balance and overspend are measured against `ActualExpenditure` (YTD + Approved +
    Routing)" rule; state explicitly that Routing is displayed but not deducted.
  - The `CONVERT` rule names `ExtendedCost` as a source column — now it is `Quantity × UnitCost`
    netted by `QTYShipped`.
  - Replace the linked-server chain in the ledger description with `0030ADGPCOA`,
    `0030AEAccountNameCorrections`, `0098FPOShipmentDetails`, and **state that the ledger refresh
    no longer touches the linked server at all**.
  - Add those three tables to the **"never write to pre-existing objects"** list.
  - Note that access now requires an active, non-blank `InstitutionID`.
  - Add the committed source script to the Reference Documents table as the current source of
    truth; demote `SQL Revised Web App.sql` to historical.
  - **Date the dated observations.** "only PositionID 10108 (FFIGUERA1) is mapped" and "`0006C`
    held 6 rows" are measurements from 2026-08-06, not invariants; label them as such so they are
    not treated as permanent facts.
- **`sql/FinanceLedgerAgentJob.sql`** — retire the Section 2 linked-server gate and the runbook
  step 3 that references it; adjust the retry interval comment ("rides out a linked-server blip",
  line 199), which no longer describes a real failure mode.
- **`instructionsforschedule.md`**, **`instructions.md`** — remove the linked-server gate from the
  prerequisite lists.
- **`Overview.md`** lines 60–61 — `Approved`/`Routing` are no longer `SUM(ExtendedCost)`.
- **`sql/GL00100_Rebuild.sql`** — header note that the ledger no longer reads GL00100 over the
  linked server, so the rebuild is retained only for other consumers. Do not delete it.
- **`sql/00_PreflightChecks.sql`** — fold in P1–P9; extend CHECK 10a's column list to `Quantity`,
  `UnitCost`, `PONumber`, `LineNbr`; update CHECK 6a/6b to the four-part mapping.

---

## Deployment — ordered; no maintenance window

**Confirmed: no maintenance window will be taken.** The ordering below is therefore not a
formality — it is the only thing keeping the app coherent while users are on it, and it is what
makes the window unnecessary rather than merely skipped.

The naive order is unsafe. `vw_FinanceLedger` changes take effect **instantly** against the
existing snapshot, while `fn_FinanceLedgerSource` changes only appear as each year refreshes. Do
them in the wrong order and, for the length of a full rebuild, the app serves the new balance rule
over old encumbrance numbers, with some years refreshed and others not, behind a frontend still
labelled "Encumbered".

Ordered as below, the exposure is different in kind. Steps 4–7 retain the old access views: only
the revised function and procedures feed the refresh, so while the snapshot rebuilds, the app keeps
serving the **old** formula over data that is progressively updated. The one genuinely
user-visible moment is step 8, where the view and the frontend land together — seconds, not the
~43 minutes of the rebuild.

**Two consequences of running live, both real:**

- **A user loading a page mid-rebuild may see a year's figures shift under them.** Encumbrance
  values change as each year completes. No figure is ever *wrong* — each row is internally
  consistent — but a refresh between two page loads can move a number. Prefer running steps 5–8
  outside business hours even without a formal window.
- **Access narrowing at step 8 is immediate.** A user whose visibility shrinks sees it on their
  next request. This is why the step-7 access comparison is a go/no-go gate: it happens *before*
  the view changes, so a bad result costs nothing.

**There is no `sp_getapplock` in the refresh procs.** Overlap is prevented solely by Agent
refusing to start a job already running — which does nothing to stop a manual refresh colliding
with the 21:30 job. Disabling the job is mandatory, not hygiene, and doubly so with no window to
guarantee separation.

1. **Beforehand:** P1–P8 are **done** and P9 is still required (see probe results); re-run all nine against **production** before
   applying there, since a restored backup is never authoritative for a live release. Run
   `npm run build` and the full test suite locally. **Rehearse the rollback end to end against the
   local replica** (confirmed approach — see the rollback record). Commit everything, including
   `public/build`.
2. **Disable the SQL Agent job** `SWRHA Finance - Ledger Refresh`; confirm it is not currently
   running.
3. **Back up** — run `sql/FinanceLedgerOversightBackup.sql`; preserve the snapshot, refresh
   metadata, function, both views, both refresh procedures, installed Agent job and application
   build identifier. Verify row counts and per-FY checksums, not merely a non-zero total.
4. **Apply the function, refresh-metadata DDL and both revised refresh procedures — but neither
   access view nor `vw_FinanceLedger`.** Users continue to see the old balance/access behavior while the snapshot
   rebuilds. Verify each object compiles. The current `sql/FinanceLedger.sql` is monolithic and
   also creates `vw_FinanceLedger`, so implementation must provide explicit ordered deployment
   scripts (for example `FinanceLedgerOversightPrepare.sql` and
   `FinanceLedgerOversightCutover.sql`) instead of relying on an operator to select line ranges in
   SSMS. The prepare script must be idempotent and must contain everything needed by step 5.
5. **Refresh all years:** `php artisan ledger:refresh --all`. Time it — with the linked server gone
   this should beat the measured 102–256s/FY, but budget the old ~43 min.
6. **Confirm every year succeeded.** `usp_RefreshFinanceLedgerSnapshotAll` continues past a failing
   year and throws only at the end, so a partial success is easy to miss:
   ```sql
   SELECT FinancialYear, Outcome, RowsLoaded, RefreshedAt, Message
   FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear DESC;   -- no Outcome = 'ABORTED'
   ```
7. **Run the reconciliation** (below). This is the go/no-go point — everything so far is
   reversible by restoring the backup, and the balance rule is not yet live.
8. **Apply `vw_WebAppUserAccess` and `vw_FinanceLedger` in one short transaction with
   `SET XACT_ABORT ON`, then deploy the complete application release (PHP/controller/trait plus
   the frontend build), and run `php artisan cache:clear file`.** The two views are one atomic
   access-control cutover: committing the four-tuple access view while the ledger still has its
   two-way predicate would duplicate the 32 cross-institution pairs and overstate money.
9. **Apply and verify the revised `sql/FinanceLedgerAgentJob.sql` while the job is disabled.** Its
   obsolete linked-server gate must actually be removed from the installed Agent job, not merely
   from the repository documentation.
10. **Verify in the app**, then **re-enable the Agent job** and confirm its next-run schedule.
11. Drop `_PreOversight` tables only after the change is accepted — not the same day.

*Contingency if pre-deployment timing/reconciliation shows the live transition is unacceptable:*
build a
parallel `FinanceLedgerSnapshot_Next`, validate it fully, then cut over the access and ledger views in one
transaction. This avoids all mixed-generation reads but requires parameterising the refresh
target and temporarily duplicating the snapshot. The approved default is the documented live
transition without a maintenance window. Switching to blue/green is a pre-release plan change,
never an improvisation by the deployment operator.

---

## Verification

### Two-tier reconciliation — not "exact match against the draft"

The production ledger **cannot** match the verbatim draft, by design: we pre-aggregate shipments,
floor over-shipments at zero, parse segments with the safe splitter, and carry a complete account
base the draft's `WHERE NetChange <> 0` union drops. Comparing against it and expecting equality
would produce differences with nowhere to put them.

**Tier 1 — hardened reference (must match exactly).** Build a standalone query that is the new
script *plus* the four approved corrections: pre-aggregated shipments, zero floor, `CHARINDEX`
splitter, `decimal(19,4)` conversion, complete account base. Save it as
`sql/source/OversightHardenedReference.sql`. Then:

```sql
-- every column, every account, zero rows returned
SELECT * FROM (
    SELECT AccountNumber, Allocation, Approved, Routing, YTDTotal,
           ActualExpenditure, Excess, AllocationBalance
    FROM dbo.vw_FinanceLedger WHERE FinancialYear = '2026' AND UserName = 'KCHARLES1'
    EXCEPT
    SELECT AccountNumber, Allocation, Approved, Routing,
           YTDTotal, ActualExpenditure, Excess, AllocationBalance
    FROM <hardened reference>
) AS a
UNION ALL
SELECT * FROM ( /* the same EXCEPT, reversed */ ) AS b;
```

**Tier 2 — verbatim draft (differences categorised and counted, not eliminated).** Run the
committed script as-is and account for every difference under exactly one heading:

| Bucket | Expected sign | How to confirm |
|---|---|---|
| Accounts we carry, draft drops (allocation- or encumbrance-only) | rows only on our side | every such row has `YTDTotal = 0` |
| Shipment fan-out avoided by pre-aggregation | normally makes the draft's `Approved`/`Routing` higher | reconcile by `(PONumber, POLineID)` and amount; the affected ledger-row count is not necessarily equal to P4 |
| Over-shipment floored at zero | draft lower (negative) | value equals P6's `value_removed_by_floor` |
| Segment parsing (26- vs 27-char accounts) | account appears under a different department | reconcile against the 15 known short accounts |

Anything that does not fall into one of these four buckets is a defect. Investigate before
proceeding — do not net it off.

### Before/after impact — run at step 3 and again at step 7

```sql
SELECT FinancialYear, COUNT(*) AS accounts,
       SUM(Allocation) AS allocation, SUM(YTDTotal) AS ytd,
       SUM(Approved) AS approved, SUM(Routing) AS routing,
       100.0 * SUM(CASE WHEN DepartmentName = 'UNDEFINED' THEN 1 ELSE 0 END) / COUNT(*) AS undefined_dept_pct
FROM dbo.FinanceLedgerSnapshot GROUP BY FinancialYear ORDER BY FinancialYear DESC;
```

`accounts`, `allocation` and `ytd` must be **unchanged**. Only `approved` and `routing` should
move. They are expected to move downward in ordinary data, but do not make direction alone a
gate: `ExtendedCost` can differ from `Quantity * UnitCost`, and returns/data corrections can
reverse the sign. Reconcile their movement account-by-account to the hardened shipment formula.
`undefined_dept_pct` must not jump. Anything else moving means the COA swap changed more than
labels — stop and investigate.

### Access comparison — every active user, not just KCHARLES1

Capture before (step 3) and after (step 7):

```sql
SELECT ua.UserName, COUNT(*) AS accessible_accounts, SUM(s.Allocation) AS allocation
FROM dbo.FinanceLedgerSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
        ON ua.ResponsibilityID = s.ResponsibilityID AND ua.DepartmentID = s.DepartmentID
       /* AFTER: AND ua.InstitutionID = s.InstitutionID */
WHERE s.FinancialYear = '2026'
GROUP BY ua.UserName ORDER BY ua.UserName;
```

Required outcomes: **no user's count rises** (institution scoping can only narrow); **no user
drops to zero** — that is a rollback trigger; every reduction is attributable to an
institution mismatch, verified by listing the excluded accounts for at least one affected user.

### Freshness, tests, lint

```bash
php artisan ledger:status          # must exit zero
php artisan test                   # unit tests must PASS, not skip; ledger tests may skip
php artisan test --filter=AllocationLineExpenditureTest
./vendor/bin/pint app/Http/Controllers/AllocationLineExpenditureController.php app/Concerns/DerivesAllocationLines.php
```

Pint only on changed files — a repo-wide run reformats ~nine unrelated pre-existing files.

### In the app (`composer dev`, logged in as KCHARLES1)

- **Allocation Line Expenditure** — `Allocation − YTD Expenditure` equals `Balance of Allocation`
  on every under-spent row; Routing is visible and affects nothing; the tooltip explains it; the
  totals row sums the whole filtered set, not the visible page; the "over" count matches step 7's
  expected drop.
- **Dashboard / Budget Allocations / Monthly Expenditure / Department Expenditure** — regression
  only. **Per-user totals may legitimately fall** where institution scoping narrowed access; they
  must reconcile exactly to the new access set, and no user may gain a record outside their
  institution. Account descriptions and the Monthly Expenditure `Responsibility` label will read
  differently now they come from the COA mirror — spot-check that they are better, not blank.
- Switch fiscal years and clear filters; confirm the FY rails still populate.

---

## Phase 2 and Phase 3 — moved to their own plans

Phase 2 (requisition-line detail, data layer) and Phase 3 (the pages over it) were part of this
document until 2026-08-26. They outgrew a subsection of a Phase 1 plan, so each now has its own:

| File | Covers |
|---|---|
| `financesqlupdatep2.md` | **Phase 2** — `FinanceRequisitionSnapshot`, its refresh, the Agent-job step, the reconciliation gate, and the measurements behind every decision |
| `financesqlupdatep3.md` | **Phase 3** — the two detail pages, controllers and tests |
| `financesqlupdateprogress.md` | progress, incidents and open TODOs for **all** phases |

What stayed here: Phase 1 only. Two Phase 1 facts that Phase 2 depends on, so they are worth
knowing before reading it — `Decision D` (the three-way institution-scoped access join) and step
2c's `ActCost` definition, which Phase 2 reuses verbatim.

## Appendix A — response to review

Revision 2 adopts most of the external review. Recorded here so the reasoning survives.

### Adopted in full

1. **COA/correction grain (review §1).** Correct and important — `SELECT DISTINCT AccountNumber,
   Description` does **not** collapse conflicting descriptions, so the draft's own join can
   multiply every money column. Now covered by probes P1/P2, permanent refresh-proc guards (4a),
   an explicit LEFT join, and a defensive `GROUP BY`. The review is also right that `MAX(...)` is
   not a business rule; it is documented as defence-in-depth only. *One correction to the review:
   `0030ADGPCOA` uniqueness is not unverified — `sql/GL00100_Rebuild.sql` records 9,463 rows /
   9,463 distinct account numbers. That is a 2026 measurement, not an invariant, so the guard
   stays.*
2. **Two-tier reconciliation (§2).** Correct; "exact match against the draft" was wrong given four
   deliberate divergences. Replaced with a hardened reference (exact) plus a categorised
   difference table against the verbatim draft.
3. **Access validation (§3).** Correct, especially the blank-vs-NULL point: `IS NOT NULL` passes a
   blank string that then matches nothing. View now uses `NULLIF(LTRIM(RTRIM(…)),'')`, and the
   comparison covers every active user.
4. **Atomic rollout (§5).** The strongest point in the review. Now an ordered maintenance window
   with the function applied before the view, a go/no-go gate after reconciliation, and mandatory
   Agent-job disabling — the procs have no `sp_getapplock`, so nothing else prevents a collision.
5. **Rollback data preservation (§6).** Correct. Timestamped backup tables make rollback minutes
   rather than a 43-minute rebuild. Also correct that `FinanceLedgerRollback.sql` is wrong for
   this — verified: its `@DropLedgerObjects` path tears down the entire subsystem.
6. **Label-fallback contract (§8).** Was vague; now an explicit table with normalisation and
   collation specified.
7. **Shipment semantics (§9).** The best technical catch. Cumulative-vs-additive `QTYShipped` is
   promoted to a **blocking gate**, and NULL handling plus the explicit `ActCost` cast are in —
   the latter matters because the drift guard compares names only and would not notice a type
   change.
8. **UI contract (§10).** Correct that I deferred a decision. Now a fixed column list with a
   tooltip, and "YTD + Approved" instead of "Actual YTD Expense".
9. **Regression expectations (§11).** Correct — per-user totals can legitimately fall after
   institution scoping. Rewritten.
10. **Gates (§7)** and **smaller fixes** — adopted, with the two qualifications below.

### Partially adopted, with reasoning

**§7 — gates on Approved/Routing.** Adopted in substance, not in form. A percentage-movement gate
on `Approved`/`Routing` would abort *this* refresh and every future one, because moving those
figures is the entire point of the change. Implemented instead as (4c) a narrow zero-collapse
guard, (4b) a label-coverage gate — which catches the failure no money gate can see — and a
mandatory deployment reconciliation. Gates should catch pathology, not intended change.

**§12 — offline tests.** Adopted for everything that can honestly be tested offline, via a
`DerivesAllocationLines` trait following the existing `DashboardDataTransforms` precedent. Not
adopted for the SQL-level assertions (institution isolation, multi-shipment fixtures): per
`CLAUDE.md` those require real data, and a green suite built on invented ledger rows is worse than
a skipped one because it reports confidence it has not earned. Those stay as skipping integration
tests.

### Not adopted

**§4 — reorder the clustered indexes to lead with InstitutionID.** Listed as "must fix"; I have
made it *measure, then decide* (step 5). The query filters `FinancialYear` and joins from a
160-row access mapping. The earlier six-row/selectivity argument is obsolete, and the measured
fact that 32 of 128 responsibility/department pairs span institutions disproves the claim that
the residual necessarily discards almost nothing. Step 5 therefore benchmarks the proposed
four-key join directly. Reorder both indexes together if that measured plan shows material
residual reads; otherwise retain them and record the IO evidence. The decision is evidence-based,
not predetermined either way.

### Added by neither the plan nor the review

- **The Agent job's linked-server gate becomes obsolete** (`FinanceLedgerAgentJob.sql` Section 2 /
  runbook step 3), along with the linked-server prerequisites in `instructionsforschedule.md` and
  `instructions.md`. Removing GL40200/DBA_Clusters eliminates the failure that gate exists to
  prevent — a genuine reduction in production risk, and a doc change that must not be missed.
- **`Excess` semantics change the visible "over" count**, which will fall and may reach zero. A
  user-facing consequence that needs communicating to finance before they report it as a bug.

---

## Appendix B — what probing changed (2026-08-24)

Running the probes rather than reasoning about them altered the plan in five places. Recorded so
the next revision knows which conclusions rest on measurement and which still rest on argument.

**Confirmed the plan's biggest assumption.** Step 2a — the entire linked-server removal — rested on
`0030ADGPCOA` carrying four name columns I had never verified. It does, and they are 100%
populated across all 9,463 rows. Had this failed, decision (A) would have needed reopening.

**Found a defect neither I nor the external review caught.** `QTYShipped` and `POLineID` are
`varchar`; `LineNbr` is `int`. The draft's join is an implicit conversion, and `CONVERT` on a
future non-numeric value would throw and take down the nightly refresh. The plan now validates
with `TRY_CONVERT` and a clear guard error, then uses `CONVERT` rather than silently treating bad
financial data as zero. This was invisible to both reviews because both reasoned about the *semantics* of the
join and neither checked the *types*.

**Resolved the blocking gate — but not the way the plan predicted.** The plan said "P4 > 0 → stop
and ask the finance team". P4 returned 65, and the answer turned out to be that none of them touch
a live encumbrance row, so the question cannot move money. `POLNENUM` further showed they are
distinct GP lines colliding on `POLineID`, not partial shipments. Asking would have produced a
correct answer to a question that did not matter.

**Turned a guessed threshold into a measured one.** The label-coverage gate was "suggest 5%, tune
later". The measured baseline is 0% null with 0.25% sentinels, so 2% is now set on evidence.

**Downgraded a decision to deferred.** Decision D was "add InstitutionID unconditionally" — a
decision taken, in the plan, on the assumption the column existed. It does not, on this replica.
Because the replica is stale this is not yet conclusive, but it is no longer something to build.

**Independently validated decision (B).** `0040DBudgetsEncumbrance.Received` is 0 for every one of
104,643 rows while `ExtendedCost = Quantity × UnitCost` for all of them — so the table's own
receipt tracking is dead, and netting via the shipment table is the only way to get a real
commitment figure. The change is worth making on its own merits, not just because the script says
so.

### Still unverified

- Every result above, against the **current** replica and against production.
- Whether the 15 short (26-char) account numbers still exist — the segment-splitter rationale.
- Build time after the linked server is removed; the 102–256s/FY figures are stale.
- The execution plan that step 5's index decision depends on.

---

## Appendix C — verification on current production data (2026-08-25)

Third verification pass, against production backups restored the same day. Two findings changed the
plan materially; the rest confirmed it.

**Decision D is resolved, and it is a different change than anyone thought.** `InstitutionID` exists
and is fully populated. But measuring what it *does* reframed it: the current two-way join matches a
`(Responsibility, Department)` pair in **any** institution, and 32 of 128 active pairs span more than
one. `KCHARLES1` currently sees TTD 227.4M of allocation where the three-way join gives 128.3M — so
**TTD 99.1M is visible to a user who was never granted it.** This is an access-control defect being
fixed, not a reporting scope being narrowed, and it is almost certainly why the finance team added
the column. The plan previously framed a large drop as a rollback trigger; that trigger has been
corrected, because a large drop is now the *expected, correct* outcome.

**A second-order hazard came with it.** Adding `InstitutionID` to `0006C` means
`(UserName, Responsibility, Department)` is no longer unique — those same 32 pairs now appear twice.
The 4-tuple `DISTINCT` in step 1 was written as good practice; it is now **mandatory**. Without it,
adding the column to the join fans those pairs out and doubles their money. The hazard `CLAUDE.md`
warns about theoretically has become live.

**The user base turned over entirely.** `FFIGUERA1` — the user every document, query and worked
example in this repo is built around — now has **no mappings at all**. Access moved to `KCHARLES1`
(PositionID 10038) with 160 mappings, ~50× the previous surface. Every hardcoded reconciliation
query in this plan was retargeted. `UsesLedgerData` resolves the user dynamically and needs no
change — a design decision that just paid off.

**Everything else held.** P1–P6 and CHECK 7 returned **identical results across three independent
database snapshots** — the May replica, 2026-07-31, and 2026-08-25. COA grain, correction grain,
label coverage, shipment grain, the varchar hazard, over-shipment value and the money impact
(−19,206,283.31 on Approved, Routing unchanged) are all stable properties of the data.

### Method note

The first pass measured decision D on a stale replica and got "column does not exist." The second
got the same answer from a three-week-old backup. Only the third — against same-day production —
showed both that the column exists *and* that its real effect is roughly ten times more significant
than the plan assumed. **Two of three verification passes produced a confidently wrong answer.**
Where a finding depends on schema, verify against data as current as the artifact that references it.

### Still unverified

- Build time after the linked server is removed; the 102–256s/FY figures remain stale.
- The execution plan that step 5's index decision depends on.
- Phase 2's access join is **decided, not merely measured** — the three-way form is adopted
  (Decision E). What is still unconfirmed is *why* the drafts used two columns; the evidence points
  to drift, since `InstitutionID` landed on `0006C` between 2026-07-31 and 2026-08-25 while the
  drafts are timestamped 2026-08-24. Worth confirming with finance, but it no longer blocks
  anything.
- Whether Phase 2's detail views should apply the reporting-line-3 goods and services join. This
  **does** need a finance answer before Phase 2 go-live.

---

## Appendix D — third-review verification (2026-08-25)

The external review's changes were checked against the plan file and against live data. Most were
correct and are kept. Two items are recorded here because they change what to trust.

### The review caught a real defect I introduced

**The rollback record had been deleted.** When I spliced in the 2026-08-25 probe results I replaced
everything between `## Probe results` and `## Implementation` — and the rollback record sat between
them. It is restored. The lesson is mechanical, not conceptual: range-based splices on a document
this size must assert what they are removing.

### The review's most valuable catch — a live fan-out

Deploying the four-column `vw_WebAppUserAccess` while `vw_FinanceLedger` still joins on two columns
would give the 32 cross-institution pairs **two** matching access rows instead of one, **doubling
every money figure on them** for the length of the rebuild. The original deployment order did
exactly that. Both views must now cut over in the same transaction, and neither belongs in the
prepare phase. This was a genuine correctness bug in the plan, not a stylistic preference.

### One change rests on a false premise — reverted with evidence

The review removed `0030ADGPCOA.AccountDescription` from the description fallback, calling it an
"unresolved dependency". It is not unresolved:

| Measurement (2026-08-25) | Result |
|---|---|
| `0030ADGPCOA.AccountDescription` blank/NULL | **0 of 9,463** — 100% populated |
| FY2026 snapshot rows with no GL activity | 215 (TTD 19.78M allocation) |
| …of those, rows having a correction | **215 — all of them** |

The narrower chain (correction → GL → `UNDEFINED`) happens to be harmless *today* only because
every allocation-only account currently carries a correction. That is a data coincidence, not a
structural guarantee: one future allocation-only account without a correction row would render
`UNDEFINED` under the narrow chain and its real name under the full one. `coaData` is already
joined for the four name columns, so the third rung costs nothing. **Restored.**

### Two smaller corrections

- **Blank-correction handling** — the review hardened `COALESCE(Edited, AccountDescription)` against
  blank strings. Measured: 153 of 190 rows have NULL `EditedAccountDescription` and **0 have a blank
  string**, so the case does not occur today. The hardening is free and correct; kept, with the
  measurement recorded so nobody later mistakes it for a fix to an observed bug.
- **Sentinel normalisation** — measured 24 `DepartmentName` and **1 `ResponsibilityName`** carrying
  `REMOVE`/`UNDEFINED`; Institution and Cluster carry none. The review required explicit handling
  but left the placement open; it now happens in `coaData`, so the final `ISNULL(…, 'UNDEFINED')`
  stays the single place a missing label is named.

### Scoreboard across three review rounds

| Round | Caught |
|---|---|
| External review 1 | COA grain hazard, non-atomic rollout, "exact match" reconciliation error, rollback strategy |
| Probing (data) | `varchar` type hazard, the real shipment grain, `InstitutionID` reality, the 99.1M access defect |
| External review 2 | **live access fan-out**, fail-closed conversion, collision guard, my deleted rollback record |

No single pass would have produced this plan. The data probes found what no amount of reading could
(types, grain, actual access impact); the reviews found what measurement cannot (ordering hazards,
missing sections). Both were necessary.
