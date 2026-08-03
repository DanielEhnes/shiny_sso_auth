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
#' @details Also idempotently ensures a `basic_user` group exists, backfills
#'   every existing user into it (so upgrading an existing database doesn't
#'   lock anyone out once console login is access-gated), and -- only the
#'   first time, same non-overriding pattern as `audit_log_enabled` -- grants
#'   that group access to the console app.
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

  activity_admin_app_id <- get_activity_admin_app_id()
  if (length(activity_admin_app_id) == 0 || is.na(activity_admin_app_id)) {
    activity_admin_app_id <- create_app(ACTIVITY_ADMIN_KEY, "User Activity", "Read-only presence-activity view across all apps, derived from the audit log.")
    permission_id <- create_permission("admin", "App Admin Role for User Activity App", activity_admin_app_id)
    role_id <- create_role(paste0(ACTIVITY_ADMIN_KEY, "_admin"), "Admin Role for User Activity App", activity_admin_app_id)
    set_role_permissions(role_id, c(permission_id))
  }

  if (!email_exists(admin_email)) {
    create_user(username = admin_username, email = admin_email, password = admin_password)
  }
  admin_user_id <- get_user_id(admin_username)

  grant_app_admin(admin_user_id, console_app_id, admin_user_id)
  grant_app_admin(admin_user_id, groups_admin_app_id, admin_user_id)
  grant_app_admin(admin_user_id, activity_admin_app_id, admin_user_id)

  audit_setting_exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM auth_settings WHERE setting_key = 'audit_log_enabled'
  ")$n > 0
  if (!audit_setting_exists) {
    authClient::set_audit_log_enabled(.pkgenv$con, audit_log_enabled)
  }

  if (!group_key_exists(BASIC_USER_GROUP_KEY)) {
    create_group(BASIC_USER_GROUP_KEY, "Basic Users", "Automatically granted to every created user.")
  }
  basic_group_id <- get_group_id(BASIC_USER_GROUP_KEY)

  # Backfill: anyone created before this group existed -- including on an
  # upgrade of an existing database -- still needs to be a member, or
  # gating console login on admin_console access would lock them out.
  DBI::dbExecute(.pkgenv$con, "
    INSERT INTO group_user (group_id, user_id)
    SELECT ?, u.user_id FROM users u
    WHERE NOT EXISTS (SELECT 1 FROM group_user gu WHERE gu.group_id = ? AND gu.user_id = u.user_id)
  ", params = list(basic_group_id, basic_group_id))

  if (identical(get_group_app_access_status(basic_group_id, console_app_id), "none")) {
    set_group_app_access_for_app(basic_group_id, console_app_id, TRUE)
  }

  invisible(admin_user_id)
}
