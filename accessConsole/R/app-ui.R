build_console_ui <- function() {
  shiny::navbarPage(
    title = "App Access Manager",
    id = "main_nav",
    header = shiny::tags$head(
      shiny::includeCSS(system.file("www/console-theme.css", package = "accessConsole")),
      # Registered once, statically, rather than via a dynamic insertUI()
      # call -- only the Logout <li>'s *position* needs to be inserted at
      # runtime, this handler just needs to exist before the first
      # session$sendCustomMessage("set_account_tab_label", ...) call.
      shiny::tags$script(shiny::HTML(
        "Shiny.addCustomMessageHandler('set_account_tab_label', function(username) {
           $('#account_tab_username').text(username);
         });"
      ))
    ),

    # First tab: the normal login form (authLoginUI's own login_area output
    # self-hides once logged in -- see authClient's mod-login.R), followed
    # by the card-deck of registered apps once logged in.
    shiny::tabPanel(
      "Landing Zone", value = "landing_zone_tab",
      shiny::fluidPage(
        shiny::br(),
        authClient::authLoginUI("console_auth"),
        shiny::uiOutput("landing_zone_ui")
      )
    ),

    shiny::tabPanel(
      "Create Account",
      shiny::fluidPage(
        shiny::div(class = "auth-card login-box",
          shiny::h3("Create an account"),
          shiny::textInput("username", "Username"),
          shiny::textInput("signup_email", "Email"),
          shiny::passwordInput("signup_password", "Password"),
          shiny::passwordInput("signup_password_confirm", "Confirm password"),
          shiny::actionButton("signup_btn", "Create account", class = "btn btn-primary"),
          shiny::uiOutput("signup_message")
        )
      )
    ),

    # Login form now lives on the Landing Zone tab -- authLoginUI() must
    # only be called once, since it's a Shiny module with its own fixed
    # namespaced output id.
    shiny::tabPanel(
      "Admin", value = "admin_tab",
      shiny::fluidPage(
        shiny::br(),
        shiny::uiOutput("admin_area")
      )
    ),

    # Hidden until login (see the showTab()/hideTab() logic in
    # app-server.R). Content-wise this is still "Account", not "Change
    # Password" -- a natural home for other self-service account
    # settings/preferences later. Its title is a placeholder span
    # (filled in with the username server-side) plus a person icon. It
    # stays a normal tab in its normal DOM position -- showTab()/hideTab()
    # resolve tabs by searching *within* #main_nav (confirmed by reading
    # shiny.js directly), so physically relocating this <li> elsewhere
    # would break login/logout after the first move. Positioned top-right
    # via CSS float only (see #main_nav li:has(...) in console-theme.css),
    # not a DOM move.
    shiny::tabPanel(
      title = shiny::tags$span(id = "account_tab_username"),
      value = "account_tab",
      icon = shiny::icon("user"),
      shiny::fluidPage(
        shiny::br(),
        # Left: who you are. Middle: what you have access to. Right:
        # change password -- changePasswordUI() already wraps itself in
        # an .auth-card, so it's the only one of the three not given an
        # explicit wrapper div here.
        shiny::fluidRow(
          shiny::column(width = 4,
            shiny::div(class = "auth-card",
              shiny::h4("Your profile"),
              shiny::uiOutput("my_profile_info")
            )
          ),
          shiny::column(width = 4,
            shiny::div(class = "auth-card",
              shiny::h4("Your app access"),
              shiny::tableOutput("my_app_access_table"),
              shiny::h4("Your groups"),
              shiny::tableOutput("my_groups_table")
            )
          ),
          shiny::column(width = 4,
            shiny::uiOutput("change_password_area")
          )
        )
      )
    )
  )
}
