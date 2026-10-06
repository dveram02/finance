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

       ParityReconciliation_Gate1.sql : is the LOGIC right?      (GATE 1)
       ParitySnapshotCheck.sql        : is the DATA right?        (GATE 2)

   Run both. Neither substitutes for the other.

   READ-ONLY. Creates only #temp tables.

   MEMORY NOTE: each side is materialised into a #temp table BEFORE any
   comparison. Comparing the draft function directly against anything in a single
   statement forces multiple full builds of a query that scans ~641k GL rows and
   raised Msg 701 on a 2048 MB instance. Do not "simplify" this by comparing the
   function inline.

   Years with no OK refresh row are skipped, not failed - a year that has never
   been built cannot disagree with anything.

   ===========================================================================
   🔴 THE MONEY TOLERANCE - IT IS HERE FOR THE SAME REASON AS IN GATE 1
   ===========================================================================
   Added 2026-10-06. The full record is in financeupdatesepprogress.md
   (2026-10-05, 2026-10-06), and the mechanism is documented at length in
   sql/ParityReconciliation_Gate1.sql - read that header once; it is not
   repeated here.

   The short version: 0098AFinGLMaster.NetChange is FLOAT, five accounts carry
   entries up to 1.3e13, and float addition is not associative - so the ORDER in
   which a plan adds those rows decides the final cent. Measured: five different
   float sums for one account's 1,208 February rows, with MAXDOP alone flipping
   the result across a rounding boundary. The exact decimal value rounds to the
   figure the PARITY side produces; Access is the cent that is wrong.

   🔴 WHY THIS GATE IS EXPOSED TOO, AND IT IS NOT THE SAME EXPOSURE AS GATE 1.
   GATE 1 compares two functions evaluated in one session. This gate compares a
   function evaluated NOW against values the refresh STORED on some earlier
   night, under whatever plan was in force then. So the stored cent and the
   freshly-computed cent can differ even when the logic is identical and the
   source has not moved - and no amount of re-running changes that, because one
   side is already written to disk. Without the tolerance this gate would fail
   intermittently on a correct deployment, which is the worst kind of gate: one
   that cries wolf and gets ignored.

   WHAT THE TOLERANCE DOES AND DOES NOT DO - identical rules to GATE 1:
     ✅ MONEY may differ by up to @Tolerance (default 0.01), and every row that
        uses it is LISTED. A tolerance you cannot see is a blind spot.
     ✅ The EXACT comparison is still computed and reported per year.
     🔴 GRAIN IS STILL EXACT - row counts, per-grain-key multiplicity, split
        counts and the key columns carry NO tolerance whatever.
     🔴 A NULL-vs-value mismatch is NEVER tolerated.
     🔴 THIS CHANGES NO DATA. Read-only harness; it changes only what the test
        calls a failure.

   SETTING @Tolerance TO 0 restores the old all-or-nothing behaviour exactly.

   @MaxDop: set to 1 on the LOCAL RESTORE, where the draft materialisation can
   stall on CXSYNC_PORT at the instance default. Leave 0 on production. Note the
   cap changes float addition order, so a capped run is not evidence about an
   uncapped one.
   =========================================================================== */

USE FinanceAutomationSystem;
GO
SET NOCOUNT ON;

DECLARE @Tolerance decimal(19,4) = 0.01;  -- money only; 0 = exact, old behaviour
DECLARE @MaxDop    int           = 0;     -- 1 on the local restore, 0 on production

IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res;
IF OBJECT_ID('tempdb..#tol') IS NOT NULL DROP TABLE #tol;
IF OBJECT_ID('tempdb..#d')   IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#s')   IS NOT NULL DROP TABLE #s;
IF OBJECT_ID('tempdb..#dd')  IS NOT NULL DROP TABLE #dd;
IF OBJECT_ID('tempdb..#ss')  IS NOT NULL DROP TABLE #ss;
IF OBJECT_ID('tempdb..#yrs') IS NOT NULL DROP TABLE #yrs;

CREATE TABLE #res (
    fy               varchar(10) COLLATE DATABASE_DEFAULT,
    exact_draft_only int,   -- EXACT comparison, reported not fatal
    exact_snap_only  int,
    tol_draft_only   int,   -- AFTER tolerance: in Access, missing from the snapshot
    tol_snap_only    int,   -- AFTER tolerance: in the snapshot, not in Access
    tolerated_rows   int,
    max_abs_delta    decimal(19,4),
    draft_rows       int,
    snap_rows        int,
    mult_diffs       int,   -- grain keys whose ROW COUNT differs (NO tolerance)
    draft_splits     int,
    snap_splits      int,
    verdict          varchar(20) COLLATE DATABASE_DEFAULT
);

/* Every row the tolerance absorbed, named - the half that keeps it honest. */
CREATE TABLE #tol (
    fy varchar(10) COLLATE DATABASE_DEFAULT, acct varchar(255) COLLATE DATABASE_DEFAULT, aid int,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    col varchar(20) COLLATE DATABASE_DEFAULT,
    draft_value decimal(19,2), snap_value decimal(19,2), delta decimal(19,4)
);

/* One shape, created once and reused. SELECT ... INTO inside a loop is a
   compile-time error ("There is already an object named '#d'") even with a DROP
   between iterations, because the whole batch is parsed up front.

   COLLATE DATABASE_DEFAULT is load-bearing: temp TABLES take tempdb's collation
   while a table VARIABLE takes the current database's, and joining the two
   raises Msg 468 ("Cannot resolve the collation conflict"). The previous version
   of this file sidestepped it by never using a table variable. */
CREATE TABLE #d (
    fy varchar(10) COLLATE DATABASE_DEFAULT, aid int,
    acct varchar(255) COLLATE DATABASE_DEFAULT, descr nvarchar(255) COLLATE DATABASE_DEFAULT,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);
CREATE TABLE #s (
    fy varchar(10) COLLATE DATABASE_DEFAULT, aid int,
    acct varchar(255) COLLATE DATABASE_DEFAULT, descr nvarchar(255) COLLATE DATABASE_DEFAULT,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);

/* The SYMMETRIC DIFFERENCE rows only, numbered within grain key so the two sides
   can be paired. The grain key alone is not unique - that is what splits ARE. */
CREATE TABLE #dd (
    rn int, aid int,
    acct varchar(255) COLLATE DATABASE_DEFAULT, descr nvarchar(255) COLLATE DATABASE_DEFAULT,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);
CREATE TABLE #ss (
    rn int, aid int,
    acct varchar(255) COLLATE DATABASE_DEFAULT, descr nvarchar(255) COLLATE DATABASE_DEFAULT,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    c01 decimal(19,2), c02 decimal(19,2), c03 decimal(19,2), c04 decimal(19,2),
    c05 decimal(19,2), c06 decimal(19,2), c07 decimal(19,2), c08 decimal(19,2),
    c09 decimal(19,2), c10 decimal(19,2), c11 decimal(19,2), c12 decimal(19,2),
    q1 decimal(19,2), q2 decimal(19,2), q3 decimal(19,2), q4 decimal(19,2),
    ytd decimal(19,2), appr decimal(19,2), rtg decimal(19,2), alloc decimal(19,2)
);

/* Declared OUTSIDE the loop deliberately - a table variable declared inside a
   WHILE body is not re-created per iteration, so it would accumulate rows across
   years and every count after the first would be wrong. */
DECLARE @pairs TABLE (
    acct varchar(255) COLLATE DATABASE_DEFAULT, aid int,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    rn int, side char(1), max_abs decimal(19,4), nullmix int
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
    DELETE FROM #d;  DELETE FROM #s;
    DELETE FROM #dd; DELETE FROM #ss;
    DELETE FROM @pairs;

    /* The @MaxDop branches differ ONLY in the hint - change both or neither. */
    IF @MaxDop = 1
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
        FROM dbo.fn_OversightDraftUnscoped(@fy) OPTION (MAXDOP 1);
    ELSE
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

    /* --- symmetric difference, paired within grain key --- */
    INSERT INTO #dd
    SELECT ROW_NUMBER() OVER (PARTITION BY acct, aid, descr, inst, resp, dept
             ORDER BY c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
                      q1,q2,q3,q4,ytd,appr,rtg,alloc),
           aid, acct, descr, inst, resp, dept,
           c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
           q1,q2,q3,q4,ytd,appr,rtg,alloc
    FROM (SELECT * FROM #d EXCEPT SELECT * FROM #s) AS a;

    INSERT INTO #ss
    SELECT ROW_NUMBER() OVER (PARTITION BY acct, aid, descr, inst, resp, dept
             ORDER BY c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
                      q1,q2,q3,q4,ytd,appr,rtg,alloc),
           aid, acct, descr, inst, resp, dept,
           c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
           q1,q2,q3,q4,ytd,appr,rtg,alloc
    FROM (SELECT * FROM #s EXCEPT SELECT * FROM #d) AS b;

    /* --- classify.
           side 'B' = a genuine PAIR, the only case the tolerance can apply to.
           side 'D'/'S' = no counterpart -> real difference, never tolerated.
           nullmix = columns where one side is NULL and the other is not. Never
                     tolerated: "no activity" and "exactly zero" must not merge.
           --- */
    INSERT INTO @pairs (acct, aid, inst, resp, dept, rn, side, max_abs, nullmix)
    SELECT COALESCE(d.acct, s.acct), COALESCE(d.aid, s.aid),
           COALESCE(d.inst, s.inst), COALESCE(d.resp, s.resp), COALESCE(d.dept, s.dept),
           COALESCE(d.rn, s.rn),
           CASE WHEN d.acct IS NOT NULL AND s.acct IS NOT NULL THEN 'B'
                WHEN d.acct IS NOT NULL THEN 'D' ELSE 'S' END,
           agg.max_abs, agg.nullmix
    FROM #dd d
    FULL OUTER JOIN #ss s
      ON  s.acct = d.acct
      AND ISNULL(s.aid, -1) = ISNULL(d.aid, -1)
      AND ISNULL(s.descr, N'<null>') = ISNULL(d.descr, N'<null>')
      AND s.inst = d.inst AND s.resp = d.resp AND s.dept = d.dept
      AND s.rn = d.rn
    CROSS APPLY (
        SELECT MAX(ABS(ISNULL(v.a,0) - ISNULL(v.b,0))) AS max_abs,
               /* T-SQL has no boolean type, so the NULL patterns are compared as
                  0/1 flags - (v.a IS NULL) <> (v.b IS NULL) is a syntax error. */
               SUM(CASE WHEN (CASE WHEN v.a IS NULL THEN 1 ELSE 0 END)
                           <> (CASE WHEN v.b IS NULL THEN 1 ELSE 0 END)
                        THEN 1 ELSE 0 END) AS nullmix
        FROM (VALUES
            (d.c01,s.c01),(d.c02,s.c02),(d.c03,s.c03),(d.c04,s.c04),
            (d.c05,s.c05),(d.c06,s.c06),(d.c07,s.c07),(d.c08,s.c08),
            (d.c09,s.c09),(d.c10,s.c10),(d.c11,s.c11),(d.c12,s.c12),
            (d.q1,s.q1),(d.q2,s.q2),(d.q3,s.q3),(d.q4,s.q4),
            (d.ytd,s.ytd),(d.appr,s.appr),(d.rtg,s.rtg),(d.alloc,s.alloc)
        ) AS v(a,b)
    ) AS agg;

    /* --- the tolerated detail, cell by cell --- */
    INSERT INTO #tol (fy, acct, aid, inst, resp, dept, col, draft_value, snap_value, delta)
    SELECT @fy, d.acct, d.aid, d.inst, d.resp, d.dept, v.col, v.a, v.b, v.b - v.a
    FROM #dd d
    JOIN #ss s
      ON  s.acct = d.acct
      AND ISNULL(s.aid, -1) = ISNULL(d.aid, -1)
      AND ISNULL(s.descr, N'<null>') = ISNULL(d.descr, N'<null>')
      AND s.inst = d.inst AND s.resp = d.resp AND s.dept = d.dept
      AND s.rn = d.rn
    JOIN @pairs g
      ON  g.acct = d.acct AND ISNULL(g.aid,-1) = ISNULL(d.aid,-1)
      AND g.inst = d.inst AND g.resp = d.resp AND g.dept = d.dept AND g.rn = d.rn
    CROSS APPLY (VALUES
        ('Oct',d.c01,s.c01),('Nov',d.c02,s.c02),('Dec',d.c03,s.c03),('Jan',d.c04,s.c04),
        ('Feb',d.c05,s.c05),('Mar',d.c06,s.c06),('Apr',d.c07,s.c07),('May',d.c08,s.c08),
        ('Jun',d.c09,s.c09),('Jul',d.c10,s.c10),('Aug',d.c11,s.c11),('Sep',d.c12,s.c12),
        ('Q1',d.q1,s.q1),('Q2',d.q2,s.q2),('Q3',d.q3,s.q3),('Q4',d.q4,s.q4),
        ('YTDTotal',d.ytd,s.ytd),('Approved',d.appr,s.appr),
        ('Routing',d.rtg,s.rtg),('Allocation',d.alloc,s.alloc)
    ) AS v(col,a,b)
    WHERE g.side = 'B' AND g.nullmix = 0 AND g.max_abs <= @Tolerance
      AND ISNULL(v.a,0) <> ISNULL(v.b,0);

    /* EXCEPT is DISTINCT-based and cannot see an identically duplicated row, and
       row multiplicity is the whole subject of this release - so the row count
       and the per-grain-key count are checked alongside it, with NO tolerance.
       Dropping either lets this pass while the snapshot disagrees with Access. */
    INSERT INTO #res (fy, exact_draft_only, exact_snap_only,
                      tol_draft_only, tol_snap_only, tolerated_rows, max_abs_delta,
                      draft_rows, snap_rows, mult_diffs, draft_splits, snap_splits)
    SELECT @fy,
      (SELECT COUNT(*) FROM #dd),
      (SELECT COUNT(*) FROM #ss),
      (SELECT COUNT(*) FROM @pairs
        WHERE side IN ('B','D') AND (side <> 'B' OR nullmix > 0 OR max_abs > @Tolerance)),
      (SELECT COUNT(*) FROM @pairs
        WHERE side IN ('B','S') AND (side <> 'B' OR nullmix > 0 OR max_abs > @Tolerance)),
      (SELECT COUNT(*) FROM @pairs
        WHERE side = 'B' AND nullmix = 0 AND max_abs <= @Tolerance),
      (SELECT MAX(max_abs) FROM @pairs),
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
SET verdict = CASE WHEN tol_draft_only = 0 AND tol_snap_only = 0 AND mult_diffs = 0
                    AND draft_rows = snap_rows AND draft_splits = snap_splits
                   THEN 'PASS' ELSE 'FAIL' END;

SELECT 'PER_YEAR' AS report, * FROM #res ORDER BY fy;

/* Every row the tolerance absorbed, named. Empty here means the snapshot is
   BIT-IDENTICAL to Access everywhere - the strongest outcome. A row here is not
   a failure, but it IS a measurement: if this list grows beyond the known
   float-artifact accounts, or a delta approaches the tolerance from below,
   investigate before signing off. */
SELECT 'TOLERATED' AS report, * FROM #tol ORDER BY fy, acct, col;

SELECT 'TOLERATED_SUMMARY' AS report,
       (SELECT COUNT(*) FROM #tol)                                 AS tolerated_cells,
       (SELECT COUNT(DISTINCT CONCAT(fy,'|',acct)) FROM #tol)      AS tolerated_accounts,
       (SELECT MAX(ABS(delta)) FROM #tol)                          AS largest_abs_delta,
       @Tolerance                                                   AS tolerance_in_force;

/* The line that decides the gate. */
SELECT 'VERDICT' AS report,
       COUNT(*)                                             AS years_checked,
       SUM(CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END)    AS years_failing,
       SUM(tol_draft_only)                                  AS total_missing_from_snapshot,
       SUM(tol_snap_only)                                   AS total_extra_in_snapshot,
       SUM(tolerated_rows)                                  AS total_tolerated_rows,
       SUM(exact_draft_only)                                AS total_exact_draft_only,
       SUM(exact_snap_only)                                 AS total_exact_snap_only,
       SUM(mult_diffs)                                      AS total_multiplicity_diffs,
       CASE WHEN SUM(CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END) = 0
            THEN 'PASS - the stored snapshot matches Access'
            ELSE 'FAIL - DO NOT PROCEED' END                AS verdict
FROM #res;

DROP TABLE #dd; DROP TABLE #ss;
DROP TABLE #d;  DROP TABLE #s;
DROP TABLE #res; DROP TABLE #tol; DROP TABLE #yrs;
GO
