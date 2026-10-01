# Finance September Update — Deployment Runbook

**Access parity + the fiscal-year control change.** Run by hand, step by step, verifying each step
before starting the next.

- **Design:** `financeupdatesep.md` · **Status log:** `financeupdatesepprogress.md`
- **Written:** 2026-09-30, against a database restored to production state as of 2026-09-29.
- **Target for this pass:** the local test instance `V200ICTF5FA0MEL\SQLEXPRESS` (SQL Server 2022
  Developer Edition, `max server memory` 2048 MB), carrying current production **data**.
  Production itself is `sqlapp\SQLEXPRESS`, Standard Edition, on a separate DB server.

## How to use this document

| Tag | Means |
|---|---|
| **[DB]** | Run on the database server, in SSMS |
| **[WEB]** | Run on the web server / dev machine, in a shell |
| **[VERIFY]** | Paste the output back before continuing |
| 🛑 **STOP** | A gate. Do not proceed on a failure — the rollback for that point is named |

Every expected figure below was measured on this data on 2026-09-29. If a figure differs, that is
information, not necessarily a failure — but **stop and check** rather than continuing.

## Confirmed starting state (2026-09-30)

| | Value |
|---|---|
| `fn_FinanceLedgerSource` / `usp_RefreshFinanceLedgerSnapshot` / `usp_RefreshFinanceRequisition` | pre-parity |
| `AccountID`, `AccountsLoaded`, `SplitAccountCount` | absent |
| Scratch parity/draft functions, `_ParityBackup` tables | absent |
| `FinanceLedgerSnapshot` FY2026 | 2,265 rows / 2,265 accounts / Approved 95,760,870.05 |
| `FinanceLedgerSnapshot` FY2025 | 2,117 rows / 2,117 accounts / Approved 74,173,406.72 |
| `FinanceRequisitionSnapshot` | 108,435 rows, **0** negative balances |
| `FinanceLedgerRefresh` / `FinanceRequisitionRefresh` | 13 / 35 rows, last OK 2026-09-28 21:33 |
| Agent job `SWRHA Finance - Ledger Refresh` | **not present on this instance** (`msdb` not restored) |

---

# Phase 0 — Preflight

### Step 0.1 [DB] Confirm the starting state

```sql
USE FinanceAutomationSystem;
SELECT
  CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerSource')) LIKE '%draftCorr%'
       THEN 'PARITY' ELSE 'pre-parity' END                                  AS ledger_fn,
  CASE WHEN COL_LENGTH('dbo.FinanceLedgerSnapshot','AccountID') IS NULL
       THEN 'absent' ELSE 'present' END                                     AS accountid_col,
  (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear='2026') AS fy2026_rows,
  (SELECT CONVERT(decimal(19,2), SUM(Approved)) FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear='2026') AS fy2026_approved,
  (SELECT COUNT(*) FROM dbo.FinanceRequisitionSnapshot WHERE ActBalance < 0) AS negative_balances;
```

**PASS:** `pre-parity`, `absent`, **2265**, **95760870.05**, **0**.

> If `ledger_fn` is already `PARITY`, the restore did not take. Stop.

### Step 0.2 [DB] Disable the Agent job

Not present on this test instance, so this is a no-op here. **On production it is mandatory** — an
overnight run mid-deployment leaves the two snapshots from different states.

```sql
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh')
    EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh', @enabled = 0;

SELECT name, enabled FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh';
```

**PASS:** either no rows (this instance) or `enabled = 0`.

### Step 0.3 [WEB] Confirm the working tree

```bash
cd /c/Users/bharathramkissoon/Desktop/Development_Projects/finance
git status --short
git rev-parse --short HEAD
```

**PASS:** on `feature/ledger-oversight-update`, and the six `sql/Parity*`/`sql/Finance*Parity*` files
plus the modified app files are present. **Record the SHA** — it is the app-side rollback point.

---

# Phase 1 — Harness, and GATE 1

The scratch objects were lost in the restore, so parity must be re-proven before anything is changed.

### Step 1.1 [DB] Create the verbatim Access query

Run **`sql/ParityVerbatimDraft.sql`**.

Creates `dbo.fn_OversightDraftVerbatim` and `dbo.fn_OversightDraftUnscoped` — the Access query
wrapped unchanged, generated mechanically from `sql/source/SQL Revised Allocation Oversight F.sql`.
Read-only; nothing else touches them.

**PASS:** completes with no error.

### Step 1.2 [DB] [VERIFY] Self-check the harness

```sql
USE FinanceAutomationSystem;
SET NOCOUNT ON;
SELECT 'SCOPED_2026' AS chk, COUNT(*) AS rows_,
       CONVERT(decimal(19,2),SUM(Allocation)) AS alloc,
       CONVERT(decimal(19,2),SUM(Approved))   AS approved
FROM dbo.fn_OversightDraftVerbatim('2026', 'FRANCIS FIGUERA');

SELECT 'UNSCOPED_2026' AS chk, COUNT(*) AS rows_, COUNT(DISTINCT AccountNumber) AS accts,
       CONVERT(decimal(19,2),SUM(Allocation)) AS alloc,
       CONVERT(decimal(19,2),SUM(YTDTotal))   AS ytd,
       CONVERT(decimal(19,2),SUM(Approved))   AS approved,
       CONVERT(decimal(19,2),SUM(Routing))    AS routing
FROM dbo.fn_OversightDraftUnscoped('2026');
```

**PASS — these are the Access figures and the whole point of the release:**

| Check | Expected |
|---|---|
| SCOPED_2026 rows / alloc / approved | 14 · 7,548,334.91 · **346,568.08** |
| UNSCOPED_2026 rows / accounts | **2275** · **2264** |
| UNSCOPED_2026 alloc | 242,817,848.69 |
| UNSCOPED_2026 ytd | 254,553,116.94 |
| UNSCOPED_2026 approved | **83,803,914.38** |
| UNSCOPED_2026 routing | 12,637,933.09 |

### Step 1.3 [DB] Create the parity function as a SCRATCH object

Run **`sql/FinanceLedgerAccessParity.sql`**.

Creates `dbo.fn_FinanceLedgerAccessParity`. Nothing reads it; the live
`dbo.fn_FinanceLedgerSource` is untouched. Reversible by `DROP FUNCTION`.

Creating a function returns no result set, so verify it with this — it builds FY2026 **once** into a
temp table and reads that four times, rather than invoking the function four times:

```sql
USE FinanceAutomationSystem;
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
SELECT * INTO #p FROM dbo.fn_FinanceLedgerAccessParity('2026');

-- 1. Shape: the function must return the snapshot's columns PLUS AccountID, and
--    nothing else. AccountID is what Step 3.1 adds to the tables.
SELECT 'SHAPE' AS chk,
       (SELECT COUNT(*) FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#p')) AS fn_columns,
       (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')) AS snapshot_columns;

SELECT 'EXTRA_COLUMN' AS chk, name COLLATE Latin1_General_CI_AS AS name
FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#p')
EXCEPT
SELECT 'EXTRA_COLUMN', name COLLATE Latin1_General_CI_AS
FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot');

-- 2. The Access figures.
SELECT 'FY2026' AS chk, COUNT(*) AS rows_, COUNT(DISTINCT AccountNumber) AS accts,
       CONVERT(decimal(19,2),SUM(Allocation)) AS alloc,
       CONVERT(decimal(19,2),SUM(YTDTotal))   AS ytd,
       CONVERT(decimal(19,2),SUM(Approved))   AS approved,
       CONVERT(decimal(19,2),SUM(Routing))    AS routing
FROM #p;

-- 3. The split grain, and the one row with no chart-of-accounts entry.
SELECT 'SPLITS' AS chk, COUNT(*) AS split_accounts
FROM (SELECT AccountNumber FROM #p GROUP BY AccountNumber HAVING COUNT(*) > 1) AS s;

SELECT 'NO_COA_ROW' AS chk, AccountNumber, AccountDescription,
       InstitutionID, ResponsibilityID, DepartmentID,
       CONVERT(decimal(19,2),Approved) AS approved
FROM #p WHERE AccountID IS NULL;

DROP TABLE #p;
```

**PASS:**

| Check | Expected |
|---|---|
| `SHAPE` | `fn_columns` **36**, `snapshot_columns` **35** |
| `EXTRA_COLUMN` | exactly one row: **`AccountID`** — nothing else may appear |
| `FY2026` rows / accts | **2275** · **2264** |
| `FY2026` alloc / ytd | 242,817,848.69 · 254,553,116.94 |
| `FY2026` approved / routing | **83,803,914.38** · 12,637,933.09 |
| `SPLITS` | **11** |
| `NO_COA_ROW` | exactly one row: `4-87800-E04-101-2004-00-000`, description **NULL**, segments `E04`/`101`/`2004`, approved **98,350.00** |

Two of these deserve a moment, because both look like defects and are not:

- **`EXTRA_COLUMN` returning only `AccountID` is the point of the check.** The snapshot does not have
  that column yet — Step 3.1 adds it. If anything *else* appears, or if a snapshot column is missing
  from the function, the drift guard will throw `51001` at Step 3.2. Catch it here instead.
- **`NO_COA_ROW`** is an encumbrance-only account absent from `dbo.0030ADGPCOA`, so the COA-sourced
  `AccountID` and `AccountDescription` are NULL while its segments still resolve — the encumbrance
  branch derives those from byte offsets on the account number, not from the COA. The Access query
  produces the identical row, which is why GATE 1 passes with it present. **Consequence:** its
  description renders **blank** on the pages rather than `UNDEFINED`, because `AccountDescription` is
  now grain taken verbatim per branch instead of a COALESCE chain. That is Access behaviour.

### Step 1.4 [DB] [VERIFY] 🛑 GATE 1 — is the LOGIC right?

Run **`sql/ParityReconciliation_Gate1.sql`**. Nothing to edit — open it and run it. ~70 seconds.

> **Do not use `sql/ParityReconciliation.sql` here.** That one targets the live
> `dbo.fn_FinanceLedgerSource`, which is still **pre-parity** at this point, so it reports failures
> that mean nothing. It becomes useful *after* the cutover, to re-confirm the promoted function.
> `_Gate1` is a copy of it pointed at the scratch function, and it fails fast with a named message if
> step 1.1 or 1.3 has not been run.

**PASS:** `VERDICT` row reads `PASS`, with `total_draft_only = 0`, `total_parity_only = 0`,
`total_multiplicity_diffs = 0`, `years_with_rowcount_diff = 0`, `years_with_split_diff = 0`, and the
per-year table matching:

| FY | rows | splits | | FY | rows | splits |
|---|---|---|---|---|---|---|
| 2014 | 1,814 | 1 | | 2021 | 1,378 | 0 |
| 2015 | 1,973 | 1 | | 2022 | 1,020 | 0 |
| 2016 | 1,697 | 0 | | 2023 | 785 | 0 |
| 2017 | 1,840 | 3 | | 2024 | 1,887 | 1 |
| 2018 | 1,867 | 3 | | 2025 | 2,121 | 4 |
| 2019 | 1,835 | 0 | | 2026 | 2,275 | 11 |
| 2020 | 1,882 | 0 | | | | |

🛑 **STOP on any non-zero.** Nothing live has changed — fix the function and repeat 1.3–1.4.
**Rollback:** `DROP FUNCTION dbo.fn_FinanceLedgerAccessParity;`

---

# Phase 2 — Backups

### Step 2.1 [DB] Copy both snapshots and both refresh logs

```sql
USE FinanceAutomationSystem;
SET NOCOUNT ON;

IF OBJECT_ID('dbo.FinanceLedgerSnapshot_ParityBackup')      IS NOT NULL DROP TABLE dbo.FinanceLedgerSnapshot_ParityBackup;
IF OBJECT_ID('dbo.FinanceRequisitionSnapshot_ParityBackup') IS NOT NULL DROP TABLE dbo.FinanceRequisitionSnapshot_ParityBackup;
IF OBJECT_ID('dbo.FinanceLedgerRefresh_ParityBackup')       IS NOT NULL DROP TABLE dbo.FinanceLedgerRefresh_ParityBackup;
IF OBJECT_ID('dbo.FinanceRequisitionRefresh_ParityBackup')  IS NOT NULL DROP TABLE dbo.FinanceRequisitionRefresh_ParityBackup;

SELECT * INTO dbo.FinanceLedgerSnapshot_ParityBackup      FROM dbo.FinanceLedgerSnapshot;
SELECT * INTO dbo.FinanceRequisitionSnapshot_ParityBackup FROM dbo.FinanceRequisitionSnapshot;
SELECT * INTO dbo.FinanceLedgerRefresh_ParityBackup       FROM dbo.FinanceLedgerRefresh;
SELECT * INTO dbo.FinanceRequisitionRefresh_ParityBackup  FROM dbo.FinanceRequisitionRefresh;

SELECT (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot_ParityBackup)      AS ledger_rows,
       (SELECT COUNT(*) FROM dbo.FinanceRequisitionSnapshot_ParityBackup) AS req_rows,
       (SELECT COUNT(*) FROM dbo.FinanceLedgerRefresh_ParityBackup)       AS ledger_log,
       (SELECT COUNT(*) FROM dbo.FinanceRequisitionRefresh_ParityBackup)  AS req_log;
```

**PASS:** **22352** · **108435** · **13** · **35**.

### Step 2.2 [DB] [VERIFY] Capture the per-year before-state

```sql
SELECT FinancialYear, COUNT(*) AS accounts,
       CONVERT(decimal(19,2),SUM(Allocation)) AS alloc,
       CONVERT(decimal(19,2),SUM(YTDTotal))   AS ytd,
       CONVERT(decimal(19,2),SUM(Approved))   AS approved,
       CONVERT(decimal(19,2),SUM(Routing))    AS routing
FROM dbo.FinanceLedgerSnapshot GROUP BY FinancialYear ORDER BY FinancialYear DESC;
```

**Keep this output.** It is the only record of what the figures were, and Finance will ask.

---

# Phase 3 — Ledger cutover, and GATE 2

### Step 3.1 [DB] Apply the ledger cutover

Run **`sql/FinanceLedgerParityCutover.sql`**.

Adds `AccountID` to the snapshot and staging tables and `AccountsLoaded`/`SplitAccountCount` to the
refresh log; promotes the parity body into `dbo.fn_FinanceLedgerSource`; updates
`dbo.usp_RefreshFinanceLedgerSnapshot` (gate 4e widened to all years, new `51008` fan-out gate, new
`51009`/`@MaxSplitAccounts` ceiling, grain telemetry). Idempotent — safe to re-run.

**PASS:** completes with no error, and the footer reports:
- **no drift rows** in either direction (an empty result for both checks)
- `PROMOTED_BODY` = `IDENTICAL to the proven body`

🛑 **STOP if any drift row appears** — the function and snapshot columns disagree and Step 3.2 would
throw `51001`. **Rollback:** re-run `sql/FinanceLedger.sql`, then
`ALTER TABLE dbo.FinanceLedgerSnapshot DROP COLUMN AccountID;` and the same for `_Staging`.

### Step 3.2 [DB] [VERIFY] Rebuild FY2026

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026';
```

**PASS — the procedure returns one row:**

| Column | Expected |
|---|---|
| RowsLoaded | **2275** |
| TotalAllocation | 242,817,848.69 |
| TotalYTD | 254,553,116.94 *(unchanged)* |
| TotalApproved | **83,803,914.38** *(was 95,760,870.05)* |
| TotalRouting | 12,637,933.09 *(unchanged)* |
| UndefinedLabelPct | 0.00 |
| AccountsLoaded | **2264** |
| SplitAccountCount | **11** |

`@Force` should not be needed. If it aborts, read the message before reaching for it.

### Step 3.3 [DB] [VERIFY] 🛑 GATE 2 — is the DATA right?

Run **`sql/ParitySnapshotCheck.sql`**. This compares the **stored snapshot rows** against the Access
query, per year.

> `sql/ParityReconciliation.sql` does **not** substitute for this. It compares function to function,
> so it passes whatever is in the snapshot and cannot detect a bad refresh.

**PASS:** FY2026 row reads `PASS` with `draft_only = 0`, `snap_only = 0`, `mult_diffs = 0`,
`draft_rows = snap_rows = 2275`, `draft_splits = snap_splits = 11`.

**Expected and NOT a failure:** every other year reports `FAIL`. They still hold pre-parity snapshot
data and have not been rebuilt yet — they are fixed in Phase 4. Only FY2026 matters at this gate.

🛑 **STOP if FY2026 is not `PASS`.** Only one year has moved.
**Rollback:**
```sql
DELETE FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = '2026';
INSERT INTO dbo.FinanceLedgerSnapshot
SELECT * FROM dbo.FinanceLedgerSnapshot_ParityBackup WHERE FinancialYear = '2026';
```
(then re-run `sql/FinanceLedger.sql` to restore the pre-parity function and proc).

### Step 3.4 [DB] [VERIFY] Spot-check the split and the user-visible figure

```sql
-- The worked example: one account, two rows, one missing M.
SELECT AccountNumber, AccountDescription,
       CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Allocation) AS alloc,
       CONVERT(decimal(19,2),Approved) AS approved
FROM dbo.FinanceLedgerSnapshot
WHERE FinancialYear='2026' AND AccountNumber='4-87300-C20-101-2004-00-000';

-- What the only mapped user actually sees, IN TOTAL.
SELECT COUNT(*) AS accounts,
       CONVERT(decimal(19,2),SUM(Approved))   AS approved,
       CONVERT(decimal(19,2),SUM(Allocation)) AS alloc,
       CONVERT(decimal(19,2),SUM(Routing))    AS routing
FROM dbo.vw_FinanceLedger WHERE FinancialYear='2026' AND UserName='FFIGUERA1';

-- The single account that carries the whole difference.
SELECT AccountNumber, CONVERT(decimal(19,2),Approved) AS approved
FROM dbo.vw_FinanceLedger
WHERE FinancialYear='2026' AND UserName='FFIGUERA1'
  AND AccountNumber = '4-80400-H01-101-2001-00-000';
```

**PASS:**

| Check | Expected |
|---|---|
| Split example | two rows — `RENT & ACCOMODATION` (ytd 253,000.00, alloc 0.00, approved 0.00) and `RENT & ACCOMMODATION` (ytd 0.00, alloc 521,336.04, approved 138,000.00) |
| FFIGUERA1 accounts | **14** |
| FFIGUERA1 **total** approved | **346,568.08** *(was 411,118.08)* |
| FFIGUERA1 alloc / routing | 7,548,334.91 · 229,173.20 *(both unchanged)* |
| `4-80400-H01-101-2001-00-000` approved | **129,100.00** *(was 193,650.00)* |

> **Do not confuse these two figures** — an earlier draft of this runbook did, and it turns a passing
> step into a false alarm. `129,100.00` / `193,650.00` are the **per-account** values for
> `4-80400-H01-101-2001-00-000`; `346,568.08` / `411,118.08` are the **user totals**. The whole
> 64,550.00 difference sits on that one account (eight lines on PO00000202871 with `Quantity` 1 and
> `QtyShipped` 2), so the two deltas are the same number viewed at two grains.

---

# Phase 4 — All years, then Phase 2 in lockstep

> **Order changed from the earlier plan, deliberately.** The all-years ledger rebuild now runs
> **before** the requisition cutover. Doing it the other way round makes GATE 3 depend on gate F's
> 36-hour freshness window: years whose ledger was refreshed recently would be compared against an
> unfloored detail and abort, while older years would be silently recorded as `ReconStaleYearDrift`.
> Rebuilding all years first means every year is parity **and** fresh, so GATE 3 is unambiguous —
> one clean run, `ReconMismatches = 0` **and** `ReconStaleYearDrift = 0`.

### Step 4.1 [DB] Rebuild every fiscal year

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 1;
```

`@Force = 1` **is** required — closed years breach `@MaxMovePercent` on Approved, which is the
intended change. It does **not** bypass `51008`/`51009` or any correctness gate.

Budget 15–45 minutes and **re-measure**; the older per-year timings predate this function.

**PASS:** completes without throwing. Then:

```sql
SELECT FinancialYear, RowsLoaded, AccountsLoaded, SplitAccountCount,
       CONVERT(decimal(19,2),TotalApproved) AS approved, Outcome, Message
FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear DESC;
```

**PASS:** every row `Outcome = 'OK'`, no `ABORTED`, and every figure matching this table — derived
from the parity function on 2026-09-30, before the rebuild, so these are targets and not guesses:

| FY | rows before → after | AccountsLoaded | SplitAccountCount | TotalApproved before → after |
|---|---|---|---|---|
| 2026 | 2265 → **2275** | 2264 | **11** | 95,760,870.05 → **83,803,914.38** |
| 2025 | 2117 → **2121** | 2117 | **4** | 74,173,406.72 → **49,658,742.34** |
| 2024 | 1886 → **1887** | 1886 | **1** | 35,515,805.74 → **14,625,771.98** |
| 2023 | 785 → 785 | 785 | 0 | 0.00 → 0.00 |
| 2022 | 1020 → 1020 | 1020 | 0 | 0.00 → 0.00 |
| 2021 | 1378 → 1378 | 1378 | 0 | 2,629,887.27 → 2,629,887.27 |
| 2020 | 1882 → 1882 | 1882 | 0 | 30,722,030.39 → **26,469,743.06** |
| 2019 | 1835 → 1835 | 1835 | 0 | 9,889,989.02 → **9,516,144.20** |
| 2018 | 1864 → **1867** | 1864 | **3** | 5,720,249.10 → **−1,444,587.97** |
| 2017 | 1837 → **1840** | 1837 | **3** | 3,372,156.84 → **−3,974,133.73** |
| 2016 | 1697 → 1697 | 1697 | 0 | 2,683,555.61 → **2,401,407.89** |
| 2015 | 1972 → **1973** | 1972 | **1** | 23,622,836.79 → **19,761,636.34** |
| 2014 | 1814 → 1814 | **1813** | **1** | 146,088,238.33 → **145,615,766.90** |

Three of these look wrong and are not:

- **FY2017 and FY2018 `TotalApproved` go NEGATIVE** (−3,974,133.73 and −1,444,587.97). Those two years
  have more over-received value than open commitment, so removing the zero floor takes the whole-year
  total below zero. The Access query produces the same figures. Gate 4c does not fire — it catches
  `@approved = 0` exactly, not a negative.
- **FY2014's row count does not change** (1814 → 1814) even though it has 1 split. One account splits
  into two rows and one different account drops out, netting to zero. `AccountsLoaded` is what reveals
  it: **1813** distinct accounts against 1814 rows.
- **`TotalRouting` moves in two years** — FY2024 falls by **107,341.68** and FY2025 by **0.01**.
  Everywhere else it is unchanged. Earlier drafts of this runbook claimed Routing never moves; that is
  true only of FY2026.

`TotalAllocation` moves in **one** year only: FY2026, by **+0.17**. `TotalYTD` is unchanged in every
year — if it moves anywhere, stop.

> `usp_RefreshFinanceLedgerSnapshotAll` logs a failing year and continues, throwing only at the end —
> so **read this table** rather than trusting the absence of an error.

### Step 4.2 [DB] [VERIFY] Re-run GATE 2 across all years

Run **`sql/ParitySnapshotCheck.sql`** again.

**PASS:** `VERDICT` reads `PASS - the stored snapshot matches Access`, `years_failing = 0`, and all 13
per-year rows `PASS`.

🛑 **STOP on any failing year.** **Rollback:** re-run `sql/FinanceLedger.sql`, then restore the
snapshot wholesale from `_ParityBackup`, then drop the two added columns.

### Step 4.3 [DB] Apply the requisition cutover

Run **`sql/FinanceRequisitionParityCutover.sql`**.

Removes the zero floor from `ActCost`/`ActBalance` (computed in float from the raw columns so it
matches the ledger's per-line expression to the cent) and aggregates gate F's ledger side by
`(FinancialYear, AccountNumber)` so split accounts reconcile.

**PASS:** completes with no error, and the footer reports:

| Check | Expected |
|---|---|
| `floor_state` | `ok - floor removed` |
| `gatef_state` | `ok - gate F aggregated` |
| `shipments_state` | `ok - pre-aggregate kept` |
| `fn_state` | `ok - ledger function is on parity` |
| `years_rebuilt_on_parity` | **13** — every year must be on the parity basis before GATE 3 |
| `years_with_splits` | **7** — only 2014, 2015, 2017, 2018, 2024, 2025 and 2026 contain any split |
| `AGENT_JOB` | no rows on this instance; `ok - disabled` on production |

> `years_with_splits = 7` is **correct and not a shortfall.** An earlier version of this footer labelled
> that number `years_rebuilt_on_parity`, which made a complete 13-year rebuild look like 6 missing
> years. The two counts are now reported separately and mean different things.

### Step 4.4 [DB] [VERIFY] 🛑 GATE 3 — do the two snapshots agree with each other?

```sql
EXEC dbo.usp_RefreshFinanceRequisition @Force = 1;
```

Measured previously at ~18 s for 106k rows; budget a few minutes.

**PASS:**

```sql
SELECT TOP 3 RefreshedAt, Outcome, RowsLoaded,
       ReconAccountsCompared, ReconMismatches, ReconStaleYearDrift,
       CONVERT(decimal(19,2),TotalApproved) AS approved,
       CONVERT(decimal(19,2),TotalRouting)  AS routing, Message
FROM dbo.FinanceRequisitionRefresh ORDER BY RefreshedAt DESC;
```

- `Outcome = 'OK'`
- **`ReconMismatches = 0`**
- **`ReconStaleYearDrift = 0`** — every year was rebuilt minutes ago, so nothing is stale. The
  pre-existing nightly rows show **7** here, because under the nightly job only two years were ever
  freshly rebuilt; a non-zero value now would mean a year did not rebuild.
- `ReconAccountsCompared` ≈ **22,351**. A small number means the freshness `INNER JOIN` is excluding
  years rather than reconciling them — investigate even if the gate passed.
- `0 duplicate grain row(s)` in the message.

> ⚠️ **`TotalApproved` on this row will NOT equal the ledger's total, and that is correct.** The
> recorded telemetry sums the WHOLE requisition snapshot (FY2010–FY2026); the ledger only holds
> FY2014–FY2026, and gate F's `INNER JOIN` on `FinanceLedgerRefresh` excludes the years it has no
> counterpart for. Measured 2026-09-30: recorded `358,543,703.27` = ledger-covered `349,064,292.66`
> **plus** FY2010–2013 `9,479,410.61`, which is exactly the detail the Phase 3 pages withhold via
> `unsummarisedYears`. `ReconMismatches = 0` is the figure that says the shared years tie; do not read
> the totals column as a reconciliation.
>
> `ReconAccountsCompared` also drops by one (22,352 → 22,351) because parity removes two
> account-keys from the ledger, both COA-absent. Expected.

The message also reports **685 rows with an unparseable account number**. Pre-existing, unchanged by
this release, and invisible to every user because they match no access grant — but worth knowing if
Finance ever asks why detail row counts do not tie to the raw table.

🛑 **This gate is never bypassable by `@Force`, deliberately.** Diagnose with
`sql/Phase2ReconciliationTest.sql`. Do not relax `@ReconToleranceTTD`.
**Rollback:** re-run `sql/FinanceRequisition.sql`, then `EXEC dbo.usp_RefreshFinanceRequisition
@Force = 1`. The ledger must be rolled back in the same window or gate F will abort.

### Step 4.5 [DB] [VERIFY] Confirm the negatives arrived, and that detail ties to summary

```sql
SELECT COUNT(*) AS negative_lines,
       COUNT(DISTINCT AccountNumber) AS accounts,
       CONVERT(decimal(19,2),SUM(ActCost)) AS negative_value
FROM dbo.FinanceRequisitionSnapshot
WHERE FinancialYear = '2026' AND ActBalance < 0;

-- Detail must equal summary, per user, to the cent.
SELECT CONVERT(decimal(19,2),SUM(CASE WHEN Status IN ('AP','PO')      THEN ExtendedCost ELSE 0 END)) AS detail_approved,
       CONVERT(decimal(19,2),SUM(CASE WHEN Status IN ('RT','HD','PN') THEN ExtendedCost ELSE 0 END)) AS detail_routing
FROM dbo.vw_FinanceRequisitionDetail WHERE FinancialYear='2026' AND UserName='FFIGUERA1';

SELECT CONVERT(decimal(19,2),SUM(Approved)) AS summary_approved,
       CONVERT(decimal(19,2),SUM(Routing))  AS summary_routing
FROM dbo.vw_FinanceLedger WHERE FinancialYear='2026' AND UserName='FFIGUERA1';
```

**PASS:**

| Check | Expected |
|---|---|
| FY2026 negative lines / accounts / value | **694** · **62** · **−17,363,584.00** *(was 0 lines)* |
| `detail_approved` = `summary_approved` | **346,568.08** — these are FFIGUERA1's **totals** |
| `detail_routing` = `summary_routing` | **229,173.20** *(unchanged by parity)* |

The equality is the point, not the value: detail and summary must agree **to the cent**. That is
Phase 2's reconciliation surviving all the way through to the views the pages actually read.

> Same warning as Step 3.4 — do **not** expect `129,100.00` here. That is the **per-account** figure
> for `4-80400-H01-101-2001-00-000`; `346,568.08` is the **user total**. Both earlier drafts of this
> runbook made that substitution, which reports a passing step as a failure.

---

# Phase 5 — Application release

### Step 5.1 [WEB] Fix the Vite manifest — do this before building

`resources/views/app.blade.php:32` requests `resources/css/app.css`, but `vite.config.js:8` declares
only `resources/js/app.js` as an input, so a fresh build produces a manifest without that key and
`Vite::asset()` throws `ViteException` on **every** page. `resources/js/app.js:1` already does
`import '../css/app.css'`, so the JS entry emits the CSS itself.

Change line 32 of `resources/views/app.blade.php` to:

```blade
@vite(['resources/js/app.js'])
```

The test suite cannot catch this — `Tests\TestCase` calls `withoutVite()` — so the check is manual.

### Step 5.2 [WEB] [VERIFY] Build from clean and confirm the manifest

```bash
rm -rf public/build
npm ci
npm run build
cat public/build/manifest.json | head -40
```

**PASS:** build succeeds, and the manifest contains an entry for `resources/js/app.js` with a `css`
array. No page may reference a manifest key that is absent.

### Step 5.3 [WEB] [VERIFY] Run the test suite

```bash
SQLSRV_HOST=127.0.0.1 php artisan test
```

The override is required: SQL Server is native on Windows while `.env` points `SQLSRV_HOST` at
`host.docker.internal` for the Docker app, and `phpunit.xml` runs the suite from the Windows host.
Laravel loads `.env` with `Dotenv::createImmutable`, so a real environment variable wins and nothing
on disk changes. **Do not edit `.env`.**

**PASS:** **0 failed.** Expect ~199 passed with ~6 skipped; every skip must be a premise guard
("this user sees one department"), never a connection timeout. A run where ledger cases skip on
timeout has verified almost nothing.

### Step 5.4 [WEB] Deploy and clear caches

```bash
php artisan optimize:clear
php artisan cache:clear file
```

`cache:clear file` is separate and necessary — the filter caches live on the `file` store and plain
`cache:clear` will not touch them.

### Step 5.5 [WEB] [VERIFY] Click through all six pages

Sign in as a user with access (**`FFIGUERA1`** — `KCHARLES1` and `SBHIM1` have no mapping today and
will correctly see empty pages).

| Page | Check |
|---|---|
| Dashboard | KPIs render; Total Budget and YTD **unchanged** |
| Budget Allocations | renders; the 11 split accounts appear **twice** in FY2026 |
| Monthly Expenditure | renders; totals row matches the sum over all pages |
| Variance | renders; Excess / Balance up by ~850,193 in total |
| **Encumbered Details** | **no year banner, no prev/next**; required **Fiscal Year** select is the first filter; negative Extended Cost present; withheld years named under the select |
| **Routing Details** | same, and no negatives (RT/HD/PN carry no shipments) |

Also: arrow keys scroll table columns but **no longer step years** on those two pages, while the four
banner pages still step years. "Clear all" keeps the selected year. Changing the year auto-applies and
updates the URL.

### Step 5.6 [WEB] [VERIFY] Exports

Click Export on all six pages. Then open one file per page in Excel on Windows — the last outstanding
item from `export.md` §11.

**PASS:** each downloads; negative Extended Cost appears as a raw negative decimal (e.g. `-48000.00`),
never text, never `-0.00`; `?page=1` and `?page=2` produce byte-identical bodies.

---

# Phase 6 — Restore normal operation

### Step 6.1 [DB] Re-enable the Agent job and run it once by hand

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh', @enabled = 1;
EXEC msdb.dbo.sp_start_job  @job_name = N'SWRHA Finance - Ledger Refresh';
```

**PASS:** both steps succeed under the Agent's own credentials, and both refresh logs gain an `OK`
row from the same run.

### Step 6.2 [WEB] [VERIFY] Health check

```bash
SQLSRV_HOST=127.0.0.1 php artisan ledger:status
```

**PASS:** exits **0**, and reports both snapshots as fresh and **from the same run**. A non-zero exit
means either a stale snapshot or drift between the two — both are stop conditions.

### Step 6.3 [DB] Drop the scratch objects — only after sign-off

Keep them until Finance has signed off; they are the only way to re-prove parity in place.

```sql
DROP FUNCTION IF EXISTS dbo.fn_FinanceLedgerAccessParity;
-- Keep fn_OversightDraftVerbatim / fn_OversightDraftUnscoped: they are the Access
-- query itself and the basis of every future parity check.
```

The `_ParityBackup` tables stay until Finance signs off one full period close. **Give that cleanup a
named owner and a date** — the repo already carries undropped `*_OversightBackup` tables from
2026-08-26.

### Step 6.4 Outstanding, tracked separately

- 🔴 **No monitoring on production**, open since 2026-08-26. This release changes every money figure
  and adds gates that can abort for new reasons. `scripts/register-health-check-task.ps1` and
  `sql/FinanceDatabaseMail.sql` are written and have never been applied.
- **Finance sign-off** on FY2026 against Access.
- **`Overview.md`** rewrite explaining the split rows, the negative encumbrances and the changed
  account descriptions in plain language. Without it, all three will be reported as portal bugs.
- Two unattended nightly runs, one exercising the 1st-of-month branch.

---

# Rollback summary

| Undo | How | Cost |
|---|---|---|
| Ledger code | Re-run `sql/FinanceLedger.sql` (idempotent, still holds pre-parity definitions) | seconds |
| Requisition code | Re-run `sql/FinanceRequisition.sql` | seconds |
| Ledger data | `DELETE FROM dbo.FinanceLedgerSnapshot;` + `INSERT ... SELECT * FROM dbo.FinanceLedgerSnapshot_ParityBackup;` | seconds |
| Requisition data | Same from `FinanceRequisitionSnapshot_ParityBackup` | seconds |
| Added columns | `ALTER TABLE ... DROP COLUMN AccountID` on snapshot **and** `_Staging` — **required**, because the restored pre-parity function does not project it and the drift guard throws `51001` while the column exists | seconds |
| Refresh logs | Restore from the two `*Refresh_ParityBackup` tables | seconds |
| App | `git checkout <SHA from Step 0.3>` + `npm ci && npm run build` + `php artisan optimize:clear` | minutes |

**Roll back both sides together.** The ledger and the requisition snapshot must be on the same basis
or gate F aborts every night.

## Stop conditions

Any of these means stop and roll back, not push on:

- GATE 1 reports anything non-zero
- Drift rows at Step 3.1
- FY2026 not `PASS` at GATE 2, or any year failing at Step 4.2
- Any `Outcome = 'ABORTED'` in either refresh log
- `ReconMismatches > 0` or `ReconStaleYearDrift > 0` at GATE 3
- `SplitAccountCount` above the GATE 1 baseline with no named explanation
- Any user's accessible-account count falling to zero
- `ledger:status` exiting non-zero
