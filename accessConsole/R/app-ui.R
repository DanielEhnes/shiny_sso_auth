build_console_ui <- function() {
  shiny::navbarPage(
    title = "App Access Manager",
    id = "main_nav",
    header = shiny::tags$head(
      shiny::includeCSS(system.file("www/console-theme.css", package = "accessConsole"))
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
    # app-server.R). Named "Account", not "Change Password" -- a natural
    # home for other self-service account settings/preferences later
    # without having to touch navigation again.
    shiny::tabPanel(
      "Account", value = "account_tab",
      shiny::fluidPage(
        shiny::br(),
        shiny::column(width = 4, offset = 4,
          shiny::uiOutput("change_password_area"),
          shiny::br(),
          # Same "auth-card" class (and so the same width) as the
          # change-password box above, rather than a plain Bootstrap .well
          # that would just fill the whole column.
          shiny::div(class = "auth-card",
            shiny::h4("Your app access"),
            shiny::tableOutput("my_app_access_table"),
            shiny::h4("Your groups"),
            shiny::tableOutput("my_groups_table")
          )
        )
      )
    )
  )
}
