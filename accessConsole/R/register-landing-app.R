#' Register (or update) an app's landing-zone tile
#'
#' Lets an app owner self-service their entry on the console's Landing
#' Zone page -- its launch URL, icon, contact, and description -- by
#' running this against the shared database file directly. Does not
#' start or depend on a running console process; opens and closes its own
#' short-lived connection.
#'
#' The app itself must already exist (created the normal way, via the
#' console's "Create a new app" panel) -- this only sets the
#' landing-zone-specific fields on an existing app, it does not create
#' apps.
#'
#' @param db_path Path to the shared SQLite database file.
#' @param app_key The app's existing, unique app key.
#' @param url The URL to open when a user clicks this app's tile.
#' @param description Overrides the app's description shown on the tile.
#'   Leave `NULL` to keep whatever is already set.
#' @param owner_contact Contact email shown on the tile (e.g. for users
#'   who don't yet have access). Leave `NULL` to keep the existing value.
#' @param icon_url URL of an icon image to show on the tile. Leave `NULL`
#'   to keep the existing value (or fall back to a generic badge if none
#'   has ever been set).
#' @param tooltip_text Supplementary text shown on hover -- distinct from
#'   `description`, which is always visible on the tile itself. Leave
#'   `NULL` to keep the existing value.
#' @return Invisibly `NULL`.
#' @export
register_landing_app <- function(db_path, app_key, url, description = NULL,
                                  owner_contact = NULL, icon_url = NULL,
                                  tooltip_text = NULL) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  on.exit(DBI::dbDisconnect(con))
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON;")
  ensure_core_schema(con)

  exists <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM apps WHERE app_key = ?", params = list(app_key))$n
  if (exists == 0) {
    stop("No app with app_key '", app_key, "' exists yet -- create it first via the console's 'Create a new app' panel.")
  }

  # A raw NULL has length 0, which DBI's parameter binding rejects --
  # must be NA_character_ to mean "no value" for a length-1 bind param.
  na_if_null <- function(x) if (is.null(x)) NA_character_ else x

  DBI::dbExecute(con, "
    UPDATE apps SET
      url = ?,
      description = COALESCE(?, description),
      owner_contact = COALESCE(?, owner_contact),
      icon_url = COALESCE(?, icon_url),
      tooltip_text = COALESCE(?, tooltip_text)
    WHERE app_key = ?
  ", params = list(url, na_if_null(description), na_if_null(owner_contact),
                    na_if_null(icon_url), na_if_null(tooltip_text), app_key))

  invisible(NULL)
}
