create_app <- function(app_key, name, description) {
  app_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "INSERT INTO apps (app_id, is_active, app_key, name, description) VALUES (?, ?, ?, ?, ?)", params = list(app_uuid, TRUE, app_key, name, description))
  return(app_uuid)
}

get_app_id <- function(app_key) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(app_key))$app_id
}

get_admin_console_app_id <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(ADMIN_CONSOLE_KEY))$app_id[1]
}

get_groups_admin_app_id <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(GROUPS_ADMIN_KEY))$app_id[1]
}

get_all_apps <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id, app_key, name FROM apps ORDER BY name")
}

app_key_exists <- function(app_key) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT COUNT(*) AS n FROM apps WHERE app_key = ?", params = list(app_key))$n > 0
}

# Cascades (via ON DELETE CASCADE on roles/permissions/user_app_access/
# group_app_access) to remove everything scoped to this app. Refuses to
# touch the console/groups pseudo-apps -- deleting either would break
# is_console_context()/is_groups_context() in app-server.R.
delete_app <- function(app_id) {
  app_key <- DBI::dbGetQuery(.pkgenv$con, "SELECT app_key FROM apps WHERE app_id = ?", params = list(app_id))$app_key[1]
  if (is.na(app_key) || app_key %in% c(ADMIN_CONSOLE_KEY, GROUPS_ADMIN_KEY)) {
    stop("Refusing to delete a protected or unknown app.")
  }
  DBI::dbExecute(.pkgenv$con, "DELETE FROM apps WHERE app_id = ?", params = list(app_id))
}
