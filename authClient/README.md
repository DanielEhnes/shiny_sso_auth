# authClient

Shared authentication, DB-backed single sign-on (SSO), and per-app access/permission checks for Shiny apps, against one central identity database. Any Shiny app can depend on this package to authenticate its users and decide what they're allowed to do, without pulling in an admin UI or duplicating login logic.

`accessConsole` (the admin console for managing apps/roles/permissions/groups against this same database) is the first, reference consumer of this package.

## Install

Not on CRAN — install from source:

```r
install.packages("authClient", repos = NULL, type = "source")
```

Dependencies: `shiny`, `DBI`, `digest`, `openssl`, `sodium`, `uuid`.

## Expected database

`authClient` doesn't create or own a database connection — the consuming app creates its own (`DBI`/`pool` connection object) and passes it in explicitly to every function here. It expects the shared identity schema defined in `python/repository/tablestructure_user.py` (kept in sync with the live SQLite file via `Base.metadata.create_all()`):

- `users`, `apps`, `user_app_access`, `group_app_access`, `group_user`, `groups`
- `roles`, `permissions`, `role_permissions`, `user_roles`, `group_roles`
- `sessions` — SSO session store (added by this package's work; call `ensure_sessions_schema(con)` once if you're not applying the Python schema)
- `auth_settings` — DB-level feature toggles (currently just audit logging); call `ensure_auth_settings_schema(con)` similarly
- `auth_audit_log` — presence log, pre-existing table, unused until you turn it on

## Quick start

```r
library(shiny)
library(pool)

con <- dbPool(RSQLite::SQLite(), dbname = "path/to/shared.sqlite", onCreate = function(conn) {
  DBI::dbExecute(conn, "PRAGMA foreign_keys = ON;")
  DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;")  # needed once multiple app processes share the DB
})
authClient::ensure_sessions_schema(con)
authClient::ensure_auth_settings_schema(con)

ui <- fluidPage(
  authClient::authLoginUI("auth"),
  uiOutput("app_body")
)

server <- function(input, output, session) {
  auth <- authClient::authLoginServer("auth", con, require_app_key = "my-app-key")

  output$app_body <- renderUI({
    req(auth$checked())          # wait for the SSO cookie check to resolve
    if (!auth$logged_in()) return(NULL)
    tagList(
      h4(paste("Logged in as", auth$username())),
      if (auth$has_permission("my-app-key", "invoice.delete")) actionButton("del", "Delete invoice"),
      authClient::changePasswordUI("pw")
    )
  })
  authClient::changePasswordServer("pw", con, auth$user_id)
}

shinyApp(ui, server)
```

**Important:** gate real UI on `checked() && logged_in()`, not just `logged_in()` — `checked()` only flips to `TRUE` once the SSO cookie check has actually resolved; skipping it flashes a login form for a frame on every page load.

## SSO mechanics

- The cookie carries `<session_id>.<raw_secret_hex>`. Only a keyed hash of the secret (`HMAC-SHA256`, key = `AUTH_SESSION_SECRET`) is ever stored in the `sessions` table — never the raw value.
- **Every app that should share SSO must be configured with the identical `AUTH_SESSION_SECRET`** (an env var) and point at the same database. Different secrets = tokens nobody else can validate.
- The cookie is written via client-side JS (`document.cookie`), not an HTTP `Set-Cookie` header — Shiny has no supported response-header API for app authors. That means the cookie **cannot be `HttpOnly`**; it's `Secure; SameSite=Lax` instead. `Secure` requires every app to actually be served over HTTPS as the browser sees it, or the cookie write is silently rejected and SSO just won't work.
- Sessions slide on use (default 8h idle timeout), rotate their secret after 30 minutes of inactivity, and are capped at a 30-day absolute lifetime. A stale/mismatched secret just fails that one request — it does **not** revoke the session (an earlier version did; that let a replayed stale cookie kill a legitimate, currently-valid session, a self-inflicted DoS — fixed).
- For real cross-app SSO you need a shared parent domain (e.g. `*.internal.example.com`) so the cookie's `Domain=` scope reaches every app. Unrelated hosts with no shared domain would need a central auth gateway instead — out of scope here.

## API reference

**Login module**
- `authLoginUI(id, cookie_name = "app_sso")`
- `authLoginServer(id, con, session_secret = Sys.getenv("AUTH_SESSION_SECRET"), cookie_name = "app_sso", cookie_domain = NULL, require_app_key = NULL, permission_cache_ttl_secs = 8*3600)` → list with:
  - `logged_in()`, `checked()`, `user_id()`, `username()` — reactives
  - `has_permission(app_key, permission_name)` — cached per session (TTL-bounded, see below), unions direct `user_roles` and group-granted `group_roles`
  - `logout()` — revokes the session, clears the cookie, wipes the permission cache

  `require_app_key = NULL` means "just authenticate, no access gate" (what the console itself uses — any registered user may log in; what they see afterward is a separate, app-specific concern). Any other app should pass its own `app_key` and get gated by `user_has_app_access()`.

**Change password module**
- `changePasswordUI(id)`
- `changePasswordServer(id, con, user_id)` — `user_id` is a reactive (e.g. `auth$user_id`). Revokes all of that user's other sessions on a successful change.

**Identity**
- `authenticate_user(con, username, password)` → `list(ok, user_id, username, reason)`
- `verify_user_password(con, user_id, password)` → `TRUE`/`FALSE`
- `set_user_password(con, user_id, new_password)`

**Access & permissions**
- `user_has_app_access(con, user_id, app_key)` — direct `user_app_access` OR group-granted `group_app_access`
- `user_has_permission(con, user_id, app_key, permission_name)` — direct `user_roles` OR group-granted `group_roles`, scoped to a named permission within one app

**Sessions**
- `ensure_sessions_schema(con)`, `create_session(con, user_id, ...)`, `validate_session(con, cookie_value, ...)`, `revoke_session(con, cookie_value)`, `revoke_all_sessions_for_user(con, user_id)`

**Audit (presence-only, off by default)**
- `ensure_auth_settings_schema(con)`
- `is_audit_log_enabled(con)` / `set_audit_log_enabled(con, enabled)` — one DB-level flag (`auth_settings` table), shared by every app using this package; flip it once, it takes effect everywhere, no per-app config or redeploy needed.
- `log_app_access(con, user_id, app_id, event_type = "app_access")` — called automatically by `authLoginServer` on **both** a fresh login and a cookie-reuse (SSO) event, for whichever app's `require_app_key` was passed. That second path matters: without it, only the first app you password-logged into would ever show up in the log — every other app reached purely via the SSO cookie would go untracked. No-ops silently if logging is disabled.

## Known limitations

- No `HttpOnly` cookie (see above) — mitigated by short expiry, rotation, and DB-side revocation, not eliminated. Don't regress the existing habit of building UI text via `shiny::tags` (auto-escaped) rather than raw `HTML()`.
- `has_permission()`'s cache is a UI-convenience, not a security boundary — a revoked permission can take up to `permission_cache_ttl_secs` (default 8h) to be reflected for a session that never logs out. Re-check anything sensitive at the point of action, uncached.
- Multi-process SQLite contention is a real concern once several app processes validate/rotate sessions against the same file concurrently — `PRAGMA journal_mode = WAL;` (shown above) is the mitigation; make sure every consuming app sets it.
