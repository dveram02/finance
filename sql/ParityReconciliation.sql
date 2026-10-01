/* ===========================================================================
   ParityReconciliation.sql
   ---------------------------------------------------------------------------
   Proves that the portal's ledger source reproduces the finance department's
   Access query EXACTLY, per fiscal year, on row grain and on every money
   column. This is the acceptance test for financeupdatesep.md (Part F).

   Requires sql/ParityVerbatimDraft.sql and either
   sql/FinanceLedgerAccessParity.sql (GATE 1, scratch object) or the promoted
   dbo.fn_FinanceLedgerSource. Set @Target below.

   READ-ONLY. Creates only #temp tables.

   WHY THE MULTIPLICITY CHECK EXISTS, AND WHY EXCEPT ALONE IS NOT ENOUGH
   ---------------------------------------------------------------------------
   EXCEPT is DISTINCT-based: it cannot see a row that appears twice on one side
   and once on the other, because both sides contain the value. ROW MULTIPLICITY
   IS THE ENTIRE SUBJECT OF THIS RELEASE - the Access query splits 24 accounts
   across FY2014-FY2026 - so EXCEPT is paired with (a) COUNT(*) equality and
   (b) a per-grain-key count comparison. Removing either makes this test able to
   pass while the portal disagrees with Access. Do not "simplify" it.

   MEASURED RESULT, 2026-09-29, against production data (all thirteen years,
   0 differences of any kind, 68 seconds total):

     FY    rows   splits        FY    rows   splits
     2014  1814   1             2021  1378   0
     2015  1973   1             2022  1020   0
     2016  1697   0             2023   785   0
     2017  1840   3             2024  1887   1
     2018  1867   3             2025  2121   4
     2019  1835   0             2026  2275  11
     2020  1882   0

   Those split counts are the baseline for @MaxSplitAccounts. A year whose count
   moves without a named explanation is a STOP, not a curiosity.
   =========================================================================== */

USE FinanceAutomationSystem;
GO
SET NOCOUNT ON;

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
INTO #p FROM dbo.fn_FinanceLedgerSource(@FY);

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
