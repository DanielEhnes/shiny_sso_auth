# SSO login module: checks for a valid session cookie on load, falls back to
# a password login form, and issues/rotates/revokes the cookie via a tiny JS
# bridge (see inst/www/auth-cookie.js) -- Shiny has no supported
# Set-Cookie/response-header API for app authors, so client-side JS is the
# only realistic way to write it.
#
# Consuming apps must gate their real UI on `checked() && logged_in()`, not
# just `logged_in()`, or they'll flash a login form for a frame while the
# cookie check is still in flight.
#
# `require_app_key = NULL` means "just authenticate, no access gate" (used
# by the admin console itself, which every registered user may log into).
# Any other app should pass its own app_key and get gated by
# user_has_app_access().

#' SSO login UI
#'
#' Renders the login form area and injects the client-side cookie bridge
#' (see `inst/www/auth-cookie.js`) -- Shiny has no supported
#' Set-Cookie/response-header API for app authors, so this is the
#' realistic way to read/write the SSO cookie.
#'
#' @param id The Shiny module ID.
#' @param cookie_name Name of the SSO cookie. Must match across every app
#'   sharing SSO sessions if you rely on the default.
#' @return A `shiny::tagList()` to place in your UI.
#' @export
authLoginUI <- function(id, cookie_name = "app_sso") {
  ns <- shiny::NS(id)
  js <- paste(readLines(system.file("www/auth-cookie.js", package = "authClient")), collapse = "\n")
  shiny::tagList(
    shiny::tags$head(
      shiny::includeCSS(system.file("www/auth-forms.css", package = "authClient"))
    ),
    shiny::tags$script(shiny::HTML(sprintf(
      "window.__AUTH_COOKIE_NAME__='%s';\nwindow.__AUTH_INPUT_ID__='%s';\n%s",
      cookie_name, ns("auth_cookie_in"), js
    ))),
    shiny::uiOutput(ns("login_area"))
  )
}

#' SSO login server logic
#'
#' Checks for a valid session cookie on load (silent SSO reuse), falls back
#' to a password login form, and issues/rotates/revokes the cookie.
#' Consuming apps must gate their real UI on `checked() && logged_in()`,
#' not just `logged_in()`, or they'll flash a login form for a frame while
#' the cookie check is still in flight.
#'
#' @param id The Shiny module ID, must match the corresponding
#'   [authLoginUI()] call.
#' @param con A DBI connection or pool object, owned by the calling app.
#' @param session_secret Shared HMAC key; must be identical across every
#'   app that should share SSO sessions.
#' @param cookie_name Name of the SSO cookie.
#' @param cookie_domain Cookie `Domain=` scope, e.g.
#'   `".internal.example.com"`, needed for the cookie to reach other apps
#'   under a shared parent domain.
#' @param require_app_key The calling app's `app_key`, used to gate login
#'   on [user_has_app_access()] and to scope `has_permission()`/audit
#'   logging. `NULL` means "just authenticate, no access gate" (used by the
#'   admin console itself, which every registered user may log into).
#' @param permission_cache_ttl_secs How long, in seconds, a
#'   `has_permission()` result is cached per session before rechecking the
#'   database.
#' @param session_backend `"sql"` (default) or `"s3"`. `"s3"` stores the
#'   session record itself (not users/apps/roles/etc., which always stay
#'   in SQL regardless) in an S3-compatible bucket instead of the `sessions`
#'   table -- see [create_session_s3()]. Configured via the `AUTH_S3_BUCKET`
#'   env var plus `aws.s3`'s own `AWS_S3_ENDPOINT`/`AWS_ACCESS_KEY_ID`/
#'   `AWS_SECRET_ACCESS_KEY`. Every app sharing this SSO deployment must be
#'   configured with the same backend (and bucket/endpoint, if `"s3"`) --
#'   same requirement as already applies to `session_secret` today.
#' @return A list of reactives/functions: `logged_in()`, `checked()`,
#'   `user_id()`, `username()`, `org_unit()` (a list with `group_key`/
#'   `name`, or `NULL` if the user has no organizational unit -- see
#'   [get_user_org_unit()]), `has_permission(app_key, permission_name)`,
#'   `is_in_group(group_key)` (cached the same way as `has_permission()`
#'   -- see [user_is_in_group()]), and `logout()`. The same list is also
#'   stashed in
#'   `session$userData$authClient`, so any module nested anywhere under
#'   the app's top-level server can reach it (e.g.
#'   `session$userData$authClient$user_id()`) without having `auth`
#'   explicitly passed down to it.
#' @export
authLoginServer <- function(id, con, session_secret = Sys.getenv("AUTH_SESSION_SECRET"),
                             cookie_name = "app_sso", cookie_domain = NULL,
                             require_app_key = NULL, permission_cache_ttl_secs = 8 * 3600,
                             session_backend = c("sql", "s3")) {
  session_backend <- match.arg(session_backend)
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    state <- shiny::reactiveValues(logged_in = FALSE, user_id = NULL, username = NULL, org_unit = NULL, checked = FALSE)

    # Cache bounded by permission_cache_ttl_secs (not just session lifetime):
    # a tab-visibility check called on every render would otherwise re-hit
    # the DB constantly, but a pure session-lifetime cache never expires on
    # its own -- a browser tab left open for days would never see a
    # mid-session permission change. Still fine for UI-level decisions, not
    # a substitute for a server-side authorization check on anything
    # sensitive.
    permission_cache <- new.env(parent = emptyenv())

    push_cookie <- function(value, max_age) {
      session$sendCustomMessage("auth_set_cookie",
        list(name = cookie_name, value = value, maxAge = max_age, domain = cookie_domain))
    }
    clear_cookie <- function() {
      session$sendCustomMessage("auth_clear_cookie", list(name = cookie_name, domain = cookie_domain))
    }

    # Presence-only audit entry ("this user used this app"), a no-op if
    # audit logging is disabled (auth_settings) or require_app_key is NULL
    # (no specific app to attribute it to, e.g. the console's own login).
    # Called from BOTH paths below -- the cookie-reuse path matters just as
    # much as the fresh-login path: logging in on App A and then reaching
    # App B purely via the SSO cookie must still record App B's usage, or
    # cross-app SSO would silently go untracked for every app but the first.
    record_app_access <- function(user_id) {
      if (is.null(require_app_key)) return(invisible(FALSE))
      app_id <- .resolve_app_id(con, require_app_key)
      if (length(app_id) == 0) return(invisible(FALSE))
      log_app_access(con, user_id, app_id)
    }

    # Fires once per page load (see shiny:sessioninitialized in the JS) --
    # this is the SSO "check on load" step.
    shiny::observeEvent(input$auth_cookie_in, once = TRUE, {
      state$checked <- TRUE
      raw <- input$auth_cookie_in
      if (is.null(raw) || raw == "") return()
      res <- if (session_backend == "s3") validate_session_s3(con, raw, session_secret) else validate_session(con, raw, session_secret)
      if (res$ok) {
        state$logged_in <- TRUE
        state$user_id <- res$user_id
        state$username <- res$username
        state$org_unit <- get_user_org_unit(con, res$user_id)
        if (!is.null(res$new_cookie_value)) push_cookie(res$new_cookie_value, res$max_age_secs)
        record_app_access(res$user_id)
      } else {
        clear_cookie()
      }
    })

    output$login_area <- shiny::renderUI({
      if (state$logged_in) return(NULL)
      shiny::req(state$checked)  # avoid flashing the form before the cookie check resolves
      shiny::div(class = "auth-card login-box",
        shiny::h3("Log in"),
        shiny::textInput(ns("username"), "Username", placeholder = "username"),
        shiny::passwordInput(ns("password"), "Password", placeholder = "password"),
        shiny::actionButton(ns("login_btn"), "Log in", class = "btn btn-primary"),
        shiny::uiOutput(ns("login_message"))
      )
    })

    output$login_message <- shiny::renderUI(NULL)
    shiny::observeEvent(input$login_btn, {
      res <- authenticate_user(con, trimws(input$username), input$password)
      if (!res$ok) {
        output$login_message <- shiny::renderUI(shiny::div(class = "login-error", res$reason))
        return()
      }
      if (!is.null(require_app_key) && !user_has_app_access(con, res$user_id, require_app_key)) {
        output$login_message <- shiny::renderUI(shiny::div(class = "login-error", "You don't have access to this application."))
        return()
      }
      created_by_app <- if (is.null(require_app_key)) NA_character_ else require_app_key
      sess <- if (session_backend == "s3") {
        create_session_s3(res$user_id, session_secret, created_by_app = created_by_app)
      } else {
        create_session(con, res$user_id, session_secret, created_by_app = created_by_app)
      }
      push_cookie(sess$cookie_value, sess$max_age_secs)
      state$logged_in <- TRUE
      state$user_id <- res$user_id
      state$username <- res$username
      state$org_unit <- get_user_org_unit(con, res$user_id)
      record_app_access(res$user_id)
    })

    result <- list(
      logged_in = shiny::reactive(state$logged_in),
      checked = shiny::reactive(state$checked),
      user_id = shiny::reactive(state$user_id),
      username = shiny::reactive(state$username),
      org_unit = shiny::reactive(state$org_unit),
      has_permission = function(app_key, permission_name) {
        if (is.null(state$user_id)) return(FALSE)
        cache_key <- paste(state$user_id, app_key, permission_name, sep = "::")
        cached <- permission_cache[[cache_key]]
        if (!is.null(cached) && as.numeric(difftime(Sys.time(), cached$at, units = "secs")) < permission_cache_ttl_secs) {
          return(cached$value)
        }
        result <- user_has_permission(con, state$user_id, app_key, permission_name)
        permission_cache[[cache_key]] <- list(value = result, at = Sys.time())
        result
      },
      # Generic group-membership check (see user_is_in_group()) -- e.g. a
      # plain "team_leads" group, checked as auth$is_in_group("team_leads"),
      # needs no schema or admin-UI work of its own since ordinary group
      # management already covers creating it and adding/removing members.
      # Cached the same way and for the same reason as has_permission().
      is_in_group = function(group_key) {
        if (is.null(state$user_id)) return(FALSE)
        cache_key <- paste(state$user_id, "group", group_key, sep = "::")
        cached <- permission_cache[[cache_key]]
        if (!is.null(cached) && as.numeric(difftime(Sys.time(), cached$at, units = "secs")) < permission_cache_ttl_secs) {
          return(cached$value)
        }
        result <- user_is_in_group(con, state$user_id, group_key)
        permission_cache[[cache_key]] <- list(value = result, at = Sys.time())
        result
      },
      logout = function() {
        if (!is.null(input$auth_cookie_in) && nzchar(input$auth_cookie_in)) {
          if (session_backend == "s3") revoke_session_s3(input$auth_cookie_in) else revoke_session(con, input$auth_cookie_in)
        }
        clear_cookie()
        state$logged_in <- FALSE
        state$user_id <- NULL
        state$username <- NULL
        state$org_unit <- NULL
        permission_cache <<- new.env(parent = emptyenv())
      }
    )

    # session$userData isn't namespaced by module (unlike input/output), so
    # this is reachable from any module nested anywhere under the app's
    # top-level server -- session$userData$authClient$user_id() -- without
    # auth having to be threaded through every intermediate function
    # signature. Keyed by package name, not something generic like "auth",
    # since userData has no enforced namespacing and a collision would
    # silently overwrite whichever assignment ran second.
    session$userData$authClient <- result

    result
  })
}
