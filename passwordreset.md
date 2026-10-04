# Self-Service Password Change on the Profile Page

**Status:** BUILT 2026-10-03 on `feature/ledger-oversight-update`. **NOT deployed, and the
production GRANT has been neither approved nor applied.** Plan written 2026-10-02.
**Scope:** one new write route, one new service, one new card on `/profile`, one column-level
database `GRANT`, two `CLAUDE.md` rule amendments.

> **§12 "As built" at the foot of this file WINS over everything above it**, by the convention
> every other feature document here follows (`export.md` §11, `financesqlupdatep3.md`). Read it
> first for status; read §12.5 before believing anything is finished.

---

## 1. Context

`GET /profile` is a read-only card today. A user who wants their password changed has to ask the
finance department to edit the source system by hand. This adds self-service: current password +
new password + confirmation, written straight back to the authoritative directory row.

It is a **change**, not a **reset** — the user must prove the existing password first. There is no
forgot-password flow, no email, no token, no admin override, and none is proposed. (The file is
named `passwordreset.md` because that is what was asked for; the feature is a change-password.)

**Passwords stay plaintext.** That is an external constraint: the finance department's source
system owns `UserPassword` and reads it as plaintext. Hashing here would lock every other
application that shares this directory out of these accounts. The existing `hash_equals()`
comparison remains the mitigation, exactly as `CLAUDE.md` already records.

### 1.1 Two standing rules this deliberately overrides

Both are stated as hard rules. Both must be **amended in the same commit**, or a future session
will correctly delete this feature as rule-violating.

| Rule | Where | Amendment |
|---|---|---|
| *"No registration, password reset, or 2FA routes exist … Do not add them."* and *"`GET /profile` is read-only … there is no profile edit form. **Do not add one.**"* | `CLAUDE.md`, Authentication & Users | Carve out exactly one write route, `POST /profile/password`. Everything else stays forbidden. |
| *"On production, only ever write to the objects THIS project created … **Every pre-existing table and view is off limits**, including the `0006*` access-control tables … This is a hard constraint, not a preference."* | `CLAUDE.md`, The Finance Ledger | Record the standing permission this project actually holds: **`UserPassword`, `LastEditedBy`, `DateEdited`, `TimeEdited`** on `dbo.0006AWebAppControls`, for the authenticated user's own row only, keyed on `LineID`. Everything else on every pre-existing table stays read-only. |

🔴 **Those four columns are not an exception this project invented — they are the whole of the
permission it holds** (confirmed 2026-10-03). The pre-existing tables are otherwise untouchable;
what this project may create freely is **new objects of its own**. If a future change appears to
need a fifth column, that is a design error, not a grant to widen.

`CLAUDE.md` is gitignored and **not recoverable from git**. Edit it with the write-then-rename
discipline its own repo-quirks note mandates.

### 1.2 The credential is shared

`0006AWebAppControls` belongs to the SWRHAExpenseControl system, not to this project. A password
changed here changes it for **every application that reads this directory**, not just the Finance
Portal. That is a communications decision, not a code one: users must be told before go-live, and
the form copy must say it.

**The Finance department maintains all three source databases** (`SWRHAExpenseControl`,
`FinanceAutomationSystem`, `ArrearsDatabase`), confirmed 2026-10-03 — so they are the people who
will field "my password stopped working" if this goes wrong, which is why the user comms matter.
Note that administering the schema is **not** what makes the write safe: the risk is to the other
applications reading these tables, and that is unchanged by who administers them. It is the
four-column scope that keeps it safe.

---

## 2. Verified facts

Measured 2026-10-02 against the dev instance, via
`sqlcmd -S tcp:127.0.0.1,1433 -E -C -l 60` (the long login timeout is required — the instance is
slow to answer prelogin and the default 30s times out).

### 2.1 The column that was asked about

> **`SWRHAExpenseControl.dbo.0006AWebAppControls.UserPassword` is `varchar(255) NULL`,
> collation `Latin1_General_CI_AS`.**
> **Maximum 255 characters. Single-byte — no Unicode.**

Surfaced unchanged through `dbo.vw_WebAppUsers` as `varchar(255)`.

### 2.2 Full table shape

`column_id` 3 was dropped at some point; the gap is in the source, not a transcription error.

| # | Column | Type | Null |
|---|---|---|---|
| 1 | `LineID` | `int` IDENTITY, **PRIMARY KEY** | no |
| 2 | `EmployeeID` | `varchar(255)` | yes |
| 4 | `UserName` | `varchar(255)` | yes |
| 5 | **`UserPassword`** | **`varchar(255)`** | yes |
| 6 | `PositionID` | `varchar(255)` | yes |
| 7 | `IsActive` | `varchar(255)` | yes |
| 8 | `CreatedBy` | `varchar(255)` | yes |
| 9 | `DateCreated` | `date` | yes |
| 10 | `TimeCreated` | `time` | yes |
| 11 | `LastEditedBy` | `varchar(255)` | yes |
| 12 | `DateEdited` | `date` | yes |
| 13 | `TimeEdited` | `time` | yes |

### 2.3 Everything else that shaped the design

- 🔴 **No unique index on `UserName`.** The only index is `PK__0006AWeb__…` on `LineID`. Two rows
  could share a username, and under `Latin1_General_CI_AS` `'ffiguera1'` matches `'FFIGUERA1'`.
  *This is already a login hazard*: `SWRHAUserProvider::findSqlServerUser()` does
  `->where('UserName', $username)->first()` with no `ORDER BY`, so two rows means SQL Server
  returns whichever it likes. The new write must **refuse on ambiguity**, not silently pick one.
- **No triggers** on the table — so `$affected` from an `UPDATE` is trustworthy.
- 3 rows: `SBHIM1`, `FFIGUERA1`, `KCHARLES1`. Password lengths 9, 6, 6. `DATALENGTH = LEN` on all
  three (no padding). All three are **printable ASCII** — checked under `Latin1_General_BIN`; the
  same `LIKE '%[^ -~]%'` check under the database's CI_AS collation gives a **false positive**,
  because range predicates follow collation sort order rather than codepoint.
- **`LastEditedBy` / `CreatedBy` hold a human display name, not a username.** Measured values:
  `FRANCIS FIGUERA`, `MERNELL SPENCER`. And `vw_WebAppUsers.EmployeeName` for these users is
  `FRANCIS FIGUERA` / `KEN CHARLES` / `SHAMEAD SHIVA BHIM` — the **same convention, same casing**.
  So the audit stamp writes `EmployeeName`, which is already mirrored into `users.name` by
  `SWRHAUserProvider::resolveDisplayName()`. One existing row has a blank `LastEditedBy`.
- `TimeEdited` values are stored at whole-minute precision (`10:52:00`) by whatever writes them
  today. The column is `time` (= `time(7)`).
- `dbo.vw_WebAppUsers` = `SELECT A.EmployeeID, B.EmployeeName, A.UserName, A.UserPassword,
  A.PositionID, A.IsActive FROM 0006AWebAppControls A LEFT JOIN ArrearsDatabase.dbo.0002AEmployees B`.
  **It does not expose the audit columns**, so the write must target the base table.
- 🔴 **The SQL login `finance` is in `db_datareader` only.** There are *no* object-level
  permissions on `0006AWebAppControls` for any principal. A `GRANT` is mandatory — see §8.
- `IsActive` stores the literal strings `'TRUE'` / `'FALSE'`, and `(bool) 'FALSE'` is `true` in
  PHP. **This was a real defect, fixed 2026-10-03 — see §13**, which carries the four affected
  call sites, the measurements, and what was done.

---

## 3. Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Policy | Current password required. New: **min 6, max 64, printable ASCII (0x20–0x7E)**, confirmed, must differ from current. Min 6 matches the shortest password already stored, so no existing user is below the new floor. |
| 2 | Audit columns | Stamp `LastEditedBy` / `DateEdited` / `TimeEdited` on success, from the **DB server's clock** (`SYSDATETIME()`). |
| 3 | Session | Stay logged in, **regenerate the session ID**, success flash on `/profile`. |
| 4 | Throttle | New named limiter `password-change`, 6/min keyed on the authenticated user's ID. **Not** `throttle:login` — a fumbled password change must not consume the login counter. |

### 3.1 ✅ RESOLVED 2026-10-03 — rotate `remember_token` (was an open decision)

**Should a password change rotate `users.remember_token`?**

`SWRHAUserProvider::retrieveByToken()` authenticates on `users.remember_token` alone and never
consults the password, and the login form has a "Remember me" checkbox. So today, someone who knows
the **old** password and ticked that box on another machine **stays logged in indefinitely after
the password is changed**. If the reason for changing a password is "it leaked", that is a hole.

- **Recommended: rotate it.** One line in the service —
  `$user->forceFill(['remember_token' => Str::random(60)])->save();` — which invalidates every
  remember-me cookie for that account.
- **Cost:** it also signs the user out of their *own* other devices on the next visit. That may be
  surprising, but it is the behaviour every other system has.
- Do **not** reach for `Auth::logoutOtherDevices()`: it re-hashes the plaintext into
  `users.password` and depends on `AuthenticateSession` middleware, which is not in this app's
  stack. It would corrupt the (unused) mirror hash and achieve nothing.

**Ruled on 2026-10-03: rotate.** The user's words were "invalidate remember-me cookies on other
devices. This security behavior is intentional." Built that way — see §12.4 for the one honest
consequence (this browser's own remember-me cookie dies too, so the box is re-ticked at the next
sign-in).

---

## 4. Implementation

### 4.1 `routes/web.php`

Inside the existing `Route::middleware(['auth', 'active.user'])` group, directly under
`profile.view`:

```php
Route::post('/profile/password', [ProfileController::class, 'updatePassword'])
    ->middleware('throttle:password-change')
    ->name('profile.password.update');
```

`POST` rather than `PUT` to match the only two non-GET routes the app has. Route middleware rather
than `HasMiddleware`, matching the `throttle:login` precedent on `POST /login`;
`.claude/context/controller-patterns.md` reserves `HasMiddleware` for permission-gated controllers,
and this app has no permission system. Group middleware runs first, so `$request->user()` is
populated by the time the limiter closure runs, and `active.user` has already bounced a deactivated
user.

Add a comment in the style of the existing export block explaining why there is a write route in a
read-only portal and why the limiter is not `throttle:login`.

This becomes the **third** non-GET route in the application, and the **only** one that writes data.

### 4.2 `app/Providers/AppServiceProvider.php`

Beside the existing `login` limiter (lines 22–24):

```php
RateLimiter::for('password-change', function (Request $request) {
    return Limit::perMinute(6)
        ->by((string) ($request->user()?->getAuthIdentifier() ?? $request->ip()))
        ->response(fn () => back()->with('error', 'Too many password change attempts. Please wait a minute and try again.'));
});
```

🔴 **The `response()` callback is not optional.** `bootstrap/app.php` renders `Pages/Error.vue` for
a 429 on an Inertia request, so without it the user is thrown off `/profile` onto a full-page error
screen and loses their form. `routes/web.php` already records this exact reasoning as the project's
own precedent. The `?? $request->ip()` fallback is defensive and makes the limiter testable without
a session.

### 4.3 `config/auth.php` — kill switch

```php
'directory_password_change' => env('DIRECTORY_PASSWORD_CHANGE', false),
```

This is what lets the app ship **before** the `GRANT` exists (the route is live, the service
refuses, the card does not render) and lets the feature be rolled back without a redeploy. See
§8.3.

### 4.4 `app/Services/DirectoryPasswordService.php` *(new — the first class in `app/Services/`)*

`.claude/context/controller-patterns.md` is explicit that transactions are the service layer's
job, and every existing `App\Concerns\*` is a read/derive helper that exists as a DB-free seam for
the offline suite. Putting the application's only write in a Concern would invert that. Service.

```php
class DirectoryPasswordService
{
    private const CONNECTION = 'SWRHAExpenseControl';
    private const TABLE = '0006AWebAppControls';

    public function isEnabled(): bool;
    public function change(User $user, string $currentPassword, string $newPassword): void;

    private function connection(): \Illuminate\Database\Connection;
    private function editStamp(): array;
}
```

`change()` body, in order:

1. `isEnabled()` false → `ValidationException` on `current_password`
   ("Password changes are not available at the moment.").
2. Open a transaction **on the `SWRHAExpenseControl` connection** —
   `$this->connection()->transaction(...)`, never the `DB::transaction()` facade. The facade opens
   a transaction on **MySQL** and leaves the SQL Server write unguarded. This is an easy and silent
   mistake.
3. **One fresh read of the base table**, inside the transaction:
   ```php
   $rows = $connection->table(self::TABLE)
       ->where('UserName', $user->username)
       ->get(['LineID', 'UserName', 'UserPassword']);
   ```
   This single query serves all three jobs — the ambiguity guard, the password check, and the
   update key. One round trip. (Why not `SWRHAUserProvider::validateCredentials()` → §5.)
4. **`$rows->count() !== 1` → refuse.** Log `username` + match count, throw a `ValidationException`
   with a generic *"Your password could not be changed. Please contact an administrator."* (not
   "duplicate" — that leaks directory structure). **Never** fall through to an unqualified
   `WHERE UserName = ?`.
5. `hash_equals((string) $row->UserPassword, $currentPassword)` → else `ValidationException` on
   `current_password`.
   🔴 **Never move this comparison into a SQL predicate.** `Latin1_General_CI_AS` is case- *and*
   accent-insensitive, so `WHERE UserPassword = ?` would accept `Secret1` for `secret1` while
   login — which compares in PHP — would then reject it.
   No separate "new must differ from stored" check is needed: the `different:current_password`
   rule (§4.6) proves `password !== current_password`, and this step proves
   `current_password === stored`.
6. **Update by `LineID`:**
   ```php
   ['date' => $date, 'time' => $time] = $this->editStamp();

   $affected = $connection->table(self::TABLE)
       ->where('LineID', $row->LineID)
       ->update([
           'UserPassword' => $newPassword,
           'LastEditedBy' => $user->name,      // EmployeeName — see §2.3
           'DateEdited'   => $date,
           'TimeEdited'   => $time,
       ]);
   ```
   🔴 **`WHERE LineID = ?`, never `WHERE UserName = ?`.** `UserName` has no unique index and the
   collation is case-insensitive, so a username predicate could rewrite *a different person's*
   password. That is the worst outcome this feature can produce. `LineID` is an `int IDENTITY`
   primary key: a clustered seek on a value that cannot be duplicated or case-folded.
7. **Read back inside the transaction and verify:**
   ```php
   $stored = (string) $connection->table(self::TABLE)->where('LineID', $row->LineID)->value('UserPassword');

   if ($affected !== 1 || ! hash_equals($stored, $newPassword)) {
       throw new \RuntimeException('Directory password update did not verify.');
   }
   ```
   One extra `SELECT`, and it rolls the write back rather than leaving a user locked out of an
   account with no reset path. The ASCII rule (§6) makes the conversion provably lossless today;
   this is what keeps it safe if the column, collation or connection encoding ever changes.
8. Outside the transaction, on success: rotate `remember_token` (pending §3.1), then
   `Log::info('Directory password changed.', ['username' => $user->username])`.
   🔴 **Username and outcome only. Never the password, never a match flag** — a `\Log::debug`
   password-match oracle lived in this codebase until 2026-08-05.

Exception handling inside `change()`: re-throw `ValidationException` untouched; catch every other
`\Throwable`, log it with the username, and convert it to a `ValidationException` on
`current_password` reading *"Your password could not be changed right now. Please try again
later."* That conversion is what stops a missing `GRANT` or a dead SQL Server becoming a 500 page
(§7.2), and it is why the controller can stay pattern-shaped.

#### 4.5 The clock — `editStamp()`

```php
private function editStamp(): array
{
    // The audit stamp must be the DB SERVER's clock: the web and database boxes
    // are separate machines, and the ledger refresh already stamps with
    // SYSDATETIME() for the same reason. The sqlite branch exists because the
    // suite's directory fake is in-memory SQLite and SQLite has no SYSDATETIME().
    return $this->connection()->getDriverName() === 'sqlite'
        ? ['date' => DB::raw("date('now','localtime')"),    'time' => DB::raw("time('now','localtime')")]
        : ['date' => DB::raw('CAST(SYSDATETIME() AS date)'), 'time' => DB::raw('CAST(SYSDATETIME() AS time)')];
}
```

A driver branch in production code is ugly and should be challenged — but the alternatives are
worse. Binding PHP's `now()` uses the *web* server's clock, contradicting the project's own
two-clock/NTP rule; stubbing the service in the feature tests loses coverage of the one write the
application performs, which is precisely what `CLAUDE.md` says to fake rather than skip.

### 4.6 `app/Http/Controllers/ProfileController.php`

```php
public function __construct(
    private readonly DirectoryPasswordService $directoryPasswords,
) {}
```

`view()` gains one prop, `'canChangePassword' => $this->directoryPasswords->isEnabled()`.

```php
// =========================================================================
// updatePassword() — the only write in this application
// =========================================================================

public function updatePassword(Request $request): RedirectResponse
{
    $data = $request->validate([
        'current_password' => ['required', 'string'],
        'password' => [
            'required', 'string', 'min:6', 'max:64',
            // Printable ASCII only. NOT a style preference: the column is varchar
            // COLLATE Latin1_General_CI_AS and the connection sends nvarchar, so a
            // codepoint outside CP1252 is silently replaced with '?' on assignment
            // and the user is permanently locked out of an application that has no
            // password-reset route. /D stops $ matching before a trailing newline.
            'regex:/^[\x20-\x7E]+$/D',
            'different:current_password',
            'confirmed',
        ],
    ], [ /* messages — see below */ ]);

    try {
        $this->directoryPasswords->change($request->user(), $data['current_password'], $data['password']);
    } catch (ValidationException $e) {
        // Deviation from the house pattern, deliberately: each of these failures is
        // attributable to one field, and a flat `error` flash would strand the
        // message away from the input the user has to correct.
        return back()->withErrors($e->errors());
    }

    $request->session()->regenerate();

    return redirect()->route('profile.view')->with('success', 'Your password has been changed.');
}
```

Validation traps, each of which is easy to hit:

- 🔴 **Never write `'current_password' => ['required', 'current_password']`.** Laravel ships a
  built-in rule with that exact name which validates against the authenticated user's **hashed**
  `users.password` via the `Hash` facade. That column holds `Hash::make(Str::random(40))` and is
  never used for authentication, so the rule would reject **100% of attempts** with a
  perfectly reasonable-looking message. The field name colliding with the rule name makes this a
  reflex mistake. The current-password check belongs in the service and nowhere else.
- 🔴 **`/D` (`PCRE_DOLLAR_ENDONLY`) is load-bearing.** Without it `"abcdef\n"` passes, and `\n` is
  not in `\x20-\x7E` — the guard would be defeated by its own anchor.
- **No `/u`.** The check is on bytes, which is what is meant; invalid UTF-8 then fails closed
  without depending on `preg_match` returning `false`.
- 🔴 **The three field names are load-bearing.** Laravel's `TrimStrings::$except` is literally
  `['current_password', 'password', 'password_confirmation']`. Rename any of them to, say,
  `new_password`, and a password ending in a space is silently trimmed on the way in and the user
  is locked out on the next login.
- **Rule order matters for the message**, not the outcome: `regex` before `different`/`confirmed`,
  so someone pasting a smart quote gets the character message rather than a mismatch message.
- Custom messages for `regex`, `different`, `confirmed`, `min`, `max`.
- Deliberately **not** used: `Illuminate\Validation\Rules\Password::defaults()` — its
  `uncompromised()` calls out to haveibeenpwned.com from a server whose outbound access is
  unknown, and it has no character-set control.

Conformance notes for `controller-patterns.md`: service injected `private readonly` ✓, no
`DB::transaction()` in the controller ✓, `ValidationException` caught ✓, `// ===` dividers ✓.
`back()->withErrors($e->errors())` instead of `back()->with('error', collect(...)->flatten()->first())`
is the one conscious deviation, required by decision §6 below. **Do not emit both** field errors and
an error flash — two signals for one failure.

The local MySQL `users.password` column is **not** touched (beyond the `remember_token` rotation of
§3.1). It holds a random hash, nothing authenticates against it, and syncing it would create a
second divergent copy of a credential. Put a one-line comment saying so — otherwise it reads as an
oversight to the next person.

### 4.7 `resources/js/Pages/Profile/View Profile.vue`

Four changes:

1. **`canChangePassword: { type: Boolean, default: false }`** added to `defineProps`.
2. **Inline flash blocks** at the top of the root `<div class="max-w-4xl mx-auto space-y-6">`
   (line ~22), copied from `Components/RequisitionDetailView.vue:260-274`.
   **Do not import `Components/FlashMessages.vue`** — nothing in the app does, `AppLayout` renders
   no flashes, and introducing a second mechanism on one page is worse than the duplication.
3. **A "Change Password" `<section>`** in the left column below Account Information (after line
   125), gated on `v-if="canChangePassword"`, matching the existing
   `bg-surface border border-line rounded-xl` + `bg-surface-2` header card chrome. Form pattern
   copied from `Pages/Auth/Login.vue` (lines 19–39 for the script, 133–207 for the template,
   including the eye / eye-slash show-hide toggle at 168–175 and `InputError`):

   ```js
   const form = useForm({ current_password: '', password: '', password_confirmation: '' })

   const submit = () => form.post(route('profile.password.update'), {
     preserveScroll: true,
     onSuccess: () => form.reset(),
     onError:   () => form.reset('current_password', 'password', 'password_confirmation'),
   })
   ```

   Three inputs with `autocomplete="current-password"` / `"new-password"` / `"new-password"`, each
   `maxlength="64"`, each with `<InputError :message="form.errors.…" />`, and a submit button
   `:disabled="form.processing"` with the spinner swap. Copy under the new-password field:
   *"6–64 characters. Letters, numbers, spaces and standard keyboard symbols only."*
   And, per §1.2: *"This changes the password you use for every SWRHA application that shares this
   account, not just the Finance Portal."*
4. **The footer `Read-only` badge** (line 175) becomes a lie next to a working form. Replace it
   (e.g. *"Account details are managed by Finance"*) or drop it.

Style with the semantic tokens the page already uses (`bg-surface`, `border-line`, `text-tx-*`),
never hardcoded greys, so dark mode follows automatically. No change to `SideBar.vue` or `app.js`.

---

## 5. Why the current-password check does **not** go through `SWRHAUserProvider`

`validateCredentials()` looks like the right call. It is not, for four reasons — and *staleness is
not one of them*: `$resolvedSqlUser` is an instance field on a provider constructed per request,
and on this request the session guard authenticates via `retrieveById()`, which never populates it.

1. **It would reintroduce the double round trip.** It returns a `bool`; the service still needs
   `LineID` (which `vw_WebAppUsers` does not expose, so the provider could not supply it even in
   principle) plus the match count for the ambiguity guard. So it is one query *in addition to*
   the service's own — the exact two-lookups shape `CLAUDE.md` and
   `LoginFlowTest::test_a_login_attempt_hits_the_auth_sql_server_exactly_once` exist to prevent.
2. **It reads the wrong object** — the view, while the write is keyed on the base table.
3. 🔴 **It swallows outages into a false answer.** `findSqlServerUser()` catches `\Throwable` and
   returns `null`, so `validateCredentials()` returns `false`. A SQL Server outage would be
   reported to the user as *"your current password is incorrect."* Same class of defect as the
   outage-must-not-read-as-no-access rule, and the decisive objection.
4. Leave `validateCredentials()` and its test exactly as they are. `CLAUDE.md` justifies that
   method by naming "a future password-confirmation screen"; this is roughly that screen and
   deliberately does not use it. **Say so in the amended rule** — otherwise the obvious next edit
   is "nothing calls this directly, make it `return true`", which is the landmine the test guards.

---

## 6. Charset — why printable-ASCII is a correctness guard, not a preference

`PDO::SQLSRV_ATTR_ENCODING => 65001` (set in `config/database.php`) tells pdo_sqlsrv that PHP
strings are UTF-8, so bound parameters are sent as **`nvarchar`**. The target column is
`varchar COLLATE Latin1_General_CI_AS`, so SQL Server implicitly converts `nvarchar → varchar`
using that collation's code page, **CP1252**. Any codepoint with no CP1252 representation is
**silently replaced with `?` (0x3F)** — no error, no warning, no truncation notice.

The row then stores `pa?word`. On the next login `hash_equals('pa?word', 'paßword')` is `false`,
forever, for a password the user typed correctly. **Permanent self-inflicted lockout, in an
application with no password-reset route.** It is the worst failure mode in the feature.

ASCII 0x20–0x7E is byte-identical in UTF-8, UTF-16 and CP1252, so under the restriction the
conversion is provably lossless. A second, subtler band — characters that *do* exist in CP1252
(`é`, `£`, Windows autocorrect's curly quotes, a pasted U+00A0) — round-trips fine today but is
collation-dependent and accent-insensitive on comparison. Excluding it is cheap insurance.

**An explicit `PDO::PARAM_STR` is neither needed nor usefully addable** — Laravel's
`Connection::bindValues()` already binds every non-int/non-bool value that way, and that is what
the login `SELECT` has always done. Casting with `DB::raw('CAST(? AS varchar(255))')` would force
manual binding management and buys nothing once the input is ASCII-only. Don't.

Note also: trailing spaces in `varchar` **are** stored (unlike `char`), and because the comparison
happens in PHP via `hash_equals` rather than in SQL, SQL Server's trailing-space-insensitive `=`
never applies. So a password ending in a space works end to end — it is just invisible to the user.
Forbidding leading/trailing whitespace outright is a usability call, not a correctness one.

---

## 7. Risks and failure modes

**7.1 — In-doubt transaction.** There is no partial-row state: one `UPDATE` of four columns, with
the row-count and read-back checks *inside* the transaction. The real risk is the server committing
and the connection dropping before the client sees the acknowledgement. The user is told it failed,
but it succeeded; they retry with the old password and are told it is wrong, with no reset path.
**Mitigation is copy, not code:** the failure message should read *"Your password may or may not
have been changed. Try signing in with your new password before trying again."* Do not attempt a
re-read-and-compare retry.

**7.2 — A missing `GRANT` is a 500 on every attempt.** `finance` is `db_datareader` only today, so
every `UPDATE` would throw a `PDOException`, which under "let unexpected exceptions bubble" becomes
the Inertia 500 page. That is why the service catches `\Throwable` and converts it, and why §4.3
adds the config flag.

**7.3 — Column-level privilege escalation.** With a *table-level* grant, a future bug in the
`->update([...])` array could write `IsActive`, `UserName` or `PositionID`. **`PositionID` is the
access-control key** — it is what `vw_WebAppUserAccess` joins on to decide whose departmental money
a user can see. A bug that writes it hands someone another department's TTD figures. The
column-level grant in §8.1 makes that impossible at the database, which is where it belongs; test
case 3 in §9 is the application-layer half of the same guard.

**7.4 — Remember-me cookies.** See §3.1 — the open decision.

**7.5 — Nothing caches the password.** `SWRHAUserProvider::$resolvedSqlUser` is request-scoped. The
`file` cache store holds ledger filter lists only; no credential ever enters it.

**7.6 — `EnsureUserIsActive` does not interact badly.** It runs before the route throttle, reads
`IsActive` / `EmployeeName` only, and never touches `UserPassword`. The view is live over the base
table, so it sees the new value immediately. The only consequence worth naming: the reverification
may add one auth round trip to this request, bounded to once per 5 minutes — true of every page
already.

**7.7 — Restoring the database silently reverts passwords.** If the DBA ever restores
`SWRHAExpenseControl` from a nightly backup, every password changed since reverts with no notice
and those users are locked out with a password that "used to work". `instructionsphase2.md` already
carries a restore hazard; this is a second one. Tell the DBA.

**7.8 — Transport.** `SQLSRV_ENCRYPT` defaults to `yes` but `SQLSRV_TRUST_SERVER_CERT` defaults to
`true`, so the inter-server link is encrypted but not authenticated. The login path already sends
plaintext passwords over it, so this adds no new exposure *class* — but it adds a new direction of
travel. Separately, confirm `/profile` is actually served over HTTPS; if not, the login form has
the same problem and both should be fixed together.

**7.9 — Route caching.** This is the first state-changing route inside the authenticated group;
CSRF is covered by the default `web` stack. Add `php artisan route:clear` to the deploy steps.

---

## 8. Production rollout

### 8.1 The `GRANT` — column-level, never table-level

```sql
USE SWRHAExpenseControl;
GO
GRANT UPDATE (UserPassword, LastEditedBy, DateEdited, TimeEdited)
    ON OBJECT::dbo.[0006AWebAppControls] TO [finance];
GO
```

Ship as `sql/GrantPasswordUpdate.sql`, with `sql/GrantPasswordUpdateRollback.sql` holding the
matching `REVOKE`. `SELECT` is already covered by `db_datareader`. **Do not grant table-level
`UPDATE` "for simplicity"** — nothing is simplified and the blast radius is the access-control
column (§7.3).

**Confirm the production login name first.** Dev uses `finance`; verify production's
`SQLSRV_USERNAME` matches before scripting it.

### 8.2 Who applies it

The scope matches a **standing permission this project already holds** — those four columns and
nothing else — so this is applying a grant, not negotiating a new one. What is still needed is the
**DBA** to run it on production, and it is worth them seeing exactly what it does: the four
columns, the predicate (`WHERE LineID = ?`), that the app verifies the current password first,
that it refuses on ambiguity, and that the audit columns are stamped from the server clock. Offer
§9's test list as evidence. The pre-existing tables remain otherwise untouchable (§1.1).

Worth one question to that team at the same time: **does any other application that writes this
directory enforce its own password rules, or read `UserPassword` into a narrower field?** A
64-character password could overflow a `varchar(50)` input elsewhere.

### 8.3 Order of operations

> 📌 **As of 2026-10-03 this sequence lives in the release runbook**, as
> `finance_sep_update_deployment.md` **Steps 5.8–5.11** (confirm the scope → baseline + grant → verify
> the grant is exactly four columns → enable and verify end to end), with the rollback rows and
> stop conditions added there too. The runbook is what gets executed; what follows is the
> rationale behind it.

1. DBA scripts a baseline off the DB server:
   `SELECT LineID, UserName, UserPassword, LastEditedBy, DateEdited, TimeEdited FROM dbo.[0006AWebAppControls]`.
   Three rows; this is the restore path for a mangled password and costs nothing.
2. Deploy the app with **`DIRECTORY_PASSWORD_CHANGE=false`**. Route exists, service refuses, card
   does not render. Verify the six existing pages are unaffected.
3. Apply the `GRANT`.
4. Verify (§8.4).
5. `DIRECTORY_PASSWORD_CHANGE=true` + `php artisan config:clear`.
6. Change **one** test account's password end to end in a browser; then change it back through the
   same UI, which exercises the path twice.
7. Tell the users — including the shared-credential point (§1.2).

### 8.4 Verification queries

```sql
SELECT HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','UserPassword') AS pw,
       HAS_PERMS_BY_NAME('dbo.[0006AWebAppControls]','OBJECT','UPDATE','COLUMN','IsActive')     AS must_be_zero;

SELECT p.permission_name, p.state_desc, c.name AS column_name
FROM   sys.database_permissions p
LEFT  JOIN sys.columns c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE  p.major_id = OBJECT_ID('dbo.[0006AWebAppControls]')
  AND  p.grantee_principal_id = DATABASE_PRINCIPAL_ID('finance');
```

`must_be_zero` returning `1` means someone granted table-level by mistake — stop and narrow it.

### 8.5 Rollback, in increasing severity

1. **Instant, no redeploy, no DBA:** `DIRECTORY_PASSWORD_CHANGE=false` + `php artisan config:clear`.
   This is the main reason to accept the extra config key.
2. **Revoke the privilege** (§8.1 rollback script). The service's `catch (\Throwable)` turns the
   permission error into "could not be changed right now", not a 500.
3. **Restore a mangled password** from the step-1 baseline, by the DBA, one `UPDATE` by `LineID`.
4. **Revert the code** — an ordinary app release. This change creates, alters and drops **no SQL
   object**, so there is no migration and no rollback script, the same shape as Phase 3.

### 8.6 Release context

Access parity is part-built, the two drill-down changes are committed-but-not-deployed, and there
is uncommitted work on `feature/ledger-oversight-update` as of 2026-10-02. This feature touches no
SQL object and no shared controller, so it is independent — but it will ride out alongside all of
that. **Build it on its own branch** so the release notes can attribute any regression.

---

## 9. Tests

All of this is fakeable offline — a directory row is a handful of columns — so per `CLAUDE.md`'s
own rule ("Login is security-relevant … fake it, don't skip it"), **every case below must pass with
no SQL Server reachable. Zero skips.**

### 9.1 `tests/Feature/Concerns/FakesExpenseControlDirectory.php`

Three **additive** edits; **none of the 12 existing `LoginFlowTest` cases changes.**

1. **Create the base table** in `fakeExpenseControlDirectory()`, after the existing
   `vw_WebAppUsers` create: `$table->increments('LineID')` plus the remaining columns as nullable
   strings. Declare `DateCreated` / `TimeCreated` / `DateEdited` / `TimeEdited` as **strings** —
   SQLite gives `date`/`time` NUMERIC affinity, and whether `'2026-10-02'` lands as TEXT or `0`
   then depends on numeral parsing. The fake's job is to let the write execute and be asserted on,
   not to reproduce SQL Server's types. **Deliberately no unique index on `UserName`** — production
   has none, and adding one would make the ambiguity-guard test unwritable.
2. **`directoryUser()` inserts into both tables** from the same array, returning the merged row
   with `LineID` appended. Existing keys unchanged, so no existing assertion moves. A fixture where
   the view and its base table disagree is a fiction that can only hide bugs.
3. **Add `directoryControlRow(array $attributes = []): int`** — inserts into the base table only,
   returning `LineID`. Needed by exactly one test: the ambiguity guard, which needs a second row
   with the same `UserName`.

🔴 **Do not change `IsActive` from `boolean` to `string` in the same edit** — two `LoginFlowTest`
cases pass `['IsActive' => false]`, and a string column changes their meaning. See §2.3.

Why the existing 12 cannot break:

- `test_a_login_attempt_hits_the_auth_sql_server_exactly_once` calls `enableQueryLog()` *after*
  `setUp()` and `directoryUser()`, so neither the extra `CREATE TABLE` nor the extra `INSERT` is
  counted. The login path still issues exactly one query — nothing in it reads the base table.
- `test_a_sql_server_outage_fails_the_login_without_a_500` drops `vw_WebAppUsers` only; the
  leftover base table is never read on that path.
- Every other case asserts on the local `users` mirror or on HTTP responses. None enumerates the
  connection's tables.

SQLite quirks, resolved:

| Quirk | Status |
|---|---|
| Table name starts with digits | Non-issue via `Schema::create` / `->table()`. Laravel's SQLite grammar quotes with `"`, the sqlsrv grammar with `[]`. Only a hand-written `DB::statement()` would need manual quoting. |
| `date` / `time` column types | Real — sidestepped by declaring `string`, with a comment saying why. |
| `increments()` vs `int IDENTITY` | Equivalent for the one thing the test needs: a stable unique `LineID`. |
| `UPDATE` affected-row count | Works on both drivers, so the `$affected !== 1` guard is genuinely exercised. |
| CI collation | **Not reproducible** — SQLite's `=` on TEXT is case-sensitive. So the ambiguity test inserts two **identical** usernames, not case-variants. Note in the test that the case-variant path is covered by reasoning only. |
| `SYSDATETIME()` | Absent — handled by the `editStamp()` driver branch (§4.5). |

### 9.2 `tests/Feature/Auth/PasswordChangeTest.php` *(new)*

Uses `FakesExpenseControlDirectory` + `RefreshDatabase`. Every case acts as a `User::factory()`
user, whose `sql_server_verified_at => now()` is what stops `active.user` reverification
interfering.

*Happy path*
1. A valid change updates `UserPassword` in `0006AWebAppControls`.
2. `LastEditedBy` = the user's display name; `DateEdited` / `TimeEdited` non-null and well-shaped
   — assert shape, **not** an exact value (the DB clock is the authority).
3. 🔴 **No collateral writes** — `IsActive`, `PositionID`, `EmployeeID`, `UserName`, `CreatedBy`,
   `DateCreated`, `TimeCreated` all untouched. The application-layer half of §7.3.
4. Redirects to `/profile` with the `success` flash.
5. The session ID changes and the user stays authenticated.
6. 🔴 **End to end** — afterwards the user can log in with the new password and **cannot** with the
   old. The only test that proves the write half and the login half agree.
7. The password-change request hits the auth SQL Server **exactly once** (`enableQueryLog()` around
   the POST) — the direct analogue of the existing login round-trip test, and what stops someone
   re-routing the check through `validateCredentials()` later (§5).
8. `remember_token` is rotated (pending §3.1).

*Rejections — each asserts a **field-scoped** error and that `UserPassword` is unchanged*
9. Wrong current password → `current_password`.
10. Shorter than 6 → `password`. 11. Longer than 64 → `password`. (And 6 and 64 are accepted.)
12. Confirmation mismatch → `password`.
13. New identical to current → `password` (the `different` rule).
14. 🔴 **Non-ASCII** (`"pa\u{00E9}ssword"`) → `password`. The lockout guard; the most important
    rejection test in the list.
15. Control character (`"abc\ndef"`) → `password`, proving the `/D` modifier.
16. Missing fields → errors on all three.

*Structural*
17. A second row with the same `UserName` → refused, **neither** row modified, generic
    "contact an administrator" message.
18. No matching row at all → refused, no 500.
19. SQL outage (`DROP TABLE "0006AWebAppControls"`) → refused with a field error, **not** a 500 and
    **not** "your current password is incorrect".
20. Guest → redirected to `/login`.
21. A user whose directory row is inactive → bounced by `active.user` before the controller.
22. Acting as user A leaves user B's row untouched regardless of input (there is no user field in
    the form; this guards against someone adding one).
23. 🔴 Throttling: the 7th request in a minute comes back as a **redirect with an `error` flash**,
    not a 429 error page — this pins the `response()` callback of §4.2.
24. With `config(['auth.directory_password_change' => false])` the POST is refused and
    `canChangePassword` is `false` on the page.

### 9.3 Other suites

- `tests/Feature/ProfileTest.php` — add a case asserting `canChangePassword` reaches the page.
- `tests/Unit/` — a pure-PHP table test over the regex boundary bytes (`0x19`, `0x20`, `0x7E`,
  `0x7F`, `\n`, `\t`, UTF-8 `é`, a lone invalid byte `"\xC3"`). Cheapest high-value coverage in the
  set, runs with no container. Worth extracting the pattern to a constant for it.

### 9.4 Commands

```bash
SQLSRV_HOST=127.0.0.1 php artisan test --filter=PasswordChangeTest   # expect 0 skipped
SQLSRV_HOST=127.0.0.1 php artisan test                               # expect 275+N passed, 7 skipped, 0 failed
npm run test:js                                                      # expect 12 passed, unaffected
./vendor/bin/pint <only the files changed>
npm run build
```

Pint only the changed files — a repo-wide run reformats ~nine unrelated pre-existing files.

---

## 10. Documentation to update in the same commit

- **This file** — add the **As built** section.
- **`CLAUDE.md`** — the two amendments of §1.1; add `POST /profile/password`, the
  `password-change` limiter and the `directory_password_change` flag to the *Authentication &
  Users* rules; note in the `validateCredentials()` rule that this screen deliberately does not use
  it (§5.4); add a `passwordreset.md` row to the Reference Documents table. Edit with the
  write-then-rename discipline — the file is gitignored and unrecoverable.
- **`Overview.md`** — one paragraph for the finance department, including the shared-credential
  point.

---

## 11. End-to-end verification

1. Run the suites and the build (§9.4).
2. Note the dev row's current `UserPassword`, `LastEditedBy`, `DateEdited`, `TimeEdited`.
3. In a browser at `/profile`: wrong current password → inline field error, no flash, row unchanged.
4. Valid change → green success flash, still logged in, and
   `SELECT UserName, UserPassword, LastEditedBy, DateEdited, TimeEdited FROM dbo.[0006AWebAppControls]`
   shows the new value with the three audit columns stamped and every other column untouched.
   Confirm `DATALENGTH = LEN` on the new value (no encoding expansion).
5. Sign out, sign in with the **new** password; confirm the old one is rejected.
6. Submit 7 times inside a minute → an inline error flash on `/profile`, **not** the 429 page.
7. Check the card in **dark mode** and at a narrow viewport.
8. `storage/logs/laravel.log` contains the username and outcome and **no password material**.
9. Restore the dev row to its original password.

---

# 12. As built (2026-10-03)

**This section wins over everything above it.** Built to plan apart from the five deviations in
§12.3.

## 12.1 What was written

| File | Change |
|---|---|
| `config/auth.php` | `directory_password_change` kill switch, default **false** |
| `routes/web.php` | `POST /profile/password` → `profile.password.update`, `throttle:password-change`, inside the existing `['auth','active.user']` group |
| `app/Providers/AppServiceProvider.php` | the `password-change` limiter, 6/min per user id, **with** the `response()` redirect callback |
| `app/Services/DirectoryPasswordService.php` *(new)* | the only write in the application — `isEnabled()`, `change()`, and private `resolveControlRow()` / `writePassword()` / `editStamp()` / `rotateRememberToken()`. Also owns `PRINTABLE_ASCII`, `MIN_LENGTH`, `MAX_LENGTH` |
| `app/Http/Controllers/ProfileController.php` | constructor injection, `canChangePassword` prop, `updatePassword()` |
| `resources/js/Pages/Profile/View Profile.vue` | flash blocks, the Change Password card, the `canChangePassword` prop, footer badge corrected |
| `tests/Feature/Concerns/FakesExpenseControlDirectory.php` | additively fakes `0006AWebAppControls`; adds `directoryControlRow()` and `directoryControlRowWhere()` |
| `tests/Feature/Auth/PasswordChangeTest.php` *(new)* | 26 cases, fully offline |
| `tests/Unit/DirectoryPasswordPolicyTest.php` *(new)* | 8 cases, container-free |
| `tests/Feature/ProfileTest.php` | one case for the `canChangePassword` prop |
| `sql/GrantPasswordUpdate.sql`, `sql/GrantPasswordUpdateRollback.sql` *(new)* | the column-level grant with its verification queries, and the revoke |
| `.env`, `.env.example` | `DIRECTORY_PASSWORD_CHANGE=false` |
| `CLAUDE.md` | five rules amended in place, one new section, one reference-table row |
| `Overview.md` | §7 rewritten for the finance department |

No migration, no package, no queue, no Agent-job change, and **no SQL object created, altered or
dropped** — the only database-side artefact is a permission.

## 12.2 Measured

- `php artisan test --filter=PasswordChangeTest` → **26 passed, 0 skipped**, with SQL Server
  unreachable. Zero skips is the point: these run everywhere.
- `php artisan test --filter=DirectoryPasswordPolicyTest` → **8 passed**, no container.
- `SQLSRV_HOST=127.0.0.1 php artisan test` → **310 passed, 7 skipped, 0 failed, 3,235 assertions,
  78s.** Baseline before this work was 275 passed / 7 skipped. **The 7 skips are unchanged** — the
  same premise guards that skip because the only mapped user sees one department, so no filter can
  narrow anything.
- The 12 existing `LoginFlowTest` cases pass untouched, including
  `test_a_login_attempt_hits_the_auth_sql_server_exactly_once`: the extra `CREATE TABLE` and
  `INSERT` in the fake both land before `enableQueryLog()`.
- `npm run build` clean. Pint clean on the changed files.

## 12.3 Deviations from the plan above

1. **Validation is inline in `updatePassword()`, not a `FormRequest`.** With the policy constants
   moved onto the service the rule array is nine lines, which is what
   `controller-patterns.md` calls simple enough for inline. A `Requests/Profile/` directory
   holding one class was not worth it.
2. **`PRINTABLE_ASCII`, `MIN_LENGTH` and `MAX_LENGTH` are public constants on the service**, which
   the controller composes its rules from; the plan had the regex inline. Extracting it is what
   lets `tests/Unit/DirectoryPasswordPolicyTest.php` exercise the lockout guard with no container
   — the one piece of coverage guaranteed to survive on a machine with no database.
3. **No `DirectoryUnavailableException` class.** The service converts every unexpected throwable
   into a field-scoped `ValidationException` itself, so the controller catches one type and
   nothing reaches a 500 page. A second exception class would have had exactly one thrower and one
   catcher.
4. **The current-password input is `maxlength="255"`, not 64.** 64 is the policy for the *new*
   password; capping the current one would make an existing longer password untypable.
5. **Pint normalised the alignment of the existing `view()` array** in `ProfileController`
   (`'id'          =>` → `'id' =>`). Left as Pint's canonical form, since that file is one this
   change owns. `config/auth.php`'s unrelated reformat — hoisting `App\Models\User` to an import —
   **was reverted**; that part of the file is not ours.

## 12.4 Decisions confirmed during implementation

- **`LastEditedBy` gets the display name.** Confirmed against the live rows: the existing values
  are `FRANCIS FIGUERA` and `MERNELL SPENCER`, and `vw_WebAppUsers.EmployeeName` for those users
  is identical. `users.name` mirrors that column, so `$user->name` is the right source.
- **`remember_token` is rotated** (§3.1 resolved, on the user's explicit instruction). The current
  session survives because it rides the regenerated session cookie. The honest consequence, worth
  stating plainly: **this browser's own remember-me cookie dies with the rest**, so the user
  re-ticks the box at their next sign-in. That is the fail-secure direction and is deliberate.
- **The read-back verify was kept.** One extra `SELECT` inside the transaction, and it turns the
  worst failure mode — a silently mangled password in a system with no reset route — from a
  permanent lockout into a rolled-back write and an error message.

## 12.6 Revision — the form became a MODAL (2026-10-03)

Requested after the first build: the inline card on `/profile` was replaced by a dialog, opened
from a button in the right column under Account Status. **No server-side change at all** — same
route, controller, service, validation and tests; the suite stayed at 311 passed / 7 skipped.

| File | Change |
|---|---|
| `resources/js/composables/useModalShell.js` *(new)* | Escape-to-close and a **reference-counted** body scroll lock |
| `resources/js/Components/PasswordChangeModal.vue` *(new)* | owns the `useForm`, the three fields and its own chrome |
| `resources/js/Components/Legal/LegalModal.vue` | consumes the composable; its private escape/scroll-lock code deleted. No visual change |
| `resources/js/Pages/Profile/View Profile.vue` | inline card removed; "Security" card + trigger button in the right column; holds only `showPasswordModal` |

Four things worth not undoing:

- 🔴 **The scroll lock is reference counted, and it had to be.** `AppLayout` → `FooterBar` →
  `PolicyModals` mounts the two legal modals on **every** authenticated page, so `/profile` now has
  three modals in the DOM. Each previously set `document.body.style.overflow = ''` on its own
  close, so closing one would unlock the page beneath another still open. The counter makes the
  last one out restore it — and restore whatever was there before rather than assuming `''`.
- 🔴 **The modal stays open when THROTTLED, and that is not the same path as a validation error.**
  The limiter returns a redirect with an `error` flash and **no** validation errors, which Inertia
  reports through `onSuccess`, not `onError`. Closing on it would discard everything the user
  typed over something they can retry in sixty seconds. The modal checks
  `page.props.flash?.error` before closing;
  `PasswordChangeTest::test_it_is_throttled_with_a_flash_rather_than_a_429_error_page` now asserts
  `assertSessionHasNoErrors()` to pin the server half of that. **Do not tidy that assertion away.**
- **It cannot be closed while `form.processing`** — Escape, backdrop, Cancel and the X are all
  gated through the composable's `canClose`. The write is already in flight to SQL Server, and a
  dialog that vanishes mid-request leaves the user with no idea whether it landed.
- **Only the BEHAVIOUR is shared, not the chrome.** Each modal keeps its own header and footer,
  the same split `useTableScroll` uses for the wide tables. A shared *visual* shell was tried for
  the page heroes (`PageHero`) and deleted, so the composable deliberately stops at Escape and the
  scroll lock.

Focus is handled in the modal rather than the page: it captures `document.activeElement` when it
opens, focuses the current-password field, and returns focus there on close, so a keyboard user is
not dropped at the top of the document.

## 12.5 Still outstanding

1. **The DBA to apply `sql/GrantPasswordUpdate.sql` on production** —
   `finance_sep_update_deployment.md` Step 5.8, which carries the scope table. The grant matches a
   permission this project already holds, so it is an application rather than a negotiation. The
   rest of the release is unaffected until it happens: the app ships with the feature switched off
   and works normally without the grant.
2. **Confirm the production login name** — dev is `finance`; verify production's `SQLSRV_USERNAME`
   before granting to the wrong principal, which fails silently.
3. **Ask that team whether any other consumer of this directory enforces its own password rules**,
   or reads `UserPassword` into a field narrower than 64.
4. **Apply the grant, then run §8.4's verification.** `must_be_zero` coming back `1` means someone
   granted at table level — stop and narrow it.
5. **Capture the three-row baseline** before the first production change (§8.3 step 1).
6. ✅ **Browser verification — DONE 2026-10-03, see §14**, and the narrow-viewport gap it left is
   now closed too (§15.3). The GRANT itself still could not be exercised on dev, because the app
   connects there as a sysadmin and bypasses object permissions — that is what Step 5.10 of the
   runbook is for.
7. **Tell the users about the shared-credential blast radius** (§1.2) before the flag goes on.
8. **A separate open defect, found while measuring — full write-up in §13.** `IsActive` is a
   `varchar` holding the strings `'TRUE'`/`'FALSE'`, and `(bool) 'FALSE'` is `true`, so a
   directory-deactivated user would still log in and browse. Three call sites need correcting.
   Not part of this change; the password-change path alone is already defended (§13.6).
   ✅ **FIXED 2026-10-03 — see §13.7.** All four call sites now go through
   `App\Support\DirectoryFlag`, the fake stores production-shaped strings, and the middleware has
   a test file for the first time. Nothing broke: 332 passed, 7 skipped.

---

# 13. ✅ RESOLVED — `(bool) 'FALSE'` is `true`, so deactivation did not deactivate

**Raised:** 2026-10-03, found while measuring for the password-change work.
**Fixed:** 2026-10-03, see §13.7.
**Severity when open:** latent security defect. Nothing had broken *only* because no row had ever
been set to `'FALSE'` — the day anyone used the intended deactivation mechanism, it would silently
not have worked.

> §13.1–13.4 below describe the defect as found and are kept as the record of it. **§13.7 is what
> was actually done**, and §13.6 has been rewritten accordingly.

## 13.1 The defect

`IsActive` is **`varchar(255)`** on `dbo.0006AWebAppControls` (and on `dbo.0006CWebAppPostControls`),
holding the literal strings `'TRUE'` / `'FALSE'` — not a bit, not an integer. The application
reads it through `vw_WebAppUsers` and casts it with a plain PHP boolean cast in **three** places:

| File | Line | Code |
|---|---|---|
| `app/Auth/SWRHAUserProvider.php` | 172 | `$localUser->is_active = (bool) $sqlUser->IsActive;` |
| `app/Auth/SWRHAUserProvider.php` | 188 | `'is_active' => (bool) $sqlUser->IsActive,` |
| `app/Http/Middleware/EnsureUserIsActive.php` | 68 | `$user->is_active = (bool) ($sqlUser?->IsActive ?? false);` |

In PHP, every non-empty string except `'0'` is truthy. Measured 2026-10-03:

```
(bool) 'TRUE'   => true      (bool) ''      => false
(bool) 'FALSE'  => true   <-- the defect
(bool) 'false'  => true   <-- also
(bool) '0'      => false
```

So `IsActive = 'FALSE'` is read as **active**. The local `users.is_active` mirror is then written
`true`, `AuthenticatedSessionController@store` lets the user in, and `EnsureUserIsActive` never
bounces them. The "Your account has been deactivated." path is unreachable by the only means the
source system has of triggering it.

## 13.2 Why nothing is broken yet

Measured 2026-10-03 on the dev instance:

```sql
SELECT DISTINCT IsActive FROM dbo.[0006AWebAppControls];   -- TRUE  (only value, 3 rows)
SELECT DISTINCT IsActive FROM dbo.[0006CWebAppPostControls]; -- TRUE  (only value)
```

Both tables hold `'TRUE'` and nothing else. **Deactivation has never actually been exercised
against this portal.** That is the whole reason this has gone unnoticed.

One path *does* still work, which is worth knowing because it hides the severity: if a user's row
disappears from `vw_WebAppUsers` entirely, `$sqlUser` is `null` and the `?? false` in
`EnsureUserIsActive` logs them out correctly. So "delete the row" deactivates; "set `IsActive` to
`'FALSE'`" — the intended mechanism, and the one the `0006C` access tables are already filtered on
in SQL — does not.

## 13.3 Why the test suite does not catch it

`tests/Feature/Concerns/FakesExpenseControlDirectory.php` declares the fake column as
`$table->boolean('IsActive')`, and the two deactivation cases in `LoginFlowTest`
(`test_a_deactivated_account_gets_the_deactivated_message_not_a_generic_failure`, line 142, and
`test_deactivation_in_the_directory_is_written_through_to_the_local_mirror`, line 157) pass PHP
`false`. SQLite stores that as the integer `0`, and `(bool) 0` is correctly `false`. **The fake
tests a representation production does not use.** The tests are right about the behaviour and
wrong about the input.

## 13.4 🔴 Correction to the first assessment

When this was first flagged (and in §2.3 and §12.5 above) it was recorded as expensive: *"fixing
it means changing `IsActive` in the test fake, which would break two existing `LoginFlowTest`
cases."*

**That is wrong, and it makes the fix look harder than it is.** `filter_var($v,
FILTER_VALIDATE_BOOLEAN)` handles **both** representations correctly — measured 2026-10-03:

```
'TRUE' => true    'true'  => true    '1' => true    true  => true    1 => true
'FALSE'=> false   'false' => false   '0' => false   false => false   0 => false
''     => false   null    => false
```

So the cast can be corrected **without touching the fake's column type and without changing a
single existing assertion.** The two `LoginFlowTest` cases keep passing exactly as written,
because `filter_var(false, FILTER_VALIDATE_BOOLEAN)` is still `false`.

## 13.5 The fix, when it is picked up

1. Replace the three `(bool)` casts with `filter_var($value, FILTER_VALIDATE_BOOLEAN)`. Put it
   behind one shared helper rather than repeating it three times — the two in
   `SWRHAUserProvider` are already adjacent, and `EnsureUserIsActive` needs the `?? false`
   null-handling preserved (a *missing* row must stay "inactive", while a *failed query* must
   still never deactivate anyone — that outage rule is in `CLAUDE.md` and must not be disturbed).
2. Add test cases passing the **string** `'FALSE'`, which is what production stores. **No schema
   change is needed in the fake**: SQLite is dynamically typed, so a `'FALSE'` string inserts into
   the `boolean`-declared column fine. Mirror the existing two deactivation cases with string
   inputs and keep the boolean ones, so both representations stay covered.
3. Consider asserting the *source* values too, so this cannot silently regress if the source
   system ever switches to `'Y'`/`'N'` or `1`/`0` — `filter_var` returns `false` for `'Y'`, which
   would fail closed (everyone locked out) rather than open. Failing closed is the right
   direction, but it should be a deliberate, tested choice rather than a surprise.

## 13.6 Scope note

This was **not** a regression introduced by the password-change work, and that work did not depend
on it. It shipped as its own change, in its own commit, with its own tests — see §13.7.

While the defect was still open, `DirectoryPasswordService::change()` was given a local
`filter_var` guard so the brand-new write path would not ship with the hole in it. That guard has
since been folded onto the shared helper, so there is one definition rather than two.

## 13.7 As fixed (2026-10-03)

### What was built

**`app/Support/DirectoryFlag.php`** — one static, `isTrue(mixed): bool`, wrapping
`filter_var($value, FILTER_VALIDATE_BOOLEAN)`. All **four** call sites now go through it:

| File | Was |
|---|---|
| `SWRHAUserProvider::syncLocalUser()` | `(bool) $sqlUser->IsActive` |
| `SWRHAUserProvider::createLocalUser()` | `(bool) $sqlUser->IsActive` |
| `EnsureUserIsActive::reverify()` | `(bool) ($sqlUser?->IsActive ?? false)` |
| `DirectoryPasswordService::change()` | its own inline `filter_var` (added while this was open) |

The fourth is the one the original write-up missed: leaving it would have meant two definitions of
the same rule. The `?? false` in the middleware is kept **explicit** — a missing row means the
account was removed upstream, which is a real deactivation, and that must not become an accident
of how `filter_var` happens to treat `null`.

### Confirmed against the live driver

Not just the SQLite fake. Reading `IsActive` through the model on the real instance returns
**`type=string value='TRUE'`**, so the diagnosis was exact and the helper is handling the type
production actually produces:

```
driver returns: type=string value='TRUE'
OLD  (bool) cast   -> true
NEW  DirectoryFlag -> true
OLD  (bool) 'FALSE' -> true   <-- the bug
NEW  DirectoryFlag  -> false
```

### The fake is now production-shaped

`IsActive` in `FakesExpenseControlDirectory` was a SQLite `boolean` defaulting to `true` — a
representation the directory never produces, which is precisely why the suite could not catch
this. **Both tables now declare it `string` defaulting to `'TRUE'`.**

🔴 **The stale comment it carried was wrong, and so was the claim in §12.5 and §2.3 that fixing
this would break two `LoginFlowTest` cases.** It breaks none. `filter_var` resolves the strings,
real booleans and `1`/`0` alike, so the two legacy cases that pass PHP `false` still pass
unchanged. The comment has been removed. Both earlier statements are corrected here; they made a
cheap fix look expensive and are the reason it was deferred at all.

### Tests

- **`tests/Unit/DirectoryFlagTest.php`** *(new, 5 cases, container-free)* — the truth table:
  the strings, case-insensitivity and padding, booleans and ints, fail-closed values, and `'Y'`/
  `'N'`/`'T'`/`'F'` all resolving to false.
- 🔴 **`tests/Feature/Auth/EnsureUserIsActiveTest.php`** *(new, 12 cases)* — **the middleware had
  no test file whatsoever before this.** Every other suite calls
  `withoutMiddleware(EnsureUserIsActive::class)`, so the reverification path — including the
  outage rule `CLAUDE.md` singles out — had never once been executed by a test. Covers: the string
  `'FALSE'` deactivating, `'TRUE'` passing, `'Y'` and `''` failing closed, boolean `false` still
  working, a missing row deactivating, **an outage NOT deactivating**, the outage back-off landing
  at `ttl - retry` so the next request retries, the interval suppressing the query entirely,
  a null timestamp always re-querying, the name resync, and that `active.user` is still on the
  route (so the file cannot pass vacuously).
- **`LoginFlowTest`** — four cases added alongside the boolean ones: `'FALSE'` blocks a first-time
  login and still creates the mirror *inactive*; `'FALSE'` flips an existing active mirror;
  `'TRUE'` permits login; `'Y'` fails closed.

Suite: **332 passed, 7 skipped, 0 failed** (was 311/7 before this change). Pint clean.

### Operational note — SUPERSEDED, see §13.8

This section originally recorded the five-minute window as accepted risk, on the reasoning that
shortening it "costs one directory round trip per page view". **That reasoning was wrong** — the
cost is per USER, not per page view — and the window was shortened to 60 seconds on the same day.
§13.8 has the correction and the measurements.

### Verified end to end against real SQL Server (2026-10-03)

Done on the local instance holding the production-shaped directory, on the user's explicit
instruction, with `IsActive` restored immediately afterwards. This is the one proof SQLite cannot
give, because the whole bug class is about what the **driver** returns.

Setup: `UPDATE dbo.[0006AWebAppControls] SET IsActive = 'FALSE' WHERE LineID = 2`, confirmed
reading `'FALSE'` through `vw_WebAppUsers` too, with the local mirror forced stale
(`sql_server_verified_at = now()-10min`) and still holding `is_active = true` — i.e. exactly the
state the old code sailed through.

| Path | Result |
|---|---|
| **Middleware** — authenticated session requests `/budget-allocations` | Logged out, redirected to `/login`, banner *"Your account has been deactivated. Please contact an administrator."* Under the old `(bool)` cast this request would have rendered the page. |
| Local mirror write-through | `is_active` flipped `true` → `false`, `sql_server_verified_at` refreshed |
| **Login** — correct password, `IsActive = 'FALSE'` | Refused with the **deactivated** banner, and `fieldErrors` empty — no generic "These credentials do not match our records." The user is told the truth rather than left retrying a password that is correct. |
| Restore | `IsActive = 'TRUE'` and the original password put back from the baseline; all three rows byte-identical to the pre-test state; `DirectoryFlag::isTrue('TRUE')` reads `true` |

Not re-tested afterwards by signing in, because the original password was restored from a baseline
held off the repo and then deleted — it is deliberately not known to this session. The row is
identical to its pre-test state and the `'TRUE'`-permits-login path is covered by the suite.

## 13.8 Trust window shortened to 60s, and the flag made strict (2026-10-03)

A follow-up pass over the same area. Three changes, one of which corrects a mistake in §13.7's own
operational note.

### 13.8.1 The window: 300s → 60s, configurable

🔴 **The reasoning in the superseded note was wrong, and the error mattered.** It said shortening
the window "costs one directory round trip per page view". It does not. `sql_server_verified_at`
lives on the **local `users` row**, so the window is bounded **per user** — every session, tab and
request that user has open shares one lookup. At 60s that is at most one directory read per
*active user* per minute, which for this portal is nothing. The five-minute window was priced as
if it were per request, and that is why it had been left alone.

The middleware's own comment said *"once per 5 minutes per session"*. Also wrong, same root cause,
and now corrected — `CLAUDE.md` and `Overview.md` too.

| | Before | After |
|---|---|---|
| Window | 300s, hard-coded constant | `ACTIVE_USER_TTL_SECONDS`, default **60** |
| Outage retry | 60s, hard-coded | `ACTIVE_USER_OUTAGE_RETRY_SECONDS`, default **15** |
| Normalisation | none | `App\Support\ActiveCheckWindow` |

**`ActiveCheckWindow` fails closed in BOTH directions, and the two directions fail differently —
that is the whole reason it exists:**

- A TTL of **0 does not mean "check every request"**. That is not secure-by-default; it is a
  denial of service against an auth server that is remote and shared with other applications. `0`,
  `'0'`, `'00'`, negatives and garbage all fall back to the 60s default.
- A **huge TTL does not mean "never check"** — clamped to `MAX_TTL_SECONDS` (900).
- Below `MIN_TTL_SECONDS` (15) is clamped up, capping the worst case at four reads per user per
  minute.
- `retrySeconds` is clamped to `[1, ttl]`: longer than the window is meaningless, and zero would
  re-query a server already known to be down on every request.
- **There is deliberately no opt-out value.** Unlike the requisition row ceiling, this check cannot
  be switched off from configuration.

### 13.8.2 A latent bug neither review caught: Carbon 3 returns a SIGNED diff

The old test was `$verifiedAt->diffInMinutes(now()) >= 5`. Measured on this project's Carbon:

```
past->diffInMinutes(now)   =  10.00001505
future->diffInMinutes(now) =  -9.9999983     <-- signed
```

So a `sql_server_verified_at` in the **future** — a backwards NTP correction is enough — produced a
negative, which is never `>= 5`, and the user would simply **never be re-verified** until real time
caught up. The replacement compares deadlines instead and treats a future stamp as stale, which is
the fail-closed reading. `test_a_future_timestamp_is_treated_as_stale_not_as_fresh` pins it.

### 13.8.3 `DirectoryFlag` is now a strict allowlist

`filter_var(..., FILTER_VALIDATE_BOOLEAN)` also accepts `'yes'` and `'on'` — values this directory
never stores. For a flag whose job is to switch an account **on**, breadth is only extra ways in,
so the accepted set is now exactly:

- boolean `true`
- integer `1`
- strings `'TRUE'` and `'1'`, case-insensitive, surrounding whitespace trimmed

Everything else is false, including `'yes'`, `'on'`, `'Y'`, `1.0` and `2`. The integer and `'1'`
stay because the SQLite fake and some drivers return those; that is what keeps one helper correct
against both the live directory and the suite.

### 13.8.4 The last `(bool)` on a directory value

`PasswordChangeTest::actingAsDirectoryUser()` still did `(bool) $row['IsActive']`. Harmless while
the fake stored booleans — but the fake now stores production's strings, so a fixture passing
`'FALSE'` would have built an **active** local mirror and silently defeated itself. Now
`DirectoryFlag::isTrue()`.

### 13.8.5 Tests

- **`tests/Unit/ActiveCheckWindowTest.php`** *(new, 11 cases, offline)* — defaults, env strings,
  `0` not meaning "every request", oversize clamped, undersize clamped up, garbage defaulted, retry
  clamped to the window, zero retry defaulted, the backdate arithmetic, and that no value switches
  the check off.
- **`EnsureUserIsActiveTest`** — six added: no query at `ttl - 1s`; revocation lands exactly at
  `ttl`; the window is configurable; a garbage window still revokes rather than trusting forever;
  a future stamp is stale; and an outage does **not** re-query on the very next request. The
  back-off assertion was converted from minutes to seconds (43–47s for a 60/15 window).
- **`DirectoryFlagTest`** — added `'yes'`/`'on'`/`'y'`/`'enabled'` all false, plus floats and `2`.

Suite: **350 passed, 7 skipped, 0 failed** (was 332/7). Pint clean.

### 13.8.6 What this does not change

The **login path is unaffected** and was always immediate — `retrieveByCredentials()` queries the
directory on every attempt regardless of the window. The window only governs how long an
*already-authenticated* session coasts.

### 13.8.7 Verified in a browser against real SQL Server (2026-10-03)

Run with no artificial staleness: the 60s window itself was left to do the work, which is the one
thing the suite can only simulate. Timings are server-side.

1. Container confirmed reading the new config — `ttl_seconds` arrives from env as the **string**
   `'60'` and normalises to int 60, retry 15, backdate 45. (That string path is exactly what
   `ActiveCheckWindowTest::test_it_accepts_numeric_strings_from_env` covers.)
2. `IsActive` set to `'FALSE'` in the directory, then the trust window restarted at **16:45:20**
   with the mirror still reading `is_active = true` — i.e. the state a real revocation produces.
3. 🔴 **At 47s into the window, `/variance` still rendered**, and `sql_server_verified_at` was
   **unchanged** — proving no directory query was issued. This is the half that matters for load:
   the check is not per request.
4. After the window expired, the next request to `/variance` was **logged out with "Your account
   has been deactivated."** and the mirror flipped to `false`.

**Measured latency: 81s** — 60s of window plus the 21s I happened to wait before the next request.
Worth stating precisely because it is a property of the design: the check runs **on request, not
on a timer**, so the real-world lag is `window + time to the user's next page load`. For someone
actively browsing that is ≤60s plus one navigation; for an idle tab it is however long the tab
sits idle, and the revocation lands the moment they touch anything.

Restored afterwards: `IsActive = 'TRUE'`, original password back from a baseline held off the repo
and then deleted, all three rows byte-identical, and the local mirror reset
(`is_active = true`, `sql_server_verified_at = null`) so the next request re-reads the directory
rather than trusting a stamp from the test.

---

# 14. Browser verification (2026-10-03)

Run against the local Docker/Sail stack at **`http://localhost`** (port 80, not the
`APP_URL=http://localhost:8000` in `.env` — that value is stale and only affects generated
absolute URLs). `DIRECTORY_PASSWORD_CHANGE=true`, `sql/GrantPasswordUpdate.sql` applied.

Acting as `FFIGUERA1`, whose password was set to a known test value beforehand and **restored
byte-for-byte afterwards** from a baseline held off the repo. The baseline file was deleted after
the restore; no password value appears in this document or in the session transcript.

## 14.1 What passed

| # | Check | Result |
|---|---|---|
| 1 | Security card renders in the right column under Account Status | ✅ |
| 2 | Footer badge now reads "Account details managed by Finance" | ✅ |
| 3 | Modal opens from the button, chrome matches the legal modals | ✅ |
| 4 | Current-password field is autofocused on open | ✅ focus ring visible |
| 5 | **Escape** closes it | ✅ |
| 6 | **Backdrop click** closes it | ✅ |
| 7 | **Focus returns to the trigger button** on close | ✅ ring visible on the button after both |
| 8 | Wrong current password → field-scoped error, **modal stays open**, fields cleared, focus back on the field | ✅ |
| 9 | Confirmation mismatch → error under the New password field | ✅ |
| 10 | **Non-ASCII** (`pàsswörd1`) → rejected with the character message. The lockout guard. | ✅ |
| 11 | **Disabled while processing** — Cancel and the X both greyed out mid-request | ✅ caught in flight |
| 12 | Success → modal closes, green "Your password has been changed." flash, user **stays signed in** | ✅ |
| 13 | DB: `UserPassword` written; `DATALENGTH = LEN = 12`, so **no encoding expansion** | ✅ |
| 14 | DB: `LastEditedBy` = `FRANCIS FIGUERA` (the display name, matching the directory's own convention), `DateEdited` = today | ✅ |
| 15 | DB: **no collateral writes** — `EmployeeID`, `PositionID`, `IsActive`, `CreatedBy`, `DateCreated` unchanged, and the other two rows untouched | ✅ |
| 16 | Sign out → old password **rejected**, new password **accepted** | ✅ the full round trip |
| 17 | 🔴 **Throttle**: 7th attempt in a minute → `error` flash, **modal stayed open**, and **the typed input survived** (`current_password` 9 chars, `password` 10 chars still in the fields). No 429 error page. | ✅ |
| 18 | **Dark mode** — card, button and modal all render correctly | ✅ |
| 19 | `laravel.log` holds username + outcome only; a grep for all six test password values returns **0 occurrences** | ✅ |

Check 17 is the one that justified the design: without the limiter's `response()` callback and the
modal's `page.props.flash?.error` guard, the user would have been thrown onto a full-page 429 error
screen with everything they typed discarded.

## 14.2 Not verified, and why

- 🔴 **The column-level GRANT was NOT exercised by any of this.** `.env` has
  `SQLSRV_USERNAME=bramkissoon`, and that login is **`sysadmin`** on the dev instance, so it
  bypasses object permissions entirely — every write above would have succeeded with no grant at
  all. What *was* verified is that the grant exists and is correctly narrow: `sys.database_permissions`
  shows `finance` holding `UPDATE` on exactly `UserPassword`, `LastEditedBy`, `DateEdited`,
  `TimeEdited` and **nothing else** on that object. The behavioural half (that those four are
  sufficient and that `IsActive`/`PositionID` are actually blocked) still needs a run as a
  non-sysadmin principal — ideally on production, where the app login is not a sysadmin.
- **`EXECUTE AS USER = 'finance'` could not be used** to close that gap on dev: SQL Server returns
  *"the principal does not exist, this type of principal cannot be impersonated, or you do not have
  permission"*, which usually means an orphaned user or an invalid database owner. Not chased —
  it is a dev-instance quirk, not a property of the change.
- **Narrow viewport is still unverified.** `resize_window` reported success twice but the rendered
  viewport did not change, so no claim is made either way. By inspection the overlay is
  `p-4` + `max-w-lg w-full`, which at 420px gives a 388px panel, and the form body is
  `overflow-y-auto` inside `max-h-[90vh]` — but that is reasoning, not a measurement. **Check it by
  hand in devtools device mode.**

## 14.3 Two observations worth keeping

- **The row had already been edited at 14:26 today, before this run.** The baseline captured at
  the start showed `LastEditedBy = FRANCIS FIGUERA` / `DateEdited = 2026-10-03`, whereas the
  2026-10-02 measurement in §2.3 showed `LastEditedBy` **blank** and `DateEdited = 2026-04-26`. So
  the feature had already been exercised once by hand. The restore returned the row to the state
  found at the start of this run, which is the correct target — but it means `FFIGUERA1`'s stored
  password is no longer the pre-feature value.
- **`TimeEdited` now carries sub-second precision** (`15:09:55.7999153`) because
  `CAST(SYSDATETIME() AS time)` fills the column's full `time(7)` scale, whereas every pre-existing
  row was written at whole-minute precision (`10:52:00`). Harmless and arguably more accurate, but
  it is a visible difference from what the source system writes. Truncate with
  `CAST(SYSDATETIME() AS time(0))` in `editStamp()` if matching the source's granularity matters to
  the finance team.

---

# 15. Outstanding items closed (2026-10-03)

The three items §12.5 and §13 left open, plus one found while closing them.

## 15.1 🔴 Login reported a SQL Server outage as a wrong password

**The real one.** `SWRHAUserProvider::findSqlServerUser()` caught the connection error and returned
`null` — which is indistinguishable from "no such user" — so `Auth::attempt()` failed and the
controller rendered `auth.failed`. **During a database outage, a user with entirely correct
credentials was told their password was wrong.**

Not a security hole; nobody gets in who shouldn't. It is a diagnosis and support-cost failure:
people conclude they have forgotten a password that works, ask for a reset, and — now that
self-service change exists — may try to change a credential that was never broken. It is worse
than it looks because production has **no monitoring**, so this misleading message would be the
only symptom anyone sees of a dead directory.

This is the same defect class §5 refused to accept on the password-change path. The reasoning was
applied there and left standing here.

**Fix.** `App\Exceptions\DirectoryUnavailableException` (new), thrown by the provider instead of
returning `null`, caught by `AuthenticatedSessionController@store`, which flashes *"The sign-in
service is temporarily unavailable. Please try again in a few minutes."* An exception rather than
a flag because `UserProvider::retrieveByCredentials()` returns `?Authenticatable` and a return
value cannot carry the distinction across the Auth facade. (Contrast §12.3 deviation 3, where a
dedicated exception was rejected: there, thrower and catcher were in the same class and a return
value sufficed.)

The username survives on `withInput`, so a retry does not mean retyping it.

🔴 **One existing test's expectation was deliberately inverted.**
`test_a_sql_server_outage_fails_the_login_without_a_500` asserted
`assertSessionHasErrors('username')` — it *locked in* the wrong behaviour. It is now
`test_a_sql_server_outage_is_reported_as_an_outage_not_a_bad_password`, asserting no field errors,
the outage flash, and the preserved input. Two tests were added beside it: a genuine wrong
password must **still** get the generic credential error (otherwise every typo would read as a
system fault), and an unknown username during an outage reports the outage rather than becoming a
user-enumeration oracle.

## 15.2 `TimeEdited` precision — and the reason is sharper than "cosmetic"

`CAST(SYSDATETIME() AS time)` fills the column's full `time(7)`, giving `15:09:55.7999153`, where
every pre-existing row is whole-second (`10:52:00`).

Two reasons to truncate to `time(0)`, the second of which was missed when this was first filed as
cosmetic:

1. The table is owned by another team. Matching the incumbent convention is the conservative
   choice when writing into someone else's schema.
2. 🔴 **The two `editStamp()` branches disagreed, and a test was passing only because of it.**
   `PasswordChangeTest::test_it_stamps_the_audit_columns_with_the_display_name` asserts
   `/^\d{2}:\d{2}:\d{2}$/`. SQLite's `time()` satisfies that; the uncast SQL Server form does not.
   The assertion passed solely because the suite never sees the SQL Server branch.

## 15.3 Narrow viewport — verified, by measurement rather than resizing

`resize_window` reports success but leaves `window.innerWidth` at 1536; three attempts, so it was
abandoned rather than retried further.

Instead: the modal contains **zero** responsive breakpoint classes (verified by enumerating every
`classList` in the subtree). Its width behaviour is therefore pure `max-w-lg w-full` inside `p-4`,
with no media queries, which makes a constrained container a genuine box-model measurement rather
than a simulation.

| Container | Panel | Overflows | H-scroll | Narrowest input | Input clipped |
|---|---|---|---|---|---|
| 1536 | 492 | no | no | 444 | no |
| 430 | 382 | no | no | 334 | no |
| 360 | 315 | no | no | 267 | no |
| 320 | 276 | no | no | 229 | no |

Also rendered at 390×640 and screenshotted: all three fields, wrapped hint text, and both footer
buttons visible and reachable.

**Scope of the claim:** this verifies the *modal*. The page's own `lg:grid-cols-3` reflow is
unverified by it — but that grid predates this work and was not touched; the Security card was
added inside an existing column.

## 15.4 Found while closing the above: a stuck leave transition can block the whole page

Pressing Escape left the overlay **in the DOM at `opacity: 0`** with `display: flex`,
`pointer-events: auto` and `inset-0` — invisible, full-viewport, and intercepting every click.
`document.elementFromPoint()` at the trigger button returned the overlay, not the button.
Reproducible 3/3. Class list showed `modal-enter-from` *and* `modal-leave-active` together: the
transition never completed.

**Cause: the automation harness, not the code.** A `requestAnimationFrame` probe never completed
in 45 seconds — rAF was throttled to a standstill, so nothing painted, CSS transitions could not
advance, and Vue's `<Transition>` never received `transitionend`. A real user needs a comparably
stalled renderer to reach it, and earlier in this same session Escape demonstrably closed the
modal and left the page clickable.

**Fixed anyway**, because the failure mode is a silently unclickable page and the guard is one
rule:

```css
.modal-leave-active,
.modal-leave-to { pointer-events: none; }
```

A dialog on its way out should not swallow clicks regardless, so this is correct independent of
the cause — it just also makes a stuck leave harmless. Applied to **both** `PasswordChangeModal`
and `LegalModal`; the latter has the same markup and is mounted on every page via `FooterBar`, so
it had the same latent exposure.

## 15.5 Result

Suite **352 passed, 7 skipped, 0 failed** (was 350/7). `npm run build` clean, `npm run test:js`
12 passed, Pint clean.

Nothing remains outstanding on the password change except **applying the grant on production**
(`finance_sep_update_deployment.md` Steps 5.8–5.9).
