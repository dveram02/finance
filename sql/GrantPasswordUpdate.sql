/*  =====================================================================
    SWRHA Finance Portal — self-service password change
    Grants the application login the ability to rewrite a user's own
    password in the staff directory.

    READ THIS BEFORE RUNNING.

    dbo.0006AWebAppControls belongs to the SWRHAExpenseControl system, NOT
    to this project. Everything else in that database stays read-only to
    this application, and this script is the single, named exception. It
    needs WRITTEN sign-off from the owner of SWRHAExpenseControl and from
    the DBA before it is applied — what is being granted is the ability
    for a web application to rewrite stored credentials that other
    systems also read.

    The grant is COLUMN-LEVEL on purpose. Do not "simplify" it to a
    table-level GRANT UPDATE: nothing is simplified, and the blast radius
    of a bug would then include PositionID, which is the access-control
    key that vw_WebAppUserAccess joins on to decide whose departmental
    money a user can see. Writing it would be a privilege escalation.

    SELECT is already covered by db_datareader, which the WHERE LineID = ?
    predicate needs.

    Rollback: sql/GrantPasswordUpdateRollback.sql
    Design and rationale: passwordreset.md
    =====================================================================  */

USE SWRHAExpenseControl;
GO

/*  ---------------------------------------------------------------------
    0. Confirm the principal before granting anything.

    Dev measured 2026-10-02: the application login is [finance], a
    SQL_USER holding db_datareader and nothing else. VERIFY production's
    SQLSRV_USERNAME matches before you run step 1 — granting to the wrong
    principal is silent.
    ---------------------------------------------------------------------  */

SELECT  dp.name,
        dp.type_desc,
        STRING_AGG(r.name, ', ') AS roles
FROM    sys.database_principals AS dp
LEFT JOIN sys.database_role_members AS rm ON rm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals  AS r  ON r.principal_id = rm.role_principal_id
WHERE   dp.name = N'finance'
GROUP BY dp.name, dp.type_desc;
GO

/*  ---------------------------------------------------------------------
    1. The grant itself — four columns, no more.
    ---------------------------------------------------------------------  */

GRANT UPDATE (UserPassword, LastEditedBy, DateEdited, TimeEdited)
    ON OBJECT::dbo.[0006AWebAppControls]
    TO [finance];
GO

/*  ---------------------------------------------------------------------
    2. Verify. `must_be_zero` coming back as 1 means someone granted at
       table level by mistake — stop, REVOKE, and re-run step 1.

    🔴 FIXED 2026-10-06 — THE ARGUMENTS WERE REVERSED. For a column-level
       check the column NAME is the 4th argument and the literal 'COLUMN'
       the 5th. This block previously passed 'COLUMN' 4th and the column
       name 5th, and MEASURED CONSEQUENCE: every call returned NULL - not
       1, not 0 - so `can_write_password` could never read 1 and the
       verification could never pass. Do not "tidy" the order back.

    🔴 AND IT ONLY MEANS ANYTHING RUN AS THE APPLICATION'S LOGIN.
       HAS_PERMS_BY_NAME reports the CURRENT connection's rights. Measured
       as dbo on the dev instance with the order corrected: ALL FOUR
       returned 1, including the two that must read 0 - which reads as
       "someone granted at table level, stop and REVOKE" when nothing is
       wrong. Connect as the app's SQLSRV_USERNAME, or wrap this in
       EXECUTE AS USER = N'<that user>' ... REVERT.

       The query in section 3 below needs no impersonation - it names the
       grantee explicitly - so prefer it when in any doubt.
    ---------------------------------------------------------------------  */

SELECT  HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'UserPassword', 'COLUMN') AS can_write_password,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'LastEditedBy', 'COLUMN') AS can_write_editor,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'IsActive',     'COLUMN') AS must_be_zero,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'PositionID',   'COLUMN') AS must_also_be_zero;
GO

SELECT  p.permission_name,
        p.state_desc,
        c.name AS column_name
FROM    sys.database_permissions AS p
LEFT JOIN sys.columns AS c
       ON c.object_id = p.major_id
      AND c.column_id = p.minor_id
WHERE   p.major_id = OBJECT_ID('dbo.[0006AWebAppControls]')
  AND   p.grantee_principal_id = DATABASE_PRINCIPAL_ID('finance')
ORDER BY c.name;
GO

/*  ---------------------------------------------------------------------
    3. Baseline, to be captured BEFORE the first production change.

       Script the output to a file held OFF the database server. It is the
       restore path for a mangled password, there are only three rows, and
       it costs nothing. Note that restoring the whole database from a
       nightly backup silently reverts every password changed since —
       mention that to the DBA.
    ---------------------------------------------------------------------  */

-- SELECT LineID, UserName, UserPassword, LastEditedBy, DateEdited, TimeEdited
-- FROM   dbo.[0006AWebAppControls]
-- ORDER  BY LineID;
