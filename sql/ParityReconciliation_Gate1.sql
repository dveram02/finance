/* ===========================================================================
   ParityReconciliation_Gate1.sql
   ---------------------------------------------------------------------------
   GATE 1 - IS THE LOGIC RIGHT?

   Proves that the parity logic reproduces the finance department's Access query
   for every fiscal year, BEFORE any live object is changed. Run this and nothing
   else at GATE 1; see finance_sep_update_deployment.md step 1.4.

   Targets the SCRATCH function dbo.fn_FinanceLedgerAccessParity, which is why
   this file exists as a separate copy: at GATE 1 the live
   dbo.fn_FinanceLedgerSource is still PRE-PARITY, so pointing the reconciliation
   at it reports failures that mean nothing. Run this one instead - no editing.

   PREREQUISITES (runbook steps 1.1 and 1.3):
     sql/ParityVerbatimDraft.sql        -> dbo.fn_OversightDraftUnscoped
     sql/FinanceLedgerAccessParity.sql  -> dbo.fn_FinanceLedgerAccessParity

   THE THREE SCRIPTS, AND WHY NONE SUBSTITUTES FOR ANOTHER
     ParityReconciliation_Gate1.sql  is the LOGIC right, before deployment?  GATE 1
     ParitySnapshotCheck.sql         is the stored DATA right, after refresh?  GATE 2
     ParityReconciliation.sql        the same logic check, run against the LIVE
                                     fn_FinanceLedgerSource after promotion -
                                     use it to re-confirm the deployed function,
                                     never as GATE 2 evidence (it compares
                                     function to function and passes whatever is
                                     in the snapshot).

   READ-ONLY. Creates only #temp tables.

   WHY EXCEPT ALONE IS NOT ENOUGH
     EXCEPT is DISTINCT-based: it cannot see a row that appears twice on one side
     and once on the other. ROW MULTIPLICITY IS THE ENTIRE SUBJECT OF THIS
     RELEASE - the Access query splits 24 accounts across FY2014-FY2026 - so it is
     paired with COUNT(*) equality and a per-grain-key count comparison. Removing
     either makes this able to pass while the portal disagrees with Access.

   MEMORY
     Each side is materialised into a #temp table before any comparison. Do NOT
     "simplify" this by EXCEPTing the two functions inline: that forces four full
     builds of a query scanning ~641k GL rows and raises Msg 701 (insufficient
     system memory) on a 2048 MB instance.

   EXPECTED RESULT - measured 2026-09-29, all thirteen years, 0 differences of any
   kind, ~70 seconds:

     FY    rows   splits        FY    rows   splits
     2014  1814   1             2021  1378   0
     2015  1973   1             2022  1020   0
     2016  1697   0             2023   785   0
     2017  1840   3             2024  1887   1
     2018  1867   3             2025  2121   4
     2019  1835   0             2026  2275  11
     2020  1882   0

   PASS: the VERDICT row reads PASS, with every count column zero. The splits
   column is the baseline for @MaxSplitAccounts - a year whose count moves without
   a named explanation is a STOP, not a curiosity.
   =========================================================================== */

USE FinanceAutomationSystem;
GO
SET NOCOUNT ON;

/* Prerequisite guard. Without this a missing dependency surfaces thirteen times
   as "Invalid object name", which buries the actual problem. */
IF OBJECT_ID('dbo.fn_OversightDraftUnscoped') IS NULL
    THROW 51100, 'GATE 1 prerequisite missing: dbo.fn_OversightDraftUnscoped. Run sql/ParityVerbatimDraft.sql first (runbook step 1.1).', 1;

IF OBJECT_ID('dbo.fn_FinanceLedgerAccessParity') IS NULL
    THROW 51101, 'GATE 1 prerequisite missing: dbo.fn_FinanceLedgerAccessParity. Run sql/FinanceLedgerAccessParity.sql first (runbook step 1.3).', 1;
GO

IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res;
CREATE TABLE #res (
    fy            varchar(10),
    draft_only    int,          -- rows Access has that the portal does not
    parity_only   int,          -- rows the portal has that Access does not
    draft_rows    int,
    parity_rows   int,
    mult_diffs    int,          -- grain keys whose ROW COUNT differs
    draft_splits  int,
    parity_splits int
);
GO
DECLARE @FY varchar(10) = '2014';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2015';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2016';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2017';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2018';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2019';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2020';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2021';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2022';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2023';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2024';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
DECLARE @FY varchar(10) = '2026';
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

INSERT INTO #res SELECT @FY,
  (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) x),
  (SELECT COUNT(*) FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) y),
  (SELECT COUNT(*) FROM #d),
  (SELECT COUNT(*) FROM #p),
  (SELECT COUNT(*) FROM (
     SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.c,0) AS ca, ISNULL(b.c,0) AS cb
     FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #d
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) a
     FULL OUTER JOIN (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS c FROM #p
           GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) b ON a.k=b.k
   ) z WHERE ca <> cb),(SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*)>1) s1),(SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*)>1) s2);
GO
SET NOCOUNT ON;

SELECT 'PER_YEAR' AS report, * FROM #res ORDER BY fy;

/* The single line that decides the gate. Every column must be 0. */
SELECT 'VERDICT' AS report,
       SUM(draft_only)  AS total_draft_only,
       SUM(parity_only) AS total_parity_only,
       SUM(mult_diffs)  AS total_multiplicity_diffs,
       SUM(CASE WHEN draft_rows   <> parity_rows   THEN 1 ELSE 0 END) AS years_with_rowcount_diff,
       SUM(CASE WHEN draft_splits <> parity_splits THEN 1 ELSE 0 END) AS years_with_split_diff,
       CASE WHEN SUM(draft_only) = 0 AND SUM(parity_only) = 0 AND SUM(mult_diffs) = 0
                 AND SUM(CASE WHEN draft_rows   <> parity_rows   THEN 1 ELSE 0 END) = 0
                 AND SUM(CASE WHEN draft_splits <> parity_splits THEN 1 ELSE 0 END) = 0
            THEN 'PASS' ELSE 'FAIL - DO NOT DEPLOY' END AS verdict
FROM #res;
GO
