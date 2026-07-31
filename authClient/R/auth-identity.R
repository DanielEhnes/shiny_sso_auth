# Moved from R/db_control.R (accessConsole's predecessor) -- identity-level
# concerns shared by every app, not console-specific.

#' Authenticate a user by username and password
#'
#' @param con A DBI connection or pool object.
#' @param username The username to look up.
#' @param password The plaintext password to verify.
#' @return A list with `ok`, and on success `user_id` and `username`; on
#'   failure, `reason` (a user-facing message).
#' @export
authenticate_user <- function(con, username, password) {
  row <- DBI::dbGetQuery(con, "SELECT user_id, password_hash, status FROM users WHERE username = ?", params = list(username))
  if (nrow(row) == 0) return(list(ok = FALSE, reason = "No account with that username."))
  if (row$status[1] != "active") return(list(ok = FALSE, reason = "This account is disabled."))
  if (!sodium::password_verify(row$password_hash[1], password)) return(list(ok = FALSE, reason = "Incorrect password."))
  list(ok = TRUE, user_id = row$user_id[1], username = username)
}

#' Verify a user's current password
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param password The plaintext password to verify.
#' @return `TRUE`/`FALSE`.
#' @export
verify_user_password <- function(con, user_id, password) {
  row <- DBI::dbGetQuery(con, "SELECT password_hash FROM users WHERE user_id = ?", params = list(user_id))
  if (nrow(row) == 0) return(FALSE)
  sodium::password_verify(row$password_hash[1], password)
}

#' Set a user's password
#'
#' @param con A DBI connection or pool object.
#' @param user_id The user's ID.
#' @param new_password The new plaintext password to hash and store.
#' @return The result of the underlying `DBI::dbExecute()` call.
#' @export
set_user_password <- function(con, user_id, new_password) {
  pw_hash <- sodium::password_store(new_password)
  DBI::dbExecute(con, "UPDATE users SET password_hash = ?, password_updated_at = CURRENT_TIMESTAMP WHERE user_id = ?",
                 params = list(pw_hash, user_id))
}
