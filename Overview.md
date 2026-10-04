# Finance Automation System — View & Calculation Overview

A plain-language reference for explaining to the Finance department **what each screen shows** and
**exactly how every number on it is produced**.

Written 2026-08-06. Where this document and the code disagree, the code wins — but every figure
below was read off the current source.

---

## Table of contents

1. [How the data gets to the screen (read this first)](#1-how-the-data-gets-to-the-screen)
2. [Rules that apply to every view](#2-rules-that-apply-to-every-view)
3. [Dashboard](#3-dashboard-dashboard)
4. [Budget Allocations](#4-budget-allocations-budget-allocations)
5. [Monthly Expenditure](#5-monthly-expenditure-monthly-expenditure)
6. [Variance](#6-variance-variance)
7. [Login and Profile](#7-login-and-profile)
8. [Frequently asked questions](#8-frequently-asked-questions)

---

## 1. How the data gets to the screen

Every money figure in the portal ultimately comes from **one table**, rebuilt nightly:
`dbo.FinanceLedgerSnapshot` in the `FinanceAutomationSystem` SQL Server database.

```
Great Plains GL          0098AFinGLMaster      (posted transactions, NetChange)
Budget allocations       0040CBudgetsAllocation (Allocation per account per FY)
Requisitions             0040DBudgetsEncumbrance (committed but unspent money)
Chart / naming           GL40200, 0000CSegmentControls, DBA_Clusters
Account scope filter     0030A/AB/AC COA Reports (reporting line 3 — 41 accounts)
        |
        |  dbo.fn_FinanceLedgerSource(@FinancialYear)   — the heavy build (~2–4 min/FY)
        v
dbo.FinanceLedgerSnapshot          one row per (FinancialYear, AccountNumber) — NO user column
        |
        |  joined LIVE to dbo.vw_WebAppUserAccess (who may see which department)
        v
dbo.vw_FinanceLedger               the app's read surface — adds UserName + 3 derived columns
        |                +--> dbo.vw_BudgetAllocation   (thin projection, Allocation <> 0)
        |                +--> dbo.MonthlyExpenditure    (UNPIVOT to one row per month;
        |                                               read by the DASHBOARD only)
        v
Laravel controllers -> Inertia props -> Vue pages
```

### What one snapshot row contains

For a single account in a single fiscal year:

| Column | Meaning | How it is built |
|---|---|---|
| `Oct` … `Sep` | Net GL movement in that calendar month | `SUM(NetChange)` from the GL, bucketed by `MONTH(TRXDate)`, converted to `decimal(19,4)` **before** summing |
| `Q1`–`Q4` | Quarter totals | Oct+Nov+Dec, Jan+Feb+Mar, Apr+May+Jun, Jul+Aug+Sep |
| `YTDTotal` | Year-to-date posted spend | Sum of all 12 month columns |
| `Allocation` | Approved budget | `SUM(Allocation)` from `0040CBudgetsAllocation` for that FY |
| `Approved` | Committed — approved requisitions, **net of goods received** | `SUM((Quantity - QtyShipped) * UnitCost)` where `Status IN ('AP','PO')`, floored at zero |
| `Routing` | Committed — in-flight requisitions, **net of goods received** | `SUM((Quantity - QtyShipped) * UnitCost)` where `Status IN ('RT','HD','PN')`, floored at zero. Displayed only — does not reduce the allocation balance |
| `ClusterName`, `InstitutionName`, `ResponsibilityName`, `DepartmentName` | Labels | Parsed out of the account number's segments, then named from the segment tables |
| `MainGroup`, `SubGroupA`, `SubGroupB` | Category | Split out of the reporting line description (`A : B : C`) |

### The three derived columns (computed in `vw_FinanceLedger`, not stored)

```
ActualExpenditure = YTDTotal + Approved + Routing
Excess            = ABS(Allocation - ActualExpenditure)  when that is negative, else 0
AllocationBalance =     (Allocation - ActualExpenditure)  when that is positive, else 0
```

**Why commitments count.** Money sitting on an approved or routing requisition is no longer
available to spend. Measuring balance against posted GL alone would overstate every line's headroom.

**Why the balance floors at zero.** An overspent line contributes `0` balance and reports the
overspend separately as `Excess`. If a negative balance were allowed, one overspent account would
cancel out another account's genuine headroom in a totals row and overstate available funds.

### Refresh cadence

The snapshot is rebuilt by a **SQL Server Agent job** on the database server
(`SWRHA Finance - Ledger Refresh`, daily 21:30). Most nights it rebuilds the current and prior
fiscal year; on the 1st of the month it rebuilds every year. Manual runs: `php artisan ledger:refresh`.

The build has sanity gates: if it returns zero rows, or the row count falls more than 10%, or the
money totals move more than 25% versus the last good load, it **aborts and keeps the previous
snapshot** rather than writing suspect data over good data.

So: **numbers are as of the last successful nightly refresh, not real-time.** Permissions, by
contrast, are live — `vw_WebAppUserAccess` is joined on at query time.

---

## 2. Rules that apply to every view

### Scope — goods and services only

Every source view INNER JOINs the reporting-line-3 account list: **41 account codes** covering
medical and hardware supplies, utilities, rent, administrative expenses and equipment.

**Salaries (70100), overtime (70500) and other benefits (72100) are excluded by design.** This is
the single most common "the budget looks far too low" question. For one measured user in FY2026 the
difference is 4 accounts / TTD 74,327 (in scope) versus 18 accounts / TTD 13,312,384 (everything).
This is intended scope, not missing data. The Budget page header and both budget KPI cards say
"goods and services" for this reason.

### Fiscal year

- A fiscal year runs **1 October → 30 September** and is named for the year it ends in.
  FY2026 = Oct 2025 – Sep 2026.
- **Period 1 = October … Period 12 = September.**
- Which FY a page opens on: the requested year if it has data → else the current FY → else the
  latest FY that has data.
- **Cutoff** (how far "so far this year" reaches): 12 for a completed year, the current fiscal
  period for the year in progress, 0 for a year that has not started.
- Budget Allocations holds **FY2025 onward only** (the source allocation table has no earlier rows),
  while the ledger behind Monthly Expenditure and Variance goes back to **FY2014**. The pages' year
  rails legitimately differ in length.

### Who sees what

A user sees only accounts belonging to departments their **position** grants:

```
0006AWebAppControls   (UserName -> PositionID,      IsActive = TRUE)
        INNER JOIN
0006CWebAppPostControls (PositionID -> ResponsibilityID + DepartmentID, IsActive = TRUE)
```

A user whose position has no active row in `0006C` maps to **zero departments** and legitimately
sees empty pages everywhere. That is an access-mapping matter in the source system, not an
application fault. (As of 2026-08-06 only PositionID 10108 was mapped.)

### The three empty states — never confused

Each page distinguishes them, because they look identical in a table and mean different things:

| State | Detected by | What the user is told |
|---|---|---|
| Source unavailable | the query threw an exception | Amber warning: "The financial data source is unavailable. Please try again later." |
| No department mapping | access probe returns false | "Department access is not configured" — contact an administrator |
| No rows match | mapped, but result set empty | "No … found" for this fiscal year / these filters |

During an outage the pages render an **empty** table, never "TTD 0". A zero figure during an outage
is indistinguishable from a real answer. Also, if the access probe itself could not run, the page
assumes the user **does** have access — telling someone they have no permissions during an outage
sends them to chase the wrong fix.

### Caching

- **Filter dropdown lists** are cached per (user, fiscal year) for 10 minutes on a dedicated file store.
- **The access probe** is cached only 60 seconds, so a newly granted permission takes effect almost at once.
- **Tables, totals and KPI figures are NOT cached** — they are read live from the snapshot on every request.
  (The Dashboard is the exception: its aggregates are cached 10 minutes, since it takes no filters.)
- Every cache key is stamped with the snapshot's last refresh time, so a nightly rebuild invalidates
  the dropdown lists immediately rather than leaving them stale for the rest of the TTL.
- To clear by hand: `php artisan cache:clear file`.

### Currency

All money is **Trinidad and Tobago Dollars (TTD)**, formatted to 2 decimal places.

---

## 3. Dashboard (`/dashboard`)

A one-screen summary of the active fiscal year: three KPI cards and three charts.

### KPI 1 — Total Budget

> *"Approved allocation, goods and services"*

**What it is:** the total approved allocation for the active fiscal year across every account the
user can see.

**How it is calculated:**
```
SUM(TotalAllocation) FROM vw_BudgetAllocation
  WHERE UserName = <user> AND FinancialYear = <active FY>
```
`TotalAllocation` is the snapshot's `Allocation` column; the view excludes accounts with an
allocation of zero.

**Which fiscal year:** the list of years the user has budget rows for is read first; the active year
is the current FY if present, otherwise the latest year with data.

**Degradation:** if the query fails, or the user has no budget years at all, the card reads
"Budget data unavailable" (or "Not assigned" if they have no department mapping). It never shows
TTD 0 as an answer.

### KPI 2 — Budget Usage

> *"TTD X remaining"* / *"TTD X over budget"*

**What it is:** how much of the annual allocation has been consumed so far this fiscal year.

**How it is calculated (in the browser, from the two figures above):**
```
utilisation % = round( YTD Expenditure / Total Budget * 100 ), capped at 100
variance      = Total Budget - YTD Expenditure
overage       = max(0, YTD Expenditure - Total Budget)
```

- Displayed **capped at 100%** — an overspend reads 100%, and the amount exceeded appears in TTD on
  the sub-label.
- Colour: green below 75%, amber 75–89%, **red at 90%+ or over budget**, grey if net-negative
  (credits exceed spend).
- Requires **both** a numerator and a denominator: if either budget or expenditure is unavailable
  the card shows "—" with the reason.

> **Note for Finance:** this KPI measures usage against **posted GL spend only** (`YTDTotal`).
> It does *not* include encumbrances. The **Variance** page is the view that sets posted spend
> against the allocation line by line, and reports what is committed (`Approved`) and in the
> pipeline (`Routing`) beside it. The two answer different questions — "what have we spent overall"
> versus "which lines are over or under".

### KPI 3 — YTD Expenditure

> *"FY 2026 · through JUN, 26"*

**What it is:** net expenditure for the active fiscal year, from October up to and including the
current fiscal month.

**How it is calculated:**
```
SUM(NetChange) FROM MonthlyExpenditure
  WHERE UserName = <user> AND FinancialYear = <active FY> AND PeriodID <= <cutoff>
```
grouped by period, then summed. **Net** means credits, reversals and corrections are netted off —
a month with more credits than debits contributes a negative amount.

The "through" label is the **current fiscal month**, not the last month with rows — so it correctly
reads "through JUN, 26" even before June's transactions post.

### Chart 1 — Cumulative Spend vs Budget (burn-up line)

**Two series across the 12 fiscal months (OCT → SEP):**

- **Annual Budget** — a flat dashed line at Total Budget, repeated for all 12 months. Omitted
  entirely if the budget source is unavailable (never drawn at zero).
- **Actual (cumulative)** — a running total of monthly net spend. Months 1..cutoff carry the running
  sum; **months beyond the cutoff are `null`**, so the line stops at the current month rather than
  flat-lining across the rest of the year.

The final point of the Actual line always equals the YTD Expenditure KPI — same source, same window.

If expenditure is unavailable the whole Actual series is blanked to nulls, so an outage can never be
misread as genuine zero spend. A genuinely new fiscal year with no transactions yet still shows a
legitimate cumulative 0, because the source *is* available.

### Chart 2 — Net Categories (horizontal bar)

**What it shows:** net spend by `MainGroup` (the top level of the reporting line description),
for the active FY up to the cutoff.

**How it is calculated:**
```
SUM(NetChange) GROUP BY MainGroup   (same user / FY / cutoff filter)
```
Then, in PHP:
1. Blank or missing `MainGroup` becomes **"Unclassified"**.
2. The **top 8 by absolute value** are kept — selection is by magnitude, so a large *negative*
   correction is not buried in "Other".
3. Everything else is folded into a single **"Other"** bar.
4. The whole set (Other included) is sorted by signed value, largest first.

Negative bars are legitimate — they are net credits for that category.

### Chart 3 — Monthly Expenditure (bar)

**What it shows:** non-cumulative net spend per fiscal month, October through the current month.

**How it is calculated:** the same per-period `SUM(NetChange)` used by the YTD KPI, padded so a
month with no rows still shows a 0 bar and the x-axis stays even. Only months 1..cutoff are drawn —
future months are not shown at all.

### Dashboard caching note

The budget total and the whole expenditure aggregate are cached for 10 minutes per
(user, fiscal year, cutoff). The dashboard takes no filters, so these are the only dimensions.
Cache keys are stamped with the snapshot version, so the nightly refresh flushes them immediately.

---

## 4. Budget Allocations (`/budget-allocations`)

A filterable list of every **budgeted** account line for one fiscal year.

**Source:** `vw_BudgetAllocation` — a thin projection of `vw_FinanceLedger` filtered to
`Allocation <> 0`. (Accounts with GL or encumbrance activity but no budget exist in the ledger but
are deliberately excluded here: a Budget Allocations page is a list of things that were *budgeted*.)

### Table columns

Year · Cluster · Institution · Responsibility · Department · Account (description) · Account No. · **Total Allocation**

Sorted by Year, Cluster, Institution, Department, Account Number. **25 rows per page.**

### KPI cards

| Card | Calculation |
|---|---|
| **Total Records** | `COUNT(*)` over the **whole filtered set**, before pagination |
| **Total Allocation** | `SUM(TotalAllocation)` over the whole filtered set, before pagination |
| **Largest Allocation** | The single highest `TotalAllocation` row in the filtered set; its account description is the sub-label |

All three respond to the filters. They are computed **before** pagination — a total that only summed
the visible 25 rows would look authoritative and be wrong.

### Filters

Fiscal Year (via the year navigator) · Cluster · Institution · Responsibility · Department · Account.

Two rules worth explaining:

- **Options are scoped to the active fiscal year.** The dropdowns only offer values that actually
  exist in that year, so a selection can never return zero rows by accident.
- **A stale filter is dropped, not applied.** If you switch fiscal years and a previously selected
  department does not exist in the new year, the filter is silently cleared rather than emptying the
  table. Clearing filters keeps the fiscal year.
- Institution options cascade from Cluster, and are keyed on cluster+institution so an institution
  appearing under two clusters survives the cascade.

---

## 5. Monthly Expenditure (`/monthly-expenditure`)

A wide, spreadsheet-style view: **one row per account, twelve months across, plus a YTD total.**

**Source:** `vw_FinanceLedger` directly — the months come pre-pivoted, so the whole page is one
query. The result set is small (scoped to the user's departments), so filter lists, totals and
pagination are all derived in memory from that single query.

### Table layout

| Frozen left | Twelve month columns | Frozen right |
|---|---|---|
| Institution · Department · Account Description + Account No. | OCT '25 … SEP '26 | **YTD** |

- Month values are read straight from the snapshot's month columns (`Oct`…`Sep`) — GL net movement
  for that calendar month.
- **YTD** is the snapshot's `YTDTotal` = the sum of the 12 months. Posted GL only; no encumbrances.
- Months later than the current fiscal month are **muted** as "future".
- Quarter boundaries (Jan, Apr, Jul) are marked with a divider.
- Cells shade by intensity **relative to that row's own peak month** — a table-wide maximum would
  wash out every smaller account.
- 25 rows per page.

### Totals row

Every month column and the YTD column carry a total **computed over the entire filtered set, before
pagination** — not just the visible 25 rows.

### KPI cards

| Card | Calculation |
|---|---|
| **Total YTD Expenditure** | `SUM(YTDTotal)` over the whole filtered set |
| **Highest Spend Month** | The month column with the largest total across the filtered set, labelled e.g. "MAR, 26" |
| **Accounts Reported** | Count of rows (= accounts) in the filtered set |

### Filters

Fiscal Year · Cluster · Institution · Responsibility · Department. Same "valid option in the active
FY only" rule as every other page.

### Keyboard

While the pointer or focus is in the table, the arrow keys **scroll the months** horizontally;
outside it, they **step fiscal years**. Never while a dropdown or text field has focus.

---

## 6. Variance (`/variance`)

The budget-versus-actual view: **allocation against actual spend, per account line.** This is the
page that answers "is this line over its budget, and by how much".

**Source:** `vw_FinanceLedger` directly, one query per request.

### Table layout

| Frozen left | | Twelve months | | | | Frozen right |
|---|---|---|---|---|---|---|
| Institution · Department · Account Description | **Allocation** | OCT … SEP | **Encumbered** | **YTD Expenditure** | **Balance of Allocation** | **Status** |

Column meanings:

| Column | Calculation |
|---|---|
| **Allocation** | The approved budget for that account in that FY (`0040CBudgetsAllocation`) |
| Month columns | Net GL movement per calendar month (same as Monthly Expenditure) |
| **Encumbered** | `Approved + Routing` — the commitment split is combined into one figure for display. Approved = requisitions at `AP`/`PO`; Routing = `RT`/`HD`/`PN` |
| **YTD Expenditure** | `YTDTotal` — posted GL only |
| **Balance of Allocation** | `Allocation − (YTD + Approved + Routing)`, **floored at zero** |
| **Status** | Derived from `Excess` / `AllocationBalance` — see below |

### The Status column — the rule this page exists to show

```
ActualExpenditure = YTD Expenditure + Encumbered
```

| Status | Condition | Label |
|---|---|---|
| **Over** | `Excess ≥ 0.005` (i.e. Actual > Allocation) | "Exceeded by X" |
| **Under** | `AllocationBalance ≥ 0.005` | "X remaining" |
| **Exact** | neither | "Allocation fully spent" |

Half a cent of tolerance decides "fully spent" — comparing rounded money for exact float equality is
unsafe, so a threshold is used.

Exactly one of `Excess` and `AllocationBalance` can be non-zero, because the SQL view computes both
from the same difference and floors each at zero. The classification is done from those two columns
rather than re-doing the arithmetic in PHP, so the rule lives in exactly one place.

### Totals row

Allocation, every month, Encumbered, YTD and Balance are totalled **over the whole filtered set,
before pagination**.

**Balance is summed per line, not derived from the totals.** An account that has overspent
contributes a zero balance; netting its overspend against another account's headroom would
overstate what is actually available. That is why:

```
Total Balance   ≠   Total Allocation − Total YTD − Total Encumbered
```
whenever any line is over. The difference is exactly the total overspend.

### KPI cards

| Card | Calculation |
|---|---|
| **Total Allocation** | `SUM(Allocation)` over the filtered set |
| **YTD Expenditure** | `SUM(YTDTotal)` over the filtered set |
| **Balance of Allocation** | `SUM(AllocationBalance)` — per-line, floored, as above |
| **Lines Over Allocation** | Count of rows with status "over" |

### Filters

Fiscal Year · Cluster · Institution · Department · Account Description · Account Number.

Choosing a specific account number clears the broader description filter (the number implies the
description); choosing a description narrows the account-number list.

---

## 7. Login and Profile

### Login (`/login`)

- Credentials are validated against **`SWRHAExpenseControl.dbo.vw_WebAppUsers`** — a separate SQL
  Server database from the financial data. Exactly **one** directory lookup per attempt.
- Rate limited to **5 attempts per minute** per username + IP.
- An **inactive account is not a credential failure**: the user is authenticated, then immediately
  logged out with "Your account has been deactivated." A wrong password gives the generic failure.
- The display name comes from `EmployeeName`, falling back to `UserName` when it is blank.
- There is **no registration, forgotten-password link or 2FA**. Accounts are managed by the
  **Finance department**, in the external staff directory rather than in this portal. Staff who
  have forgotten their password still have to ask Finance to reset it. Someone who *knows* their
  password can now change it themselves, on the Profile page.
- Active status is re-verified against SQL Server **every 60 seconds** while browsing, so an account
  deactivated by the Finance department loses access within about a minute. A SQL Server
  outage during re-verification never deactivates anyone.

### Profile (`/profile`)

Shows the authenticated user's name, username and employee ID as mirrored locally at login. **Those
three are read-only** — the source system owns them, and anything typed over them would be
overwritten at the next sign-in.

### Changing your password (`/profile`)

The Profile page has a **Change Password** button, under Account Status on the right. It opens a
small window that asks for your current password, the new one, and the new one again, and writes
straight to the staff directory the portal signs you in against. Press Escape, click outside it, or
use Cancel to close it without changing anything.

- **You must know your current password.** This is a change, not a reset. If you have forgotten it,
  the Finance department still has to reset it for you.
- **The new password must be 6 to 64 characters**, and may only contain letters, numbers, spaces and
  ordinary keyboard symbols. Accented and non-English characters are refused *on purpose*: the
  account system cannot store them, and a password it cannot store is one you could never sign in
  with again.
- **It changes the password for every SWRHA application that uses the same account**, not just the
  Finance Portal. The portal does not own this directory; it shares it.
- **You stay signed in on this computer. You are signed out everywhere else** — if you ticked
  "Remember me" on another machine, that machine will ask for the new password. This is deliberate:
  if the reason for the change is that someone else learned the old password, leaving those
  sessions alive would defeat the point.
- The change is recorded against your name, with the date and time, in the directory's own audit
  columns. **The password itself is never written to any log.**
- If the button is not on the page, self-service changes have not been switched on yet — ask the
  Finance department.
- Six attempts a minute are allowed. That is there to stop someone guessing at the current-password
  box from a computer you left unlocked.

---

## 8. Frequently asked questions

**"The Total Budget is far too low."**
The portal covers **goods and services only** — the 41 reporting-line-3 account codes. Payroll,
overtime and benefits are excluded by design.

**"User X can log in but sees nothing anywhere."**
Almost always a missing access mapping, not a fault. Their `PositionID` has no active row in
`0006CWebAppPostControls`. Diagnose with:
```sql
SELECT UserName, COUNT(*) FROM dbo.vw_WebAppUserAccess GROUP BY UserName;
```
Note that `0006BWebAppDepartmentControls` is **not read by anything** — a row there grants nothing.

**"I was just granted access but still see nothing."**
The department join is live and takes effect within about a minute, but the cached filter dropdown
lists can linger up to 10 minutes. `php artisan cache:clear file` to see it at once.

**"Budget Usage on the Dashboard doesn't match the Balance on Variance."**
Correct, and intentional. The Dashboard measures usage across the whole allocation; Variance
measures it **line by line** and floors each line at zero, so overspend on one account never nets
off headroom on another (it is reported separately as Excess). Both measure balance against
**posted GL spend alone** — since 2026-08-25, `Approved` is displayed and counted into the reported
actual but does not reduce the balance, and `Routing` reduces nothing at all.

**"Why does one page's fiscal-year list go back further than another's?"**
Budget Allocations only has FY2025 onward (the source allocation table has nothing earlier); the
ledger behind Monthly Expenditure and Variance goes back to FY2014. Source data, not a filter bug.

**"How fresh are the numbers?"**
As of the last successful nightly refresh (SQL Agent, 21:30). Permissions are live.
Check freshness with `php artisan ledger:status` — it exits non-zero when the snapshot is stale.

**"A month shows a negative figure."**
`NetChange` is net of credits, reversals and corrections. A month with more credits than debits is
legitimately negative, and the charts show it rather than hiding it.

**"The page says the data source is unavailable — has money been lost?"**
No. On any query failure the pages render an **empty** table with a warning rather than showing
TTD 0, precisely so an outage can never be mistaken for a real answer.
