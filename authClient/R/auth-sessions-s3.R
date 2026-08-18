# S3-backed equivalent of auth-sessions.R, selected via authLoginServer()'s
# session_backend = "s3". Same public shape (create/validate/revoke/
# revoke-all) as the SQL-backed functions, so mod-login.R's dispatch is a
# simple if/else, not a rewrite of the surrounding login flow.
#
# Only the *session* store moves to S3 -- users/apps/roles/permissions/etc.
# stay in SQLite regardless of this setting. validate_session_s3() still
# takes `con` for exactly one reason: fetching a fresh username/status for
# the session's user. Denormalizing those into the S3 session object
# instead (as originally sketched) would risk showing a disabled account
# as still-active until that session object was next rewritten -- a plain
# read against the (rarely-written, so uncontended) `users` table avoids
# that staleness without reintroducing any write-contention problem, since
# the actual goal here is cutting down *writes* to a hot, shared object,
# not reads.
#
# Every app sharing this SSO deployment must be configured with the same
# session_backend, bucket, endpoint, and AUTH_S3_PREFIX (if set) -- same
# requirement as already applies to AUTH_SESSION_SECRET today.

# Thin S3 client wrapper, held in a mutable environment (same pattern as
# accessConsole's .pkgenv) specifically so tests can substitute a fake
# in-memory store without a real S3-compatible endpoint. Defaults to the
# real aws.s3-backed implementation, configured via AUTH_S3_BUCKET and
# aws.s3's own AWS_S3_ENDPOINT/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env
# vars (no new config-passing mechanism invented).
#
# To override in a test: `pkg:::name$field <- value` does NOT work in R --
# it fails with a confusing "object not found" error, because complex
# assignment through `:::` tries to construct a nonexistent `:::<-`
# replacement function. Grab a local reference first, then mutate that:
#   s3_ops <- authClient:::.s3_ops
#   s3_ops$put <- function(key, value, headers = list()) { ... }
# Since environments have reference semantics, this mutates the exact
# same environment `.s3_ops` refers to inside the package -- no need to
# assign anything back.
.s3_ops <- local({
  env <- new.env(parent = emptyenv())
  env$bucket <- function() Sys.getenv("AUTH_S3_BUCKET")
  env$put <- function(key, value, headers = list()) {
    aws.s3::put_object(what = value, object = key, bucket = env$bucket(), headers = headers)
  }
  env$get <- function(key) {
    if (!aws.s3::object_exists(object = key, bucket = env$bucket())) return(NULL)
    aws.s3::get_object(object = key, bucket = env$bucket(), as = "text")
  }
  env$delete <- function(key) {
    aws.s3::delete_object(object = key, bucket = env$bucket())
  }
  # Current ETag, for the conditional (If-Match) write rotation uses below
  # -- confirmed against aws.s3's actual source (not guessed): s3HTTP()
  # attaches every HTTP response header, including "etag", as an R
  # attribute on its return value, and head_object() returns that value
  # unmodified.
  env$etag <- function(key) {
    if (!aws.s3::object_exists(object = key, bucket = env$bucket())) return(NULL)
    as.character(attr(aws.s3::head_object(object = key, bucket = env$bucket()), "etag"))
  }
  env
})

# Optional prefix ahead of every key this file writes, e.g. so multiple
# deployments/environments can share one bucket without their session
# objects colliding -- same env-var-config convention as AUTH_S3_BUCKET.
# Unset (the default) reproduces the previous unprefixed key layout exactly.
.s3_key_prefix <- function() {
  p <- Sys.getenv("AUTH_S3_PREFIX", "")
  if (nzchar(p)) paste0(gsub("/+$", "", p), "/") else ""
}

.s3_session_key <- function(session_id) paste0(.s3_key_prefix(), "sessions/", session_id, ".json")
.s3_user_index_key <- function(user_id) paste0(.s3_key_prefix(), "user_sessions/", user_id, ".json")

.s3_read_json <- function(key) {
  raw <- .s3_ops$get(key)
  if (is.null(raw)) return(NULL)
  jsonlite::fromJSON(raw, simplifyVector = TRUE)
}

# A JSON `null` (written for an NA_character_ field like revoked_at)
# round-trips through jsonlite::fromJSON() as R NULL, not NA -- plain
# is.na(x) on that errors with "argument has length 0" instead of
# returning FALSE. Treat "absent" and "NA" as the same "unset" state.
.s3_is_unset <- function(x) length(x) == 0 || is.na(x)
.s3_write_json <- function(key, value, headers = list()) {
  .s3_ops$put(key, jsonlite::toJSON(value, auto_unbox = TRUE, na = "null"), headers = headers)
}

# --- user -> active-session-ids index, needed for revoke_all_sessions_for_user_s3()
#     since S3 has no query-by-field the way SQL's WHERE user_id = ? does. ---
.s3_index_add_session <- function(user_id, session_id) {
  key <- .s3_user_index_key(user_id)
  current <- .s3_read_json(key)
  # current$session_ids on a NULL current (no index yet -- this user's
  # first-ever session) is itself just NULL, so c(NULL, session_id)
  # correctly reduces to session_id alone. The earlier version special-
  # cased is.null(current) into character(0), which silently dropped
  # every user's first session from their own index.
  ids <- unique(c(current$session_ids, session_id))
  .s3_write_json(key, list(session_ids = ids))
}
.s3_index_remove_session <- function(user_id, session_id) {
  key <- .s3_user_index_key(user_id)
  current <- .s3_read_json(key)
  if (is.null(current)) return(invisible(FALSE))
  ids <- setdiff(current$session_ids, session_id)
  .s3_write_json(key, list(session_ids = ids))
}

#' Create a new SSO session (S3-backed)
#'
#' @inherit create_session return
#' @export
create_session_s3 <- function(user_id, session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                               idle_timeout_secs = 8 * 3600,
                               created_by_app = NA_character_, user_agent = NA_character_,
                               ip_address = NA_character_) {
  session_id <- uuid::UUIDgenerate()
  raw_secret <- new_raw_secret()
  secret_hash <- hash_secret(raw_secret, key = session_secret)
  now <- Sys.time()
  expires_at <- now + idle_timeout_secs

  record <- list(
    session_id = session_id, user_id = user_id, secret_hash = secret_hash,
    created_at = .fmt_utc(now), last_seen_at = .fmt_utc(now), expires_at = .fmt_utc(expires_at),
    revoked_at = NA_character_, created_by_app = created_by_app,
    user_agent = user_agent, ip_address = ip_address
  )
  .s3_write_json(.s3_session_key(session_id), record)
  .s3_index_add_session(user_id, session_id)

  list(
    cookie_value = paste0(session_id, ".", raw_secret),
    session_id = session_id,
    expires_at = expires_at,
    max_age_secs = as.integer(idle_timeout_secs)
  )
}

#' Validate an SSO session cookie (S3-backed)
#'
#' @inherit validate_session return
#' @param con A DBI connection or pool object -- used only to fetch a
#'   fresh username/status for the session's user (see the note at the
#'   top of this file for why that isn't denormalized into S3 instead).
#' @export
validate_session_s3 <- function(con, cookie_value, session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                                 idle_timeout_secs = 8 * 3600, absolute_ttl_secs = 30 * 24 * 3600,
                                 rotate_after_secs = 30 * 60) {
  fail <- list(ok = FALSE, user_id = NULL, username = NULL, new_cookie_value = NULL, max_age_secs = NULL)

  parts <- strsplit(cookie_value, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2) return(fail)
  session_id <- parts[1]
  raw_secret <- parts[2]

  key <- .s3_session_key(session_id)
  record <- .s3_read_json(key)
  if (is.null(record)) return(fail)

  if (!.s3_is_unset(record$revoked_at)) return(fail)

  user_row <- DBI::dbGetQuery(con, "SELECT username, status FROM users WHERE user_id = ?", params = list(record$user_id))
  if (nrow(user_row) == 0 || !identical(user_row$status[1], "active")) return(fail)

  now <- Sys.time()
  expires_at <- .parse_utc(record$expires_at)
  created_at <- .parse_utc(record$created_at)
  last_seen_at <- .parse_utc(record$last_seen_at)

  if (now > expires_at) return(fail)
  if (now > created_at + absolute_ttl_secs) return(fail)

  expected_hash <- hash_secret(raw_secret, key = session_secret)
  if (!identical(expected_hash, record$secret_hash)) return(fail)

  new_cookie_value <- NULL
  new_max_age <- as.integer(idle_timeout_secs)

  if (as.numeric(difftime(now, last_seen_at, units = "secs")) > rotate_after_secs) {
    # Rotation is the one write worth protecting with a conditional
    # (If-Match) write -- a lost update here would mean the secret_hash
    # we just wrote gets silently overwritten by a stale concurrent
    # request, breaking the *next* validation for this session. A plain
    # last_seen_at touch (the `else` branch below) has no such stakes --
    # worst case it just reflects whichever of two near-simultaneous
    # requests wrote last.
    etag <- .s3_ops$etag(key)
    raw_secret_new <- new_raw_secret()
    secret_hash_new <- hash_secret(raw_secret_new, key = session_secret)
    new_expires_at <- min(now + idle_timeout_secs, created_at + absolute_ttl_secs)
    candidate <- record
    candidate$secret_hash <- secret_hash_new
    candidate$last_seen_at <- .fmt_utc(now)
    candidate$expires_at <- .fmt_utc(new_expires_at)
    rotated <- tryCatch({
      .s3_write_json(key, candidate, headers = if (!is.null(etag)) list("If-Match" = etag) else list())
      TRUE
    }, error = function(e) FALSE)
    if (rotated) {
      new_cookie_value <- paste0(session_id, ".", raw_secret_new)
      new_max_age <- max(0L, as.integer(difftime(new_expires_at, now, units = "secs")))
    } else {
      # Another app validating the same session concurrently won the
      # rotation race first (its write landed between our read and our
      # own conditional write, so our If-Match failed). This request's
      # own secret was still verified valid against the record *we* read,
      # so treat it as a successful validation -- just don't attempt a
      # write of our own: we have no way to construct a cookie for the
      # secret the other request just generated, and overwriting its
      # change with ours (using our stale `record`) would revert it. The
      # browser will pick up the winning rotation's cookie on its next
      # reload, since the SSO cookie is shared domain-wide, not per-app.
      new_max_age <- as.integer(idle_timeout_secs)
    }
  } else {
    record$last_seen_at <- .fmt_utc(now)
    .s3_write_json(key, record)
  }

  list(ok = TRUE, user_id = record$user_id, username = user_row$username[1],
       new_cookie_value = new_cookie_value, max_age_secs = new_max_age)
}

#' Revoke an SSO session (S3-backed)
#'
#' @inherit revoke_session return
#' @export
revoke_session_s3 <- function(cookie_value) {
  parts <- strsplit(cookie_value, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2) return(invisible(FALSE))
  session_id <- parts[1]
  key <- .s3_session_key(session_id)
  record <- .s3_read_json(key)
  if (is.null(record)) return(invisible(FALSE))
  if (.s3_is_unset(record$revoked_at)) {
    record$revoked_at <- .fmt_utc(Sys.time())
    .s3_write_json(key, record)
    .s3_index_remove_session(record$user_id, session_id)
  }
  invisible(TRUE)
}

#' Revoke every session belonging to a user (S3-backed)
#'
#' @inherit revoke_all_sessions_for_user return
#' @export
revoke_all_sessions_for_user_s3 <- function(user_id) {
  index_key <- .s3_user_index_key(user_id)
  index <- .s3_read_json(index_key)
  if (!is.null(index)) {
    for (session_id in index$session_ids) {
      key <- .s3_session_key(session_id)
      record <- .s3_read_json(key)
      if (!is.null(record) && .s3_is_unset(record$revoked_at)) {
        record$revoked_at <- .fmt_utc(Sys.time())
        .s3_write_json(key, record)
      }
    }
  }
  .s3_write_json(index_key, list(session_ids = character(0)))
  invisible(TRUE)
}
