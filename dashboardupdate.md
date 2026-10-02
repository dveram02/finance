# Dashboard Fiscal-Year Navigation

*Revision 6. Changes from r5 are marked **[r6]**; earlier additions keep their **[r2]**–**[r5]** marks. r6 changes only how the work is verified — no implementation step changed.*

> **SUPERSEDED IN PART — 2026-10-02. This is a historical plan; do not implement from it.**
> Two of its deliverables no longer exist:
>
> - **§3's `composables/useFiscalYearNav.js` was DELETED**, and with it every arrow-key fiscal-year
>   step in the app (`useTableScroll`'s `onPrevYear`/`onNextYear` went at the same time). The year
>   is changed only from the hero's stepper and rail, or a Filters card select. Steps 203, 246 and
>   255 below describe wiring that is gone.
> - **The page names in §Context are stale.** `Department Expenditure` and
>   `Allocation Line Expenditure` were renamed to `Monthly Expenditure` and `Variance` in
>   `1cc2a87`, and the old per-period `Monthly Expenditure` page was deleted. There are **six**
>   ledger-backed pages now, not five.
>
> What DID survive is the part this plan existed for: the Dashboard honours `?fy=`, renders the
> shared `FiscalYearHero`, and the FY navigator stopped existing in four copies.
> `CLAUDE.md` is the authority.

## Context

There are **five** ledger-backed pages. Four of them navigate fiscal years: `Budget/All Budget Allocations.vue`, `Expenditure/Monthly Expenditure.vue`, `Expenditure/Department Expenditure.vue` and `Expenditure/Allocation Line Expenditure.vue` all receive `years` / `activeFiscalYear` / `currentFiscalYear` / `fyNav`, render a gold FY stepper + year rail, honour `?fy=`, and step years with ← →.

The Dashboard does not. Its metrics are computed for exactly one fiscal year — `budgetTotal()` sums `vw_BudgetAllocation` for one FY, `expenditureData()` reads `dbo.MonthlyExpenditure` for one FY up to `resolveCutoff($fy)`, and the burn-up axis is `fiscalMonthLabels($fy)` — but `DashboardController::budgetTotal()` line 133 calls `resolveFiscalYear(null, ...)`, hard-coding "no year was requested". The `?fy=` query string is silently ignored, and `Dashboard.vue` renders `fiscalYear` as static text (line 394). The result is a page whose data is year-scoped but whose UI pretends it is current-only.

Outcome: the Dashboard becomes FY-navigable and correct in all three FY states (past, current, future), the FY navigator stops existing in four copies, and malformed `?fy=` input — of any shape, including arrays — stops being accepted on any of the five pages.

### The duplication this change retires

`Components/FiscalYearHero.vue` and `Components/LedgerLoadingOverlay.vue` exist, but only the two wide Expenditure pages import them:

| Page | FY hero | Arrow keys | Loading overlay |
|---|---|---|---|
| Department Expenditure | component | `useLedgerTable` | component |
| Allocation Line Expenditure | component | `useLedgerTable` | component |
| **Budget Allocations** | inline, lines 192–279 | own `handleKeydown`, 103–114 | inline, 418–434 |
| **Monthly Expenditure** | inline, lines 196–283 | own `handleKeydown`, 107–118 | inline, 437–450 + ~110 lines of CSS, 541–650 |
| **Dashboard** | — | — | — |

Monthly Expenditure's inline overlay is byte-identical to `LedgerLoadingOverlay` apart from `z-20` vs `z-40`, and the component's default `label` is already `'Loading expenditure'` — a literal drop-in. Monthly has no `useLedgerTable` (it renders a normal paginated table, not a wide ledger table), so it is a genuine consumer of the new arrow-key composable rather than an awkward fit.

### Corrections folded in

1. **The outage path would silently jump the year.** `budgetTotal()`'s `catch` returns `fiscalYear => $currentFiscalYear`, so a SQL blip while reading FY2025 throws the user to FY2026 unannounced.
2. **The `$years->isEmpty()` early return (line 124) exits before any nav data exists.** The return shape must carry `years` and `fyNav` on *every* path.
3. **"YTD Expenditure … through SEP, 25" is wrong copy for a completed year.**
4. **No loading feedback** on an FY switch, unlike the ledger pages.
5. **Arrow-key stepping would become a third copy** — extract it instead.
6. **[r2] Monthly Expenditure was omitted from the cleanup.** Now in scope.
7. **[r2] The dashboard overlay was scoped to the chart grid only.** Changing FY also changes all three KPI cards; a chart-only overlay leaves stale money figures legible mid-request.
8. **[r2] `FiscalYearHero` never re-centres its year rail.** `onMounted(scrollActiveIntoView)` (line 50) is the only call, and every page navigates with `preserveState: true` — the flag that tells Inertia to *reuse* the mounted instance. Pre-existing bug, invisible on Budget (2 chips), visible on Department Expenditure (~13).
9. **[r3] Malformed `?fy=` is accepted on the SUCCESS path, not just the outage path — and r2 got this wrong.** r2 added a regex only to the outage helper while asserting in a test that `?fy=2025abc` must not resolve to 2025. It would have. `ResolvesFiscalYear::resolveFiscalYear()` lines 84–88 read:

   ```php
   $available = $years->map(fn ($y) => (int) $y);
   if ($requested !== null && $available->contains((int) $requested)) {
       return (int) $requested;
   }
   ```

   `(int) '2025abc'` is `2025`, which *is* in `$available`, so it is returned. **This affects all four existing FY pages today, not just the Dashboard.** Fix is §1a below.
10. **[r4] `?fy[]=x` becomes a hard 500 on the Dashboard — a regression this design would have introduced.** r3 noted array input as a pre-existing edge and deferred it. That was wrong, because the Dashboard's call shape is not the same as the other four pages':

    | | Where `try` sits | Array input does |
    |---|---|---|
    | The four existing pages | `resolveFiscalYear($request->input('fy'), …)` is called **inside** the controller's `try` | `TypeError` → caught → "source unavailable" (wrong copy, but the page renders) |
    | **Dashboard as designed in r3** | `index()` calls `budgetTotal($username, $request->input('fy'))`; the `try` is **inside** `budgetTotal()` | `TypeError` at the parameter boundary, **before** the try, in an `index()` with no catch → **uncaught → 500** |

    PHP's coercive mode never converts an array to a string, so this is a certainty, not a maybe. Fixed in §1a along with the scalar case.
11. **[r4] `usageSubLabel` has no future-FY branch.** r3 claimed `usageSubLabel`, `expenditureChartState` and `burnupState` were all already correct for a future FY. Only the last two are. For a future FY the guards in `Dashboard.vue:89–96` all pass — `hasAccess` ✓, `budgetAvailable` ✓, `expenditureAvailable` ✓ (the query *succeeded*; there are simply no rows at or below period 0), `totalExpenditure` is `0` so not `< 0`, `overBudget` false — and it falls through to **"TTD X remaining"** while the two charts beside it read "Fiscal year has not started".
12. **[r4] The YTD card shows a fake zero for a not-started year.** Same root cause, missed by every review so far: `expenditureAvailable` is `true` for a future FY, so the card renders **"TTD 0.00"** under the heading "YTD Expenditure". That is exactly the fake zero `CLAUDE.md` prohibits ("an outage that shows '$0 spend' is a bug" — a year that has not begun is the same claim). Fixed in §4.
13. **[r5] The same card shows a fake zero for a no-access user — and this one is live today, not a consequence of this change.** The branch order at `Dashboard.vue:401–412` is `v-if="expenditureAvailable"` → `v-else-if="!hasAccess"` → `v-else`. A user with no department mapping does not make that query *fail*; `vw_WebAppUserAccess` is joined live, so it **succeeds and returns zero rows** → `expenditureAvailable === true` → the money branch wins and prints **"TTD 0.00"**. The `!hasAccess` branch beneath it is unreachable whenever the query succeeds, i.e. always in this scenario. Per `CLAUDE.md` (measured 2026-08-06) only PositionID 10108 / FFIGUERA1 is mapped, so **every other user who logs in sees a fabricated TTD 0.00 on the dashboard today.**

    Worth recording because it explains why only one card is affected: **the Total Budget card (342–353) has the identical branch order but is correct by accident.** `budgetTotal()` returns `available => false` on the empty-years path, so a no-access user falls through to "Not assigned". The expenditure card has no equivalent guard, because there "zero rows" is a legitimate result rather than a signal. Fixed — and made explicit on both cards — in §4.

### Decisions taken

- **Year scope = budget years only** (`vw_BudgetAllocation`, FY2025+). The Dashboard is a budget-vs-actual page; a year with expenditure but no allocation baseline gives a burn-up chart with no budget line and two dead KPI cards. It also preserves the deliberate cache-key sharing documented in `CLAUDE.md` — the Dashboard reuses the exact `budget-allocations:years:{username}` key the Budget page writes, so FY navigation costs **zero** additional queries. FY2014–2024 expenditure history stays reachable from Monthly Expenditure.
- ~~**[r2] The Dashboard gets a *compact* FY control, not a second hero band**~~ — **[BUILT: reverted]** A `variant="compact"` prop was implemented, but the row layout did not render acceptably in place. The Dashboard now uses the **standard `FiscalYearHero` band**, identical to Budget Allocations and the two Expenditure pages, sitting directly below the welcome header. The `variant` prop and its layout computeds were removed rather than left in as an unused code path — an untried branch in a shared component is exactly the drift risk this component exists to prevent. `FiscalYearHero`'s net diff is now only the rail-scroll fix.
- **All four duplicating pages converge on the shared components** in this change.

---

## Changes

### 1a. **[r3]** `app/Concerns/ResolvesFiscalYear.php` — reject malformed requested years

**[r4]** Widen the parameter to `mixed` and gate on `is_string()`, which handles the scalar and the array case in one edit:

```php
/**
 * Pick the fiscal year to display: the requested one if it has data,
 * otherwise the current FY if present, otherwise the latest FY with data.
 *
 * $requested is raw request input, so it is typed mixed deliberately: it may
 * be a string, null, or — from `?fy[]=x` — an array. Anything that is not a
 * four-digit string is not a fiscal year, and falls through to the default.
 */
protected function resolveFiscalYear(mixed $requested, $years, int $currentFiscalYear): ?int
{
    // …
    if (is_string($requested)
        && preg_match('/^\d{4}$/', $requested)
        && $available->contains((int) $requested)) {
        return (int) $requested;
    }
    // …
}
```

**Why inside the trait rather than a sanitizer called from each controller:** one edit fixes all five pages with zero call-site changes, and there is no way for a future page to forget to call it. A call-site sanitizer needs four extra controller edits now — in files this change would otherwise not touch — plus perfect discipline forever, which is the same discipline that produced four copies of the hero. Widening a parameter type is LSP-safe; the input genuinely *is* mixed, and typing it `?string` is what let the array case through in the first place.

The regex is the point, not the range: `(int) 'notayear'` is already safe (it yields `0`, never in `$available`); `(int) '2025abc'` is `2025` and is not. **[r4]** `is_string()` is what stops `?fy[]=2025` from throwing.

Behavioural delta is confined to input that is currently mis-parsed or fatal. `''` and `'notayear'` already fell through to the current-FY branch and still do; `'2025abc'` and `'2025.0'` now fall through instead of resolving to 2025; an array now falls through instead of throwing.

**[r4]** With this in place, the claim "malformed `?fy=` input stops being accepted anywhere" holds for **all** input shapes and needs no narrowing — that is why the trait fix is preferred to per-call-site normalization, which would leave the four other pages' behaviour depending on four separate edits.

### 1b. `app/Http/Controllers/DashboardController.php`

**[r4] Both new signatures take `mixed`, not `?string`** — `budgetTotal(string $username, mixed $requestedFy)` and `fallbackFiscalYear(mixed $requested, int $currentFiscalYear)`. This is the actual fix for the 500 in correction 10: the `TypeError` fires at `budgetTotal()`'s parameter boundary, outside its own `try`, so no amount of hardening *inside* the method helps. Both bodies guard with `is_string()` before touching the value. `index()` therefore passes `$request->input('fy')` through unchanged, exactly as the other four controllers do.

**`budgetTotal(string $username, mixed $requestedFy)`** — accept the requested year, return the full nav shape on all three paths:

```php
@return array{fiscalYear:int, years:array, fyNav:array{prev:?int,next:?int},
              totalBudget:float, available:bool}
```

- Success path: `$activeFiscalYear = $this->resolveFiscalYear($requestedFy, $years, $currentFiscalYear);` (replacing the `null` at line 133), plus `$fyNav = $this->fiscalYearNav($activeFiscalYear, $years);`. The `dashboard:budget-total:{user}:{fy}` cache key is already FY-dimensioned — no key change.
- Empty-years path (line 124): `years => []`, `fyNav => ['prev' => null, 'next' => null]`, `fiscalYear => $currentFiscalYear`, `available => false`. Same semantics, fuller shape.
- `catch` path: same empty nav shape, `fiscalYear` from a new private `fallbackFiscalYear(mixed $requested, int $currentFiscalYear): int` — `is_string()` **[r4]** and `preg_match('/^\d{4}$/', ...)` first, then accept only `2000 .. $currentFiscalYear + 1`, else current FY. **[r3]** This stays even with §1a in place: §1a guards the *year list* lookup, but on the outage path there is no list to check against, so the helper needs its own gate. Keeping the control on the requested year during an outage mirrors `BudgetAllocationController.php:195`.
- Change the existing `Log::error` to report `'fy' => $requested` rather than `$currentFiscalYear`, so the log names the year that actually failed.

**`index()`** — pass `$request->input('fy')` into `budgetTotal()` and add four props:

```php
'years'             => $budget['years'],
'activeFiscalYear'  => $fiscalYear,
'currentFiscalYear' => $this->currentFiscalYear(),
'fyNav'             => $budget['fyNav'],
```

Keep `fiscalYear` as-is — `Dashboard.vue:394` binds it and `LedgerAccessStateTest` exercises the page. `activeFiscalYear` is the name `FiscalYearHero` and every sibling page expect. Same value; the alias is what lets the control drop in with no prop mapping.

`expenditureData()`, `budgetVsActualData()`, `hasLedgerAccess()` and everything in `DashboardDataTransforms` need **no change** — they already take `$fiscalYear`/`$cutoff` as parameters, and `dashboard:expenditure:{user}:{fy}:{cutoff}` is already FY-dimensioned.

### 2. `resources/js/Components/FiscalYearHero.vue` — two fixes

**[r2] a. Re-centre the rail when the active year changes.** **[r3]** Import `watch`, drop the now-unused `onUnmounted` from the import and delete the no-op `onUnmounted(() => {})` on line 51. Give the helper a behaviour argument so the first paint does not animate:

```js
const scrollActiveIntoView = (behavior = 'smooth') => {
    nextTick(() => {
        const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
        const el = yearRail.value?.querySelector('[data-active="true"]')
        el?.scrollIntoView({ inline: 'center', block: 'nearest',
                             behavior: reduceMotion ? 'auto' : behavior })
    })
}

onMounted(() => scrollActiveIntoView('auto'))   // jump on first paint
watch(activeYearStr, () => scrollActiveIntoView())
```

`'auto'` on mount avoids a visible scroll animation as the page appears; the `prefers-reduced-motion` guard matches what `useLedgerTable.scrollMonths()` already does. Held arrow keys retarget an in-flight smooth scroll rather than queueing — acceptable, and worth an eyeball during verification (step 6). Keep `defineExpose`.

**[r2] b. ~~Add `variant`~~ — [BUILT: dropped].** The compact variant was implemented and removed; see Decisions. All four pages now render the single existing layout, and this is the component's only change.

<details><summary>Original spec, kept for the record</summary>

**Add `variant: { type: String, default: 'hero' }`** accepting `'hero'` | `'compact'`.

- `'hero'` — today's markup, byte-for-byte. Existing call sites pass nothing and are unaffected.
- `'compact'` — drops the `<section>` chrome (no gradient wash, dot texture, gold filament, glow, border or shadow) and lays the same three pieces out in a row:

```
FISCAL YEAR  ● Current
    ‹  2026  ›   Oct 2025 – Sep 2026    [2025] [2026]
```

Concretely: outer element becomes `<div class="flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-5">`; the numeral drops `text-5xl` → `text-3xl` and the `min-w-[7rem] sm:min-w-[9rem]` reservation; the year span moves inline beside the numeral; the rail loses `mt-3` and switches `justify-center` → `sm:justify-start`. **Every colour, ring, gradient, transition name and `data-active` binding stays shared** — bind the variant-dependent classes through a small `computed`, never by forking the template into two independent trees, or the two will drift exactly as the four pages did. The `.fy-*` and `.year-rail` scoped styles need no change.

</details>

### 3. New `resources/js/composables/useFiscalYearNav.js`

```js
export function useFiscalYearNav({ fyNav, goToFy }) { … }
```

Body is `All Budget Allocations.vue:103–114` moved verbatim — bail on `SELECT`/`INPUT`/`TEXTAREA` via `document.activeElement.tagName`, `ArrowLeft` → `fyNav().prev`, `ArrowRight` → `fyNav().next`, `preventDefault()` only when a step actually happens. `window` listener bound in `onMounted`, removed in `onUnmounted`. Accessors are functions (`fyNav()`) to match the `useLedgerTable` convention.

**[r2]** Three consumers: Dashboard, Budget Allocations, Monthly Expenditure. Do **not** touch `useLedgerTable.js` — it already delegates via `onPrevYear`/`onNextYear`, the correct seam for the two wide tables where arrows are context-sensitive.

### 4. `resources/js/Pages/Dashboard.vue`

**[r3] Exact import changes.** The file currently has only `import { computed } from 'vue'` (line 2) and `import { Head } from '@inertiajs/vue3'` (line 3):

```js
import { computed, ref, onMounted, onUnmounted } from 'vue'
import { Head, router } from '@inertiajs/vue3'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import { useFiscalYearNav } from '@/composables/useFiscalYearNav'
```

`onMounted`/`onUnmounted` are for the `router.on` subscriptions only — the keydown listener lives inside the composable.

- Add props: `years: { type: Array, default: () => [] }`, `activeFiscalYear: [Number, String]`, `currentFiscalYear: [Number, String]`, `fyNav: { type: Object, default: () => ({ prev: null, next: null }) }`.
- **[BUILT]** Render `<FiscalYearHero … @select="goToFy" />` as a **sibling directly below the welcome band**, before `<NoAccessNotice>` — the same placement and the same full band as the other four pages. (r2 called for a compact control nested inside the welcome header; it did not render acceptably and was reverted, taking the `variant` prop with it.)
- `goToFy(fy)`:
  ```js
  const goToFy = (fy) => router.get(route('dashboard'), { fy: String(fy) },
      { preserveState: true, preserveScroll: true, replace: true })
  ```
  Same three options as every sibling page; `preserveState` keeps the Chart.js instances alive across the swap.
- Wire `useFiscalYearNav({ fyNav: () => props.fyNav, goToFy })`.
- **[r2] Loading feedback covering the whole data region.** A `loading` ref driven by `router.on('start')` / `router.on('finish')` (pattern at `Monthly Expenditure.vue:125–144`, filtering the visit URL on `dashboard`), with `<LedgerLoadingOverlay :show="loading" label="Loading dashboard" />` inside a **single `relative` wrapper enclosing both the KPI grid (line 325) and the chart grid (line 419)** — not the charts alone. All three KPI cards are FY-scoped money figures; veiling the charts while leaving stale TTD totals legible is the worse failure. Give the wrapper `class="relative space-y-5"` so inter-section spacing is unchanged.
- **Copy fixes — three FY states, not two.** Navigation makes past *and* future years reachable for the first time, and the existing copy only ever assumed "current".

  Add `const isPastFy = computed(() => Number(props.activeFiscalYear) < Number(props.currentFiscalYear))`.

  **a. The expenditure KPI card (392–395, 401–412).** **[r5]** This card has to answer two independent questions — *can we show a number at all?* and *what is that number called?* — and r4 conflated them. Separate them.

  **First, the value branch, as an ordered priority chain.** The current template is `v-if="expenditureAvailable"` → `v-else-if="!hasAccess"` → `v-else`, which puts the money branch first and makes everything under it unreachable whenever the query succeeds. Invert it so the *narrowest* condition wins:

  | # | Condition | Renders |
  |---|---|---|
  | 1 | `!hasAccess` | `Not assigned` + "Department access is not configured." |
  | 2 | `!expenditureAvailable` | `Expenditure unavailable` + "Financial data source could not be reached." |
  | 3 | `!expenditureWindowStarted` | `Not started` + "This fiscal year has not begun." |
  | 4 | otherwise | `TTD` + the figure |

  Branches 1–3 reuse the existing `text-base font-semibold text-tx-muted` styling already present at 406 and 410, so only the ordering and one new branch are new.

  **Why `!hasAccess` can safely go first** — the ordering question this raises is whether a no-access test could mask an outage. It cannot: `DashboardController::hasLedgerAccess()` hard-codes `true` when the probe throws, precisely so an outage is never reported as a permissions problem (`CLAUDE.md`). So `!hasAccess` is only ever true when the probe **succeeded and said no**, which is strictly more specific than branch 2. Keeping outage (2) ahead of not-started (3) follows the same logic: if the source is down we do not know whether the year has data, and "unavailable" is the honest answer.

  **Second, the label, which is purely about which FY is shown:**

  | FY | Title | Sub-label |
  |---|---|---|
  | past | `Total Expenditure` | `FY {{ fiscalYear }} · full year` |
  | current | `YTD Expenditure` | `FY {{ fiscalYear }} · through {{ latestPeriodLabel }}` |
  | future | `Expenditure` | `FY {{ fiscalYear }} · fiscal year has not started` |

  **[r5]** When `!hasAccess`, drop the `· through …` clause from the sub-label (393–395) and show `FY {{ fiscalYear }}` alone — there is no expenditure window to be "through" for someone with no mapping.

  **[r5] Apply the same explicit ordering to the Total Budget card (342–353).** It is not currently broken — `budgetTotal()`'s empty-years path returns `available => false`, which routes a no-access user to "Not assigned" — but it is correct only as a side effect of that guard. Reordering it to `!hasAccess` → `!budgetAvailable` → money costs nothing and stops a future change to the empty-years branch from silently turning it into the same fake zero. Defensive, not a bug fix; call it out as such in the commit so it is not mistaken for one.

  **b. [r4] `usageSubLabel` (89–96).** Insert `if (!props.expenditureWindowStarted) return 'Fiscal year has not started'` immediately after the three availability checks and before the `totalExpenditure < 0` branch. Without it, a future FY with loaded budget rows reads **"TTD X remaining"** beside two charts that say "Fiscal year has not started" — see correction 11. Leave `usageAvailable` alone: `0%` under that sub-label is honest and more informative than the `—` the unavailable path shows.

  **c.** Leave `expenditureChartState` and `burnupState` untouched — they already branch on `!expenditureWindowStarted` and their copy is correct.

### 5. `resources/js/Pages/Budget/All Budget Allocations.vue` — consistency cleanup

Pure refactor, no behaviour change:

- Replace the inline hero (192–279) with `<FiscalYearHero … @select="goToFy" />` (default `hero` variant).
- Delete the now-dead `activeYearStr`, `isCurrentFiscalYear`, `fiscalYearSpan`, `yearRail`, `scrollActiveIntoView` and the `.fy-*` / `.year-rail` scoped styles.
- Replace its bespoke `handleKeydown` + `onMounted`/`onUnmounted` registration (103–114, 124–143) with `useFiscalYearNav`.
- Replace the inline loading overlay (418–434) with `<LedgerLoadingOverlay :show="loading" label="Loading allocations" />` and delete the corresponding coin/dots/overlay CSS.

### 6. **[r2]** `resources/js/Pages/Expenditure/Monthly Expenditure.vue` — same cleanup

Identical in kind to §5, larger in volume:

- Replace the inline hero (196–283) with `<FiscalYearHero … @select="goToFy" />`.
- Delete `activeYearStr` (39), `isCurrentFiscalYear` (41–43), `fiscalYearSpan` (46–50), `yearRail` + `scrollActiveIntoView` (97–104). `goToFy` (52–57) **stays** — it sets `filters.value.fy` then calls `applyFilters()`, which the component cannot do. Its two guard clauses can go, since the component already guards.
- Replace `handleKeydown` (107–118) with `useFiscalYearNav`; keep the `router.on('start'/'finish')` block in `onMounted` exactly as it is (121–144) — only the `keydown` listener and the `scrollActiveIntoView()` call come out.
- Replace the inline overlay (437–450) with `<LedgerLoadingOverlay :show="loading" />` — **the default label is already `'Loading expenditure'`, so pass none.** Only behavioural delta is `z-20` → `z-40`, which is strictly safer.
- Delete the whole `<style scoped>` block from `.fy-enter-active` through the `prefers-reduced-motion` rule (541–650). Verify nothing else on the page uses `.coin`, `.loading-dots` or `.overlay-*` first.

### 7. Tests

**[r3] a. `tests/Unit/DashboardTransformsTest.php` — malformed-FY regression, offline.**
This is the right home for §1a: it is the only fully-offline suite (per `CLAUDE.md`), and it tests the regression directly rather than through HTTP. The anonymous harness at lines 25–59 already `use`s `ResolvesFiscalYear`; add one accessor:

```php
public function resolve(mixed $requested, $years, int $current): ?int
{
    return $this->resolveFiscalYear($requested, $years, $current);
}
```

Cases against `collect(['2025', '2026'])` with current FY 2026: `'2025'` → 2025; `'2025abc'` → **2026, not 2025**; `'2025.0'` → 2026; `'notayear'` → 2026; `''` → 2026; `null` → 2026; `'1999'` (valid format, absent from list) → 2026. **[r4]** Plus the non-string shapes, which must *return* rather than throw: `['2025']` → 2026; `2025` (int) → 2026. Plus the latest-FY fallback: current 2027 not in list → 2026.

**[r3] b. New `tests/Feature/Concerns/UsesBudgetData.php`.**
`UsesLedgerData` resolves its username from `vw_FinanceLedger`, but the Dashboard's year list comes from `vw_BudgetAllocation`, which filters `Allocation <> 0` — a strict subset. A ledger user with no allocation rows yields an empty `years` and turns every FY assertion into a silent no-op, which PHPUnit reports as *risky*, not failing. Mirror `UsesLedgerData` exactly, but select a `UserName` that has at least one distinct `FinancialYear` in `vw_BudgetAllocation`, and `markTestSkipped()` on both an unreachable server and an empty result.

**c. New `tests/Feature/DashboardFiscalYearTest.php`** — `RefreshDatabase` + `UsesBudgetData`, `withoutMiddleware(EnsureUserIsActive::class)`.

- Prop contract: component `Dashboard`, `has('years')`, `has('activeFiscalYear')`, `has('currentFiscalYear')`, `has('fyNav')`, and `fiscalYear === activeFiscalYear`.
- `?fy=<a year present in props.years>` is honoured. Guard the premise: `markTestSkipped` if the user has fewer than two budget years.
- `?fy=1999` falls back to a year that *is* in the list.
- `fyNav.prev` null at the earliest year, `fyNav.next` null at the latest.
- A past FY reports `expenditureWindowStarted === true` and a `latestPeriodLabel` starting `SEP` (cutoff 12). Guard on a completed FY existing.
- **[r2]** `years` on `/dashboard` equals `years` on `/budget-allocations` for the same user — the explicit "budget years only" decision, and the only thing that will catch a future change quietly re-pointing it at `vw_FinanceLedger`.
- **[r3]** The `?fy=2025abc` case moves to §7a, where it runs offline and asserts the actual mechanism. Keep one HTTP-level smoke assertion here so the wiring is covered end to end — **[r6]** but assert it against the *no-`fy` baseline*, never against a literal year:

  ```php
  $props = fn (array $query = []) => $this->actingAs($user)
      ->get('/dashboard'.($query ? '?'.http_build_query($query) : ''))
      ->viewData('page')['props'];

  $this->assertSame($props()['activeFiscalYear'], $props(['fy' => '2025abc'])['activeFiscalYear']);
  ```

  A literal `assertNotSame(2025, …)` is wrong for the same reason as verification step 7: for a user whose budget years stop at FY2025, 2025 *is* the correct fallback, and the assertion would fail on correct behaviour. The unit cases in §7a keep their literal expectations — they construct `collect(['2025', '2026'])` themselves, so the default is known rather than data-dependent. Apply the same baseline shape to the `?fy=1999` case.
- **[r4] `/dashboard?fy[]=2025` must return 200**, with `activeFiscalYear` present in `years`, and **`assertSessionMissing('warning')`** — malformed input is not an outage, and the warning flash is what would prove the request had fallen into the `catch`. This is the direct regression test for correction 10; without §1a and the `mixed` signatures it is a 500.

**[r5] d. `tests/Feature/LedgerAccessStateTest.php` — pin the prop combination behind correction 13.**
The bad rendering is Vue-side and not assertable from PHPUnit, but the *prop combination* that causes it is. For a user with no mapping, assert that `/dashboard` returns **`hasAccess === false` while `expenditureAvailable === true`**. That is the exact pairing the template must not render as money, and writing it down stops a future reader concluding that "no access" implies "unavailable" and re-simplifying the branch chain back to the broken order. The file already has a no-access user and a `/dashboard` case, so this is one added assertion, not a new test class.

The rest of `LedgerAccessStateTest` is unaffected — the new props are additive.

---

## Verification

1. `./vendor/bin/pint app/Http/Controllers/DashboardController.php app/Concerns/ResolvesFiscalYear.php` — **only** the changed files (`CLAUDE.md`: a broad run reformats ~nine unrelated files).
2. `php artisan test --filter=DashboardTransformsTest` first — it is offline, so it must pass everywhere, and it is what proves §1a.
3. Then `--filter=DashboardFiscalYearTest`, `--filter=LedgerAccessStateTest`, `--filter=DepartmentExpenditureTest`, `--filter=AllocationLineExpenditureTest`. **[r3]** The last two matter more than usual now: §1a touches a trait all four FY pages share. Expect skips, not failures, when SQL Server is unreachable.
4. `npm run build` — four page rewrites fail at compile time if at all.
5. `php artisan cache:clear file` (budget/ledger caches are on the `file` store, not the default), then `composer dev` and sign in as **FFIGUERA1** — per `CLAUDE.md` (measured 2026-08-06) the only user with an active access mapping; any other account renders empty pages by design.
6. Manual checks on `/dashboard`:
   - **[BUILT]** The FY band sits directly below the welcome header and is indistinguishable from the one on `/monthly-expenditure` viewed side by side, in **both** light and dark mode — it is now literally the same component with no variant.
   - Clicking FY2025 sets `?fy=2025` and moves every figure together — Total Budget, Budget Usage, Total Expenditure, all three charts.
   - ← / → step years; inert while a `<select>` has focus; inert at the first/last year. **[r3]** Hold an arrow key down and confirm the rail's retargeting scroll looks acceptable rather than juddering.
   - On FY2025 the third KPI reads **Total Expenditure / full year**, not "YTD … through".
   - The loading veil covers the **KPI cards and the charts** — clear the file cache first to see it on a cold query.
7. **[r3]** Malformed input, on `/dashboard` **and** on `/budget-allocations`, `/monthly-expenditure`, `/department-expenditure`, `/allocation-line-expenditure`, since §1a changes all five. Inputs: `?fy=2025abc`, `?fy=2025.0`, `?fy=notayear`, `?fy=1999`, `?fy=`, **[r4]** and `?fy[]=2025`.

   **[r6] Establish the baseline first, and compare against it — do not assert a literal year.** Load each page with **no** `fy` param and note the FY it settles on; every malformed input must land on **that same year**. An earlier draft of this step said "none may resolve to 2025", which is wrong: `resolveFiscalYear()` falls back to the current FY *if the user has data for it*, otherwise to the latest year they do have. A user whose budget rows stop at FY2025 — ordinary where FY2026 allocations are not loaded yet — has a legitimate default of 2025, and the literal check would flag a correct result as a failure. The bug being hunted is "`2025abc` was *parsed into* 2025", and only the baseline comparison distinguishes that from "2025 is simply this user's default".

   All six inputs must also render normally with **no** "financial data source is unavailable" warning — malformed input is a bad request, not an outage. Check `/dashboard` first: it is the only page that returns a 500 without the fix.
7b. **[r4] Future fiscal year**, if `vw_BudgetAllocation` holds rows for one (today, FY2027). Load `/dashboard?fy=2027` and confirm all four states agree that the year has not started: the expenditure KPI reads **"Not started"**, *not* "TTD 0.00"; Budget Usage shows `0%` with **"Fiscal year has not started"**; and both charts show their existing "Fiscal year has not started" placeholder. If no future budget rows exist, note it as unverifiable rather than assuming it passes.
7c. **[r5] No-access user — the regression test for correction 13, and the easiest one to run.** Sign in as **any user other than FFIGUERA1** (per `CLAUDE.md`, none of them is mapped) and load `/dashboard`. Before the change the expenditure KPI reads "YTD Expenditure · TTD 0.00"; after it, **"Not assigned"** with the "Department access is not configured." sub-line, matching the Total Budget card beside it and the `NoAccessNotice` banner above. Confirm no `warning` flash — this is not an outage. Then re-check the same page as FFIGUERA1 to be sure the money branch still renders for a mapped user.
8. **[r2]** Rail re-scroll: on `/department-expenditure` (~13 chips), pick a year at one end of the rail then use ← several times — the rail should keep the active chip centred, which it does not do today. Confirm no scroll animation on first paint.
9. Outage behaviour. **[r6] `php artisan cache:clear file` immediately before this step, and again between attempts** — otherwise the test can silently pass on cached data and prove nothing. `budgetTotal()` and `expenditureData()` call `$cache->remember(...)` *inside* their `try`, so a warm cache returns without ever touching SQL Server and the `catch` never runs.

   The interaction is subtler than "the cache hides the outage", and worth knowing before you conclude the plan is broken: `ledgerCacheKey()` calls `ledgerVersion()`, which queries `FinanceLedgerRefresh` and falls back to the literal string `'unknown'` when that fails. So once the outage is noticed, **every key's suffix flips from `:v<md5>` to `:vunknown`**, misses, and reaches the real query — which throws, giving the correct outage state. But `ledgerVersion()` is itself cached for `ledger.cache.version_seconds` (60s), so for up to a minute after you break the connection the old suffix is still in play and live-looking figures render. Clearing the cache removes the ambiguity entirely.

   Then: point `SQLSRV_HOST` at an unreachable host, load `/dashboard?fy=2025`, and confirm the control still shows **2025** (not the current FY — this one *is* a literal check, because `fallbackFiscalYear()` echoes the requested year without consulting any list), the cards read "unavailable" rather than TTD 0, and `hasAccess` stays `true`.
10. Regression sweep on `/budget-allocations` and `/monthly-expenditure`: hero renders identically to before, ← / → still work, the loading overlay still appears on a filter change, and no console error about a missing `.coin` / `.loading-dots` style.
