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

## Confirmed starting state

🆕 **Re-measured 2026-10-05 on the 05-10-2026 production restore.** Every figure below moved
between the two runs because production refreshes nightly. **The 2026-10-05 column is the live
expectation; the 2026-09-30 column is kept only so a reader can tell drift from a defect.** A figure
that differs from the newer column is information — re-measure before calling it a failure.

| | 2026-09-30 (first rehearsal) | **2026-10-05 (current)** |
|---|---|---|
| `fn_FinanceLedgerSource` / `usp_RefreshFinanceLedgerSnapshot` / `usp_RefreshFinanceRequisition` | pre-parity | **pre-parity** |
| `AccountID`, `AccountsLoaded`, `SplitAccountCount` | absent | **absent** |
| Scratch parity/draft functions, `_ParityBackup` tables | absent | **absent** |
| `FinanceLedgerSnapshot` FY2026 | 2,265 rows / Approved 95,760,870.05 | **2,267 rows / Approved 99,890,944.67** |
| `FinanceLedgerSnapshot` FY2025 | 2,117 rows / Approved 74,173,406.72 | **2,117 rows / Approved 74,173,406.72** (unchanged) |
| `FinanceRequisitionSnapshot` | 108,435 rows, **0** negative balances | **109,104 rows, 0** negative balances |
| `FinanceLedgerRefresh` / `FinanceRequisitionRefresh` | 13 / 35 rows, last OK 2026-09-28 21:33 | **13 / 43 rows, last OK 2026-10-04 21:31** |
| Agent job `SWRHA Finance - Ledger Refresh` | **not present on this instance** (`msdb` not restored) | **not present** (`msdb` not restored) |

The FY2026 snapshot figures above were **confirmed identical on production itself** on 2026-10-05
(2,267 / 99,890,944.67), so the restore is faithful.

### 🛑 The local instance is NOT plan-equivalent to production — read before trusting a gate result

| | Local restore | Production |
|---|---|---|
| Build | SQL Server 2022 **RTM, 16.0.1000.6** (no CU) | SQL Server 2022, `sqlapp\SQLEXPRESS` |
| Edition | **Developer**, `EngineEdition` **3** | **Standard**, `EngineEdition` **2** |
| `max server memory` | 2048 MB | — |
| `cpu_count` | **12** | — |
| instance `MAXDOP` / cost threshold | **12** / **5** | — |
| DB compatibility level | 160 | — |

🔴 **Two consequences, both load-bearing:**

1. **`OPTION (MAXDOP 1)` is REQUIRED here or the gate hangs.** Measured 2026-10-05: materialising
   `fn_FinanceLedgerAccessParity('2026')` into a temp table at the instance default (DOP 12) **stalled
   for 11 minutes** on `CXSYNC_PORT` having done **2,293 logical reads and zero tempdb allocation** —
   a parallel-exchange stall, not work, on an RTM build with known `CXSYNC_PORT` hangs. The identical
   statement with `OPTION (MAXDOP 1)` completed in **12.3 s**. The gate materialises 26 such result
   sets, so uncapped it will hang rather than take its documented ~70 s. Cap **both sides**, never one
   — a one-sided cap introduces a plan asymmetry into the very comparison being made.
2. 🔴 **Capping MAXDOP CHANGES FLOAT ADDITION ORDER, which is the subject of the open cent
   disagreement** (see `financeupdatesepprogress.md`, 2026-10-05). So a MAXDOP-capped pass here is
   **not** evidence that production passes uncapped, and a failure here is not evidence production
   fails. **Production must be re-gated on production.** Treat this instance as the place to develop
   and prove the comparison logic, not as a proxy for production's arithmetic.

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

**PASS — these are the Access figures and the whole point of the release.** 🆕 **Re-measured
2026-10-05 on the current restore (9.7 s, uncapped — the draft side does not stall).** Use the
2026-10-05 column.

| Check | 2026-09-29 | **2026-10-05 (current)** |
|---|---|---|
| SCOPED_2026 rows / alloc | 14 · 7,548,334.91 | **14 · 7,548,334.91** |
| SCOPED_2026 approved | 346,568.08 | **428,008.08** |
| UNSCOPED_2026 rows / accounts | 2275 · 2264 | **2278 · 2267** |
| UNSCOPED_2026 alloc | 242,817,848.69 | **242,817,848.69** |
| UNSCOPED_2026 ytd | 254,553,116.94 | **254,553,116.94** |
| UNSCOPED_2026 approved | 83,803,914.38 | **88,092,538.18** |
| UNSCOPED_2026 routing | 12,637,933.09 | **12,401,480.96** |

**The shape of that drift is itself a check.** `alloc` and `ytd` are identical **to the cent** across
the six days, while the encumbrance figures and the row counts moved. That is requisitions churning
daily against an FY2026 GL that has not posted since — consistent with the posting-boundary rule, and
what you should expect to see. If `ytd` or `alloc` ever moves between two runs days apart, that is a
GL posting and worth knowing about, not drift to wave through.

`2278 − 2267 = 11` split accounts, which is the FY2026 split count the next step asserts directly.

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
-- OPTION (MAXDOP 1) is not a tuning preference: at the local instance default
-- (DOP 12) this statement stalls on CXSYNC_PORT for 11+ minutes having done
-- ~2,300 logical reads. Capped, it is 12.3 s. See the plan-equivalence warning
-- under "Confirmed starting state". Drop the hint when running on production,
-- and record which way it was run.
SELECT * INTO #p FROM dbo.fn_FinanceLedgerAccessParity('2026') OPTION (MAXDOP 1);

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

🆕 **Re-measured 2026-10-05 (12.3 s, MAXDOP 1). ALL CHECKS PASSED.**

| Check | 2026-09-29 | **2026-10-05 (current)** | |
|---|---|---|---|
| `SHAPE` | 36 / 35 | **36 / 35** | ✅ |
| `EXTRA_COLUMN` | `AccountID` only | **`AccountID`** only | ✅ |
| `MISSING_COLUMN` | *(not previously checked)* | **none** | ✅ |
| `FY2026` rows / accts | 2275 · 2264 | **2278 · 2267** | |
| `FY2026` alloc / ytd | 242,817,848.69 · 254,553,116.94 | **242,817,848.69 · 254,553,116.94** | |
| `FY2026` approved / routing | 83,803,914.38 · 12,637,933.09 | **88,092,538.18 · 12,401,480.96** | |
| `SPLITS` | 11 | **11** | ✅ |
| `NO_COA_ROW` | one row, approved 98,350.00 | **one row: `4-87800-E04-101-2004-00-000`, description NULL, `E04`/`101`/`2004`, approved 98,350.00** | ✅ |

🔑 **The check that matters most here is not in the table above:** the parity function's FY2026
figures are **identical in all six values** to the draft's from step 1.2 — rows, accounts,
allocation, YTD, approved and routing. Two independent implementations landing on the same six
numbers is the substance of GATE 1 holding for FY2026, before the gate is run across all thirteen
years.

A `Warning: Null value is eliminated by an aggregate or other SET operation.` on this step is
expected and benign — the monthly columns are NULL where a month has no activity.

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
| 2019 | 1,835 | 0 | | 2026 | **2,278** (was 2,275) | 11 |
| 2020 | 1,882 | 0 | | | | |

🛑 **STOP on any non-zero.** Nothing live has changed — fix the function and repeat 1.3–1.4.
**Rollback:** `DROP FUNCTION dbo.fn_FinanceLedgerAccessParity;`

---

### ✅ GATE 1 FAILED TWICE ON A SINGLE CENT — RESOLVED 2026-10-06. Read this before re-running it.

**It failed identically on two different machines, and the cause is NOT a defect. If you see this
gate fail on one cent, do NOT "fix the function" — there is nothing wrong with it.** The fix was to
the GATES (see the RESOLVED section below); the parity function was never changed. Full analysis in
`financeupdatesepprogress.md` (2026-10-05, 2026-10-06).

| Run | Instance | Parallelism | Elapsed | Verdict |
|---|---|---|---|---|
| 2026-09-29 | test instance | default | ~70 s | **PASS**, 0 differences |
| 2026-10-05 | **production** `sqlapp\SQLEXPRESS` | default | — | **FAIL** 1/1 on FY2025 |
| 2026-10-06 | local restore (Developer) | **MAXDOP 1** | **226.9 s** | **FAIL** 1/1 on FY2025 |

Every run returns `mult_diffs = 0`, `years_with_rowcount_diff = 0`, `years_with_split_diff = 0` and
twelve of thirteen years byte-identical. The failure is always the same **single row**:

```
FY2025  4-76100-H01-203-0251-00-000  FOOD SUPPLIES  H01/203/0251  AccountID 12480
Feb   draft 818,966,030,193.12   parity ...93.11   delta -0.01
Q2 and YTDTotal carry the same cent; they are not separate findings.
```

🔴 **It is float non-associativity, and the PARITY SIDE IS THE CORRECT ONE.** `NetChange` is
`float`; both sides sum it as float (draft via `PIVOT`, parity via conditional `SUM`), so the two
query forms add in different orders. February for that account is 1,208 rows including entries at
1.77e12, where one ulp of a double is ~0.00024. Measured over those identical rows:

| How summed | Result | Rounds to |
|---|---|---|
| **Exact (`decimal`) — the true value** | 818,966,030,193.**109965** | **.11** |
| Production, default plan | …93.114746 | .11 |
| Local, parallel (DOP 12) | …93.110107 | .11 |
| **Local, `MAXDOP 1`** | …93.**115479** | **.12** |
| Production, forced small-values-first | …93.109863 | .11 |
| Production, forced large-values-first | …93.109253 | .11 |

**Five different float answers for one set of rows, and `MAXDOP` alone flips the cent.** The exact
value rounds to **.11**, which is what the parity function produces — **Access is the cent that is
wrong.** The gate fails because the new function is *more accurate* than its reference.

🔴 **The gate's own comparison reproduces it consistently — but the cent is not a fixed property of
either function, and this is the subtlety that matters.** Across all three runs the gate's
full-column comparison gives the draft `.12` and parity `.11`, on two different editions and at two
different DOPs. Yet `sql/Gate1Diagnose_FY2025.sql` **Part 2**, which re-materialises the *same two
functions* over a **reduced 9-column projection**, returned `draft_only 0, parity_only 0` — the
`YTDTotal` cent **agreed** — in the same session, at the same `MAXDOP 1`, minutes later.

That is the proof of what this is. SQL Server inlines these table-valued functions into the calling
query, so **the surrounding projection changes the plan, which changes the addition order, which
changes the cent.** The disagreement is a property of the *whole statement*, not of the parity
logic. Consequences:

- **No amount of tuning will make this gate pass**, and re-running it will not help.
- **Narrowing the comparison to make it agree would be self-deception** — Part 2 agrees because it
  compares fewer columns, not because the arithmetic improved.
- A future "it passed this time" is luck, not a fix, and must not be treated as evidence.

**Five accounts carry billion-scale entries** (all FY2025; two at 12,999,999,999,999.87, whose ulp
of ~0.002 makes them *more* exposed than the one that actually failed — they pass by luck). So the
gate is also **non-deterministic**: which account trips it can change between runs.

#### How much money is actually at stake — measured, not assumed

GATE 1 counts differing **rows**. "One row differs" is not the same claim as "the money differs by
one cent", so `sql/ParityMoneyDelta.sql` was written to measure the money directly: each side
materialised once per year, every figure converted to `decimal(19,2)` **per row** before summing so
the comparison adds no float error of its own. Measured 2026-10-06, all thirteen years:

| Figure | 13-FY total (draft) | Parity − draft |
|---|---|---|
| Allocation | 440,826,948.69 | **0.00** |
| Approved | 353,219,050.22 | **0.00** |
| Routing | 36,346,867.64 | **0.00** |
| YTDTotal | 3,694,251,307.70 | **−0.01** (FY2025 only) |
| Row count | — | **0 in every year** |

`months_delta` shows the same **−0.01** because `YTDTotal` is derived from the months — one cent
reported twice, which is why `total_abs` reads `0.02` rather than `0.01`. **The entire disagreement
between the portal and the finance department's Access query is one cent in 3.69 billion
(2.7e-12), and the portal is the correct side.**

### ✅ RESOLVED 2026-10-06 — the money tolerance, and GATE 1 now PASSES

Both gate scripts were changed. **They are read-only test harnesses: no data, no stored figure and
no page changed.** What changed is only what the test calls a failure.

- **Money columns compare at ≤ `@Tolerance` (default 0.01)**, and **every row that uses it is
  printed** in a `TOLERATED` block naming account, column, both values and the delta, with a
  summary carrying the largest delta seen and the tolerance in force. A tolerance you cannot see is
  a blind spot; this one is a standing measurement.
- **Grain is still EXACT** — row counts, per-grain-key multiplicity, split counts and the key
  columns carry no tolerance whatever.
- **The exact comparison is still computed and reported** per year as `exact_draft_only` /
  `exact_parity_only`, so a bit-identical year still reads as bit-identical.
- **A NULL-vs-value mismatch is never tolerated**, however small the implied delta — otherwise "no
  activity" and "exactly zero" would silently merge.
- **`@MaxDop`**: 0 on production, **1 on the local restore**. Applied to both sides or neither.
- **`@Tolerance = 0` restores the old all-or-nothing behaviour** — verified, not assumed: at 0 the
  FY2025 run returns `FAIL 1/1`, identical to before.

GATE 1 was also rewritten from thirteen copy-pasted blocks into **one loop**, so the comparison
exists once rather than thirteen times.

**MEASURED 2026-10-06 — local restore, `@MaxDop 1`, `@Tolerance 0.01`, 191.5 s:**

```
VERDICT  total_draft_only 0  total_parity_only 0  total_tolerated_rows 1
         total_exact_draft_only 1  total_exact_parity_only 1
         total_multiplicity_diffs 0  years_with_rowcount_diff 0
         years_with_split_diff 0   ->  PASS

TOLERATED  FY2025  4-76100-H01-203-0251-00-000  (AccountID 12480, H01/203/0251)
           Feb       818,966,030,193.12 -> ...93.11      -0.01
           Q2      3,714,287,202,312.62 -> ...12.61      -0.01
           YTDTotal        6,315,268.79 -> 6,315,268.78  -0.01
```

**Twelve of thirteen years are BIT-IDENTICAL** (`exact_draft_only 0`). FY2025 is the known float
artifact, and the three cells are **one cent propagating** — `Q2` and `YTDTotal` are derived from
`Feb` — not three defects.

🔑 **How to read this gate from now on:** `PASS` with a small, named `TOLERATED` list is the
expected healthy outcome. An **empty** `TOLERATED` list is stronger still (bit-identical
everywhere). What must be investigated is the list **growing beyond the known float-artifact
accounts**, or a delta **approaching 0.01 from below** — either means something other than
representation is moving.

**Do not deploy on the strength of this MAXDOP-capped local pass** — see the plan-equivalence
warning under "Confirmed starting state". The cap changes the float addition order, so this run is
not evidence about an uncapped one. **Production must be re-gated on production, with `@MaxDop 0`.**

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

**PASS (2026-09-29 data):** 22352 · 108435 · 13 · 35.

🆕 **Measured 2026-10-06 on the 05-10 restore: 22354 · 109104 · 13 · 43.**

🔑 **The row counts are NOT the check — they drift with production every night.** The check is that
the four backup counts **equal the four source counts**, which is why a `SOURCE_COUNTS` row was
added beside them. Confirmed identical 2026-10-06. Compare the two rows the script prints; do not
compare either against the numbers above.

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

🆕 **Captured 2026-10-06, local restore of the 05-10-2026 production databases — the PRE-PARITY
figures:**

| FY | accounts | Allocation | YTDTotal | Approved | Routing |
|---|---|---|---|---|---|
| 2026 | 2,267 | 242,817,848.52 | 254,553,116.94 | 99,890,944.67 | 12,166,750.08 |
| 2025 | 2,117 | 198,009,100.00 | 266,968,436.41 | 74,173,406.72 | 3,377,383.46 |
| 2024 | 1,886 | 0.00 | 252,965,146.64 | 35,416,144.98 | 3,458,987.64 |
| 2023 | 785 | 0.00 | −117,774,963.13 | 0.00 | 0.00 |
| 2022 | 1,020 | 0.00 | 268,601,782.14 | 0.00 | 0.00 |
| 2021 | 1,378 | 0.00 | 122,153,215.10 | 2,629,887.27 | 11,138,095.57 |
| 2020 | 1,882 | 0.00 | 477,424,672.57 | 30,722,030.39 | 3,996,245.41 |
| 2019 | 1,835 | 0.00 | 321,318,067.54 | 9,889,989.02 | 1,308,026.04 |
| 2018 | 1,864 | 0.00 | 316,277,169.72 | 5,720,249.10 | 577,312.09 |
| 2017 | 1,837 | 0.00 | 303,288,734.76 | 3,372,156.84 | 48,533.84 |
| 2016 | 1,697 | 0.00 | 272,943,370.48 | 2,683,555.61 | 732.00 |
| 2015 | 1,972 | 0.00 | 641,286,549.61 | 23,622,836.79 | 42,874.86 |
| 2014 | 1,814 | 0.00 | 314,246,008.91 | 146,088,238.33 | 26,615.95 |
| **TOTAL** | **22,354** | **440,826,948.52** | **3,694,251,307.69** | **434,209,439.72** | **36,141,556.94** |

🔴 **These figures are EXPECTED to change at the cutover, and two of them substantially. Do not
read the differences as defects:**

- **`Approved` 434,209,439.72 → ~353,219,050.22.** The parity change removes the zero floor on
  encumbrance, so over-received lines now carry a NEGATIVE commitment. This is the single largest
  visible movement in the release and it is deliberate — `financeupdatesep.md` has the rationale.
- **Row counts rise where accounts SPLIT.** Per-year the increase equals that year's split count:
  FY2026 2,267 → 2,278 (+11), FY2025 2,117 → 2,121 (+4), FY2018 1,864 → 1,867 (+3), FY2017
  1,837 → 1,840 (+3), FY2024 1,886 → 1,887 (+1), FY2015 1,972 → 1,973 (+1).
- **`Allocation` and `YTDTotal` barely move** — 440,826,948.52 → .69 and 3,694,251,307.69 → .70,
  sub-dollar, which is the float artifact documented at step 1.4, not a change in the money.
- **FY2023's negative YTD (−117.8M) is pre-existing source data**, not something this release
  introduces. It is unchanged by the cutover.

**Allocation is 0.00 for every year before FY2025** because `0040CBudgetsAllocation` holds no
earlier rows — source data, not a filter bug.

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

**PASS — the procedure returns one row.** 🆕 **Measured 2026-10-06 on the 05-10 restore, 15 s
(`DurationSeconds`), 17.1 s wall clock:**

| Column | 2026-09-29 | **2026-10-06 (current)** |
|---|---|---|
| RowsLoaded | 2275 | **2278** |
| TotalAllocation | 242,817,848.69 | **242,817,848.69** |
| TotalYTD | 254,553,116.94 | **254,553,116.94** |
| TotalApproved | 83,803,914.38 *(was 95,760,870.05)* | **88,092,538.18** *(was 99,890,944.67)* |
| TotalRouting | 12,637,933.09 | **12,401,480.96** |
| UndefinedLabelPct | 0.00 | **0.00** |
| AccountsLoaded | 2264 | **2267** |
| SplitAccountCount | **11** | **11** |

🔑 **The real check is not the column values — it is that they EQUAL the figures steps 1.2 and 1.3
produced.** All six money and count figures match the draft and the parity function exactly
(2278 / 2267 / 242,817,848.69 / 254,553,116.94 / 88,092,538.18 / 12,401,480.96). That is what proves
the refresh stored what the function computes. Compare against your own step 1.2/1.3 output, not
against the table above.

`TotalApproved` dropping 99,890,944.67 → 88,092,538.18 is the **encumbrance floor removal** — the
intended headline change, not a loss of data.

`@Force` was not needed. If it aborts, read the message before reaching for it.

⚠️ **This run was made with `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 1`** on the restored
database, because the refresh proc calls the source function internally and so cannot take a
per-statement hint — at the instance default this box stalls on `CXSYNC_PORT` (see the
plan-equivalence warning). It was 0 before and must be set back to 0 afterwards. **Production should
not need this**, and because the cap changes float addition order the stored cents here are specific
to this box.

### Step 3.3 [DB] [VERIFY] 🛑 GATE 2 — is the DATA right?

Run **`sql/ParitySnapshotCheck.sql`**. This compares the **stored snapshot rows** against the Access
query, per year.

> `sql/ParityReconciliation.sql` does **not** substitute for this. It compares function to function,
> so it passes whatever is in the snapshot and cannot detect a bad refresh.

**PASS:** FY2026 row reads `PASS` with `tol_draft_only = 0`, `tol_snap_only = 0`, `mult_diffs = 0`,
`draft_rows = snap_rows`, `draft_splits = snap_splits = 11`.

🆕 **Measured 2026-10-06, 97.6 s — FY2026 PASSED, and BIT-IDENTICALLY:**

```
PER_YEAR 2026  exact_draft_only 0  exact_snap_only 0  tol_draft_only 0  tol_snap_only 0
               tolerated_rows 0  max_abs_delta NULL  2278 = 2278  mult_diffs 0  splits 11 = 11  PASS
```

🔑 **`tolerated_rows 0` is the result to note.** The money tolerance was available and **was not
needed** — the stored snapshot matches Access to the cent on all 2,278 rows. The tolerance exists
for the float artifact at step 1.4; it did not quietly paper over anything here.

**Expected and NOT a failure:** every other year reports `FAIL`, with large `max_abs_delta` values
(FY2025 shows 3.7e12). They still hold pre-parity snapshot data and have not been rebuilt — Phase 4
fixes them. Those deltas are the pre-parity-vs-parity difference, not float noise. Only FY2026
matters at this gate. The `VERDICT` line will read **`FAIL - DO NOT PROCEED`** at this point *because
of those twelve years* — read the FY2026 row, not the verdict, until Phase 4 is done.

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

| Check | 2026-09-29 | **2026-10-06 (measured)** | |
|---|---|---|---|
| Split example | two rows (below) | **two rows, exactly as described** | ✅ |
| FFIGUERA1 accounts | 14 | **14** | ✅ |
| FFIGUERA1 **total** approved | 346,568.08 *(was 411,118.08)* | **428,008.08** | drift |
| FFIGUERA1 alloc | 7,548,334.91 | **7,548,334.91** | ✅ |
| FFIGUERA1 routing | 229,173.20 | **204,709.08** | drift |
| `4-80400-H01-101-2001-00-000` approved | 129,100.00 *(was 193,650.00)* | **193,650.00** | see below |

**Split example, verified 2026-10-06** — `4-87300-C20-101-2004-00-000` returns two rows:
`RENT & ACCOMODATION` (ytd 253,000.00, alloc 0.00, approved 0.00) and `RENT & ACCOMMODATION`
(ytd 0.00, alloc 521,336.04, approved 138,000.00). The one-M / two-M spelling split is the worked
example of the release and it reproduces exactly.

🔴 **FFIGUERA1's total approved is the figure to check, and the check is that it EQUALS step 1.2's
`SCOPED_2026` approved.** Measured 2026-10-06: both **428,008.08**. That is the portal agreeing with
Access for the only mapped user. Do not compare it against the 2026-09-29 number.

#### 🛑 The `4-80400-H01-101-2001-00-000` worked example is STALE — do not treat it as a failure

The runbook expected **129,100.00** post-parity against **193,650.00** pre-parity, the difference
being eight over-received lines on `PO00000202871`. On 2026-10-05 data that is no longer true, and it
was established by measurement rather than assumed:

| Source | Approved |
|---|---|
| `fn_OversightDraftUnscoped('2026')` — **Access itself** | **193,650.00** |
| `FinanceLedgerSnapshot` — the rebuilt parity snapshot | **193,650.00** |
| `FinanceLedgerSnapshot_ParityBackup` — **pre**-parity | **193,650.00** |

Pre-parity and post-parity are now **identical on that account**, so its lines are no longer
over-received and the floor removal has nothing to act on there. **Access and the portal agree
exactly**, which is what the step is actually for.

🔑 **The floor removal IS working — it has simply moved to other accounts.** Measured 2026-10-06,
**16 FY2026 accounts carry a negative commitment**, each sitting at 0.00 pre-parity:

| Account | Parity | Pre-parity | Delta |
|---|---|---|---|
| `4-87300-H05-401-0627-00-000` | **−500,000.00** | 0.00 | −500,000.00 |
| `4-75600-D02-401-0627-00-000` | **−239,149.40** | 0.00 | −239,149.40 |
| `4-87200-D01-304-0526-00-000` | **−26,643.32** | 0.00 | −26,643.32 |
| `4-87200-D02-304-0526-00-000` | **−26,643.32** | 0.00 | −26,643.32 |
| `4-87200-D03-304-0526-00-000` | **−26,643.32** | 0.00 | −26,643.32 |

FY2026 `Approved` total: **99,890,944.67 pre-parity → 88,092,538.18 parity.**

🔴 **LESSON FOR THIS STEP: never pin it to a named account again.** Which accounts are over-received
changes with daily shipment activity, so any single-account expectation goes stale within weeks and
reads as a deployment failure. **Check instead that (a) `COUNT(*) WHERE Approved < 0` is non-zero in
FY2026, and (b) the FY2026 `Approved` total fell by roughly 12M against the backup.** Both are
properties of the behaviour rather than of one row:

```sql
SELECT 'NEGATIVE_COMMITMENTS' AS chk, COUNT(*) AS accounts
FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear='2026' AND Approved < 0;

SELECT 'APPROVED_TOTALS' AS chk,
  (SELECT CONVERT(decimal(19,2),SUM(Approved)) FROM dbo.FinanceLedgerSnapshot_ParityBackup WHERE FinancialYear='2026') AS preparity,
  (SELECT CONVERT(decimal(19,2),SUM(Approved)) FROM dbo.FinanceLedgerSnapshot)              AS parity;
```

> **Do not confuse per-account and user-total figures** — an earlier draft of this runbook did, and
> it turns a passing step into a false alarm. The per-account values belong to one account; the
> 428,008.08-style figures are **user totals** across fourteen accounts.

**Note:** `FinanceRequisitionSnapshot` still reports **0** negative `ActBalance` rows at this point.
That is correct — Phase 2's snapshot has not been rebuilt in lockstep yet. Phase 4 does it, and
negatives appear there.

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

`TotalAllocation` moves in **one** year only: FY2026, by **+0.17**.

🆕 **CORRECTION 2026-10-06 — `TotalYTD` is NOT unchanged in every year, and the old "if it moves
anywhere, stop" rule is a FALSE STOP.** Measured: YTD moves in exactly **one** year, **FY2025, by
+0.01** — the known float artifact of step 1.4, the same cent, on the same account. Allocation
moves only in FY2026, by +0.17, as stated. **The correct rule: YTD must be unchanged everywhere
EXCEPT a sub-cent move in FY2025; anything larger, or in any other year, is a STOP.**

> ⚠️ **Verify this with aggregates computed SEPARATELY per side, then joined.** Joining the snapshot
> to the backup on `FinancialYear` and *then* summing is a per-year **cartesian product** and inflates
> both sides by the other's row count — it reported "6 years moved" before being corrected to the
> true answer of one. Easy mistake, convincing wrong answer:
>
> ```sql
> WITH s AS (SELECT FinancialYear, CONVERT(decimal(19,2),SUM(YTDTotal)) AS ytd
>            FROM dbo.FinanceLedgerSnapshot GROUP BY FinancialYear),
>      b AS (SELECT FinancialYear, CONVERT(decimal(19,2),SUM(YTDTotal)) AS ytd
>            FROM dbo.FinanceLedgerSnapshot_ParityBackup GROUP BY FinancialYear)
> SELECT s.FinancialYear, s.ytd - b.ytd AS ytd_delta
> FROM s JOIN b ON b.FinancialYear = s.FinancialYear WHERE s.ytd <> b.ytd;
> ```

### 🆕 Measured 2026-10-06 — step 4.1 on the 05-10 restore: **185.8 s, all 13 years `OK`**

Far under the 15–45 minute budget (serial, `MAXDOP 1`; per-year `DurationSeconds` 10–19).

| FY | rows | AccountsLoaded | Splits | TotalApproved before → after |
|---|---|---|---|---|
| 2026 | 2,278 | 2,267 | 11 | 99,890,944.67 → **88,092,538.18** |
| 2025 | 2,121 | 2,117 | 4 | 74,173,406.72 → **49,572,302.86** |
| 2024 | 1,887 | 1,886 | 1 | 35,416,144.98 → **14,578,345.22** |
| 2023 | 785 | 785 | 0 | 0.00 → 0.00 |
| 2022 | 1,020 | 1,020 | 0 | 0.00 → 0.00 |
| 2021 | 1,378 | 1,378 | 0 | 2,629,887.27 → 2,629,887.27 |
| 2020 | 1,882 | 1,882 | 0 | 30,722,030.39 → **26,469,743.06** |
| 2019 | 1,835 | 1,835 | 0 | 9,889,989.02 → **9,516,144.20** |
| 2018 | 1,867 | **1,864** | 3 | 5,720,249.10 → **−1,444,587.97** |
| 2017 | 1,840 | **1,837** | 3 | 3,372,156.84 → **−3,974,133.73** |
| 2016 | 1,697 | 1,697 | 0 | 2,683,555.61 → **2,401,407.89** |
| 2015 | 1,973 | 1,972 | 1 | 23,622,836.79 → **19,761,636.34** |
| 2014 | 1,814 | **1,813** | 1 | 146,088,238.33 → **145,615,766.90** |

**Three documented oddities all reproduced exactly:** FY2017 and FY2018 go negative at
**−3,974,133.73** and **−1,444,587.97** — *identical to the 2026-09-30 predictions*, because those
years are closed and their source does not drift. FY2014 holds its row count (1,814 → 1,814) while
`AccountsLoaded` reveals **1,813** distinct accounts. Every row `Outcome = 'OK'`, no `ABORTED`.

🔑 **Why the CLOSED years match the predictions to the cent and the open years do not.** FY2014–FY2023
match because their source is frozen; FY2024–FY2026 drift because requisitions churn daily. **A
corollary that is easy to get wrong: for FY2026 the before/after comparison is NOT a clean parity
comparison at all.** The `_ParityBackup` row was built by the nightly job on **2026-10-04 21:31**,
while the rebuild reads today's source — so its delta mixes the parity change with two days of
requisition movement. That is why FY2026 `TotalRouting` **rose** (12,166,750.08 → 12,401,480.96),
which removing a floor alone can never do. **Judge the open years against the step 1.2/1.3 draft
figures, not against the backup.**

The earlier claim that Routing falls in FY2024 by 107,341.68 and FY2025 by 0.01 is also drift-bound:
measured 2026-10-06, FY2024 Routing is **unchanged**, FY2025 fell by **29,420.18** and FY2026 rose.
Do not expect specific Routing deltas.

> `usp_RefreshFinanceLedgerSnapshotAll` logs a failing year and continues, throwing only at the end —
> so **read this table** rather than trusting the absence of an error.

### Step 4.2 [DB] [VERIFY] Re-run GATE 2 across all years

Run **`sql/ParitySnapshotCheck.sql`** again.

**PASS:** `VERDICT` reads `PASS - the stored snapshot matches Access`, `years_failing = 0`, and all 13
per-year rows `PASS`.

🆕 **Measured 2026-10-06 — PASSED, 99.7 s, `years_failing = 0`, all 13 years `PASS`:**

```
VERDICT  years_checked 13  years_failing 0  total_missing_from_snapshot 0
         total_extra_in_snapshot 0  total_tolerated_rows 1
         total_multiplicity_diffs 0   ->  PASS - the stored snapshot matches Access

TOLERATED  FY2025  4-76100-H01-203-0251-00-000  Feb  818,966,030,193.12 -> ...93.11  -0.01
```

**Twelve of thirteen years are BIT-IDENTICAL to Access** (`exact_draft_only 0`, `exact_snap_only 0`,
`tolerated_rows 0`), including every year with splits. Row counts and split counts match in all
thirteen.

🔑 **Note which cells the tolerance absorbed here: `Feb` ALONE.** In the GATE 1 run the same account
reported `Feb`, `Q2` **and** `YTDTotal`; here `Q2` and `YTDTotal` agree and only `Feb` differs. Same
data, same account, same cent, different set of columns — **this is the plan-dependence documented at
step 1.4 showing up again, and it is the reason the tolerance is per-cell rather than per-figure.**
Do not expect the tolerated list to be identical between runs; expect it to stay *small and on known
accounts*.

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

🆕 **Measured 2026-10-06 — GATE 3 PASSED, 38 s (38.6 s wall clock):**

| Field | Expected | **Measured** | |
|---|---|---|---|
| `Outcome` | `OK` | **OK** | ✅ |
| `ReconMismatches` | **0** | **0** | ✅ |
| `ReconStaleYearDrift` | **0** | **0** | ✅ |
| `ReconAccountsCompared` | ≈22,351 | **22,354** | ✅ |
| `DuplicateGrainRows` | 0 | **0** | ✅ |
| `RowsLoaded` | — | 109,256 (16 FYs) | |
| `UnparsedSegmentRows` | 685 | **685** (unchanged) | ✅ |
| `TotalApproved` / `TotalRouting` | *not comparable — see warning above* | 362,698,460.83 / 37,207,767.10 | |

🔑 **The `ReconStaleYearDrift` transition is the evidence this phase ordering works.** The preceding
**nightly** row (2026-10-04 21:31) shows `ReconStaleYearDrift = **9**`; this run shows **0**. Under
the nightly job only two years are freshly rebuilt, so nine years legitimately sat outside the 36-hour
window; rebuilding all thirteen first — the deliberate order change at the head of this phase —
brings it to zero and makes the gate unambiguous. **A non-zero value here would mean a year did not
rebuild.** (The runbook previously said the nightly rows show 7; measured 2026-10-06 it is 9. The
number depends on when the nightly job last ran — do not treat a specific value as expected.)

`ReconAccountsCompared` came in at **22,354**, slightly *above* the predicted 22,351 rather than
below — the freshness `INNER JOIN` is reconciling every year, which is what this figure exists to
confirm.

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

| Check | 2026-09-30 | **2026-10-06 (measured)** | |
|---|---|---|---|
| FY2026 negative lines / accounts / value | 694 · 62 · −17,363,584.00 | **674** · **59** · **−17,265,069.60** | ✅ non-zero |
| `detail_approved` = `summary_approved` | 346,568.08 | **428,008.08 = 428,008.08** | ✅ **exact** |
| `detail_routing` = `summary_routing` | 229,173.20 | **204,709.08 = 204,709.08** | ✅ **exact** |

🔑 **The equality is the point, not the value: detail and summary must agree TO THE CENT.** Both
pairs matched exactly on 2026-10-06. That is Phase 2's reconciliation surviving all the way through
to the views the pages actually read — and it is the check to make, because the absolute figures
drift daily while the equality must never break.

The negative-line counts drifted (694 → 674 lines, 62 → 59 accounts) for the same reason as
everything else open-year: shipment activity. **Check that they are NON-ZERO**, not that they match
a stored number — they were 0 before the cutover, so non-zero is the signal that the floor removal
reached the requisition snapshot.

> Same warning as Step 3.4 — do **not** expect `129,100.00` here. That is a **per-account** figure;
> these are **user totals**. Both earlier drafts of this runbook made that substitution, which
> reports a passing step as a failure.

> Same warning as Step 3.4 — do **not** expect `129,100.00` here. That is the **per-account** figure
> for `4-80400-H01-101-2001-00-000`; `346,568.08` is the **user total**. Both earlier drafts of this
> runbook made that substitution, which reports a passing step as a failure.

---

# Phase 5 — Application release

### Step 5.1 [WEB] ✅ ALREADY DONE — fixed in `45652ae` (2026-10-01), verified again 2026-10-06

**Do not make the edit this step used to describe. It is already applied, and the description of
`vite.config.js` below the fix line was wrong in a way that would break things if acted on.**

Verified in the working tree 2026-10-06:

| File | State |
|---|---|
| `resources/views/app.blade.php:41` | `@vite(['resources/js/app.js'])` — JS entry only ✅ |
| `vite.config.js` | declares **BOTH** `resources/js/app.js` **and** `resources/css/app.css` |
| `resources/views/errors/_layout.blade.php:7` | `@vite(['resources/css/app.css'])` |

🔴 **The CSS input in `vite.config.js` is NOT redundant and must not be removed.** The original
wording of this step said `vite.config.js` "declares only `resources/js/app.js`", which invites
someone to leave it that way. It must declare both: `resources/views/errors/_layout.blade.php` — which
six **Blade** error views extend — asks for the stylesheet alone, because those pages are deliberately
not Inertia and must not boot the Vue app. Without the CSS input `Vite::asset()` throws for them on a
clean build, **and because a `ViteException` renders the 500 page, which extends that same layout, the
failure recurses.** The sibling inventory-app's single JS-only input is not sufficient here for exactly
that reason. Both halves of the fix are load-bearing; simplify neither.

The test suite cannot catch any of this — `Tests\TestCase` calls `withoutVite()` — so step 5.2 is the
only check.

### Step 5.2 [WEB] [VERIFY] Build from clean and confirm the manifest

```bash
rm -rf public/build
npm ci
npm run build
cat public/build/manifest.json | head -40
```

**PASS:** build succeeds, and the manifest contains an entry for `resources/js/app.js` with a `css`
array. No page may reference a manifest key that is absent.

🆕 **Measured 2026-10-06 — PASSED.** `public/build` deleted first, so this was a genuinely clean
build: `✓ built in 8.14s`. Manifest holds **10 keys**, and both required entries are present:

| Key | File | `css` array |
|---|---|---|
| `resources/js/app.js` | `assets/app-C29zY09s.js` | **`['assets/app-B5beW7-l.css']`** ✅ |
| `resources/css/app.css` | `assets/app-U-9DTqip.css` | — (it *is* the stylesheet) ✅ |

Both keys present is the whole point — the JS entry for the Inertia pages, the CSS entry for the six
Blade error views. The remaining eight keys are Font Awesome webfonts.

The `(!) Some chunks are larger than 500 kB` warning on `app-C29zY09s.js` (615.72 kB, 195.34 kB
gzipped) is Vite's default advisory, pre-existing and **not** a failure of this step.

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

### ✅ PASSED 2026-10-06 — 352 passed, 7 skipped, 0 failed, 3,402 assertions, 260.4 s

**Run against PARITY data** — the rebuilt snapshots, split rows and signed encumbrance — so this is
the first evidence the application layer agrees with the new figures. Matches the expected
"~350 passed with 7 skipped" exactly.

🔑 **All seven skips are premise guards, and ZERO are connection timeouts** — "This user sees one
department…", "The ledger holds one depart…", "Premise f…". That is the only shape of skip that
counts as a pass here; a run where ledger cases skip on a timeout has verified almost nothing.

🔴 **IT WAS RUN INSIDE THE SAIL CONTAINER, NOT FROM THE WINDOWS HOST**, because on this machine the
host cannot reach MySQL at all (below). The command:

```bash
docker exec -e DB_HOST=mysql finance-laravel.test-1 php artisan test
```

Two things make that correct rather than a fudge:

- **`phpunit.xml` sets no `force="true"` on any `<env>`**, so a real environment variable takes
  precedence over the file. `-e DB_HOST=mysql` therefore overrides the hardcoded `localhost`.
- **`SQLSRV_HOST` must be LEFT ALONE inside the container** — `.env`'s `host.docker.internal` is
  already right there, and it reaches SQL Server on the Windows host. The `SQLSRV_HOST=127.0.0.1`
  override in the step above is **only** for running from the Windows host. Applying both at once
  is the mistake to avoid.

Measured from inside the container: MySQL connect **0.02 s**, SQL Server connect **0.05 s**.

#### Why the Windows-host route does not work on this machine

**Port 3306 is unreachable from Windows even with the MySQL container healthy and the port
published.** `docker port` reports `3306/tcp -> 0.0.0.0:3306`, but every connection attempt returns
**`WSAEACCES (10013)` — "An attempt was made to access a socket in a way forbidden by its access
permissions"**. `netsh interface ipv4 show excludedportrange protocol=tcp` lists **no** range
covering 3306, so this is not the usual Hyper-V port reservation. Unresolved; the container route
sidesteps it entirely.

Before Docker was started the symptom was different and simpler: the **`MySQL84` Windows service was
Stopped**, and a host-side run stalled for **31 minutes on 6.8 s of CPU** — every test burning a
connection timeout. ⚠️ **That signature — long wall clock, almost no CPU — means a database is
unreachable, not that the suite is slow.** Check it before waiting.

#### Getting the dev dependencies installed (the earlier blocker, now resolved)

<details>
<summary>`vendor/` had been installed <code>--no-dev</code>; <code>composer install</code> failed twice on Windows file locking</summary>

`vendor/composer/installed.json` held **91 packages** with `phpunit/phpunit`,
`nunomaduro/collision`, `mockery/mockery`, `fakerphp/faker` and `laravel/breeze` all absent — so
`artisan test` was not a registered command (`Command "test" is not defined`).

`composer install` then failed twice with:

```
In Filesystem.php line 311:
  Could not delete .../vendor/composer/tmp-<hash>.zip:
  This can be due to an antivirus or the Windows Search Indexer locking the file
```

🔴 **The failure leaves EMPTY package directories behind.** `vendor/phpunit/phpunit/` and
`vendor/nunomaduro/collision/` both existed afterwards while containing no files, so a path check
reports them "present" when nothing is installed. **Check `installed.json`, not the directory.**

Ruled out: no Docker containers were running at the time (`docker ps` empty), so a bind-mount was
not holding the files. Fixes, in order of likelihood: exclude the project directory from real-time
AV scanning and delete `vendor/composer/tmp-*.zip`; or `composer install --prefer-source`, which
clones instead of extracting zips.

**Production is unaffected** — its `vendor/` is installed `--no-dev` deliberately and the suite is
not expected to run there.

</details>

---

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
| Budget Allocations | renders — **but see FINDING 1: split accounts do NOT appear twice here** |
| Monthly Expenditure | renders; totals row matches the sum over all pages |
| Variance | renders — **but see FINDING 2: the ~850,193 figure is NOT visible to any user** |

#### 🔴 FINDING 1 (reviewed 2026-10-06) — "the 11 split accounts appear twice" is wrong twice over

**On Budget Allocations they appear ONCE at most, never twice.** `vw_BudgetAllocation` filters
`Allocation <> 0`, and a split puts the allocation on **one** of the two rows and the GL activity on
the other. Measured on the rebuilt FY2026 snapshot: of the 11 split accounts, only **4** have a row
with a non-zero allocation, and in each case only **one** of the pair carries it. So **4 appear once
and 7 do not appear at all.**

🔴 **And it cannot be checked in a browser regardless: `FFIGUERA1` sees ZERO split accounts.**
Measured — 14 ledger rows across 14 distinct accounts, no duplicates, and 6 rows on Budget
Allocations. None of the 11 splits falls in the one department that is mapped. **The headline
behaviour of this release is invisible to the only user who can sign in.**

**So verify splits in SQL, not in the browser** — step 3.4 already does it properly. The pages where
a split *would* show twice are Monthly Expenditure and Variance, which read `vw_FinanceLedger`
without the allocation filter — but only for a user whose departments contain one.

#### 🔴 FINDING 2 (reviewed 2026-10-06) — the ~850,193 is a SNAPSHOT-WIDE figure, not a page total

For **`FFIGUERA1` both Balance and Excess are UNCHANGED** — measured delta **0.00** on each, with
the same 14 rows and unchanged YTD and Allocation. Nothing on that user's Variance page moves.

The figure is the FY2026 **user-agnostic snapshot** delta: Balance **+850,193.91**
(107,847,587.71 → 108,697,781.62) and Excess **+850,193.74** (119,582,856.13 → 120,433,049.87).
It arises from split rows, which carry allocation and GL activity separately — so each split
contributes to both Balance and Excess. **A verifier watching the Variance page for a ~850,193
increase will see nothing move and report a correct build as a failure.** Check it in SQL against
`_ParityBackup` instead.
| **Encumbered Details** | **the `FiscalYearHero` banner IS present but DISPLAY-ONLY** — see the correction below; the **Fiscal Year** select is the first filter and is **OPTIONAL, opening on "All Fiscal Years"**; no `fy` in the URL and **no filter badge**; negative Extended Cost present; withheld years named under the select |
| **Routing Details** | same, and no negatives (RT/HD/PN carry no shipments). Note it offers **noticeably fewer years** than Encumbered — 3 against 11 when measured — which is correct: the eligible set is route-specific |

🆕 **CORRECTED 2026-10-06 — the two rows above described the `79eef8e` state and were already two
revisions out of date.** Verified against `resources/js/Components/RequisitionDetailView.vue`:

| This runbook used to say | What is actually built |
|---|---|
| "**no year banner**, no prev/next" | **The banner is BACK** (2026-10-02). `<FiscalYearHero … all-years-label="All Years" :controls="false">` — the same component the four summary pages use |
| "the gold period chip beside the title reads *All available fiscal years*" | **The gold period chip is GONE.** `periodSpan` and `isCurrentFiscalYear` were deleted with it. The banner states the scope instead |

So what to check is: the banner renders, its numeral slot reads **"All Years"** in words (not a year
and not `—`), and the line beneath spans the **eligible** years — `Oct <earliest − 1> – Sep <latest>`.
There is **no year rail and no prev/next stepper** (`:controls="false"`), because the Filters card
already owns the fiscal year and two controls for one value would be able to disagree.

⚠️ **Encumbered and Routing legitimately render the IDENTICAL span line** (`Oct 2013 – Sep 2026`)
even though Routing offers only 3 eligible years against Encumbered's 11 — the span reports
endpoints, and that was a deliberate decision. **Not a bug.**

Also: arrow keys scroll table columns but **no longer step years anywhere in the app** — the
app-wide removal on 2026-10-02 deleted `useFiscalYearNav.js`. The four summary pages still step
years from the hero's own prev/next **buttons**. Changing the year auto-applies and updates the URL.

⚠️ **Two further rows were inverted until 2026-10-01**, and someone following them would have logged
a correct build as a failure. Fiscal year became an **optional** filter on these two pages
(`routingupdate.md`), so:

| Was | Now |
|---|---|
| "**required** Fiscal Year select" | optional, defaulting to All Fiscal Years |
| "'Clear all' **keeps** the selected year" | **"Clear all" returns the year to All**, like every other filter — and a chosen year **counts in the filter badge** |

Select a year and confirm the banner switches from "All Years" to `2026` with its single-year span
and the badge at 1, then "Clear all" and confirm it returns to "All Years" with no badge and no `fy`
in the URL. **No year shows "Current"** — the current FY is **2027** (today is in October) and the
newest selectable year is 2026.

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
with real data today, so it is verified by lowering the ceiling.

🆕 **Re-measured 2026-10-06 after the rebuild** (the "416 rows" above was 2026-10-01):

| For `FFIGUERA1` | Encumbered (AP/PO) | Routing (RT/HD/PN) |
|---|---|---|
| Lines, all years | **460** | **56** |
| Negative `ExtendedCost` | **8** | **0** |
| Eligible fiscal years | **11** (2014–2026, no 2022/2023) | **3** (2026, 2021, 2014) |
| Withheld years named under the select | **3** — 2013, 2012, 2011 | none |

460 against a 25,000 ceiling, so the refusal is still unreachable without lowering it. These also
confirm step 5.5's "negative Extended Cost present" / "no negatives on Routing" and the 11-vs-3 year
asymmetry — all three hold.

⚠️ **`Status` and `StatusName` are different columns and only `Status` carries the codes.**
`StatusName` holds words — `APPROVED`, `PURCHASE ORDER`, `ROUTING`. A hand-written check using
`StatusName IN ('AP','PO')` returns **zero rows** and looks like missing data. Step 4.5's query is
right because it uses `Status`.

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

**Confirm the production login name before granting.** Production's `SQLSRV_USERNAME` must be
checked, because granting to the wrong principal fails **silently**.

🔴 **FINDING 5 (reviewed 2026-10-06) — "Dev uses `finance`" is WRONG, and the consequence matters.**
Measured on the dev instance: `.env` has **`SQLSRV_USERNAME=bramkissoon`**, which maps to **`dbo`**
in `SWRHAExpenseControl`. A `finance` principal does exist, but the application does not connect as
it.

**So the dev machine cannot validate this grant at all.** As `dbo` the app has blanket rights, so a
password change will succeed on dev **whether or not the column grant exists** — and a successful
dev test is therefore no evidence that the production grant is correct or correctly scoped. Treat
Steps 5.8–5.11 as **verifiable only on production**, against the real `SQLSRV_USERNAME`, and read
FINDING 4 before interpreting Step 5.10.

```sql
-- Run this on PRODUCTION and use the answer, not the name in this runbook.
SELECT name, type_desc FROM sys.database_principals
WHERE name = N'<the production SQLSRV_USERNAME>';
```

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

🔴 **FINDING 3 (reviewed 2026-10-06) — the `HAS_PERMS_BY_NAME` calls below had their ARGUMENTS
REVERSED, and the documented PASS was unachievable.** The column **name** is the 4th argument and
the literal `'COLUMN'` the 5th; the old form passed `'COLUMN','UserPassword'`. **Measured: every
call returned `NULL`** — not 1, not 0 — so `pw`/`editor` could never read 1 and the step could never
pass. The same reversal is in **`sql/GrantPasswordUpdate.sql`** (its verification block) and must be
fixed there too. Corrected below:

```sql
SELECT HAS_PERMS_BY_NAME('dbo.0006AWebAppControls','OBJECT','UPDATE','UserPassword','COLUMN') AS pw,
       HAS_PERMS_BY_NAME('dbo.0006AWebAppControls','OBJECT','UPDATE','LastEditedBy','COLUMN') AS editor,
       HAS_PERMS_BY_NAME('dbo.0006AWebAppControls','OBJECT','UPDATE','IsActive','COLUMN')     AS must_be_zero,
       HAS_PERMS_BY_NAME('dbo.0006AWebAppControls','OBJECT','UPDATE','PositionID','COLUMN')   AS must_also_be_zero;

SELECT p.permission_name, p.state_desc, c.name AS column_name
FROM   sys.database_permissions p
LEFT  JOIN sys.columns c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE  p.major_id = OBJECT_ID('dbo.[0006AWebAppControls]')
  AND  p.grantee_principal_id = DATABASE_PRINCIPAL_ID('finance')
ORDER  BY c.name;
```

🔴 **FINDING 4 — the first query is only meaningful run AS THE APPLICATION'S LOGIN.**
`HAS_PERMS_BY_NAME` reports the **current** connection's rights. Measured as `dbo` on the dev
instance with the corrected argument order: **all four returned 1**, including both columns that
must read 0 — which reads as "someone granted at table level. Stop, `REVOKE`" when nothing is wrong
at all. Run it in a session connected as the app's `SQLSRV_USERNAME`, or with
`EXECUTE AS USER = N'<that user>'` … `REVERT` around it. (On the dev instance even that fails —
`Msg 15517`, the `finance` user cannot be impersonated — which is part of FINDING 5.)

**The SECOND query is the trustworthy one** and needs no impersonation: it names the grantee
explicitly via `DATABASE_PRINCIPAL_ID('finance')`. Measured on dev it returns **0 rows**, correctly
reflecting that the grant has not been applied.

**PASS:** `pw` and `editor` are **1**, both `must_be_zero` columns are **0** — *when run as the
application's login* — and the second query returns **exactly four rows**, one per granted column,
with no table-level row.

A `must_be_zero` of 1 **when run as the app login** means someone granted at table level.
**Stop, `REVOKE`, and re-run Step 5.9.** A `must_be_zero` of 1 when run as `dbo`/sysadmin means
nothing — re-run it as the right principal before reacting.

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
