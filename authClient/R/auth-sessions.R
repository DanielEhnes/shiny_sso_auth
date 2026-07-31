# All timestamps are written/read in UTC, matching SQLite's own
# CURRENT_TIMESTAMP (always UTC) -- mixing in local time here would make
# expiry comparisons silently wrong depending on the server's timezone.
.fmt_utc <- function(t) format(t, "%Y-%m-%d %H:%M:%OS6", tz = "UTC")
.parse_utc <- function(s) as.POSIXct(s, tz = "UTC")

#' Create a new SSO session
#'
#' Generates a fresh session secret, stores a keyed hash of it in the
#' `sessions` table, and returns the cookie value to hand to the browser.
#' Cookie value is `"<session_id>.<raw_secret_hex>"`. Only `secret_hash` (a
#' keyed HMAC of the raw secret) is ever stored -- the raw secret exists
#' only in the browser's cookie and in-memory during login/rotation.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param session_secret Shared HMAC key; must be identical across every
#'   app that should share SSO sessions. Defaults to the
#'   `AUTH_SESSION_SECRET` environment variable.
#' @param idle_timeout_secs Sliding idle timeout, in seconds.
#' @param created_by_app The calling app's `app_key`, recorded for
#'   audit/debug purposes. `NA` if not applicable (e.g. the console's own
#'   login, which has no single app to attribute it to).
#' @param user_agent Optional user-agent string to record.
#' @param ip_address Optional IP address to record.
#' @return A list with `cookie_value`, `session_id`, `expires_at`, and
#'   `max_age_secs`.
#' @export
create_session <- function(con, user_id, session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                            idle_timeout_secs = 8 * 3600,
                            created_by_app = NA_character_, user_agent = NA_character_,
                            ip_address = NA_character_) {
  session_id <- uuid::UUIDgenerate()
  raw_secret <- new_raw_secret()
  secret_hash <- hash_secret(raw_secret, key = session_secret)
  expires_at <- Sys.time() + idle_timeout_secs

  DBI::dbExecute(con, "
    INSERT INTO sessions (session_id, user_id, secret_hash, expires_at, created_by_app, user_agent, ip_address)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  ", params = list(session_id, user_id, secret_hash, .fmt_utc(expires_at),
                    created_by_app, user_agent, ip_address))

  list(
    cookie_value = paste0(session_id, ".", raw_secret),
    session_id = session_id,
    expires_at = expires_at,
    max_age_secs = as.integer(idle_timeout_secs)
  )
}

#' Validate an SSO session cookie
#'
#' Checks a cookie value against the `sessions` table: rejects
#' expired/revoked sessions, and transparently rotates the session secret
#' if it hasn't been used in more than `rotate_after_secs`, returning a new
#' `new_cookie_value` the caller must push back to the browser.
#'
#' A presented secret that doesn't match a still-live session_id's current
#' hash just fails that one request -- it does NOT revoke the session. The
#' session_id alone is not a secret (it rides in the same cookie), so a bare
#' mismatch is at least as likely to be a stale rotated cookie (a narrow but
#' real race: the browser's cookie jar is shared across tabs, so this should
#' be rare) as a forged token; revoking on mismatch would let anyone holding
#' a stale cookie value kill the legitimate, currently-valid session too --
#' a self-inflicted denial-of-service, not a useful security property.
#'
#' @param con A DBI connection or pool object.
#' @param cookie_value The raw cookie value, `"<session_id>.<raw_secret_hex>"`.
#' @param session_secret Shared HMAC key (see [create_session()]).
#' @param idle_timeout_secs Sliding idle timeout, in seconds.
#' @param absolute_ttl_secs Hard cap on session lifetime from creation, in seconds.
#' @param rotate_after_secs Rotate the session secret if idle longer than this, in seconds.
#' @return A list with `ok`, and on success `user_id`, `username`,
#'   `new_cookie_value` (non-`NULL` only if rotated), and `max_age_secs`.
#' @export
validate_session <- function(con, cookie_value, session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                              idle_timeout_secs = 8 * 3600, absolute_ttl_secs = 30 * 24 * 3600,
                              rotate_after_secs = 30 * 60) {
  fail <- list(ok = FALSE, user_id = NULL, username = NULL, new_cookie_value = NULL, max_age_secs = NULL)

  parts <- strsplit(cookie_value, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2) return(fail)
  session_id <- parts[1]
  raw_secret <- parts[2]

  row <- DBI::dbGetQuery(con, "
    SELECT s.session_id, s.user_id, s.secret_hash, s.created_at, s.last_seen_at, s.expires_at, s.revoked_at,
           u.username, u.status
    FROM sessions s JOIN users u ON u.user_id = s.user_id
    WHERE s.session_id = ?
  ", params = list(session_id))
  if (nrow(row) == 0) return(fail)
  row <- row[1, ]

  if (!is.na(row$revoked_at)) return(fail)
  if (!identical(row$status, "active")) return(fail)

  now <- Sys.time()
  expires_at <- .parse_utc(row$expires_at)
  created_at <- .parse_utc(row$created_at)
  last_seen_at <- .parse_utc(row$last_seen_at)

  if (now > expires_at) return(fail)
  if (now > created_at + absolute_ttl_secs) return(fail)

  expected_hash <- hash_secret(raw_secret, key = session_secret)
  if (!identical(expected_hash, row$secret_hash)) return(fail)

  new_cookie_value <- NULL
  new_max_age <- as.integer(idle_timeout_secs)

  if (as.numeric(difftime(now, last_seen_at, units = "secs")) > rotate_after_secs) {
    raw_secret_new <- new_raw_secret()
    secret_hash_new <- hash_secret(raw_secret_new, key = session_secret)
    new_expires_at <- min(now + idle_timeout_secs, created_at + absolute_ttl_secs)
    DBI::dbExecute(con, "
      UPDATE sessions SET secret_hash = ?, last_seen_at = ?, expires_at = ? WHERE session_id = ?
    ", params = list(secret_hash_new, .fmt_utc(now), .fmt_utc(new_expires_at), session_id))
    new_cookie_value <- paste0(session_id, ".", raw_secret_new)
    new_max_age <- max(0L, as.integer(difftime(new_expires_at, now, units = "secs")))
  } else {
    DBI::dbExecute(con, "UPDATE sessions SET last_seen_at = ? WHERE session_id = ?",
                   params = list(.fmt_utc(now), session_id))
  }

  list(ok = TRUE, user_id = row$user_id, username = row$username,
       new_cookie_value = new_cookie_value, max_age_secs = new_max_age)
}

#' Revoke an SSO session
#'
#' @param con A DBI connection or pool object.
#' @param cookie_value The cookie value identifying the session to revoke.
#' @return Invisibly `TRUE`/`FALSE`.
#' @export
revoke_session <- function(con, cookie_value) {
  parts <- strsplit(cookie_value, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2) return(invisible(FALSE))
  DBI::dbExecute(con, "UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = ? AND revoked_at IS NULL",
                 params = list(parts[1]))
  invisible(TRUE)
}

#' Revoke every session belonging to a user
#'
#' Called on password change / account disable -- a leaked or stale session
#' cookie is a persistent DB row, not an in-memory reactive that dies with
#' the R process, so this is real defense-in-depth, not paranoia.
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user whose sessions should all be revoked.
#' @return Invisibly `TRUE`.
#' @export
revoke_all_sessions_for_user <- function(con, user_id) {
  DBI::dbExecute(con, "UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = ? AND revoked_at IS NULL",
                 params = list(user_id))
  invisible(TRUE)
}
