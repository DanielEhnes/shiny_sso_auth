build_console_ui <- function() {
  shiny::navbarPage(
    title = "App Access Manager",

    shiny::tabPanel(
      "Create Account",
      shiny::fluidPage(
        shiny::br(),
        shiny::column(
          width = 4, offset = 4,
          shiny::wellPanel(
            shiny::h3("Create an account"),
            shiny::textInput("username", "Username"),
            shiny::textInput("signup_email", "Email"),
            shiny::passwordInput("signup_password", "Password"),
            shiny::passwordInput("signup_password_confirm", "Confirm password"),
            shiny::actionButton("signup_btn", "Create account", class = "btn-primary"),
            shiny::br(), shiny::br(),
            shiny::uiOutput("signup_message")
          )
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
    )
  )
}
