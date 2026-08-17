# user_id/org_unit_group_id are optional, mutually-exclusive scoping
# filters -- both NULL (the default) reproduces the original, unfiltered
# "everyone" feed exactly.
get_recent_audit_events <- function(limit = 200, user_id = NULL, org_unit_group_id = NULL) {
  where_extra <- ""
  extra_params <- list()
  if (!is.null(user_id)) {
    where_extra <- "AND l.user_id = ?"
    extra_params <- list(user_id)
  } else if (!is.null(org_unit_group_id)) {
    where_extra <- "AND l.user_id IN (SELECT user_id FROM group_user WHERE group_id = ?)"
    extra_params <- list(org_unit_group_id)
  }
  DBI::dbGetQuery(.pkgenv$con, paste0("
    SELECT u.username, a.name AS app_name, l.event_type, l.created_at
    FROM auth_audit_log l
    LEFT JOIN users u ON u.user_id = l.user_id
    LEFT JOIN apps  a ON a.app_id  = l.app_id
    WHERE l.event_type = 'app_access' ", where_extra, "
    ORDER BY l.created_at DESC
    LIMIT ?
  "), params = c(extra_params, list(limit)))
}

# Single row for one specific user -- no unique-users metric, meaningless
# scoped to one person.
get_activity_summary_for_user <- function(user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT
      MAX(created_at) AS last_seen,
      COUNT(CASE WHEN created_at >= datetime('now','-7 days')  THEN 1 END) AS connections_7d,
      COUNT(CASE WHEN created_at >= datetime('now','-30 days') THEN 1 END) AS connections_30d
    FROM auth_audit_log
    WHERE user_id = ? AND event_type = 'app_access'
  ", params = list(user_id))
}

# Single row for everyone currently in the given org-unit group -- same
# conditional-aggregation shape as get_overall_activity_counts(), just
# joined through group_user to scope it to that group's members.
get_activity_summary_for_org_unit <- function(org_unit_group_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT
      MAX(l.created_at) AS last_seen,
      COUNT(DISTINCT CASE WHEN l.created_at >= datetime('now','-7 days')  THEN l.user_id END) AS unique_users_7d,
      COUNT(DISTINCT CASE WHEN l.created_at >= datetime('now','-30 days') THEN l.user_id END) AS unique_users_30d,
      COUNT(CASE WHEN l.created_at >= datetime('now','-7 days')  THEN 1 END) AS connections_7d,
      COUNT(CASE WHEN l.created_at >= datetime('now','-30 days') THEN 1 END) AS connections_30d
    FROM auth_audit_log l
    JOIN group_user gu ON gu.user_id = l.user_id
    WHERE gu.group_id = ? AND l.event_type = 'app_access'
  ", params = list(org_unit_group_id))
}

# One row per app; both metrics (unique users / total connections), both
# windows (7d / 30d) -- the UI picks which pair of columns to show based
# on the unique/total toggle rather than re-querying.
get_app_activity_by_window <- function() {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT a.name AS app_name,
      COUNT(DISTINCT CASE WHEN l.created_at >= datetime('now','-7 days')  THEN l.user_id END) AS unique_users_7d,
      COUNT(DISTINCT CASE WHEN l.created_at >= datetime('now','-30 days') THEN l.user_id END) AS unique_users_30d,
      COUNT(CASE WHEN l.created_at >= datetime('now','-7 days')  THEN 1 END) AS connections_7d,
      COUNT(CASE WHEN l.created_at >= datetime('now','-30 days') THEN 1 END) AS connections_30d
    FROM auth_audit_log l
    JOIN apps a ON a.app_id = l.app_id
    WHERE l.event_type = 'app_access'
    GROUP BY a.app_id
    ORDER BY a.name
  ")
}

# Single row, platform-wide; same four columns as above, no GROUP BY.
get_overall_activity_counts <- function() {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT
      COUNT(DISTINCT CASE WHEN created_at >= datetime('now','-7 days')  THEN user_id END) AS unique_users_7d,
      COUNT(DISTINCT CASE WHEN created_at >= datetime('now','-30 days') THEN user_id END) AS unique_users_30d,
      COUNT(CASE WHEN created_at >= datetime('now','-7 days')  THEN 1 END) AS connections_7d,
      COUNT(CASE WHEN created_at >= datetime('now','-30 days') THEN 1 END) AS connections_30d
    FROM auth_audit_log
    WHERE event_type = 'app_access'
  ")
}
