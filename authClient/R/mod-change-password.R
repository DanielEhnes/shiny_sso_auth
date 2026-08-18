# Self-service password change, shared across every app since it's
# identity-level, not console-specific. Revokes every other session for the
# user on success -- a changed password should invalidate any existing SSO
# cookie issued under the old one.

#' Change-password UI
#'
#' @param id The Shiny module ID.
#' @return A `shiny::wellPanel()` to place in your UI.
#' @export
changePasswordUI <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::tags$head(
      shiny::includeCSS(system.file("www/auth-forms.css", package = "authClient"))
    ),
    shiny::div(class = "auth-card",
      shiny::h4("Change password"),
      shiny::passwordInput(ns("current_password"), "Current password"),
      shiny::passwordInput(ns("new_password"), "New password"),
      shiny::passwordInput(ns("new_password_confirm"), "Confirm new password"),
      shiny::actionButton(ns("change_password_btn"), "Change password", class = "btn btn-primary"),
      shiny::uiOutput(ns("change_password_message"))
    )
  )
}

#' Change-password server logic
#'
#' Verifies the current password, validates the new one, and revokes every
#' other session belonging to the user on success.
#'
#' @param id The Shiny module ID, must match the corresponding
#'   [changePasswordUI()] call.
#' @param con A DBI connection or pool object.
#' @param user_id A reactive returning the logged-in user's ID (e.g.
#'   `auth$user_id` from [authLoginServer()]).
#' @param session_backend `"sql"` (default) or `"s3"` -- must match
#'   whatever was passed to [authLoginServer()] for this same deployment,
#'   since it determines where the sessions being revoked actually live.
#' @return `NULL`, invisibly (side-effecting module server).
#' @export
changePasswordServer <- function(id, con, user_id, session_backend = c("sql", "s3")) {
  session_backend <- match.arg(session_backend)
  shiny::moduleServer(id, function(input, output, session) {
    output$change_password_message <- shiny::renderUI(NULL)
    shiny::observeEvent(input$change_password_btn, {
      uid <- user_id()
      shiny::req(uid)
      current_pw <- input$current_password
      new_pw <- input$new_password
      new_pw2 <- input$new_password_confirm
      msg <- NULL
      if (!verify_user_password(con, uid, current_pw)) {
        msg <- "Current password is incorrect."
      } else if (nchar(new_pw) < 8) {
        msg <- "New password must be at least 8 characters."
      } else if (new_pw != new_pw2) {
        msg <- "New passwords do not match."
      } else if (new_pw == current_pw) {
        msg <- "New password must be different from the current password."
      }
      if (!is.null(msg)) {
        output$change_password_message <- shiny::renderUI(shiny::div(class = "login-error", msg))
        return()
      }
      set_user_password(con, uid, new_pw)
      if (session_backend == "s3") revoke_all_sessions_for_user_s3(uid) else revoke_all_sessions_for_user(con, uid)
      output$change_password_message <- shiny::renderUI(shiny::div(class = "login-success", "Password changed."))
      shiny::updateTextInput(session, "current_password", value = "")
      shiny::updateTextInput(session, "new_password", value = "")
      shiny::updateTextInput(session, "new_password_confirm", value = "")
    })
  })
}
