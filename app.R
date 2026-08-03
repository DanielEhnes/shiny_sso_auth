# Deployment entrypoint -- some hosting platforms require a literal app.R
# at the app's root that gets auto-run. This just loads the packaged
# console (see authClient/ and accessConsole/) and starts it; there is no
# other app logic here on purpose.
#
# Configure via environment variables on the deployment platform. The
# values below are placeholders -- either edit them directly for this
# deployment, or (better, so secrets/identity aren't hardcoded into a
# checked-in script) set the corresponding env vars on the server and
# leave this file as-is.

library(accessConsole)

run_admin_console(
  db_path           = Sys.getenv("DB_PATH", unset = "/path/to/persistent/users_database.sqlite"),
  admin_username    = Sys.getenv("ADMIN_USERNAME", unset = "admin"),
  admin_email       = Sys.getenv("ADMIN_EMAIL", unset = "admin@example.com"),
  audit_log_enabled = as.logical(Sys.getenv("AUDIT_LOG_ENABLED", unset = "FALSE"))
)
# session_secret is intentionally not set here -- it defaults to
# Sys.getenv("AUTH_SESSION_SECRET") inside run_admin_console(), and
# authClient already errors clearly if that's missing rather than
# silently falling back to a weak secret. Set AUTH_SESSION_SECRET on the
# server; every other app sharing SSO with this one must use the same
# value.
