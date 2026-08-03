# authenticate_user/verify_user_password/set_user_password moved OUT to
# authClient (identity-level, shared across apps) -- called directly as
# authClient::... at their call sites in app-server.R.

email_is_valid <- function(email) grepl("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", email)

email_exists <- function(email) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT COUNT(*) AS n FROM users WHERE email = ?", params = list(email))$n > 0
}

# Every created user automatically becomes a member of the basic_user
# group (created lazily here if it doesn't exist yet) -- basic_user is
# granted access to the console app in run_initial_setup(), so this is
# what keeps "anyone with an account can log into the console" working
# now that the console's login is access-gated rather than open to any
# authenticated account.
create_user <- function(username, email, password) {
  pw_hash <- sodium::password_store(password)
  user_uuid <- uuid::UUIDgenerate()
  DBI::dbExecute(.pkgenv$con, "INSERT INTO users (user_id, username, email, password_hash, status, failed_login_count) VALUES (?, ?, ?, ?, 'active', 0)", params = list(user_uuid, username, email, pw_hash))

  if (!group_key_exists(BASIC_USER_GROUP_KEY)) {
    create_group(BASIC_USER_GROUP_KEY, "Basic Users", "Automatically granted to every created user.")
  }
  add_user_to_group(get_group_id(BASIC_USER_GROUP_KEY), user_uuid, NA_character_)

  invisible(user_uuid)
}

get_user_id <- function(username) {
  DBI::dbGetQuery(.pkgenv$con, "SELECT user_id, username, email, status, created_at FROM users WHERE username = ?", params = list(username))$user_id
}

get_all_users <- function() {
  DBI::dbGetQuery(.pkgenv$con, "SELECT user_id, username, email, status, created_at FROM users ORDER BY created_at DESC")
}

set_user_status <- function(user_id, new_status) {
  DBI::dbExecute(.pkgenv$con, "UPDATE users SET status = ? WHERE user_id = ?", params = list(new_status, user_id))
}
