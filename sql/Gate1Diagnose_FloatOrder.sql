/* ===========================================================================
   Gate1Diagnose_FloatOrder.sql
   ---------------------------------------------------------------------------
   DIAGNOSTIC ONLY. READ-ONLY. No #temp tables, no writes. Delete after use.

   WHAT THIS SETTLES
     GATE 1 fails on production with ONE cent of difference, repeatably, on one
     row:

       FY2025  4-76100-H01-203-0251-00-000  FOOD SUPPLIES  H01/203/0251
       Feb       draft 818,966,030,193.12   parity ...93.11   delta -0.01
       Q2      3,714,287,202,312.62  ->  ...12.61            (carries Feb)
       YTDTotal        6,315,268.79  ->  6,315,268.78        (carries Feb)

     Only Feb differs. Q2 and YTDTotal are derived from the monthly values, so
     they inherit that one cent and are not independent findings.

     The hypothesis is FLOAT NON-ASSOCIATIVITY, not a logic difference:

       - 0098AFinGLMaster.NetChange is float, and BOTH sides sum it as float -
         the draft through PIVOT (SUM(NetChange)), the parity function through
         SUM(CASE WHEN Measure = '2' THEN Amount END). Same rows, same branch,
         same filter; different physical aggregation plan, therefore a different
         ADDITION ORDER.
       - Float addition is not associative. One ulp of a double at 3.7e12 is
         ~0.00049, and this account carries Dec -3,714,285,689,284.16 against
         Jan +2,895,320,880,063.63 - trillion-scale entries that cancel into a
         6.3M year. Reordering sums of that size moves the result by more than
         half a cent, so ROUND(...,2) can land on either side.
       - That is why only this account, in only one month, in one of thirteen
         years, disagrees - and why nothing disagreed on the quiet dev replica,
         whose data for this account differed.

   HOW TO READ THE RESULT
     Query 2 computes February three ways. If exact_decimal_sum ends in
     ...93.115 (or within a cent of both reported values), the two float answers
     are both legitimate roundings of one exact quantity and the difference is
     REPRESENTATIONAL - there is no wrong branch to fix. If the exact sum is
     clearly one of the two and far from the other, the hypothesis is wrong and
     the branch logic needs looking at.
   =========================================================================== */

USE FinanceAutomationSystem;
SET NOCOUNT ON;

DECLARE @Acct varchar(50) = '4-76100-H01-203-0251-00-000';
DECLARE @FY   varchar(10) = '2025';

/* 1. The scale of the inputs. A cent of reorder error needs terms large enough
      that one ulp approaches a cent - look at max_abs and the count. */
SELECT 'FEB_INPUT_SCALE' AS chk,
       COUNT(*)                                            AS gl_rows,
       CONVERT(decimal(19,2), MIN(NetChange))              AS min_netchange,
       CONVERT(decimal(19,2), MAX(NetChange))              AS max_netchange,
       CONVERT(decimal(19,2), MAX(ABS(NetChange)))         AS max_abs,
       SUM(CASE WHEN ABS(NetChange) >= 1000000000 THEN 1 ELSE 0 END) AS rows_over_1bn
FROM dbo.[0098AFinGLMaster]
WHERE FinancialYear = @FY
  AND AccountNumber = @Acct
  AND FORMAT(TRXDate, 'MMM') = 'Feb';

/* 2. THE DECISIVE COMPARISON. Same rows, three aggregations:
        float_sum          - what both sides do today, order-dependent
        exact_decimal_sum  - order-independent, the true value
        exact_rounded      - the exact value rounded to 2dp */
SELECT 'FEB_THREE_WAYS' AS chk,
       CONVERT(decimal(28,6), SUM(NetChange))                       AS float_sum,
       CONVERT(decimal(28,6), SUM(CONVERT(decimal(28,6), NetChange))) AS exact_decimal_sum,
       ROUND(SUM(CONVERT(decimal(28,6), NetChange)), 2)             AS exact_rounded,
       ROUND(CONVERT(decimal(28,6), SUM(NetChange)), 2)             AS float_rounded
FROM dbo.[0098AFinGLMaster]
WHERE FinancialYear = @FY
  AND AccountNumber = @Acct
  AND FORMAT(TRXDate, 'MMM') = 'Feb';

/* 3. Order-dependence demonstrated directly: force two different addition
      orders over the same rows. Different answers here prove the plan, not the
      logic, decides the cent. (MAXDOP 1 vs parallel also changes order, which
      is why this can differ between runs of the SAME query.) */
WITH f AS (
    SELECT CONVERT(float, NetChange) AS n,
           ROW_NUMBER() OVER (ORDER BY ABS(NetChange) ASC)  AS asc_rn,
           ROW_NUMBER() OVER (ORDER BY ABS(NetChange) DESC) AS desc_rn
    FROM dbo.[0098AFinGLMaster]
    WHERE FinancialYear = @FY AND AccountNumber = @Acct
      AND FORMAT(TRXDate, 'MMM') = 'Feb'
)
SELECT 'FEB_ORDER_SENSITIVITY' AS chk,
       CONVERT(decimal(28,6), (SELECT SUM(n) FROM (SELECT n FROM f ORDER BY asc_rn  OFFSET 0 ROWS) a)) AS sum_small_first,
       CONVERT(decimal(28,6), (SELECT SUM(n) FROM (SELECT n FROM f ORDER BY desc_rn OFFSET 0 ROWS) b)) AS sum_large_first;

/* 4. Is this account unique in its magnitudes? If the trillion-scale entries
      are confined to it, the exposure is one account, not a systemic risk -
      which is what makes a named tolerance defensible rather than a blind one. */
SELECT 'ACCOUNTS_OVER_1BN' AS chk, FinancialYear, AccountNumber,
       COUNT(*) AS big_rows,
       CONVERT(decimal(28,2), MAX(ABS(NetChange))) AS max_abs
FROM dbo.[0098AFinGLMaster]
WHERE ABS(NetChange) >= 1000000000
GROUP BY FinancialYear, AccountNumber
ORDER BY max_abs DESC;
