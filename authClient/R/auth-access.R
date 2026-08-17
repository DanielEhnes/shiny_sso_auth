# Not exported -- shared by every function here (and by audit logging in
# mod-login.R) that needs to turn an app_key into its app_id.
.resolve_app_id <- function(con, app_key) {
  DBI::dbGetQuery(con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(app_key))$app_id
}

#' Check whether a user has access to an app
#'
#' Unions direct per-user grants (`user_app_access`) with grants via group
#' membership (`group_app_access`). A grant with `valid_from`/`valid_until`
#' set only counts while the current time falls inside that window --
#' evaluated live on every call, not by a background job that flips
#' `status`, so an expired or not-yet-started grant is excluded instantly
#' with no lag either side of the boundary.
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
    SELECT 1 FROM user_app_access
    WHERE user_id = ? AND app_id = ? AND status = 'active'
      AND (valid_from IS NULL OR valid_from <= datetime('now'))
      AND (valid_until IS NULL OR valid_until >= datetime('now'))
  ", params = list(user_id, app_id))
  if (nrow(direct) > 0) return(TRUE)

  DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM group_user gu
    JOIN group_app_access ga ON ga.group_id = gu.group_id
    WHERE gu.user_id = ? AND ga.app_id = ? AND ga.status = 'active'
      AND (ga.valid_from IS NULL OR ga.valid_from <= datetime('now'))
      AND (ga.valid_until IS NULL OR ga.valid_until >= datetime('now'))
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

#' Get a user's organizational unit
#'
#' Organizational units are ordinary groups flagged `group_type =
#' 'org_unit'` (by `accessConsole`'s Groups Management panel) -- exclusive
#' by convention (at most one per user, enforced by whoever writes
#' `group_user`, not by this function), unlike regular multi-membership
#' groups. Queries `groups`/`group_user` directly rather than depending on
#' `accessConsole`, the same layering already used by
#' [user_has_app_access()] for `group_app_access`.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param group_type The group type to look for. Defaults to `"org_unit"`.
#' @return A list with `group_key` and `name`, or `NULL` if the user has no
#'   group of this type.
#' @export
get_user_org_unit <- function(con, user_id, group_type = "org_unit") {
  row <- DBI::dbGetQuery(con, "
    SELECT g.group_key, g.name
    FROM group_user gu JOIN groups g ON g.group_id = gu.group_id
    WHERE gu.user_id = ? AND g.group_type = ?
  ", params = list(user_id, group_type))
  if (nrow(row) == 0) return(NULL)
  list(group_key = row$group_key[1], name = row$name[1])
}

#' Check whether a user belongs to a given group
#'
#' Generic membership check by `group_key` -- deliberately not specific to
#' any one concept (org units, "team leads", or anything else). Any group
#' an admin creates via `accessConsole`'s existing Groups Management panel
#' (ordinary `create_group()`/`add_user_to_group()`, no special setup)
#' already works with this -- e.g. a plain "team_leads" group, checked
#' with `user_is_in_group(con, user_id, "team_leads")`, needs no schema or
#' admin-UI changes of its own.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param group_key The group's `group_key`.
#' @return `TRUE`/`FALSE`.
#' @export
user_is_in_group <- function(con, user_id, group_key) {
  DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM group_user gu
    JOIN groups g ON g.group_id = gu.group_id
    WHERE gu.user_id = ? AND g.group_key = ?
  ", params = list(user_id, group_key))$n > 0
}
