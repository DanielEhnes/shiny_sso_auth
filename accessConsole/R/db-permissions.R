create_permission <- function(permission_name, description, app_id) {
  permission_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "
    INSERT INTO permissions (permission_id, app_id, permission_name, description) VALUES (?, ?, ?, ?)
  ", params = list(permission_uuid, app_id, permission_name, description))
  return(permission_uuid)
}

get_admin_permission_for_app <- function(app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT permission_id FROM permissions WHERE app_id = ? AND permission_name = ?
  ", params = list(app_id, "admin"))
}

get_all_permissions <- function() {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT permission_id, app_id permission_name, description FROM permissions ORDER BY permission_name
  ")
}

get_permissions_for_app <- function(app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT permission_id, permission_name, description FROM permissions WHERE app_id = ? ORDER BY permission_name
  ", params = list(app_id))
}

permission_name_exists <- function(app_id, permission_name) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM permissions WHERE app_id = ? AND permission_name = ?
  ", params = list(app_id, permission_name))$n > 0
}

# Cascades (via ON DELETE CASCADE on role_permissions) to unassign this
# permission from every role. Refuses to delete an app's "admin"
# permission -- that would break the app's admin role/rights.
delete_permission <- function(permission_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "SELECT permission_name FROM permissions WHERE permission_id = ?", params = list(permission_id))
  if (nrow(row) == 0) stop("Permission not found.")
  if (identical(row$permission_name[1], "admin")) {
    stop("Refusing to delete this app's admin permission.")
  }
  DBI::dbExecute(.pkgenv$con, "DELETE FROM permissions WHERE permission_id = ?", params = list(permission_id))
}

set_role_permissions <- function(role_id, permission_ids) {
  pool::poolWithTransaction(.pkgenv$con, function(conn) {
    DBI::dbExecute(conn, "DELETE FROM role_permissions WHERE role_id = ?", params = list(role_id))
    for (pid in permission_ids) {
      DBI::dbExecute(conn, "INSERT INTO role_permissions (role_id, permission_id) VALUES (?, ?)", params = list(role_id, pid))
    }
  })
}

get_role_permission_ids <- function(role_id) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT permission_id FROM role_permissions WHERE role_id = ?", params = list(role_id))$permission_id
}
