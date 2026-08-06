# Example: gating a tab's visibility on a permission, using authClient's
# has_permission(). Run this as its own app (library(shiny); runApp(...))
# against a database that already has authClient's/accessConsole's schema
# applied.
#
# One-time setup in the console (Admin -> Console context) before this
# will show anything interesting:
#   1. Create an app with key "example_app".
#   2. Create a permission "reports.view" on that app.
#   3. Create a role on that app, assign it the "reports.view" permission.
#   4. Grant a user that role (per-user, or via a group).
#
# has_permission() checks user_roles/group_roles -> role_permissions,
# scoped to "example_app" -- see authClient::user_has_permission().
#
# Two tabs below demonstrate two different ways to gate the SAME
# permission, contrasting what an unauthorized user's browser actually
# receives:
#   - "Reports" (nav_show()/nav_hide()): the tab's static markup is
#     always part of the page's initial HTML -- hiding it is a
#     client-side visibility toggle. Its reactive outputs are still never
#     computed while hidden (Shiny's outputOptions(suspendWhenHidden)
#     defaults to TRUE), so no live data leaks, only the static shell.
#   - "Reports (dynamic)" (nav_insert()/nav_remove()): the tab doesn't
#     exist in the static UI at all -- nothing (not even its label or
#     layout) reaches the browser until nav_insert() adds it server-side.
#     Strictly more private, at the cost of tracking insertion state
#     yourself. Reach for this when the tab's mere existence/label is
#     itself sensitive, not just the data behind it.

library(shiny)
library(bslib)
library(pool)
library(RSQLite)
library(authClient)

APP_KEY <- "example_app"

ui <- page_navbar(
  title = "Example App",
  id = "main_nav",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  # Bootstrap's CSS/JS needs to be present even before page_navbar's own
  # content has rendered anything -- see bs_theme_dependencies() note in
  # the login-form-in-a-tagList discussion. page_navbar() already
  # supplies it here since it's the actual top-level ui, so no extra step
  # needed in this particular layout.
  header = authClient::authLoginUI("auth"),

  nav_panel("Home", value = "home_tab",
    p("Anyone can see this tab, logged in or not.")
  ),

  # Hidden by default -- shown only once the logged-in user holds the
  # "reports.view" permission on "example_app". nav_panel() still needs
  # to exist in the static UI (nav_show()/nav_hide() only toggle
  # visibility of a tab that's already there, they don't add/remove one).
  nav_panel("Reports", value = "reports_tab",
    p("Only visible to users with the 'reports.view' permission.")
  )

  # "Reports (dynamic)" is deliberately NOT declared here -- that's the
  # whole point of nav_insert()/nav_remove() (see server below): it
  # doesn't exist in the page's initial HTML at all until inserted.
)

server <- function(input, output, session) {
  con <- pool::dbPool(RSQLite::SQLite(), dbname = "path/to/shared.sqlite")
  onStop(function() pool::poolClose(con))

  auth <- authClient::authLoginServer("auth", con, require_app_key = APP_KEY)

  # nav_hide() at the start, same reasoning as accessConsole's own
  # hideTab()/showTab() pattern for its Account/Admin tabs -- there's
  # nothing useful behind "Reports" until we know the user qualifies.
  nav_hide("main_nav", target = "reports_tab")

  observe({
    can_view_reports <- isTRUE(auth$logged_in()) && auth$has_permission(APP_KEY, "reports.view")
    if (can_view_reports) {
      nav_show("main_nav", target = "reports_tab")
    } else {
      nav_hide("main_nav", target = "reports_tab")
    }
  })

  # Dynamic counterpart: unlike nav_show()/nav_hide(), nav_insert()/
  # nav_remove() aren't idempotent -- inserting a tab that's already
  # there, or removing one that isn't, is an error. dynamic_tab_inserted
  # is the guard that makes this safe to call on every reactive
  # invalidation, not just once.
  dynamic_tab_inserted <- reactiveVal(FALSE)

  observe({
    can_view_reports <- isTRUE(auth$logged_in()) && auth$has_permission(APP_KEY, "reports.view")
    if (can_view_reports && !dynamic_tab_inserted()) {
      nav_insert("main_nav", nav = nav_panel("Reports (dynamic)", value = "reports_dynamic_tab",
        p("Only visible to users with the 'reports.view' permission -- and never sent to the browser at all otherwise.")
      ))
      dynamic_tab_inserted(TRUE)
    } else if (!can_view_reports && dynamic_tab_inserted()) {
      nav_remove("main_nav", target = "reports_dynamic_tab")
      dynamic_tab_inserted(FALSE)
    }
  })
}

shinyApp(ui, server)
