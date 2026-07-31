# Replaces R/app.R + R/initial_setup.R's old top-level
# db_pool <- dbPool(...) / onStop(...) / source("db_control.R") -- those ran
# at *source* time against a hardcoded relative path, which doesn't work
# once this is a package (loaded once, no active Shiny session yet, and no
# guarantee about the process's cwd). Everything now happens inside this
# exported entrypoint instead.
#' Run the admin console Shiny app
#'
#' Sole entrypoint for the console: owns the database pool, applies
#' authClient's schema guards, idempotently bootstraps the console and
#' groups pseudo-apps plus the given admin account, and launches the app.
#'
#' @param db_path Path to the shared SQLite database file.
#' @param admin_username Username for the bootstrap admin account.
#' @param admin_email Email for the bootstrap admin account.
#' @param host Host to bind the Shiny server to.
#' @param port Port to bind the Shiny server to, or `NULL` to let Shiny
#'   pick one.
#' @param session_secret Shared HMAC key for SSO sessions; must match every
#'   other app sharing SSO. Defaults to the `AUTH_SESSION_SECRET`
#'   environment variable.
#' @param audit_log_enabled Whether presence audit logging should start
#'   out enabled. Only takes effect the first time this is run against a
#'   given database -- see [run_initial_setup()].
#' @return A `shiny::shinyApp()` object.
#' @export
run_admin_console <- function(db_path, admin_username, admin_email, host = "127.0.0.1", port = NULL,
                               session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                               audit_log_enabled = FALSE) {
  .pkgenv$con <- pool::dbPool(RSQLite::SQLite(), dbname = db_path, onCreate = function(conn) {
    DBI::dbExecute(conn, "PRAGMA foreign_keys = ON;")
    DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;")
  })
  ensure_core_schema(.pkgenv$con)
  authClient::ensure_sessions_schema(.pkgenv$con)
  authClient::ensure_auth_settings_schema(.pkgenv$con)
  shiny::onStop(function() pool::poolClose(.pkgenv$con))

  run_initial_setup(admin_username, admin_email, audit_log_enabled = audit_log_enabled)

  shiny::shinyApp(build_console_ui(), build_console_server(), options = list(host = host, port = port))
}
