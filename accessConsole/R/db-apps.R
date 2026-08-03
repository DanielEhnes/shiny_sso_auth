# url/owner_contact/icon_url/tooltip_text are the landing-zone tile
# fields (see register_landing_app()) -- optional here since the app
# creator may not know them yet (e.g. the app isn't deployed). A NULL
# has length 0, which DBI's parameter binding rejects, so NULL is
# converted to NA_character_ (a proper length-1 SQL NULL) before binding.
create_app <- function(app_key, name, description, url = NULL, owner_contact = NULL,
                        icon_url = NULL, tooltip_text = NULL) {
  na_if_null <- function(x) if (is.null(x)) NA_character_ else x
  app_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "
    INSERT INTO apps (app_id, is_active, app_key, name, description, url, owner_contact, icon_url, tooltip_text)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  ", params = list(app_uuid, TRUE, app_key, name, description,
                    na_if_null(url), na_if_null(owner_contact), na_if_null(icon_url), na_if_null(tooltip_text)))
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

get_activity_admin_app_id <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id FROM apps WHERE app_key = ?", params = list(ACTIVITY_ADMIN_KEY))$app_id[1]
}

get_all_apps <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT app_id, app_key, name FROM apps ORDER BY name")
}

app_key_exists <- function(app_key) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT COUNT(*) AS n FROM apps WHERE app_key = ?", params = list(app_key))$n > 0
}

# Cascades (via ON DELETE CASCADE on roles/permissions/user_app_access/
# group_app_access) to remove everything scoped to this app. Refuses to
# touch the console/groups/activity pseudo-apps -- deleting any of them
# would break is_console_context()/is_groups_context()/is_activity_context()
# in app-server.R.
delete_app <- function(app_id) {
  app_key <- DBI::dbGetQuery(.pkgenv$con, "SELECT app_key FROM apps WHERE app_id = ?", params = list(app_id))$app_key[1]
  if (is.na(app_key) || app_key %in% c(ADMIN_CONSOLE_KEY, GROUPS_ADMIN_KEY, ACTIVITY_ADMIN_KEY)) {
    stop("Refusing to delete a protected or unknown app.")
  }
  DBI::dbExecute(.pkgenv$con, "DELETE FROM apps WHERE app_id = ?", params = list(app_id))
}
