get_recent_audit_events <- function(limit = 200) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT u.username, a.name AS app_name, l.event_type, l.created_at
    FROM auth_audit_log l
    LEFT JOIN users u ON u.user_id = l.user_id
    LEFT JOIN apps  a ON a.app_id  = l.app_id
    WHERE l.event_type = 'app_access'
    ORDER BY l.created_at DESC
    LIMIT ?
  ", params = list(limit))
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
