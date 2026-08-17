# A NULL/NA valid_from/valid_until means "no bound" -- unchanged behavior
# from before this column existed. valid_until is normalized to that
# date's end-of-day so "access until the 30th" includes the whole 30th,
# not just up to midnight at its start.
#
# dateInput() gives a bare calendar date -- interpreted as local midnight
# (or local end-of-day), then converted to true UTC before storing, same
# discipline as authClient's .fmt_utc()/.parse_utc() (auth-sessions.R) and
# for the same reason: the access-check queries compare against SQLite's
# datetime('now'), which is UTC, not local time. Storing a naive
# "YYYY-MM-DD 00:00:00" string and comparing it directly against that
# would silently shift both boundaries by the server's UTC offset.
# dateInput() can hand back NULL, NA, "", or character(0) for "no date
# picked" depending on exactly how/when it's empty (initial state vs.
# cleared by the user) -- rather than enumerate every shape, just attempt
# the parse and fall back to "no bound" for anything that doesn't produce
# a single valid Date.
.parse_optional_date <- function(d) {
  date <- tryCatch(as.Date(d), error = function(e) as.Date(NA))
  if (length(date) != 1 || is.na(date)) NA else date
}
.format_valid_from <- function(d) {
  date <- .parse_optional_date(d)
  if (is.na(date)) return(NA_character_)
  t <- as.POSIXct(paste(date, "00:00:00"), tz = Sys.timezone())
  format(t, "%Y-%m-%d %H:%M:%S", tz = "UTC")
}
.format_valid_until <- function(d) {
  date <- .parse_optional_date(d)
  if (is.na(date)) return(NA_character_)
  t <- as.POSIXct(paste(date, "23:59:59"), tz = Sys.timezone())
  format(t, "%Y-%m-%d %H:%M:%S", tz = "UTC")
}

set_user_app_access_for_app <- function(user_id, app_id, granted, valid_from = NULL, valid_until = NULL) {
  exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM user_app_access WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))$n
  from_str <- .format_valid_from(valid_from)
  until_str <- .format_valid_until(valid_until)

  if (exists == 0) {
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO user_app_access (user_id, app_id, status, valid_from, valid_until) VALUES (?, ?, ?, ?, ?)
    ", params = list(user_id, app_id, if (granted) "active" else "revoked", from_str, until_str))
  } else {
    DBI::dbExecute(.pkgenv$con, "
      UPDATE user_app_access SET status = ?, valid_from = ?, valid_until = ? WHERE user_id = ? AND app_id = ?
    ", params = list(if (granted) "active" else "revoked", from_str, until_str, user_id, app_id))
  }
}

get_user_app_access_status <- function(user_id, app_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT status, valid_from, valid_until FROM user_app_access WHERE user_id = ? AND app_id = ?
  ", params = list(user_id, app_id))
  if (nrow(row) == 0) {
    list(status = "none", valid_from = NA, valid_until = NA)
  } else {
    list(status = row$status[1], valid_from = row$valid_from[1], valid_until = row$valid_until[1])
  }
}

# Every app this user currently has active access to, whether granted
# directly (user_app_access) or via any group they belong to
# (group_app_access) -- for a self-service "your access" summary, not an
# admin management view.
get_user_accessible_apps <- function(user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT DISTINCT a.app_id, a.app_key, a.name
    FROM apps a
    WHERE a.app_id IN (
      SELECT app_id FROM user_app_access
      WHERE user_id = ? AND status = 'active'
        AND (valid_from IS NULL OR valid_from <= datetime('now'))
        AND (valid_until IS NULL OR valid_until >= datetime('now'))
    ) OR a.app_id IN (
      SELECT ga.app_id FROM group_user gu
      JOIN group_app_access ga ON ga.group_id = gu.group_id
      WHERE gu.user_id = ? AND ga.status = 'active'
        AND (ga.valid_from IS NULL OR ga.valid_from <= datetime('now'))
        AND (ga.valid_until IS NULL OR ga.valid_until >= datetime('now'))
    )
    ORDER BY a.name
  ", params = list(user_id, user_id))
}

# Every app registered for the landing zone (has a url configured, and
# isn't one of the console's own pseudo-apps), regardless of whether this
# user has access -- has_access lets the UI render locked/unlocked tiles
# so users can discover apps and see who to contact for ones they don't
# have yet.
get_landing_apps_for_user <- function(user_id) {
  DBI::dbGetQuery(.pkgenv$con, "
    SELECT a.app_id, a.app_key, a.name, a.description, a.tooltip_text,
      a.url, a.icon_url, a.owner_contact,
      CASE WHEN EXISTS (
        SELECT 1 FROM user_app_access
        WHERE user_id = ? AND app_id = a.app_id AND status = 'active'
          AND (valid_from IS NULL OR valid_from <= datetime('now'))
          AND (valid_until IS NULL OR valid_until >= datetime('now'))
      ) OR EXISTS (
        SELECT 1 FROM group_user gu
        JOIN group_app_access ga ON ga.group_id = gu.group_id
        WHERE gu.user_id = ? AND ga.app_id = a.app_id AND ga.status = 'active'
          AND (ga.valid_from IS NULL OR ga.valid_from <= datetime('now'))
          AND (ga.valid_until IS NULL OR ga.valid_until >= datetime('now'))
      ) THEN 1 ELSE 0 END AS has_access
    FROM apps a
    WHERE a.url IS NOT NULL
      AND a.app_key NOT IN (?, ?, ?)
    ORDER BY has_access DESC, a.name
  ", params = list(user_id, user_id, ADMIN_CONSOLE_KEY, GROUPS_ADMIN_KEY, ACTIVITY_ADMIN_KEY))
}

set_group_app_access_for_app <- function(group_id, app_id, granted, valid_from = NULL, valid_until = NULL) {
  exists <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT COUNT(*) AS n FROM group_app_access WHERE group_id = ? AND app_id = ?
  ", params = list(group_id, app_id))$n
  from_str <- .format_valid_from(valid_from)
  until_str <- .format_valid_until(valid_until)

  if (exists == 0) {
    DBI::dbExecute(.pkgenv$con, "
      INSERT INTO group_app_access (group_id, app_id, status, valid_from, valid_until) VALUES (?, ?, ?, ?, ?)
    ", params = list(group_id, app_id, if (granted) "active" else "revoked", from_str, until_str))
  } else {
    DBI::dbExecute(.pkgenv$con, "
      UPDATE group_app_access SET status = ?, valid_from = ?, valid_until = ? WHERE group_id = ? AND app_id = ?
    ", params = list(if (granted) "active" else "revoked", from_str, until_str, group_id, app_id))
  }
}

get_group_app_access_status <- function(group_id, app_id) {
  row <- DBI::dbGetQuery(.pkgenv$con, "
    SELECT status, valid_from, valid_until FROM group_app_access WHERE group_id = ? AND app_id = ?
  ", params = list(group_id, app_id))
  if (nrow(row) == 0) {
    list(status = "none", valid_from = NA, valid_until = NA)
  } else {
    list(status = row$status[1], valid_from = row$valid_from[1], valid_until = row$valid_until[1])
  }
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
