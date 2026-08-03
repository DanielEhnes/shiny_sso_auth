group_key_exists <- function(group_key) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT COUNT(*) AS n FROM groups WHERE group_key = ?", params = list(group_key))$n > 0
}

get_group_id <- function(group_key) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT group_id FROM groups WHERE group_key = ?", params = list(group_key))$group_id
}

create_group <- function(group_key, name, description) {
  group_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "
    INSERT INTO groups (group_id, group_key, name, description) VALUES (?, ?, ?, ?)
  ", params = list(group_uuid, group_key, name, description))
  return(group_uuid)
}

get_all_groups <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT group_id, group_key, name, description FROM groups ORDER BY name")
}

get_group_members <- function(group_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT u.user_id, u.username, u.email
    FROM group_user gu
    JOIN users u ON u.user_id = gu.user_id
    WHERE gu.group_id = ?
    ORDER BY u.email
  ", params = list(group_id))
}

get_groups_for_user <- function(user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT g.group_id, g.group_key, g.name
    FROM group_user gu
    JOIN groups g ON g.group_id = gu.group_id
    WHERE gu.user_id = ?
    ORDER BY g.name
  ", params = list(user_id))
}

is_user_in_group <- function(group_id, user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM group_user WHERE group_id = ? AND user_id = ?
  ", params = list(group_id, user_id))$n > 0
}

add_user_to_group <- function(group_id, user_id, added_by) {
  if (!is_user_in_group(group_id, user_id)) {
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO group_user (group_id, user_id, added_by) VALUES (?, ?, ?)
    ", params = list(group_id, user_id, added_by))
  }
}

remove_user_from_group <- function(group_id, user_id) {
  DBI::dbExecute(.pkgenv$con, "DELETE FROM group_user WHERE group_id = ? AND user_id = ?", params = list(group_id, user_id))
}

# Cascades (via ON DELETE CASCADE on group_user/group_app_access/group_roles)
# to remove all memberships/access/roles for this group.
delete_group <- function(group_id) {
  DBI::dbExecute(.pkgenv$con, "DELETE FROM groups WHERE group_id = ?", params = list(group_id))
}
