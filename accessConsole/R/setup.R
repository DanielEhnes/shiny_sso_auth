#' Idempotently seed the console/groups pseudo-apps and a bootstrap admin
#'
#' Safe to call on every startup: only creates what's missing. Called
#' automatically by [run_admin_console()].
#'
#' @param admin_username Username for the bootstrap admin account.
#' @param admin_email Email for the bootstrap admin account.
#' @param admin_password Password for the bootstrap admin account if it
#'   doesn't already exist. Defaults to `"admin"` -- change it via the
#'   in-app "Change password" panel after first login.
#' @param audit_log_enabled Whether presence audit logging
#'   (`authClient::log_app_access()`) should start out enabled. Only
#'   applied the first time this is called against a given database --
#'   once the `auth_settings` row exists, this argument is ignored, so a
#'   later manual `authClient::set_audit_log_enabled()` call (or a console
#'   admin toggling it) is never silently overwritten by a subsequent
#'   restart.
#' @return Invisibly, the bootstrap admin's user ID.
#' @export
run_initial_setup <- function(admin_username, admin_email, admin_password = "admin",
                               audit_log_enabled = FALSE) {
  console_app_id <- get_admin_console_app_id()
  if (length(console_app_id) == 0 || is.na(console_app_id)) {
    console_app_id <- create_app(ADMIN_CONSOLE_KEY, "Admin Console", "Die App, die Zugaenge usw fuer andere apps administriert.")
    permission_id <- create_permission("admin", "App Admin Role for Admin Console App", console_app_id)
    role_id <- create_role(paste0(ADMIN_CONSOLE_KEY, "_admin"), "Admin Role for Admin Console App", console_app_id)
    set_role_permissions(role_id, c(permission_id))
  }

  groups_admin_app_id <- get_groups_admin_app_id()
  if (length(groups_admin_app_id) == 0 || is.na(groups_admin_app_id)) {
    groups_admin_app_id <- create_app(GROUPS_ADMIN_KEY, "Groups Management", "Verwaltung von Gruppen und deren Mitgliedern (nur Mitgliedschaft, kein App-Zugriff).")
    permission_id <- create_permission("admin", "App Admin Role for Groups Management App", groups_admin_app_id)
    role_id <- create_role(paste0(GROUPS_ADMIN_KEY, "_admin"), "Admin Role for Groups Management App", groups_admin_app_id)
    set_role_permissions(role_id, c(permission_id))
  }

  if (!email_exists(admin_email)) {
    create_user(username = admin_username, email = admin_email, password = admin_password)
  }
  admin_user_id <- get_user_id(admin_username)

  grant_app_admin(admin_user_id, console_app_id, admin_user_id)
  grant_app_admin(admin_user_id, groups_admin_app_id, admin_user_id)

  audit_setting_exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM auth_settings WHERE setting_key = 'audit_log_enabled'
  ")$n > 0
  if (!audit_setting_exists) {
    authClient::set_audit_log_enabled(.pkgenv$con, audit_log_enabled)
  }

  invisible(admin_user_id)
}
