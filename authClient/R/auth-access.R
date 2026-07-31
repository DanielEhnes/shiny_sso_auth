# Not exported -- shared by every function here (and by audit logging in
# mod-login.R) that needs to turn an app_key into its app_id.
.resolve_app_id <- function(con, app_key) {
  DBI::dbGetQuery(con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(app_key))$app_id
}

#' Check whether a user has access to an app
#'
#' Unions direct per-user grants (`user_app_access`) with grants via group
#' membership (`group_app_access`).
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param app_key The app's `app_key`.
#' @return `TRUE`/`FALSE`.
#' @export
user_has_app_access <- function(con, user_id, app_key) {
  app_id <- .resolve_app_id(con, app_key)
  if (length(app_id) == 0) return(FALSE)

  direct <- DBI::dbGetQuery(con, "
    SELECT status FROM user_app_access WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))
  if (nrow(direct) > 0 && identical(direct$status[1], "active")) return(TRUE)

  DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM group_user gu
    JOIN group_app_access ga ON ga.group_id = gu.group_id
    WHERE gu.user_id = ? AND ga.app_id = ? AND ga.status = 'active'
  ", params = list(user_id, app_id))$n > 0
}

#' Check whether a user holds a specific permission within an app
#'
#' Finer-grained than [user_has_app_access()] -- checks a named permission,
#' again unioning direct role assignment (`user_roles`) with group-granted
#' roles (`group_roles`). Meant for UI-level decisions like "should this
#' tab/button be visible", not as the sole authorization check for anything
#' sensitive -- see [authLoginServer()]'s cached `has_permission()`.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param app_key The app's `app_key`.
#' @param permission_name The permission to check, e.g. `"invoice.delete"`.
#' @return `TRUE`/`FALSE`.
#' @export
user_has_permission <- function(con, user_id, app_key, permission_name) {
  app_id <- .resolve_app_id(con, app_key)
  if (length(app_id) == 0) return(FALSE)

  direct <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n
    FROM user_roles ur
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.permission_id = rp.permission_id
    WHERE ur.user_id = ? AND p.app_id = ? AND p.permission_name = ?
  ", params = list(user_id, app_id, permission_name))$n > 0
  if (direct) return(TRUE)

  DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n
    FROM group_user gu
    JOIN group_roles gr ON gr.group_id = gu.group_id
    JOIN role_permissions rp ON rp.role_id = gr.role_id
    JOIN permissions p ON p.permission_id = rp.permission_id
    WHERE gu.user_id = ? AND p.app_id = ? AND p.permission_name = ?
  ", params = list(user_id, app_id, permission_name))$n > 0
}
