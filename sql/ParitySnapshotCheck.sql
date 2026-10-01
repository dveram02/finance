/* ===========================================================================
   ParitySnapshotCheck.sql
   ---------------------------------------------------------------------------
   Compares what is ACTUALLY STORED in dbo.FinanceLedgerSnapshot against the
   finance department's Access query, per fiscal year.

   This is the evidence for GATE 2 (and, re-run after the all-years rebuild, for
   the final sign-off). It exists because sql/ParityReconciliation.sql compares
   dbo.fn_FinanceLedgerSource against dbo.fn_OversightDraftUnscoped - FUNCTION to
   FUNCTION - so it passes whatever is in the snapshot and CANNOT prove that a
   refresh deployed correctly. The two scripts answer different questions:

       ParityReconciliation.sql : is the LOGIC right?      (GATE 1)
       ParitySnapshotCheck.sql  : is the DATA right?       (GATE 2)

   Run both. Neither substitutes for the other.

   READ-ONLY. Creates only #temp tables.

   MEMORY NOTE: each side is materialised into a #temp table BEFORE any EXCEPT.
   Comparing the draft function directly against anything in a single statement
   forces multiple full builds of a query that scans ~641k GL rows and raised
   Msg 701 on a 2048 MB instance. Do not "simplify" this by EXCEPTing the
   function inline.

   Years with no OK refresh row are skipped, not failed - a year that has never
   been built cannot disagree with anything.
   =========================================================================== */

USE FinanceAutomationSystem;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res;
IF OBJECT_ID('tempdb..#d')   IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#s')   IS NOT NULL DROP TABLE #s;
IF OBJECT_ID('tempdb..#yrs') IS NOT NULL DROP TABLE #yrs;

CREATE TABLE #res (
    fy            varchar(10),
    draft_only    int,   -- in Access, missing from the snapshot
    snap_only     int,   -- in the snapshot, not in Access
    draft_rows    int,
    snap_rows     int,
    mult_diffs    int,   -- grain keys whose ROW COUNT differs
    draft_splits  int,
    snap_splits   int,
    verdict       varchar(20)
);

/* One shape, created once and reused. SELECT ... INTO inside a loop is a
   compile-time error ("There is already an object named '#d'") even with a DROP
   between iterations, because the whole batch is parsed up front. */
CREATE TABLE #d (
    fy varchar(10), aid int, acct varchar(255), descr nvarchar(255),
    inst varchar(50), resp varchar(50), dept varchar(50),
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);
CREATE TABLE #s (
    fy varchar(10), aid int, acct varchar(255), descr nvarchar(255),
    inst varchar(50), resp varchar(50), dept varchar(50),
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);

/* Only years the ledger has actually loaded. */
SELECT FinancialYear
INTO #yrs
FROM dbo.FinanceLedgerRefresh
WHERE Outcome = 'OK';

DECLARE @fy varchar(10);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT FinancialYear FROM #yrs ORDER BY FinancialYear;
OPEN c;
FETCH NEXT FROM c INTO @fy;

WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM #d;
    DELETE FROM #s;

    INSERT INTO #d
    SELECT CONVERT(varchar(10), FinancialYear), CONVERT(int, AccountID),
           CONVERT(varchar(255), AccountNumber), CONVERT(nvarchar(255), AccountDescription),
           CONVERT(varchar(50), InstitutionID), CONVERT(varchar(50), ResponsibilityID),
           CONVERT(varchar(50), DepartmentID),
           CONVERT(decimal(19,2), [Oct]), CONVERT(decimal(19,2), [Nov]), CONVERT(decimal(19,2), [Dec]),
           CONVERT(decimal(19,2), [Jan]), CONVERT(decimal(19,2), [Feb]), CONVERT(decimal(19,2), [Mar]),
           CONVERT(decimal(19,2), [Apr]), CONVERT(decimal(19,2), [May]), CONVERT(decimal(19,2), [Jun]),
           CONVERT(decimal(19,2), [Jul]), CONVERT(decimal(19,2), [Aug]), CONVERT(decimal(19,2), [Sep]),
           CONVERT(decimal(19,2), Q1), CONVERT(decimal(19,2), Q2),
           CONVERT(decimal(19,2), Q3), CONVERT(decimal(19,2), Q4),
           CONVERT(decimal(19,2), YTDTotal), CONVERT(decimal(19,2), Approved),
           CONVERT(decimal(19,2), Routing), CONVERT(decimal(19,2), Allocation)
    FROM dbo.fn_OversightDraftUnscoped(@fy);

    INSERT INTO #s
    SELECT CONVERT(varchar(10), FinancialYear), CONVERT(int, AccountID),
           CONVERT(varchar(255), AccountNumber), CONVERT(nvarchar(255), AccountDescription),
           CONVERT(varchar(50), InstitutionID), CONVERT(varchar(50), ResponsibilityID),
           CONVERT(varchar(50), DepartmentID),
           CONVERT(decimal(19,2), [Oct]), CONVERT(decimal(19,2), [Nov]), CONVERT(decimal(19,2), [Dec]),
           CONVERT(decimal(19,2), [Jan]), CONVERT(decimal(19,2), [Feb]), CONVERT(decimal(19,2), [Mar]),
           CONVERT(decimal(19,2), [Apr]), CONVERT(decimal(19,2), [May]), CONVERT(decimal(19,2), [Jun]),
           CONVERT(decimal(19,2), [Jul]), CONVERT(decimal(19,2), [Aug]), CONVERT(decimal(19,2), [Sep]),
           CONVERT(decimal(19,2), Q1), CONVERT(decimal(19,2), Q2),
           CONVERT(decimal(19,2), Q3), CONVERT(decimal(19,2), Q4),
           CONVERT(decimal(19,2), YTDTotal), CONVERT(decimal(19,2), Approved),
           CONVERT(decimal(19,2), Routing), CONVERT(decimal(19,2), Allocation)
    FROM dbo.FinanceLedgerSnapshot
    WHERE FinancialYear = @fy;

    /* EXCEPT is DISTINCT-based and cannot see an identically duplicated row, and
       row multiplicity is the whole subject of this release - so the row count
       and the per-grain-key count are checked alongside it. Dropping either lets
       this pass while the snapshot disagrees with Access. */
    INSERT INTO #res (fy, draft_only, snap_only, draft_rows, snap_rows, mult_diffs, draft_splits, snap_splits)
    SELECT @fy,
      (SELECT COUNT(*) FROM (SELECT * FROM #d EXCEPT SELECT * FROM #s) AS a),
      (SELECT COUNT(*) FROM (SELECT * FROM #s EXCEPT SELECT * FROM #d) AS b),
      (SELECT COUNT(*) FROM #d),
      (SELECT COUNT(*) FROM #s),
      (SELECT COUNT(*) FROM (
          SELECT ISNULL(x.k, y.k) AS k, ISNULL(x.n, 0) AS nx, ISNULL(y.n, 0) AS ny
          FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS n
                FROM #d GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) AS x
          FULL OUTER JOIN
               (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS n
                FROM #s GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) AS y
            ON x.k = y.k
      ) AS z WHERE nx <> ny),
      (SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*) > 1) AS s1),
      (SELECT COUNT(*) FROM (SELECT acct FROM #s GROUP BY acct HAVING COUNT(*) > 1) AS s2);

    FETCH NEXT FROM c INTO @fy;
END

CLOSE c;
DEALLOCATE c;

UPDATE #res
SET verdict = CASE WHEN draft_only = 0 AND snap_only = 0 AND mult_diffs = 0
                    AND draft_rows = snap_rows AND draft_splits = snap_splits
                   THEN 'PASS' ELSE 'FAIL' END;

SELECT 'PER_YEAR' AS report, * FROM #res ORDER BY fy;

/* The line that decides the gate. */
SELECT 'VERDICT' AS report,
       COUNT(*)                                             AS years_checked,
       SUM(CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END)    AS years_failing,
       SUM(draft_only)                                      AS total_missing_from_snapshot,
       SUM(snap_only)                                       AS total_extra_in_snapshot,
       SUM(mult_diffs)                                      AS total_multiplicity_diffs,
       CASE WHEN SUM(CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END) = 0
            THEN 'PASS - the stored snapshot matches Access'
            ELSE 'FAIL - DO NOT PROCEED' END               AS verdict
FROM #res;
GO
