/* ===========================================================================
   Gate1Diagnose_FY2025.sql
   ---------------------------------------------------------------------------
   DIAGNOSTIC ONLY. READ-ONLY. Creates only #temp tables. Not part of the
   runbook; delete after use.

   WHY THIS EXISTS
     GATE 1 (runbook step 1.4) reported, on PRODUCTION, 2026-10-05:

       PER_YEAR 2025  draft_only 1  parity_only 1  draft_rows 2121
                      parity_rows 2121  mult_diffs 0  splits 4 / 4

     That combination is NOT a grain defect. mult_diffs = 0 means every grain key
     (acct|aid|descr|inst|resp|dept) appears the same number of times on both
     sides, and the row counts and split counts agree. So ONE row shares its grain
     key across both sides and differs in one or more of the MONEY columns - a
     value difference, not a row difference.

     Two candidate causes, told apart by whether the diff REPEATS:

       (a) A real logic difference in one money branch on one account.
       (b) The SOURCE MOVED between the two materialisations. GATE 1 builds #d and
           #p as two separate statements seconds apart, over live GP tables. A
           requisition approved, routed or received in that window shifts Approved
           or Routing on exactly one account and produces this exact signature.
           (b) is invisible on a quiet dev replica and ordinary on production in
           working hours, which is why the 2026-09-29 baseline never saw it.

   HOW TO USE
     Part 1 names the row and the differing column.
     Part 2 re-materialises both sides and compares again. A diff that MOVES or
     VANISHES is (b); a diff that stays on the same account and column with the
     same values is (a) and is a genuine STOP.
   =========================================================================== */

USE FinanceAutomationSystem;
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------- PART 1 --- */

DECLARE @FY varchar(10) = '2025';

IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(varchar(10),FinancialYear) AS fy, CONVERT(int,AccountID) AS aid,
       CONVERT(varchar(255),AccountNumber) AS acct, CONVERT(nvarchar(255),AccountDescription) AS descr,
       CONVERT(varchar(50),InstitutionID) AS inst, CONVERT(varchar(50),ResponsibilityID) AS resp,
       CONVERT(varchar(50),DepartmentID) AS dept,
       CONVERT(decimal(19,2),[Oct]) AS c01,CONVERT(decimal(19,2),[Nov]) AS c02,CONVERT(decimal(19,2),[Dec]) AS c03,
       CONVERT(decimal(19,2),[Jan]) AS c04,CONVERT(decimal(19,2),[Feb]) AS c05,CONVERT(decimal(19,2),[Mar]) AS c06,
       CONVERT(decimal(19,2),[Apr]) AS c07,CONVERT(decimal(19,2),[May]) AS c08,CONVERT(decimal(19,2),[Jun]) AS c09,
       CONVERT(decimal(19,2),[Jul]) AS c10,CONVERT(decimal(19,2),[Aug]) AS c11,CONVERT(decimal(19,2),[Sep]) AS c12,
       CONVERT(decimal(19,2),Q1) AS q1,CONVERT(decimal(19,2),Q2) AS q2,
       CONVERT(decimal(19,2),Q3) AS q3,CONVERT(decimal(19,2),Q4) AS q4,
       CONVERT(decimal(19,2),YTDTotal) AS ytd, CONVERT(decimal(19,2),Approved) AS appr,
       CONVERT(decimal(19,2),Routing) AS rtg, CONVERT(decimal(19,2),Allocation) AS alloc
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY);

SELECT CONVERT(varchar(10),FinancialYear) AS fy, CONVERT(int,AccountID) AS aid,
       CONVERT(varchar(255),AccountNumber) AS acct, CONVERT(nvarchar(255),AccountDescription) AS descr,
       CONVERT(varchar(50),InstitutionID) AS inst, CONVERT(varchar(50),ResponsibilityID) AS resp,
       CONVERT(varchar(50),DepartmentID) AS dept,
       CONVERT(decimal(19,2),[Oct]) AS c01,CONVERT(decimal(19,2),[Nov]) AS c02,CONVERT(decimal(19,2),[Dec]) AS c03,
       CONVERT(decimal(19,2),[Jan]) AS c04,CONVERT(decimal(19,2),[Feb]) AS c05,CONVERT(decimal(19,2),[Mar]) AS c06,
       CONVERT(decimal(19,2),[Apr]) AS c07,CONVERT(decimal(19,2),[May]) AS c08,CONVERT(decimal(19,2),[Jun]) AS c09,
       CONVERT(decimal(19,2),[Jul]) AS c10,CONVERT(decimal(19,2),[Aug]) AS c11,CONVERT(decimal(19,2),[Sep]) AS c12,
       CONVERT(decimal(19,2),Q1) AS q1,CONVERT(decimal(19,2),Q2) AS q2,
       CONVERT(decimal(19,2),Q3) AS q3,CONVERT(decimal(19,2),Q4) AS q4,
       CONVERT(decimal(19,2),YTDTotal) AS ytd, CONVERT(decimal(19,2),Approved) AS appr,
       CONVERT(decimal(19,2),Routing) AS rtg, CONVERT(decimal(19,2),Allocation) AS alloc
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY);

/* 1a. The two offending rows, side by side. */
SELECT 'DRAFT_ONLY' AS side, * FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) a
UNION ALL
SELECT 'PARITY_ONLY' AS side, * FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) b;

/* 1b. WHICH COLUMN differs, and by how much. Unpivoted so the answer is one
       short result set instead of 28 columns to eyeball. */
WITH d AS (SELECT * FROM #d EXCEPT SELECT * FROM #p),
     p AS (SELECT * FROM #p EXCEPT SELECT * FROM #d),
     du AS (SELECT acct, aid, inst, resp, dept, v.col, v.val FROM d
            CROSS APPLY (VALUES ('Oct',c01),('Nov',c02),('Dec',c03),('Jan',c04),('Feb',c05),('Mar',c06),
                                ('Apr',c07),('May',c08),('Jun',c09),('Jul',c10),('Aug',c11),('Sep',c12),
                                ('Q1',q1),('Q2',q2),('Q3',q3),('Q4',q4),
                                ('YTDTotal',ytd),('Approved',appr),('Routing',rtg),('Allocation',alloc)) v(col,val)),
     pu AS (SELECT acct, aid, inst, resp, dept, v.col, v.val FROM p
            CROSS APPLY (VALUES ('Oct',c01),('Nov',c02),('Dec',c03),('Jan',c04),('Feb',c05),('Mar',c06),
                                ('Apr',c07),('May',c08),('Jun',c09),('Jul',c10),('Aug',c11),('Sep',c12),
                                ('Q1',q1),('Q2',q2),('Q3',q3),('Q4',q4),
                                ('YTDTotal',ytd),('Approved',appr),('Routing',rtg),('Allocation',alloc)) v(col,val))
SELECT 'COLUMN_DIFF' AS chk, du.acct, du.aid, du.inst, du.resp, du.dept, du.col,
       du.val AS draft_value, pu.val AS parity_value, pu.val - du.val AS delta
FROM du
JOIN pu ON pu.acct = du.acct
       AND ISNULL(pu.aid,-1) = ISNULL(du.aid,-1)
       AND pu.inst = du.inst AND pu.resp = du.resp AND pu.dept = du.dept
       AND pu.col = du.col
WHERE du.val <> pu.val;

/* 1c. Confirm the grain is intact - this should return NOTHING. If it returns
       rows the diff IS a grain defect after all, and 1b will have found no
       differing column. */
SELECT 'GRAIN_MISMATCH' AS chk, ISNULL(a.k,b.k) AS k,
       ISNULL(a.c,0) AS draft_count, ISNULL(b.c,0) AS parity_count
FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c
      FROM #d GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
FULL OUTER JOIN
     (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c
      FROM #p GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k = b.k
WHERE ISNULL(a.c,0) <> ISNULL(b.c,0);

DROP TABLE #d; DROP TABLE #p;
GO

/* ---------------------------------------------------------------- PART 2 ---
   REPEATABILITY. Rebuild both sides and compare again. Interpretation:

     same account + same column + same values  -> (a) real logic difference, STOP
     different account/column, or zero rows    -> (b) the source moved; re-run
                                                      GATE 1 outside posting hours
   --------------------------------------------------------------------------- */

DECLARE @FY varchar(10) = '2025';

IF OBJECT_ID('tempdb..#d2') IS NOT NULL DROP TABLE #d2;
IF OBJECT_ID('tempdb..#p2') IS NOT NULL DROP TABLE #p2;

SELECT CONVERT(varchar(255),AccountNumber) AS acct, CONVERT(int,AccountID) AS aid,
       CONVERT(varchar(50),InstitutionID) AS inst, CONVERT(varchar(50),ResponsibilityID) AS resp,
       CONVERT(varchar(50),DepartmentID) AS dept,
       CONVERT(decimal(19,2),YTDTotal) AS ytd, CONVERT(decimal(19,2),Approved) AS appr,
       CONVERT(decimal(19,2),Routing) AS rtg, CONVERT(decimal(19,2),Allocation) AS alloc
INTO #d2 FROM dbo.fn_OversightDraftUnscoped(@FY);

SELECT CONVERT(varchar(255),AccountNumber) AS acct, CONVERT(int,AccountID) AS aid,
       CONVERT(varchar(50),InstitutionID) AS inst, CONVERT(varchar(50),ResponsibilityID) AS resp,
       CONVERT(varchar(50),DepartmentID) AS dept,
       CONVERT(decimal(19,2),YTDTotal) AS ytd, CONVERT(decimal(19,2),Approved) AS appr,
       CONVERT(decimal(19,2),Routing) AS rtg, CONVERT(decimal(19,2),Allocation) AS alloc
INTO #p2 FROM dbo.fn_FinanceLedgerAccessParity(@FY);

SELECT 'RERUN_DRAFT_ONLY' AS side, * FROM (SELECT * FROM #d2 EXCEPT SELECT * FROM #p2) a
UNION ALL
SELECT 'RERUN_PARITY_ONLY' AS side, * FROM (SELECT * FROM #p2 EXCEPT SELECT * FROM #d2) b;

SELECT 'RERUN_SUMMARY' AS chk,
       (SELECT COUNT(*) FROM (SELECT * FROM #d2 EXCEPT SELECT * FROM #p2) x) AS draft_only,
       (SELECT COUNT(*) FROM (SELECT * FROM #p2 EXCEPT SELECT * FROM #d2) y) AS parity_only,
       (SELECT COUNT(*) FROM #d2) AS draft_rows,
       (SELECT COUNT(*) FROM #p2) AS parity_rows;

DROP TABLE #d2; DROP TABLE #p2;
GO
