build_console_ui <- function() {
  shiny::navbarPage(
    title = "App Access Manager",
    id = "main_nav",
    header = shiny::tags$head(
      shiny::includeCSS(system.file("www/console-theme.css", package = "accessConsole"))
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

    shiny::tabPanel(
      "Admin",
      shiny::fluidPage(
        shiny::br(),
        authClient::authLoginUI("console_auth"),
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
