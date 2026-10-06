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
   at it reports failures that mean nothing. Run this one instead.

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

   ===========================================================================
   🔴 WHY THERE IS A MONEY TOLERANCE, AND WHY IT IS NOT A WEAKENING
   ===========================================================================
   Added 2026-10-06, after this gate FAILED three times on a single cent. The
   full record is in financeupdatesepprogress.md (2026-10-05, 2026-10-06); the
   short version:

     dbo.0098AFinGLMaster.NetChange is FLOAT, and BOTH sides sum it as float -
     the draft through PIVOT, the parity function through conditional SUM. Float
     addition is not associative, and five accounts carry entries up to 1.3e13
     where one ulp of a double is ~0.002. So the two query forms add in
     different orders and can land either side of a half-cent rounding
     boundary.

     MEASURED over one account's 1,208 February rows: the exact decimal sum is
     818,966,030,193.109965 (-> .11). Production's plan gave ...114746; the same
     statement at MAXDOP 1 gave ...115479 (-> .12); two forced orderings gave
     ...109863 and ...109253. FIVE answers for one set of rows. MAXDOP alone
     flips the cent.

     The exact value rounds to .11, which is what the PARITY function produces.
     ACCESS IS THE CENT THAT IS WRONG. This gate was failing because the new
     function is MORE accurate than its own reference.

     Decisive: sql/Gate1Diagnose_FY2025.sql Part 2 re-materialises the SAME two
     functions over a REDUCED projection and finds zero differences. SQL Server
     inlines these TVFs into the calling query, so the surrounding projection
     changes the plan, changes the addition order, changes the cent. The
     disagreement is a property of the whole STATEMENT, not of the parity logic.
     No tuning fixes it; re-running is not a strategy.

     Total exposure, measured across all 13 FYs by sql/ParityMoneyDelta.sql:
     ONE CENT of YTDTotal in 3,694,251,307.70 - 2.7e-12. Allocation, Approved,
     Routing and every row count agree EXACTLY in every year.

   WHAT THE TOLERANCE DOES AND DOES NOT DO
     ✅ MONEY columns may differ by up to @Tolerance (default 0.01), and every
        row that uses it is LISTED in the TOLERATED output. A tolerance you
        cannot see is a blind spot; this one is a standing measurement.
     ✅ The EXACT comparison is still computed and reported, per year, in
        exact_draft_only / exact_parity_only. A bit-identical year still reads as
        bit-identical. The tolerance never hides that something moved.
     🔴 GRAIN IS STILL EXACT. Row counts, per-grain-key multiplicity, split
        counts and the key columns themselves (account, AccountID, description,
        institution, responsibility, department) are compared with NO tolerance
        whatsoever. Row grain is the entire subject of this release.
     🔴 A NULL-vs-value mismatch is NEVER tolerated, however small the implied
        delta - see @nullmix below. Otherwise "no activity" and "exactly zero"
        would silently merge.
     🔴 THIS CHANGES NO DATA. This file is a read-only test harness. The
        deployed function, the snapshot, the six pages and the CSV exports are
        byte-identical with or without it. It changes only what the TEST calls a
        failure.

   SETTING @Tolerance TO 0 restores the old all-or-nothing behaviour exactly.

   ===========================================================================
   STRUCTURE
   ===========================================================================
   Rewritten 2026-10-06 from thirteen copy-pasted blocks into one loop, so the
   comparison exists ONCE. The previous shape had the same 40 lines thirteen
   times; the tolerance would have had to be correct in thirteen places.

   MEMORY: each side is materialised into a pre-created #temp table before any
   comparison. Do NOT "simplify" this by comparing the two functions inline:
   that forces repeated full builds of a query scanning ~641k GL rows and raises
   Msg 701 (insufficient system memory) on a 2048 MB instance. The tables are
   CREATEd once and DELETEd per iteration because SELECT ... INTO inside a loop
   is a compile-time error even with a DROP between iterations.

   @MaxDop: set to 1 on the LOCAL RESTORE. Measured 2026-10-06 there, at the
   instance default (DOP 12) the parity materialisation stalls on CXSYNC_PORT for
   11+ minutes having done ~2,300 logical reads - a parallel-exchange stall, not
   work, on SQL Server 2022 RTM. Capped it is ~12 s/year. Leave it 0 on
   production, which does not need it. 🔴 The cap is applied to BOTH sides or
   NEITHER: a one-sided cap puts a plan asymmetry inside the comparison itself.
   And note the cap CHANGES the float addition order, so a capped run is not
   evidence about an uncapped one. Production must be gated on production.

   EXPECTED: the VERDICT row reads PASS, with tol_draft_only, tol_parity_only,
   total_multiplicity_diffs, years_with_rowcount_diff and years_with_split_diff
   all zero. tolerated_rows is EXPECTED to be small and non-zero (1 on the
   2026-10-05 data, FY2025) and every one of them is printed. The splits column
   is the baseline for @MaxSplitAccounts - a year whose count moves without a
   named explanation is a STOP, not a curiosity.

     FY    rows   splits        FY    rows   splits
     2014  1814   1             2021  1378   0
     2015  1973   1             2022  1020   0
     2016  1697   0             2023   785   0
     2017  1840   3             2024  1887   1
     2018  1867   3             2025  2121   4
     2019  1835   0             2026  2278  11
     2020  1882   0

   Those row counts MOVE with production data (FY2026 was 2275 on 2026-09-29 and
   2278 on 2026-10-05). The gate does not compare against them - they are here so
   a reader can tell drift from a defect. Re-measure; do not treat a difference
   as a failure.
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

/* ===========================================================================
   KNOBS
   =========================================================================== */
DECLARE @Tolerance decimal(19,4) = 0.01;  -- money only; 0 = exact, old behaviour
DECLARE @MaxDop    int           = 0;     -- 1 on the local restore, 0 on production

/* ---------------------------------------------------------------------------
   The fiscal years to check. One list, not thirteen blocks. Add a year here
   when the ledger gains one; a year with no rows on either side reports 0/0 and
   passes trivially, which is correct but costs a build, so do not pad it.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#yrs') IS NOT NULL DROP TABLE #yrs;
CREATE TABLE #yrs (fy varchar(10) PRIMARY KEY);
INSERT INTO #yrs (fy) VALUES
    ('2014'),('2015'),('2016'),('2017'),('2018'),('2019'),('2020'),
    ('2021'),('2022'),('2023'),('2024'),('2025'),('2026');

IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res;
CREATE TABLE #res (
    fy                varchar(10),
    exact_draft_only  int,   -- EXACT comparison, reported not fatal
    exact_parity_only int,
    tol_draft_only    int,   -- AFTER tolerance: rows Access has that parity does not
    tol_parity_only   int,   -- AFTER tolerance: rows parity has that Access does not
    tolerated_rows    int,   -- differed by <= @Tolerance on money alone
    max_abs_delta     decimal(19,4),
    draft_rows        int,
    parity_rows       int,
    mult_diffs        int,   -- grain keys whose ROW COUNT differs (NO tolerance)
    draft_splits      int,
    parity_splits     int,
    verdict           varchar(10)
);

/* The tolerated detail - printed at the end. This is the half of the tolerance
   that keeps it honest: a cent that is absorbed silently is a blind spot, a
   cent that is named every run is a measurement. */
IF OBJECT_ID('tempdb..#tol') IS NOT NULL DROP TABLE #tol;
CREATE TABLE #tol (
    fy varchar(10) COLLATE DATABASE_DEFAULT, acct varchar(255) COLLATE DATABASE_DEFAULT, aid int,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    col varchar(20) COLLATE DATABASE_DEFAULT, draft_value decimal(19,2), parity_value decimal(19,2),
    delta decimal(19,4)
);

/* One shape, created once and reused - see the MEMORY note in the header. */
IF OBJECT_ID('tempdb..#d')  IS NOT NULL DROP TABLE #d;
IF OBJECT_ID('tempdb..#p')  IS NOT NULL DROP TABLE #p;
IF OBJECT_ID('tempdb..#dd') IS NOT NULL DROP TABLE #dd;
IF OBJECT_ID('tempdb..#pp') IS NOT NULL DROP TABLE #pp;

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
CREATE TABLE #p (
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

/* The SYMMETRIC DIFFERENCE rows only, each numbered within its grain key so the
   two sides can be paired. This set is tiny (1 row on the 2026-10-05 data), so
   materialising it costs nothing and lets the row-level and cell-level passes
   both read it without recomputing the EXCEPT. */
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
CREATE TABLE #pp (
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

/* Declared OUTSIDE the loop deliberately. A table variable declared inside a
   WHILE body is not re-created per iteration, so it would accumulate rows across
   years and every count after the first would be wrong. It is emptied at the top
   of each iteration instead. */
DECLARE @pairs TABLE (
    acct varchar(255) COLLATE DATABASE_DEFAULT, aid int,
    inst varchar(50) COLLATE DATABASE_DEFAULT, resp varchar(50) COLLATE DATABASE_DEFAULT,
    dept varchar(50) COLLATE DATABASE_DEFAULT,
    rn int, side char(1), max_abs decimal(19,4), nullmix int
);

DECLARE @fy varchar(10);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT fy FROM #yrs ORDER BY fy;
OPEN c;
FETCH NEXT FROM c INTO @fy;

WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM #d;  DELETE FROM #p;
    DELETE FROM #dd; DELETE FROM #pp;

    /* --- materialise both sides. The @MaxDop branches differ ONLY in the hint;
           keep them identical in every other respect, and change both or
           neither. --- */
    IF @MaxDop = 1
    BEGIN
        INSERT INTO #d
        SELECT CONVERT(varchar(10),FinancialYear), CONVERT(int,AccountID),
               CONVERT(varchar(255),AccountNumber), CONVERT(nvarchar(255),AccountDescription),
               CONVERT(varchar(50),InstitutionID), CONVERT(varchar(50),ResponsibilityID),
               CONVERT(varchar(50),DepartmentID),
               CONVERT(decimal(19,2),[Oct]), CONVERT(decimal(19,2),[Nov]), CONVERT(decimal(19,2),[Dec]),
               CONVERT(decimal(19,2),[Jan]), CONVERT(decimal(19,2),[Feb]), CONVERT(decimal(19,2),[Mar]),
               CONVERT(decimal(19,2),[Apr]), CONVERT(decimal(19,2),[May]), CONVERT(decimal(19,2),[Jun]),
               CONVERT(decimal(19,2),[Jul]), CONVERT(decimal(19,2),[Aug]), CONVERT(decimal(19,2),[Sep]),
               CONVERT(decimal(19,2),Q1), CONVERT(decimal(19,2),Q2),
               CONVERT(decimal(19,2),Q3), CONVERT(decimal(19,2),Q4),
               CONVERT(decimal(19,2),YTDTotal), CONVERT(decimal(19,2),Approved),
               CONVERT(decimal(19,2),Routing), CONVERT(decimal(19,2),Allocation)
        FROM dbo.fn_OversightDraftUnscoped(@fy) OPTION (MAXDOP 1);

        INSERT INTO #p
        SELECT CONVERT(varchar(10),FinancialYear), CONVERT(int,AccountID),
               CONVERT(varchar(255),AccountNumber), CONVERT(nvarchar(255),AccountDescription),
               CONVERT(varchar(50),InstitutionID), CONVERT(varchar(50),ResponsibilityID),
               CONVERT(varchar(50),DepartmentID),
               CONVERT(decimal(19,2),[Oct]), CONVERT(decimal(19,2),[Nov]), CONVERT(decimal(19,2),[Dec]),
               CONVERT(decimal(19,2),[Jan]), CONVERT(decimal(19,2),[Feb]), CONVERT(decimal(19,2),[Mar]),
               CONVERT(decimal(19,2),[Apr]), CONVERT(decimal(19,2),[May]), CONVERT(decimal(19,2),[Jun]),
               CONVERT(decimal(19,2),[Jul]), CONVERT(decimal(19,2),[Aug]), CONVERT(decimal(19,2),[Sep]),
               CONVERT(decimal(19,2),Q1), CONVERT(decimal(19,2),Q2),
               CONVERT(decimal(19,2),Q3), CONVERT(decimal(19,2),Q4),
               CONVERT(decimal(19,2),YTDTotal), CONVERT(decimal(19,2),Approved),
               CONVERT(decimal(19,2),Routing), CONVERT(decimal(19,2),Allocation)
        FROM dbo.fn_FinanceLedgerAccessParity(@fy) OPTION (MAXDOP 1);
    END
    ELSE
    BEGIN
        INSERT INTO #d
        SELECT CONVERT(varchar(10),FinancialYear), CONVERT(int,AccountID),
               CONVERT(varchar(255),AccountNumber), CONVERT(nvarchar(255),AccountDescription),
               CONVERT(varchar(50),InstitutionID), CONVERT(varchar(50),ResponsibilityID),
               CONVERT(varchar(50),DepartmentID),
               CONVERT(decimal(19,2),[Oct]), CONVERT(decimal(19,2),[Nov]), CONVERT(decimal(19,2),[Dec]),
               CONVERT(decimal(19,2),[Jan]), CONVERT(decimal(19,2),[Feb]), CONVERT(decimal(19,2),[Mar]),
               CONVERT(decimal(19,2),[Apr]), CONVERT(decimal(19,2),[May]), CONVERT(decimal(19,2),[Jun]),
               CONVERT(decimal(19,2),[Jul]), CONVERT(decimal(19,2),[Aug]), CONVERT(decimal(19,2),[Sep]),
               CONVERT(decimal(19,2),Q1), CONVERT(decimal(19,2),Q2),
               CONVERT(decimal(19,2),Q3), CONVERT(decimal(19,2),Q4),
               CONVERT(decimal(19,2),YTDTotal), CONVERT(decimal(19,2),Approved),
               CONVERT(decimal(19,2),Routing), CONVERT(decimal(19,2),Allocation)
        FROM dbo.fn_OversightDraftUnscoped(@fy);

        INSERT INTO #p
        SELECT CONVERT(varchar(10),FinancialYear), CONVERT(int,AccountID),
               CONVERT(varchar(255),AccountNumber), CONVERT(nvarchar(255),AccountDescription),
               CONVERT(varchar(50),InstitutionID), CONVERT(varchar(50),ResponsibilityID),
               CONVERT(varchar(50),DepartmentID),
               CONVERT(decimal(19,2),[Oct]), CONVERT(decimal(19,2),[Nov]), CONVERT(decimal(19,2),[Dec]),
               CONVERT(decimal(19,2),[Jan]), CONVERT(decimal(19,2),[Feb]), CONVERT(decimal(19,2),[Mar]),
               CONVERT(decimal(19,2),[Apr]), CONVERT(decimal(19,2),[May]), CONVERT(decimal(19,2),[Jun]),
               CONVERT(decimal(19,2),[Jul]), CONVERT(decimal(19,2),[Aug]), CONVERT(decimal(19,2),[Sep]),
               CONVERT(decimal(19,2),Q1), CONVERT(decimal(19,2),Q2),
               CONVERT(decimal(19,2),Q3), CONVERT(decimal(19,2),Q4),
               CONVERT(decimal(19,2),YTDTotal), CONVERT(decimal(19,2),Approved),
               CONVERT(decimal(19,2),Routing), CONVERT(decimal(19,2),Allocation)
        FROM dbo.fn_FinanceLedgerAccessParity(@fy);
    END

    /* --- the symmetric difference, paired within grain key.
           ORDER BY every money column so both sides number identically; the
           grain key alone is not unique (that is what splits ARE). --- */
    INSERT INTO #dd
    SELECT ROW_NUMBER() OVER (PARTITION BY acct, aid, descr, inst, resp, dept
             ORDER BY c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
                      q1,q2,q3,q4,ytd,appr,rtg,alloc),
           aid, acct, descr, inst, resp, dept,
           c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
           q1,q2,q3,q4,ytd,appr,rtg,alloc
    FROM (SELECT * FROM #d EXCEPT SELECT * FROM #p) AS x;

    INSERT INTO #pp
    SELECT ROW_NUMBER() OVER (PARTITION BY acct, aid, descr, inst, resp, dept
             ORDER BY c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
                      q1,q2,q3,q4,ytd,appr,rtg,alloc),
           aid, acct, descr, inst, resp, dept,
           c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,
           q1,q2,q3,q4,ytd,appr,rtg,alloc
    FROM (SELECT * FROM #p EXCEPT SELECT * FROM #d) AS y;

    /* --- classify each differing row.
           side 'B' = present on both sides at this rn, so it is a genuine PAIR
                      and the only case the tolerance can apply to.
           side 'D' / 'P' = no counterpart at all -> a real difference, never
                      tolerated regardless of magnitude.
           nullmix  = columns where one side is NULL and the other is not. Never
                      tolerated: "no activity" and "exactly zero" must not merge.
           --- */
    DELETE FROM @pairs;

    INSERT INTO @pairs (acct, aid, inst, resp, dept, rn, side, max_abs, nullmix)
    SELECT COALESCE(d.acct, p.acct), COALESCE(d.aid, p.aid),
           COALESCE(d.inst, p.inst), COALESCE(d.resp, p.resp), COALESCE(d.dept, p.dept),
           COALESCE(d.rn, p.rn),
           CASE WHEN d.acct IS NOT NULL AND p.acct IS NOT NULL THEN 'B'
                WHEN d.acct IS NOT NULL THEN 'D' ELSE 'P' END,
           agg.max_abs, agg.nullmix
    FROM #dd d
    FULL OUTER JOIN #pp p
      ON  p.acct = d.acct
      AND ISNULL(p.aid, -1) = ISNULL(d.aid, -1)
      AND ISNULL(p.descr, N'<null>') = ISNULL(d.descr, N'<null>')
      AND p.inst = d.inst AND p.resp = d.resp AND p.dept = d.dept
      AND p.rn = d.rn
    CROSS APPLY (
        SELECT MAX(ABS(ISNULL(v.a,0) - ISNULL(v.b,0))) AS max_abs,
               /* T-SQL has no boolean type, so the NULL patterns are compared as
                  0/1 flags - (v.a IS NULL) <> (v.b IS NULL) is a syntax error. */
               SUM(CASE WHEN (CASE WHEN v.a IS NULL THEN 1 ELSE 0 END)
                           <> (CASE WHEN v.b IS NULL THEN 1 ELSE 0 END)
                        THEN 1 ELSE 0 END) AS nullmix
        FROM (VALUES
            (d.c01,p.c01),(d.c02,p.c02),(d.c03,p.c03),(d.c04,p.c04),
            (d.c05,p.c05),(d.c06,p.c06),(d.c07,p.c07),(d.c08,p.c08),
            (d.c09,p.c09),(d.c10,p.c10),(d.c11,p.c11),(d.c12,p.c12),
            (d.q1,p.q1),(d.q2,p.q2),(d.q3,p.q3),(d.q4,p.q4),
            (d.ytd,p.ytd),(d.appr,p.appr),(d.rtg,p.rtg),(d.alloc,p.alloc)
        ) AS v(a,b)
    ) AS agg;

    /* --- the tolerated detail, cell by cell --- */
    INSERT INTO #tol (fy, acct, aid, inst, resp, dept, col, draft_value, parity_value, delta)
    SELECT @fy, d.acct, d.aid, d.inst, d.resp, d.dept, v.col, v.a, v.b, v.b - v.a
    FROM #dd d
    JOIN #pp p
      ON  p.acct = d.acct
      AND ISNULL(p.aid, -1) = ISNULL(d.aid, -1)
      AND ISNULL(p.descr, N'<null>') = ISNULL(d.descr, N'<null>')
      AND p.inst = d.inst AND p.resp = d.resp AND p.dept = d.dept
      AND p.rn = d.rn
    JOIN @pairs g
      ON  g.acct = d.acct AND ISNULL(g.aid,-1) = ISNULL(d.aid,-1)
      AND g.inst = d.inst AND g.resp = d.resp AND g.dept = d.dept AND g.rn = d.rn
    CROSS APPLY (VALUES
        ('Oct',d.c01,p.c01),('Nov',d.c02,p.c02),('Dec',d.c03,p.c03),('Jan',d.c04,p.c04),
        ('Feb',d.c05,p.c05),('Mar',d.c06,p.c06),('Apr',d.c07,p.c07),('May',d.c08,p.c08),
        ('Jun',d.c09,p.c09),('Jul',d.c10,p.c10),('Aug',d.c11,p.c11),('Sep',d.c12,p.c12),
        ('Q1',d.q1,p.q1),('Q2',d.q2,p.q2),('Q3',d.q3,p.q3),('Q4',d.q4,p.q4),
        ('YTDTotal',d.ytd,p.ytd),('Approved',d.appr,p.appr),
        ('Routing',d.rtg,p.rtg),('Allocation',d.alloc,p.alloc)
    ) AS v(col,a,b)
    WHERE g.side = 'B' AND g.nullmix = 0 AND g.max_abs <= @Tolerance
      AND ISNULL(v.a,0) <> ISNULL(v.b,0);

    /* --- the per-year row. Grain checks carry NO tolerance. --- */
    INSERT INTO #res (fy, exact_draft_only, exact_parity_only,
                      tol_draft_only, tol_parity_only, tolerated_rows, max_abs_delta,
                      draft_rows, parity_rows, mult_diffs, draft_splits, parity_splits)
    SELECT @fy,
      (SELECT COUNT(*) FROM #dd),
      (SELECT COUNT(*) FROM #pp),
      (SELECT COUNT(*) FROM @pairs
        WHERE side IN ('B','D') AND (side <> 'B' OR nullmix > 0 OR max_abs > @Tolerance)),
      (SELECT COUNT(*) FROM @pairs
        WHERE side IN ('B','P') AND (side <> 'B' OR nullmix > 0 OR max_abs > @Tolerance)),
      (SELECT COUNT(*) FROM @pairs
        WHERE side = 'B' AND nullmix = 0 AND max_abs <= @Tolerance),
      (SELECT MAX(max_abs) FROM @pairs),
      (SELECT COUNT(*) FROM #d),
      (SELECT COUNT(*) FROM #p),
      (SELECT COUNT(*) FROM (
          SELECT ISNULL(a.k,b.k) AS k, ISNULL(a.n,0) AS na, ISNULL(b.n,0) AS nb
          FROM (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS n
                FROM #d GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) AS a
          FULL OUTER JOIN
               (SELECT CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept) AS k, COUNT(*) AS n
                FROM #p GROUP BY CONCAT(acct,'|',aid,'|',descr,'|',inst,'|',resp,'|',dept)) AS b
            ON a.k = b.k
      ) AS z WHERE na <> nb),
      (SELECT COUNT(*) FROM (SELECT acct FROM #d GROUP BY acct HAVING COUNT(*) > 1) AS s1),
      (SELECT COUNT(*) FROM (SELECT acct FROM #p GROUP BY acct HAVING COUNT(*) > 1) AS s2);

    FETCH NEXT FROM c INTO @fy;
END

CLOSE c;
DEALLOCATE c;

UPDATE #res
SET verdict = CASE WHEN tol_draft_only = 0 AND tol_parity_only = 0 AND mult_diffs = 0
                    AND draft_rows = parity_rows AND draft_splits = parity_splits
                   THEN 'PASS' ELSE 'FAIL' END;

SELECT 'PER_YEAR' AS report, * FROM #res ORDER BY fy;

/* Every row the tolerance absorbed, named. An empty result here means the two
   sides are BIT-IDENTICAL everywhere - the strongest outcome. A row here is not
   a failure, but it IS a measurement: if this list grows beyond the known
   float-artifact accounts, or a delta approaches the tolerance from below,
   investigate before signing off. */
SELECT 'TOLERATED' AS report, * FROM #tol
ORDER BY fy, acct, col;

SELECT 'TOLERATED_SUMMARY' AS report,
       (SELECT COUNT(*) FROM #tol)                      AS tolerated_cells,
       (SELECT COUNT(DISTINCT CONCAT(fy,'|',acct))      FROM #tol) AS tolerated_accounts,
       (SELECT MAX(ABS(delta)) FROM #tol)               AS largest_abs_delta,
       @Tolerance                                        AS tolerance_in_force;

/* The line that decides the gate. */
SELECT 'VERDICT' AS report,
       SUM(tol_draft_only)                                   AS total_draft_only,
       SUM(tol_parity_only)                                  AS total_parity_only,
       SUM(tolerated_rows)                                   AS total_tolerated_rows,
       SUM(exact_draft_only)                                 AS total_exact_draft_only,
       SUM(exact_parity_only)                                AS total_exact_parity_only,
       SUM(mult_diffs)                                       AS total_multiplicity_diffs,
       SUM(CASE WHEN draft_rows   <> parity_rows   THEN 1 ELSE 0 END) AS years_with_rowcount_diff,
       SUM(CASE WHEN draft_splits <> parity_splits THEN 1 ELSE 0 END) AS years_with_split_diff,
       CASE WHEN SUM(CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END) = 0
            THEN 'PASS' ELSE 'FAIL - DO NOT DEPLOY' END      AS verdict
FROM #res;

DROP TABLE #dd; DROP TABLE #pp;
DROP TABLE #d;  DROP TABLE #p;
DROP TABLE #res; DROP TABLE #tol; DROP TABLE #yrs;
GO
