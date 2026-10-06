/* ===========================================================================
   ParityMoneyDelta.sql
   ---------------------------------------------------------------------------
   HOW MUCH MONEY do the Access draft and the parity function disagree about,
   across every account and all thirteen fiscal years?

   READ-ONLY. #temp tables only. ~215 s.

   WHY THIS EXISTS, AND WHY IT IS NOT THE SAME QUESTION AS GATE 1
     GATE 1 counts DIFFERING ROWS. It reported one. "One row differs" and "the
     money differs by one cent" are different claims, and on a financial system
     the second needs measuring rather than inferring - a single differing row
     could in principle hide a large delta. This answers the money question.

   METHOD
     Each side is materialised ONCE per year into a #temp table and aggregated
     from there - the same discipline ParityReconciliation_Gate1.sql's header
     insists on. 26 function builds, not 130. A first draft of this file called
     the functions five times per side per year and would have taken ~19 minutes
     instead of ~3.5; do not "simplify" it back into inline subqueries.

     Money is CONVERTed to decimal(19,2) PER ROW before summing, so the
     comparison itself is exact and contributes no float error of its own. That
     matters here above all places: the thing being measured IS float error.

     OPTION (MAXDOP 1) is required on the local restore or the parity
     materialisation stalls on CXSYNC_PORT. Drop it on production.

   MEASURED 2026-10-06, local restore of the 05-10-2026 production databases,
   all 13 FYs:

     row_delta ........ 0 in EVERY year
     alloc_delta ...... 0.00   over 440,826,948.69
     appr_delta ....... 0.00   over 353,219,050.22
     rtg_delta ........ 0.00   over  36,346,867.64
     ytd_delta ........ -0.01  over 3,694,251,307.70   (FY2025 only)
     months_delta ..... -0.01  (the SAME cent - YTDTotal is derived from the
                               months, so it is one cent reported twice, which
                               is why total_abs reads 0.02 and not 0.01)

   CONCLUSION: the two agree to the cent on every figure in every year except
   ONE cent of YTD on one FY2025 account - 0.01 in 3.69 billion, 2.7e-12. And
   the parity side is the arithmetically CORRECT one (see
   sql/Gate1Diagnose_FloatOrder.sql). Re-run this after any change to the parity
   function; a delta that grows beyond a cent is a real defect, not an artifact.
   =========================================================================== */
USE FinanceAutomationSystem;
SET NOCOUNT ON;
GO
IF OBJECT_ID('tempdb..#m') IS NOT NULL DROP TABLE #m;
CREATE TABLE #m (
    fy varchar(10), side char(1),
    rows_ int,
    alloc decimal(19,2), ytd decimal(19,2),
    appr  decimal(19,2), rtg decimal(19,2),
    months decimal(19,2)
);
GO
DECLARE @FY varchar(10) = '2014';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2015';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2016';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2017';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2018';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2019';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2020';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2021';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2022';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2023';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2024';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2025';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
DECLARE @FY varchar(10) = '2026';
IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #d FROM dbo.fn_OversightDraftUnscoped(@FY) OPTION (MAXDOP 1);

SELECT CONVERT(decimal(19,2),Allocation) AS alloc, CONVERT(decimal(19,2),YTDTotal) AS ytd,
       CONVERT(decimal(19,2),Approved) AS appr, CONVERT(decimal(19,2),Routing) AS rtg,
       CONVERT(decimal(19,2),ISNULL([Oct],0))+CONVERT(decimal(19,2),ISNULL([Nov],0))+CONVERT(decimal(19,2),ISNULL([Dec],0))
      +CONVERT(decimal(19,2),ISNULL([Jan],0))+CONVERT(decimal(19,2),ISNULL([Feb],0))+CONVERT(decimal(19,2),ISNULL([Mar],0))
      +CONVERT(decimal(19,2),ISNULL([Apr],0))+CONVERT(decimal(19,2),ISNULL([May],0))+CONVERT(decimal(19,2),ISNULL([Jun],0))
      +CONVERT(decimal(19,2),ISNULL([Jul],0))+CONVERT(decimal(19,2),ISNULL([Aug],0))+CONVERT(decimal(19,2),ISNULL([Sep],0)) AS months
INTO #p FROM dbo.fn_FinanceLedgerAccessParity(@FY) OPTION (MAXDOP 1);

INSERT INTO #m SELECT @FY,'D',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #d;
INSERT INTO #m SELECT @FY,'P',COUNT(*),SUM(alloc),SUM(ytd),SUM(appr),SUM(rtg),SUM(months) FROM #p;
DROP TABLE #d; DROP TABLE #p;
GO
SELECT 'PER_YEAR' AS report, d.fy, p.rows_ - d.rows_ AS row_delta,
       p.alloc - d.alloc AS alloc_delta, p.ytd - d.ytd AS ytd_delta,
       p.appr - d.appr AS appr_delta, p.rtg - d.rtg AS rtg_delta,
       p.months - d.months AS months_delta
FROM #m d JOIN #m p ON p.fy = d.fy AND p.side='P' AND d.side='D'
ORDER BY d.fy;

SELECT 'TOTAL_DELTA' AS report,
       SUM(p.alloc - d.alloc) AS alloc, SUM(p.ytd - d.ytd) AS ytd,
       SUM(p.appr - d.appr) AS appr, SUM(p.rtg - d.rtg) AS rtg,
       SUM(p.months - d.months) AS months,
       SUM(ABS(p.alloc-d.alloc)+ABS(p.ytd-d.ytd)+ABS(p.appr-d.appr)+ABS(p.rtg-d.rtg)+ABS(p.months-d.months)) AS total_abs
FROM #m d JOIN #m p ON p.fy = d.fy AND p.side='P' AND d.side='D';

SELECT 'MAGNITUDE_13FY' AS report, SUM(alloc) AS allocation, SUM(ytd) AS ytd, SUM(appr) AS approved, SUM(rtg) AS routing
FROM #m WHERE side='D';
DROP TABLE #m;
