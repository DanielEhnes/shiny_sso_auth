#' Ensure the core identity/RBAC schema exists
#'
#' Idempotent guard (`CREATE TABLE`/`INDEX IF NOT EXISTS` throughout) that
#' creates every core table -- users, apps, access gates, RBAC, groups,
#' audit log -- if they don't already exist. Ported from the SQLAlchemy
#' schema in `python/repository/tablestructure_user.py`, which is kept
#' around and still usable via `Base.metadata.create_all()`, but this is
#' now the actual mechanism the console itself relies on.
#'
#' `sessions` and `auth_settings` are NOT created here -- those are
#' authClient's own tables, applied via its own
#' `ensure_sessions_schema()`/`ensure_auth_settings_schema()` guards.
#'
#' One deliberate deviation from the Python model: `auth_audit_log.log_id`
#' is declared `INTEGER PRIMARY KEY` here, not `BIGINT`. SQLite only treats
#' a column as an auto-incrementing rowid alias if its declared type is
#' the literal word `INTEGER` -- `BIGINT` has the same numeric affinity but
#' does NOT qualify, so a plain `INSERT ... (user_id, app_id, event_type)`
#' omitting `log_id` fails with a `NOT NULL constraint failed` the moment
#' audit logging is ever turned on. Confirmed by testing against the
#' original Python-created table directly.
#'
#' @param con A DBI connection or pool object.
#' @return Invisibly `NULL`.
#' @export
ensure_core_schema <- function(con) {
  # Dependency order matters for readability (and matches how SQLAlchemy's
  # create_all() topologically sorts them), even though SQLite doesn't
  # actually validate FK targets exist at CREATE TABLE time.
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS users (
      user_id CHAR(32) NOT NULL,
      email TEXT NOT NULL,
      username TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      password_updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      status VARCHAR(20) NOT NULL,
      email_verified_at DATETIME,
      failed_login_count INTEGER NOT NULL DEFAULT 0,
      locked_until DATETIME,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      last_login_at DATETIME,
      PRIMARY KEY (user_id),
      UNIQUE (email),
      UNIQUE (username)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS apps (
      app_id CHAR(32) NOT NULL,
      app_key TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      owner_contact TEXT,
      url TEXT,
      icon_url TEXT,
      tooltip_text TEXT,
      is_active BOOLEAN NOT NULL DEFAULT 1,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      PRIMARY KEY (app_id),
      UNIQUE (app_key)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS user_app_access (
      user_id CHAR(32) NOT NULL,
      app_id CHAR(32) NOT NULL,
      status VARCHAR(16) NOT NULL,
      granted_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      revoked_at DATETIME,
      PRIMARY KEY (user_id, app_id),
      FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE CASCADE,
      FOREIGN KEY(app_id) REFERENCES apps (app_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS groups (
      group_id CHAR(32) NOT NULL,
      group_key TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      PRIMARY KEY (group_id),
      UNIQUE (group_key)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS group_app_access (
      group_id CHAR(32) NOT NULL,
      app_id CHAR(32) NOT NULL,
      status VARCHAR(16) NOT NULL,
      granted_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      revoked_at DATETIME,
      PRIMARY KEY (group_id, app_id),
      FOREIGN KEY(group_id) REFERENCES groups (group_id) ON DELETE CASCADE,
      FOREIGN KEY(app_id) REFERENCES apps (app_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS group_user (
      group_id CHAR(32) NOT NULL,
      user_id CHAR(32) NOT NULL,
      added_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      added_by CHAR(32),
      PRIMARY KEY (group_id, user_id),
      FOREIGN KEY(group_id) REFERENCES groups (group_id) ON DELETE CASCADE,
      FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE CASCADE,
      FOREIGN KEY(added_by) REFERENCES users (user_id)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS roles (
      role_id CHAR(32) NOT NULL,
      app_id CHAR(32) NOT NULL,
      role_name TEXT NOT NULL,
      description TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      PRIMARY KEY (role_id),
      CONSTRAINT uq_role_app_name UNIQUE (app_id, role_name),
      FOREIGN KEY(app_id) REFERENCES apps (app_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS permissions (
      permission_id CHAR(32) NOT NULL,
      app_id CHAR(32) NOT NULL,
      permission_name TEXT NOT NULL,
      description TEXT,
      PRIMARY KEY (permission_id),
      CONSTRAINT uq_permission_app_key UNIQUE (app_id, permission_name),
      FOREIGN KEY(app_id) REFERENCES apps (app_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS role_permissions (
      role_id CHAR(32) NOT NULL,
      permission_id CHAR(32) NOT NULL,
      PRIMARY KEY (role_id, permission_id),
      FOREIGN KEY(role_id) REFERENCES roles (role_id) ON DELETE CASCADE,
      FOREIGN KEY(permission_id) REFERENCES permissions (permission_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS user_roles (
      user_id CHAR(32) NOT NULL,
      role_id CHAR(32) NOT NULL,
      granted_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      granted_by CHAR(32),
      PRIMARY KEY (user_id, role_id),
      FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE CASCADE,
      FOREIGN KEY(role_id) REFERENCES roles (role_id) ON DELETE CASCADE,
      FOREIGN KEY(granted_by) REFERENCES users (user_id)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS group_roles (
      group_id CHAR(32) NOT NULL,
      role_id CHAR(32) NOT NULL,
      granted_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      granted_by CHAR(32),
      PRIMARY KEY (group_id, role_id),
      FOREIGN KEY(group_id) REFERENCES groups (group_id) ON DELETE CASCADE,
      FOREIGN KEY(role_id) REFERENCES roles (role_id) ON DELETE CASCADE,
      FOREIGN KEY(granted_by) REFERENCES users (user_id)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS user_tokens (
      token_id CHAR(32) NOT NULL,
      user_id CHAR(32) NOT NULL,
      purpose VARCHAR(14) NOT NULL,
      token_hash TEXT NOT NULL,
      expires_at DATETIME NOT NULL,
      used_at DATETIME,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      PRIMARY KEY (token_id),
      FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE CASCADE
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS auth_audit_log (
      log_id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id CHAR(32),
      app_id CHAR(32),
      event_type TEXT NOT NULL,
      metadata JSON,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
      FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE SET NULL,
      FOREIGN KEY(app_id) REFERENCES apps (app_id) ON DELETE SET NULL
    )
  ")

  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_users_status ON users (status)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_user_app_access_app ON user_app_access (app_id, status)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_group_app_access_app ON group_app_access (app_id, status)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_group_user_user ON group_user (user_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_role_permissions_role ON role_permissions (role_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_user_roles_user ON user_roles (user_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_group_roles_group ON group_roles (group_id)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_user_tokens_lookup ON user_tokens (user_id, purpose)")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_audit_user ON auth_audit_log (user_id, created_at)")

  invisible(NULL)
}
