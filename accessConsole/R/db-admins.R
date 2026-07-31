get_admin_apps_for_user <- function(user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT ur.user_id, r.role_name, a.app_id, a.app_key, a.name
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.role_id
    JOIN role_permissions rp ON rp.role_id = r.role_id
    JOIN permissions p ON p.permission_id = rp.permission_id
    JOIN apps a ON r.app_id = a.app_id
    WHERE ur.user_id = ?
    AND p.permission_name = ?
    ORDER BY a.name
  ", params = list(user_id, 'admin'))
}

grant_app_admin <- function(user_id, app_id, granted_by) {
  existing <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n
    FROM apps a
    JOIN roles r ON a.app_id = r.app_id
    JOIN user_roles ur ON r.role_id = ur.role_id
    JOIN role_permissions rp ON ur.role_id = rp.role_id
    JOIN permissions p ON rp.permission_id = p.permission_id
    WHERE ur.user_id = ?
    AND a.app_id = ?
    AND p.permission_name = ?", params = list(user_id, app_id, "admin"))$n
  if (existing == 0) {
    role_id <- get_app_admin_role(app_id)
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO user_roles (user_id, role_id, granted_by) VALUES (?, ?, ?)
    ", params = list(user_id, role_id, granted_by))
  }
}

get_app_admins <- function(app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT u.user_id, u.email
    FROM roles r
    JOIN user_roles ur ON r.role_id = ur.role_id
    JOIN users u ON u.user_id = ur.user_id
    JOIN role_permissions rp ON r.role_id = rp.role_id
    JOIN permissions p ON rp.permission_id = p.permission_id
    WHERE r.app_id = ?
    AND p.permission_name = ?
    ORDER BY u.email
  ", params = list(app_id, 'admin'))
}

is_app_admin <- function(user_id, app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM app_admins WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))$n > 0
}

get_app_admin_role <- function(app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT r.role_id
    FROM roles r
    JOIN role_permissions rp ON rp.role_id = r.role_id
    JOIN permissions p ON p.permission_id = rp.permission_id
    WHERE r.app_id = ?
    AND p.permission_name = ?
  ", params = list(app_id, 'admin'))$role_id
}

revoke_app_admin <- function(user_id, app_id) {
  role_id <- get_app_admin_role(app_id)
  DBI::dbExecute(.pkgenv$con, "DELETE FROM user_roles WHERE user_id = ? AND role_id = ?", params = list(user_id, role_id))
}

check_if_last_admin <- function(app_id) {
  role_id <- get_app_admin_role(app_id)
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM user_roles WHERE role_id = ?", params = list(role_id))$n
}
