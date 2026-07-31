create_role <- function(role_name, description, app_id) {
  role_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "INSERT INTO roles (role_id, app_id, role_name, description) VALUES (?, ?, ?, ?)", params = list(role_uuid, app_id, role_name, description))
  return(role_uuid)
}

get_roles_for_app <- function(app_id) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT role_id, role_name, description FROM roles WHERE app_id = ? ORDER BY role_name", params = list(app_id))
}

get_all_roles <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT role_id, role_name, description FROM roles ORDER BY role_name")
}

role_name_exists <- function(app_id, role_name) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT COUNT(*) AS n FROM roles WHERE app_id = ? AND role_name = ?", params = list(app_id, role_name))$n > 0
}

# Cascades (via ON DELETE CASCADE on role_permissions/user_roles/group_roles)
# to remove this role's permission wiring and unassign it from every
# user/group. Refuses to delete an app's admin role -- that would break
# grant_app_admin/revoke_app_admin/check_if_last_admin for that app.
delete_role <- function(role_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "SELECT app_id FROM roles WHERE role_id = ?", params = list(role_id))
  if (nrow(row) == 0) stop("Role not found.")
  if (role_id %in% get_app_admin_role(row$app_id[1])) {
    stop("Refusing to delete this app's admin role.")
  }
  DBI::dbExecute(.pkgenv$con, "DELETE FROM roles WHERE role_id = ?", params = list(role_id))
}
