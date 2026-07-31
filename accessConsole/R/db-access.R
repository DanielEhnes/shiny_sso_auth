set_user_app_access_for_app <- function(user_id, app_id, granted) {
  exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM user_app_access WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))$n

  if (exists == 0) {
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO user_app_access (user_id, app_id, status) VALUES (?, ?, ?)
    ", params = list(user_id, app_id, if (granted) "active" else "revoked"))
  } else {
    DBI::dbExecute(.pkgenv$con, "
      UPDATE user_app_access SET status = ? WHERE user_id = ? AND app_id = ?
    ", params = list(if (granted) "active" else "revoked", user_id, app_id))
  }
}

get_user_app_access_status <- function(user_id, app_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT status FROM user_app_access WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))
  if (nrow(row) == 0) "none" else row$status[1]
}

set_group_app_access_for_app <- function(group_id, app_id, granted) {
  exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM group_app_access WHERE group_id = ? AND app_id = ?
  ", params = list(group_id, app_id))$n

  if (exists == 0) {
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO group_app_access (group_id, app_id, status) VALUES (?, ?, ?)
    ", params = list(group_id, app_id, if (granted) "active" else "revoked"))
  } else {
    DBI::dbExecute(.pkgenv$con, "
      UPDATE group_app_access SET status = ? WHERE group_id = ? AND app_id = ?
    ", params = list(if (granted) "active" else "revoked", group_id, app_id))
  }
}

get_group_app_access_status <- function(group_id, app_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT status FROM group_app_access WHERE group_id = ? AND app_id = ?
  ", params = list(group_id, app_id))
  if (nrow(row) == 0) "none" else row$status[1]
}

set_user_roles_for_app <- function(user_id, app_id, role_ids) {
  pool::poolWithTransaction(.pkgenv$con, function(conn) {
    DBI::dbExecute(conn, "
      DELETE FROM user_roles
      WHERE user_id = ?
      AND role_id IN (SELECT role_id FROM roles WHERE app_id = ?)
    ", params = list(user_id, app_id))
    for (rid in role_ids) {
      DBI::dbExecute(conn, "INSERT INTO user_roles (user_id, role_id) VALUES (?, ?)", params = list(user_id, rid))
    }
  })
}

get_user_role_ids_for_app <- function(user_id, app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT ur.role_id FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id
    WHERE ur.user_id = ? AND r.app_id = ?
  ", params = list(user_id, app_id))$role_id
}

set_group_roles_for_app <- function(group_id, app_id, role_ids) {
  pool::poolWithTransaction(.pkgenv$con, function(conn) {
    DBI::dbExecute(conn, "
      DELETE FROM group_roles
      WHERE group_id = ?
      AND role_id IN (SELECT role_id FROM roles WHERE app_id = ?)
    ", params = list(group_id, app_id))
    for (rid in role_ids) {
      DBI::dbExecute(conn, "INSERT INTO group_roles (group_id, role_id) VALUES (?, ?)", params = list(group_id, rid))
    }
  })
}

get_group_role_ids_for_app <- function(group_id, app_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT gr.role_id FROM group_roles gr JOIN roles r ON r.role_id = gr.role_id
    WHERE gr.group_id = ? AND r.app_id = ?
  ", params = list(group_id, app_id))$role_id
}
