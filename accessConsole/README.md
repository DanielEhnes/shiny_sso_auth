# accessConsole

The admin console Shiny app for a shared, multi-app identity system: create/delete apps, roles, and permissions; grant/revoke per-app admin rights; manage groups and membership; and control per-user and per-group access and roles for each app. Authentication and SSO are delegated to [`authClient`](../authClient/README.md) — this package owns the admin CRUD and UI, not identity.

## Install

```r
install.packages("accessConsole", repos = NULL, type = "source")
```

Dependencies: `authClient`, `shiny`, `DT`, `DBI`, `pool`, `RSQLite`, `sodium`, `uuid`.

## Run it

```r
Sys.setenv(AUTH_SESSION_SECRET = "some-shared-secret")  # must match every other app sharing SSO
library(accessConsole)
run_admin_console(
  db_path = "path/to/shared.sqlite",
  admin_username = "someadmin",
  admin_email = "someadmin@example.com"
)
```

`run_admin_console()` is the sole entrypoint — it owns the DB pool (`PRAGMA foreign_keys = ON` and `journal_mode = WAL`, the latter needed once multiple app processes share this file via SSO), applies `authClient`'s schema guards, idempotently bootstraps two pseudo-apps (`admin_console`, `groups_admin`) plus the given admin account (default password `"admin"` if the account doesn't already exist — change it via the in-app "Change password" panel), and launches the Shiny app.

`admin_username`/`admin_email` are required, not defaulted — earlier versions defaulted to a specific real person's account, which is exactly the kind of thing you don't want silently baked into a shared package.

## What it does

Every registered user (created via the "Create Account" tab) can log into "Admin" — what they see afterward depends entirely on what they've been granted, via three contexts:

- **Console context** (`admin_console` pseudo-app): create/delete real apps; grant/revoke admin rights on *any* app, including the console itself; disable/enable whole accounts.
- **Groups context** (`groups_admin` pseudo-app): create/delete groups; manage membership. Independently grantable — a console admin can hand someone rights to manage groups without giving them full console access, using the same generic "grant app_admin rights" mechanism as any other app.
- **Regular-app context** (any other app): manage that app's admins (peer-to-peer, no console admin needed), roles, permissions, role↔permission wiring, and per-user/per-group access + roles for that one app.

All destructive actions (delete app/role/permission/group) require retyping the item's key/name in a confirmation modal. Removing the last admin of an app is blocked everywhere it's possible to attempt it — the dedicated "remove admin" flow, and the generic per-user roles checkbox panel (which could otherwise achieve the same thing through a different path).

## Architecture note: why no `con` parameter

Unlike `authClient` (small, written from scratch, takes an explicit `con` on every function), `accessConsole`'s ~50 relocated CRUD functions all close over a package-private connection (`.pkgenv$con`, set once by `run_admin_console()`) instead of taking it as a parameter. Deliberate: this is a single internal tool with ~30 `observeEvent` call sites; threading a connection through every one of those signatures would be a large mechanical diff for little real benefit here. `authClient`'s functions are the ones meant to be called from arbitrary other apps, so they got the more explicit treatment.

## Known pre-existing issues (carried over, not yet fixed)

These existed in the original flat `db_control.R`/`app.R` before the package split and were carried over mechanically rather than fixed silently — worth knowing about if you go looking:

- `is_app_admin()` (`R/db-admins.R`) queries a table (`app_admins`) that doesn't exist in the schema. Currently unused anywhere in the app — dead code, not a live bug, but will error if ever called.
- `get_all_permissions()` (`R/db-permissions.R`) has a SQL typo (`app_id permission_name` — missing comma) that silently drops the real `permission_name` column. Marked `## TODO NOT USED` in the original and still unused by any panel.
- `roles`/`permissions` tables declare `app_id` as `nullable = False`, but the schema docstring (and some now-dead R code) describes a "global roles" concept requiring `app_id IS NULL`. Never reconciled — global roles/permissions don't actually work today.

## Related

- [`authClient`](../authClient/README.md) — identity, SSO, and access/permission checks used by this package (and available to any other Shiny app on the same database).
