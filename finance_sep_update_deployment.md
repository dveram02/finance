# Finance September Update — Deployment Runbook

**Access parity + the fiscal-year control change.** Run by hand, step by step, verifying each step
before starting the next.

- **Design:** `financeupdatesep.md` · **Status log:** `financeupdatesepprogress.md`
- **Also released in this pass:** the self-service password change — design, measurements and
  verification in `passwordreset.md`. It is the only part of this release that needs a database
  **permission** (Steps 5.8–5.11) and the only part that writes to a table this project does not own.
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

**PASS:** **0 failed.** Expect **~350 passed with 7 skipped** (measured 2026-10-03; the figure was
~199/6 when this runbook was written, before the password-change, `DirectoryFlag` and
active-window suites were added). Every skip must be a premise guard ("this user sees one
department"), never a connection timeout. A run where ledger cases skip on timeout has verified
almost nothing.

⚠️ **Failures mixed with a HIGH skip count mean the DB link died partway through the run**, not that
the code is broken. `UsesLedgerData` probes once at setup and skips if SQL Server is unreachable;
a connection that dies mid-test is past that guard and fails. A clean outage is all skips and zero
failures (verified: 134 skipped, 223 passed, 0 failed). Re-run before investigating.

### Step 5.4 [WEB] Deploy, set the new config keys, and clear caches

**Three new `.env` keys ship with this release.** Add all three BEFORE clearing caches. The first
is the deploy-first kill switch and **must go out as `false`** — the grant does not exist yet at
this point in the runbook, and with the switch off the route refuses and the card does not render.

```
DIRECTORY_PASSWORD_CHANGE=false
ACTIVE_USER_TTL_SECONDS=60
ACTIVE_USER_OUTAGE_RETRY_SECONDS=15
```

All three are normalised in code and every one of them fails closed, so a typo degrades rather
than breaks: an unusable `ACTIVE_USER_TTL_SECONDS` falls back to 60 (it can be neither 0 — which
would be a directory round trip on every request — nor so large that the check never runs), and
anything but a true value leaves the password feature off.

```bash
php artisan optimize:clear
php artisan cache:clear file
```

`cache:clear file` is separate and necessary — the filter caches live on the `file` store and plain
`cache:clear` will not touch them.

⚠️ **This release also changes authentication behaviour, independently of the password feature and
with no database dependency:**

- **`IsActive` is now read correctly.** It is a `varchar` holding the strings `'TRUE'`/`'FALSE'`,
  and `(bool) 'FALSE'` is `true` in PHP — so until now, **setting that flag did not deactivate
  anyone**. Nothing had broken only because every production row is `'TRUE'` and the flag had never
  been used. After this release it works. If Finance has ever set a row to `'FALSE'` expecting it
  to take effect, **that user loses access on this deploy** — check before releasing:
  `SELECT UserName, IsActive FROM dbo.[0006AWebAppControls];`
- **The active-status trust window drops from 5 minutes to 60 seconds.** The cost is bounded per
  USER, not per request (the timestamp lives on the local `users` row), so this is at most one
  directory read per active user per minute.

### Step 5.5 [WEB] [VERIFY] Click through all six pages

Sign in as a user with access (**`FFIGUERA1`** — `KCHARLES1` and `SBHIM1` have no mapping today and
will correctly see empty pages).

| Page | Check |
|---|---|
| Dashboard | KPIs render; Total Budget and YTD **unchanged** |
| Budget Allocations | renders; the 11 split accounts appear **twice** in FY2026 |
| Monthly Expenditure | renders; totals row matches the sum over all pages |
| Variance | renders; Excess / Balance up by ~850,193 in total |
| **Encumbered Details** | **no year banner, no prev/next**; the **Fiscal Year** select is the first filter and is **OPTIONAL, opening on "All Fiscal Years"**; the gold period chip beside the title reads **"All available fiscal years"**; no `fy` in the URL and **no filter badge**; negative Extended Cost present; withheld years named under the select |
| **Routing Details** | same, and no negatives (RT/HD/PN carry no shipments). Note it offers **noticeably fewer years** than Encumbered — 3 against 11 when measured — which is correct: the eligible set is route-specific |

Also: arrow keys scroll table columns but **no longer step years** on those two pages, while the four
banner pages still step years. Changing the year auto-applies and updates the URL.

⚠️ **Two rows of this table were inverted until 2026-10-01**, and someone following them would have
logged a correct build as a failure. Fiscal year became an **optional** filter on these two pages
(`routingupdate.md`), so:

| Was | Now |
|---|---|
| "**required** Fiscal Year select" | optional, defaulting to All Fiscal Years |
| "'Clear all' **keeps** the selected year" | **"Clear all" returns the year to All**, like every other filter — and a chosen year **counts in the filter badge** |

Select a year and confirm the chip reads `FY 2026 · Oct 2025 – Sep 2026` with the badge at 1, then
"Clear all" and confirm it returns to "All available fiscal years" with no badge and no `fy` in the
URL. **No year shows "Current"** — the current FY is 2027 and the newest selectable year is 2026.

### Step 5.6 [WEB] [VERIFY] Exports

Click Export on all six pages. Then open one file per page in Excel on Windows — the last outstanding
item from `export.md` §11.

**PASS:** each downloads; negative Extended Cost appears as a raw negative decimal (e.g. `-48000.00`),
never text, never `-0.00`; `?page=1` and `?page=2` produce byte-identical bodies.

🆕 **The two requisition files now have two filename shapes**, because the year is optional:

| Scope | Filename | Contents |
|---|---|---|
| All Fiscal Years (the default) | `encumbered-details-<date>-<time>.csv` — **no `fy` segment** | every eligible year; its distinct `Financial Year` set must equal the dropdown's |
| A selected year | `encumbered-details-fy2026-<date>-<time>.csv` | that year only |

A missing `fy` segment is correct, not a bug — a filename must not claim a scope the file does not
have.

### Step 5.7 [WEB] [VERIFY] The row-ceiling guard

New with `routingupdate.md`. The all-years default means the read is bounded by
`FINANCE_REQUISITION_ROW_CEILING` (default 25,000) rather than by one fiscal year. It is unreachable
with real data today — 416 rows for the only mapped user — so it is verified by lowering the ceiling.

```
# In .env on the WEB server, then: php artisan config:clear
FINANCE_REQUISITION_ROW_CEILING=10
```

⚠️ **Walk ALL FOUR branches.** They produce different URLs and different messages, and testing only
one is how a `?fy=0` redirect bug survived two review rounds.

| Start at | Expect |
|---|---|
| `/encumbered-details` (no `fy`) | **302** → `?fy=<newest>`; the flash names that year as **selected** (not "shown"), and contains a real year, never a literal `:year`; the page then shows the amber refusal block |
| `/encumbered-details?fy=<newest>` | **no redirect**; refusal block; the Fiscal Year select is still **enabled and populated** |
| `/encumbered-details/export` | **302** → `?fy=<newest>`; flash begins **"No file was created…"**; **nothing downloads** |
| `/encumbered-details/export?fy=<newest>` | **302** → `?fy=<newest>` — **the same year, never `fy=0`**; the single-year flash; nothing downloads |

**PASS, on the refusal page:** **no "TTD 0" anywhere** and the KPI grid is **absent** rather than
zeroed; **no** "No requisition lines found"; the **export button is absent** rather than a disabled
control blaming the data; the **other six selects are disabled** with the explanatory note; the
totals row and pagination are **absent**. An oversized result must never read as an empty one.

**Then restore the ceiling** (remove the line or set it back to 25000) and `php artisan config:clear`
again. Note an `.env` edit alone does nothing under `config:cache` — the config must be rebuilt and
the FastCGI workers recycled.

### Step 5.8 [DB] [VERIFY] Confirm the grant matches the standing permission

New with `passwordreset.md`. The self-service password change is the **only write this application
performs**. It writes to `SWRHAExpenseControl.dbo.0006AWebAppControls`, which is a **pre-existing
table** — but this project holds a standing permission to edit **exactly four of its columns**, and
the grant is cut to match that permission precisely and nothing wider.

| | |
|---|---|
| Columns | `UserPassword`, `LastEditedBy`, `DateEdited`, `TimeEdited` — **column-level**, nothing else |
| Predicate | `WHERE LineID = ?` (the primary key), never `WHERE UserName = ?` |
| Precondition | the user's current password is verified with `hash_equals` first |
| Ambiguity | a `UserName` matching anything other than exactly one row is **refused**, not resolved |
| Audit | `LastEditedBy` = the user's display name, `DateEdited`/`TimeEdited` from `SYSDATETIME()` |

🔴 **The four columns are the whole permission. Nothing else on this table, and nothing on any
other pre-existing table, may be written** — see the hard rule in `CLAUDE.md`. If a future change
appears to need a fifth column, that is a design error, not a grant to widen.

**Confirm the production login name before granting.** Dev uses `finance`; production's
`SQLSRV_USERNAME` must be checked, because granting to the wrong principal fails **silently**.

Nothing else in the release depends on this step. The application ships with the feature switched
off and works normally without the grant, so it can be deferred without holding anything up.

```sql
SELECT name, type_desc FROM sys.database_principals WHERE name = N'finance';
```

### Step 5.9 [DB] Capture the password baseline, then apply the grant

**Baseline first.** Script the output to a file held **off** the database server. It is the restore
path for a mangled password, there are only three rows, and it costs nothing.

```sql
USE SWRHAExpenseControl;
SELECT LineID, UserName, UserPassword, IsActive, LastEditedBy, DateEdited, TimeEdited
FROM   dbo.[0006AWebAppControls]
ORDER  BY LineID;
```

Then run **`sql/GrantPasswordUpdate.sql`**, which contains the principal check, the grant and the
verification queries. The grant itself is:

```sql
GRANT UPDATE (UserPassword, LastEditedBy, DateEdited, TimeEdited)
    ON OBJECT::dbo.[0006AWebAppControls] TO [finance];
```

🔴 **Never widen this to a table-level `GRANT UPDATE`.** Nothing is simplified and the blast radius
becomes `PositionID` — the access-control key `vw_WebAppUserAccess` joins on to decide whose
departmental money a user can see. A bug that wrote it would be a privilege escalation. The
column-level grant makes that impossible at the database rather than by code review.

### Step 5.10 [DB] [VERIFY] Confirm the grant is exactly four columns

```sql
SELECT HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','UserPassword') AS pw,
       HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','LastEditedBy') AS editor,
       HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','IsActive')     AS must_be_zero,
       HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','PositionID')   AS must_also_be_zero;

SELECT p.permission_name, p.state_desc, c.name AS column_name
FROM   sys.database_permissions p
LEFT  JOIN sys.columns c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE  p.major_id = OBJECT_ID('dbo.[0006AWebAppControls]')
  AND  p.grantee_principal_id = DATABASE_PRINCIPAL_ID('finance')
ORDER  BY c.name;
```

**PASS:** `pw` and `editor` are **1**, both `must_be_zero` columns are **0**, and the second query
returns **exactly four rows** — one per granted column — and no table-level row.

A `must_be_zero` of 1 means someone granted at table level. **Stop, `REVOKE`, and re-run Step 5.9.**

### Step 5.11 [WEB] Enable the feature and verify it end to end

Only now. Up to this point the application has been running with the card absent and the route
refusing, which is the correct deploy-first state.

```
# In .env on the WEB server, then: php artisan config:clear
DIRECTORY_PASSWORD_CHANGE=true
```

Note an `.env` edit alone does nothing under `config:cache` — the config must be rebuilt and the
FastCGI workers recycled, the same caveat as Step 5.7.

Then, signed in as **`FFIGUERA1`**, on `/profile`:

| Check | Expect |
|---|---|
| Right column, under Account Status | a **Security** card with a **Change Password** button |
| Click it | a modal opens, focus lands in **Current password** |
| Escape / click outside / Cancel | closes, and focus returns to the button |
| Wrong current password | inline error **under that field**; the modal **stays open**; no page-level flash |
| A non-ASCII new password (`pàsswörd1`) | rejected with the character message — this is the **lockout guard**, not a style rule |
| A valid change | modal closes, green **"Your password has been changed."**, and you are **still signed in** |
| Sign out, sign in with the **new** password | works; the **old** password is rejected |

Then confirm the write in SSMS:

```sql
SELECT UserName, UserPassword, DATALENGTH(UserPassword) AS bytes, LEN(UserPassword) AS chars,
       LastEditedBy, DateEdited, TimeEdited, IsActive, PositionID
FROM   dbo.[0006AWebAppControls] WHERE UserName = 'FFIGUERA1';
```

**PASS:** the new password is present; **`DATALENGTH = LEN`** (no encoding expansion — a mismatch
means a character was mangled on the way in and that account is locked out); `LastEditedBy` is the
user's display name and `DateEdited` is today; and **`IsActive`, `PositionID` and `EmployeeID` are
unchanged**, as are the other two rows.

**Then change the password back** through the same UI, which exercises the path twice.

⚠️ **Tell the users before, not after.** This password is shared with every SWRHA application that
uses the account — the portal does not own this directory, it shares it. The form says so, but the
first someone hears of it should not be the form.

Finally, confirm no password material reached the log:

```bash
grep "Directory password" storage/logs/laravel.log | tail -5
```

**PASS:** lines read `Directory password changed. {"username":"..."}` — username and outcome only,
never a value and never a match flag.

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
- ✅ **Resolved 2026-10-03, all three** (`passwordreset.md` §15): the login outage message, the
  `TimeEdited` precision, and the narrow-viewport check. Nothing outstanding on the password
  change beyond the DBA applying the grant (Steps 5.8–5.9).

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
| Password change, instantly | `DIRECTORY_PASSWORD_CHANGE=false` + `php artisan config:clear`. **Try this first** — no DBA, no redeploy | seconds |
| Directory write permission | `sql/GrantPasswordUpdateRollback.sql` (the matching `REVOKE`). The service catches the permission error and shows "could not be changed right now", not a 500 | seconds |
| A mangled password | One `UPDATE ... WHERE LineID = ?` from the Step 5.9 baseline, by the DBA. Note passwords already changed by users are **not** reverted by any of the above | minutes |
| Active-window change | `ACTIVE_USER_TTL_SECONDS=300` restores the old 5-minute behaviour without a redeploy | seconds |
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
- Step 5.10 showing `UPDATE` on any column other than the four named — `REVOKE` and re-grant
- Step 5.11 showing `DATALENGTH <> LEN` on a changed password — a character was mangled and that
  account is locked out; restore it from the Step 5.9 baseline before going further
