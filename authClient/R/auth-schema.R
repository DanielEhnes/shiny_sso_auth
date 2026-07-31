#' Ensure the sessions table exists
#'
#' Idempotent guard that creates the `sessions` table (and its indexes) if
#' they don't already exist. Consuming apps normally get this table via the
#' shared SQLAlchemy schema (`python/repository/tablestructure_user.py` ->
#' `Session`, applied with `Base.metadata.create_all()`); this guard just
#' makes authClient usable standalone against a bare users/apps/... SQLite
#' file too.
#'
#' @param con A DBI connection or pool object.
#' @return Invisibly `NULL`.
#' @export
ensure_sessions_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sessions (
      session_id     CHAR(36) PRIMARY KEY,
      user_id        CHAR(36) NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
      secret_hash    CHAR(64) NOT NULL,
      created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_seen_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      expires_at     DATETIME NOT NULL,
      revoked_at     DATETIME,
      created_by_app TEXT,
      user_agent     TEXT,
      ip_address     TEXT
    )
  ")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)")
  invisible(NULL)
}
