/*  =====================================================================
    Rollback for sql/GrantPasswordUpdate.sql.

    Removes the application login's ability to write any column of
    dbo.0006AWebAppControls, returning that table to read-only for this
    project — which is the state every other pre-existing object on the
    server is in.

    THIS IS THE SECOND-LINE ROLLBACK, NOT THE FIRST. Prefer the config
    kill switch, which needs no DBA and no redeploy:

        DIRECTORY_PASSWORD_CHANGE=false
        php artisan config:clear

    Revoking is safe to combine with that, and fails closed on its own:
    DirectoryPasswordService catches the resulting permission error and
    turns it into "your password could not be changed right now", not a
    500 page. Passwords already changed are NOT reverted by this script —
    restore those from the baseline captured in step 3 of the grant.
    =====================================================================  */

USE SWRHAExpenseControl;
GO

REVOKE UPDATE (UserPassword, LastEditedBy, DateEdited, TimeEdited)
    ON OBJECT::dbo.[0006AWebAppControls]
    FROM [finance];
GO

/*  Verify: every column must now come back 0.

    🔴 FIXED 2026-10-06 — THE ARGUMENTS WERE REVERSED (column NAME is 4th,
       the literal 'COLUMN' is 5th). Measured: the old order returned NULL
       from every call.

       THAT WAS MORE DANGEROUS HERE THAN IN THE GRANT SCRIPT. A revoke
       check looks for 0, and NULL is "not 1" at a glance - so this block
       appeared to confirm a successful REVOKE whether or not the revoke
       had done anything. The grant script's version at least failed
       visibly, because it was looking for a 1 it could never get.

    🔴 Run this AS THE APPLICATION'S LOGIN. HAS_PERMS_BY_NAME reports the
       CURRENT connection's rights; as dbo/sysadmin every column returns 1
       no matter what was revoked. Use EXECUTE AS USER = N'<app user>' ...
       REVERT, or rely on the explicit-grantee query below, which needs no
       impersonation.  */

SELECT  HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'UserPassword', 'COLUMN') AS must_be_zero_password,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'LastEditedBy', 'COLUMN') AS must_be_zero_editor,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'DateEdited',   'COLUMN') AS must_be_zero_date,
        HAS_PERMS_BY_NAME('dbo.0006AWebAppControls', 'OBJECT', 'UPDATE', 'TimeEdited',   'COLUMN') AS must_be_zero_time;
GO

SELECT  p.permission_name,
        p.state_desc,
        c.name AS column_name
FROM    sys.database_permissions AS p
LEFT JOIN sys.columns AS c
       ON c.object_id = p.major_id
      AND c.column_id = p.minor_id
WHERE   p.major_id = OBJECT_ID('dbo.[0006AWebAppControls]')
  AND   p.grantee_principal_id = DATABASE_PRINCIPAL_ID('finance');
GO
