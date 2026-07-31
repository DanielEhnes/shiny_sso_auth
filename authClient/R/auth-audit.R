# Presence-only audit logging: "did this user use this app", not duration
# or what they did with it. Controlled centrally in the DB (auth_settings),
# not per-app code -- every app using authClient checks the same row, so
# flipping it once turns logging on/off everywhere at once.

#' Ensure the auth_settings table exists
#'
#' @param con A DBI connection or pool object.
#' @return Invisibly `NULL`.
#' @export
ensure_auth_settings_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS auth_settings (
      setting_key TEXT PRIMARY KEY,
      setting_value TEXT
    )
  ")
  invisible(NULL)
}

#' Check whether presence audit logging is enabled
#'
#' Reads a single DB-level flag (the `auth_settings` table), shared by
#' every app using authClient against this database -- flipping it with
#' [set_audit_log_enabled()] takes effect everywhere at once, with no
#' per-app configuration or redeploy needed.
#'
#' @param con A DBI connection or pool object.
#' @return `TRUE`/`FALSE`. Defaults to `FALSE` if the setting hasn't been
#'   set yet.
#' @export
is_audit_log_enabled <- function(con) {
  row <- DBI::dbGetQuery(con, "SELECT setting_value FROM auth_settings WHERE setting_key = 'audit_log_enabled'")
  if (nrow(row) == 0) return(FALSE)
  identical(tolower(trimws(row$setting_value[1])), "true")
}

#' Enable or disable presence audit logging
#'
#' @param con A DBI connection or pool object.
#' @param enabled `TRUE` to enable, `FALSE` to disable.
#' @return Invisibly `NULL`.
#' @export
set_audit_log_enabled <- function(con, enabled) {
  value <- if (isTRUE(enabled)) "true" else "false"
  exists <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM auth_settings WHERE setting_key = 'audit_log_enabled'")$n > 0
  if (exists) {
    DBI::dbExecute(con, "UPDATE auth_settings SET setting_value = ? WHERE setting_key = 'audit_log_enabled'", params = list(value))
  } else {
    DBI::dbExecute(con, "INSERT INTO auth_settings (setting_key, setting_value) VALUES ('audit_log_enabled', ?)", params = list(value))
  }
  invisible(NULL)
}

#' Record that a user accessed an app
#'
#' Presence-only: records *that* `user_id` used `app_id`, not what they did
#' or for how long. No-ops silently when logging is disabled -- callers
#' don't need to check [is_audit_log_enabled()] themselves first.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param app_id The app's ID (not `app_key` -- callers typically already
#'   have this resolved).
#' @param event_type A short label for the event.
#' @return Invisibly `TRUE`/`FALSE` (whether a row was written).
#' @export
log_app_access <- function(con, user_id, app_id, event_type = "app_access") {
  if (!is_audit_log_enabled(con)) return(invisible(FALSE))
  DBI::dbExecute(con, "
    INSERT INTO auth_audit_log (user_id, app_id, event_type) VALUES (?, ?, ?)
  ", params = list(user_id, app_id, event_type))
  invisible(TRUE)
}
