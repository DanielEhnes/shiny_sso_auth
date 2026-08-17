# Near-verbatim relocation of the original R/app.R server function. The only
# real changes: wrapped as build_console_server() (called once by
# run_admin_console()), and the three identity operations (login, change
# password) now delegate to authClient rather than local db_pool-backed
# copies. Everything else -- console/app/groups panel UI+observers -- is
# unchanged, still one flat closure (not literal Shiny modules) to keep this
# a low-risk, behavior-preserving split rather than a rewrite.
build_console_server <- function() {
  function(input, output, session) {

    # --------------------------------------------------------------------
    # Sign-up
    # --------------------------------------------------------------------

    output$signup_message <- renderUI(NULL)

    observeEvent(input$signup_btn, {
      username <- trimws(input$username)
      email <- trimws(input$signup_email)
      pw <- input$signup_password
      pw2 <- input$signup_password_confirm
      msg <- NULL

      if (!email_is_valid(email)) {
        msg <- "Please enter a valid email address."
      } else if (email_exists(email)) {
        msg <- "An account with that email already exists."
      } else if (nchar(pw) < 8) {
        msg <- "Password must be at least 8 characters."
      } else if (pw != pw2) {
        msg <- "Passwords do not match."
      }

      if (!is.null(msg)) {
        output$signup_message <- renderUI(div(style = "color: #b00020;", msg))
        return()
      }

      create_user(username = username, email = email, password = pw)
      output$signup_message <- renderUI(div(style = "color: #1a7d1a;", "Account created."))
      updateTextInput(session, "signup_email", value = "")
      updateTextInput(session, "signup_password", value = "")
      updateTextInput(session, "signup_password_confirm", value = "")
    })

    # --------------------------------------------------------------------
    # Admin auth state -- delegated to authClient's SSO module.
    # Gated on admin_console access like any other app -- every user gets
    # that access automatically via the basic_user group (create_user() /
    # run_initial_setup()), so this still means "any registered account may
    # log in" in practice. What they see afterward still depends on
    # get_admin_apps_for_user(), not on this gate. Also means console logins
    # now get real app-scoped audit logging and session attribution instead
    # of the NULL/NA placeholder require_app_key = NULL implied.
    # --------------------------------------------------------------------

    auth <- authClient::authLoginServer("console_auth", .pkgenv$con, require_app_key = ADMIN_CONSOLE_KEY)
    authClient::changePasswordServer("console_pw", .pkgenv$con, auth$user_id)

    # "Account" tab (currently just change-password, a natural home for
    # other self-service settings later) and "Admin" tab (its own login
    # form moved to the Landing Zone tab, so there's nothing useful to show
    # here while logged out either) are both hidden until logged in, and
    # re-hidden on logout.
    hideTab(inputId = "main_nav", target = "account_tab")
    hideTab(inputId = "main_nav", target = "admin_tab")
    observe({
      if (isTRUE(auth$logged_in())) {
        showTab(inputId = "main_nav", target = "account_tab")
        showTab(inputId = "main_nav", target = "admin_tab")
      } else {
        hideTab(inputId = "main_nav", target = "account_tab")
        hideTab(inputId = "main_nav", target = "admin_tab")
      }
    })

    # ------------------------------------------------------------------
    # Top-right navbar area: Account (username + person icon) followed by
    # Logout (power-off icon) -- replaces what used to be three separate
    # "Logged in as X / Log out" spots (Landing Zone, and both branches
    # of admin_area). Account stays a normal tab in its normal DOM
    # position (see the comment on its tabPanel() in app-ui.R for why --
    # showTab()/hideTab() resolve tabs by searching inside #main_nav, so
    # relocating it would break login/logout) -- it's positioned
    # top-right by CSS float alone (console-theme.css). Logout is a new,
    # plain <li>, inserted once per session immediately before Account's
    # <li> -- both float:right, and CSS stacks earlier-in-source-order
    # floats furthest right, so this insertion order puts Account to
    # Logout's *left*, without moving anything that already existed.
    # ------------------------------------------------------------------

    insertUI(
      selector = '#main_nav li:has(> a[data-value="account_tab"])',
      where = "beforeBegin",
      ui = tags$li(class = "navbar-right-item", uiOutput("navbar_logout_area", inline = TRUE))
    )

    observe({
      req(auth$logged_in())
      session$sendCustomMessage("set_account_tab_label", auth$username())
    })

    output$navbar_logout_area <- renderUI({
      req(auth$logged_in())
      actionLink("navbar_logout_btn", tagList(icon("power-off"), " Logout"), style = "color:#FFFFF2; font-weight:600;")
    })

    observeEvent(input$navbar_logout_btn, {
      auth$logout()
    })

    # ------------------------------------------------------------------
    # Landing Zone: the first tab. Shows a card-deck of every registered
    # app once logged in -- both apps the user already has access to
    # (clickable) and ones they don't yet (locked, but still shown so
    # they can see who to ask -- see get_landing_apps_for_user()).
    # ------------------------------------------------------------------

    output$landing_zone_ui <- renderUI({
      req(auth$checked())
      if (!auth$logged_in()) return(NULL)
      refresh_trigger()

      apps <- get_landing_apps_for_user(auth$user_id())

      cards <- lapply(seq_len(nrow(apps)), function(i) {
        app <- apps[i, ]
        locked <- app$has_access == 0

        icon <- if (!is.na(app$icon_url) && nzchar(app$icon_url)) {
          tags$img(src = app$icon_url, class = "landing-card-icon")
        } else {
          div(class = "landing-card-icon-badge", toupper(substr(app$name, 1, 1)))
        }

        contact <- if (!is.na(app$owner_contact) && nzchar(app$owner_contact)) {
          div(class = "landing-card-contact",
            HTML(paste0("Ansprechpartner: <a href='mailto:", app$owner_contact, "'>", app$owner_contact, "</a>")))
        } else {
          NULL
        }

        has_tooltip <- !is.na(app$tooltip_text) && nzchar(app$tooltip_text)
        card_attrs <- list(
          class = if (locked) "landing-card locked" else "landing-card",
          `data-toggle` = if (has_tooltip) "tooltip" else NULL,
          `data-placement` = if (has_tooltip) "bottom" else NULL,
          `data-html` = if (has_tooltip) "true" else NULL,
          title = if (has_tooltip) app$tooltip_text else NULL,
          onclick = if (!locked) sprintf("window.open('%s', '_blank')", app$url) else NULL
        )

        description <- if (!is.na(app$description) && nzchar(app$description)) p(app$description) else NULL

        # Wrapped together (not just adjacent tagList siblings) so the
        # card and its contact info are one flex item inside
        # .landing-card-deck -- contact is centered below the card, and
        # the two move/wrap together as a unit.
        div(class = "landing-card-wrapper",
          do.call(div, c(card_attrs, list(
            div(class = "landing-card-header", icon, h4(app$name)),
            description
          ))),
          contact
        )
      })

      tagList(
        div(class = "landing-card-deck", cards),
        tags$script(HTML("$('[data-toggle=\"tooltip\"]').tooltip();"))
      )
    })

    output$change_password_area <- renderUI({
      req(auth$checked())
      if (!auth$logged_in()) return(NULL)
      authClient::changePasswordUI("console_pw")
    })

    output$my_profile_info <- renderUI({
      req(auth$logged_in())
      org_unit <- authClient::get_user_org_unit(.pkgenv$con, auth$user_id())
      tagList(
        p(strong("Username: "), auth$username()),
        p(strong("Email: "), get_user_email(auth$user_id())),
        if (!is.null(org_unit)) p(strong("Organizational Unit: "), org_unit$name) else NULL
      )
    })

    output$my_app_access_table <- renderTable({
      req(auth$logged_in())
      apps <- get_user_accessible_apps(auth$user_id())
      data.frame(App = apps$name)
    })

    output$my_groups_table <- renderTable({
      req(auth$logged_in())
      groups <- get_groups_for_user(auth$user_id())
      groups <- groups[groups$group_key != BASIC_USER_GROUP_KEY, ]
      data.frame(Group = groups$name)
    })

    refresh_trigger <- reactiveVal(0)

    # Panels get fully rebuilt on every refresh_trigger() tick, which would
    # otherwise reset any selectInput lacking an explicit `selected=` back to
    # its first choice. Keep the current selection when it's still valid.
    keep_selected <- function(current, choices, default = if (length(choices) > 0) choices[1] else NULL) {
      if (!is.null(current) && current %in% choices) current else default
    }

    # dateInput(value = as.Date(NA)) warns ("Couldn't coerce the `value`
    # argument to a date string...") -- it wants NULL for "no date", not
    # an NA-valued Date. get_user/group_app_access_status() return NA
    # (no window set, by far the common case), so every render of the
    # access panels warned without this.
    na_date_to_null <- function(x) if (is.na(x)) NULL else as.Date(x)

    # Holds the app/group awaiting a retype-the-key confirmation in a modal.
    pending_delete_app <- reactiveValues(app_id = NULL, app_key = NULL, name = NULL)
    pending_delete_group <- reactiveValues(group_id = NULL, group_key = NULL, name = NULL)
    pending_delete_role <- reactiveValues(role_id = NULL, role_name = NULL)
    pending_delete_permission <- reactiveValues(permission_id = NULL, permission_name = NULL)

    output$admin_area <- renderUI({
      req(auth$checked())  # avoid flashing empty content before the SSO cookie check resolves
      if (!auth$logged_in()) return(NULL)

      refresh_trigger()

      admin_apps <- get_admin_apps_for_user(auth$user_id())

      if (nrow(admin_apps) == 0) {
        return(fluidPage(
          div(em("You don't administer any apps yet. Ask a Admin Console admin to grant you rights."))
        ))
      }

      fluidPage(
        selectInput(
          "managing_app", "Managing:",
          choices = setNames(admin_apps$app_id, admin_apps$name),
          selected = keep_selected(input$managing_app, admin_apps$app_id),
          width = "100%"
        ),
        uiOutput("app_management_ui")
      )
    })

    managing_app_id <- reactive({
      req(input$managing_app)
      input$managing_app
    })

    is_console_context <- reactive({
      req(auth$logged_in())
      managing_app_id() == get_admin_console_app_id()
    })

    is_groups_context <- reactive({
      req(auth$logged_in())
      managing_app_id() == get_groups_admin_app_id()
    })

    is_activity_context <- reactive({
      req(auth$logged_in())
      managing_app_id() == get_activity_admin_app_id()
    })

    # --------------------------------------------------------------------
    # Branch: console context vs. groups context vs. activity context vs.
    # regular-app context
    # --------------------------------------------------------------------

    output$app_management_ui <- renderUI({
      req(auth$logged_in())
      refresh_trigger()
      if (is_console_context()) {
        console_panel_ui()
      } else if (is_groups_context()) {
        groups_panel_ui()
      } else if (is_activity_context()) {
        activity_panel_ui()
      } else {
        app_panel_ui(managing_app_id())
      }
    })

    # ====================================================================
    # CONSOLE CONTEXT: create apps, grant/revoke app_admin anywhere,
    # block/unblock whole accounts.
    # ====================================================================

    console_panel_ui <- function() {
      all_apps <- get_all_apps()
      all_users <- get_all_users()
      deletable_apps <- all_apps[!(all_apps$app_key %in% c(ADMIN_CONSOLE_KEY, GROUPS_ADMIN_KEY, ACTIVITY_ADMIN_KEY)), ]

      tagList(
        wellPanel(
          h4("Create a new app"),
          textInput("new_app_key", "App key (unique, e.g. 'invoicing')"),
          textInput("new_app_name", "Display name"),
          textInput("new_app_description", "Description (also the Landing Zone card text)"),
          helpText("The fields below are optional and only matter for the Landing Zone page -- leave them blank if you don't know them yet; the app owner can set/update them later via accessConsole::register_landing_app()."),
          textInput("new_app_url", "Landing Zone URL"),
          textInput("new_app_owner_contact", "Contact email"),
          textInput("new_app_icon_url", "Icon URL"),
          textInput("new_app_tooltip_text", "Tooltip text (shown on hover, separate from the description above)"),
          actionButton("create_app_btn", "Create app", class = "btn-sm btn-primary"),
          uiOutput("create_app_message")
        ),
        wellPanel(
          h4("Edit an app's Landing Zone details"),
          selectInput("edit_app_target", "App", choices = setNames(all_apps$app_id, all_apps$name), selected = keep_selected(input$edit_app_target, all_apps$app_id)),
          uiOutput("edit_app_fields_ui"),
          actionButton("save_app_landing_btn", "Save", class = "btn-sm btn-primary"),
          uiOutput("save_app_landing_message")
        ),
        wellPanel(
          h4("Grant app_admin rights"),
          helpText("This lets someone administer roles, permissions, and user access for the chosen app -- or, if you pick Admin Console, lets them do everything you can do here."),
          selectInput("grant_target_app", "App", choices = setNames(all_apps$app_id, all_apps$name), selected = keep_selected(input$grant_target_app, all_apps$app_id)),
          selectInput("grant_target_user", "User", choices = setNames(all_users$user_id, all_users$email), selected = keep_selected(input$grant_target_user, all_users$user_id)),
          actionButton("grant_admin_btn", "Grant", class = "btn-sm btn-primary"),
          uiOutput("grant_admin_message")
        ),
        wellPanel(
          h4("Revoke app_admin rights"),
          selectInput("revoke_target_app", "App", choices = setNames(all_apps$app_id, all_apps$name), selected = keep_selected(input$revoke_target_app, all_apps$app_id)),
          uiOutput("revoke_target_user_ui"),
          actionButton("revoke_admin_btn", "Revoke", class = "btn-sm"),
          uiOutput("app_admin_revoked"),
        ),
        wellPanel(
          h4("Disable or activate a user's whole account"),
          helpText("This affects every app the user has access to, not just one."),
          selectInput("status_target_user", "User", choices = setNames(all_users$user_id, paste0(all_users$email, " (", all_users$status, ")")), selected = keep_selected(input$status_target_user, all_users$user_id)),
          radioButtons("status_target_value", "Status", choices = c("Active" = "active", "Disabled" = "disabled"), inline = TRUE),
          actionButton("save_account_status_btn", "Update account status", class = "btn-sm"),
          uiOutput("account_status_message")
        ),
        wellPanel(
          h4("Delete an app"),
          helpText("Permanently deletes the app, its roles, permissions, and all user/group access to it. This cannot be undone."),
          if (nrow(deletable_apps) == 0) {
            helpText("No deletable apps yet.")
          } else {
            tagList(
              selectInput("delete_target_app", "App", choices = setNames(deletable_apps$app_id, deletable_apps$name), selected = keep_selected(input$delete_target_app, deletable_apps$app_id)),
              actionButton("delete_app_btn", "Delete app", class = "btn-sm btn-danger")
            )
          }
        )
      )
    }

    output$create_app_message <- renderUI(NULL)
    observeEvent(input$create_app_btn, {
      key <- as.character(trimws(input$new_app_key))
      app_name <- as.character(trimws(input$new_app_name))
      description <- as.character(trimws(input$new_app_description))
      blank_to_null <- function(x) if (nzchar(x)) x else NULL
      url <- blank_to_null(trimws(input$new_app_url))
      owner_contact <- blank_to_null(trimws(input$new_app_owner_contact))
      icon_url <- blank_to_null(trimws(input$new_app_icon_url))
      tooltip_text <- blank_to_null(trimws(input$new_app_tooltip_text))
      msg <- NULL
      if (key == "" || app_name == "") {
        msg <- "App key and name are both required."
      } else if (nchar(key) < 4) {
        msg <- "App key must be at least 4 characters."
      } else if (nchar(app_name) < 4) {
        msg <- "App name must be at least 4 characters."
      } else if (!grepl("^[a-z0-9_\\-]+$", key)) {
        msg <- "App key can only contain lowercase letters, numbers, - and _."
      } else if (app_key_exists(key)) {
        msg <- "That app key is already in use."
      }
      if (!is.null(msg)) {
        output$create_app_message <- renderUI(div(style = "color: #b00020;", msg))
        return()
      }
      app_id <- create_app(key, app_name, description, url = url, owner_contact = owner_contact,
                           icon_url = icon_url, tooltip_text = tooltip_text)
      permission_id <- create_permission("admin", paste0("App Admin Role for ", app_name), app_id)
      role_id <- create_role(paste0(key, "_admin"), paste0("Admin Role for ", app_name), app_id)
      set_role_permissions(role_id, c(permission_id))
      output$create_app_message <- renderUI(div(style = "color: #1a7d1a;", paste0("App '", app_name, "' created.")))
      updateTextInput(session, "new_app_key", value = "")
      updateTextInput(session, "new_app_name", value = "")
      updateTextInput(session, "new_app_description", value = "")
      updateTextInput(session, "new_app_url", value = "")
      updateTextInput(session, "new_app_owner_contact", value = "")
      updateTextInput(session, "new_app_icon_url", value = "")
      updateTextInput(session, "new_app_tooltip_text", value = "")
      refresh_trigger(refresh_trigger() + 1)
    })

    output$edit_app_fields_ui <- renderUI({
      req(input$edit_app_target)
      refresh_trigger()
      current <- get_app_details(as.character(input$edit_app_target))
      na_to_blank <- function(x) if (is.na(x)) "" else x
      tagList(
        textInput("edit_app_description", "Description (also the Landing Zone card text)", value = na_to_blank(current$description[1])),
        textInput("edit_app_url", "Landing Zone URL", value = na_to_blank(current$url[1])),
        textInput("edit_app_owner_contact", "Contact email", value = na_to_blank(current$owner_contact[1])),
        textInput("edit_app_icon_url", "Icon URL", value = na_to_blank(current$icon_url[1])),
        textInput("edit_app_tooltip_text", "Tooltip text (shown on hover, separate from the description above)", value = na_to_blank(current$tooltip_text[1]))
      )
    })

    output$save_app_landing_message <- renderUI(NULL)
    observeEvent(input$save_app_landing_btn, {
      req(input$edit_app_target)
      blank_to_na <- function(x) if (nzchar(trimws(x))) trimws(x) else NA_character_
      update_app_landing_info(
        as.character(input$edit_app_target),
        description = blank_to_na(input$edit_app_description),
        url = blank_to_na(input$edit_app_url),
        owner_contact = blank_to_na(input$edit_app_owner_contact),
        icon_url = blank_to_na(input$edit_app_icon_url),
        tooltip_text = blank_to_na(input$edit_app_tooltip_text)
      )
      output$save_app_landing_message <- renderUI(div(style = "color: #1a7d1a;", "Saved."))
      refresh_trigger(refresh_trigger() + 1)
    })

    output$grant_admin_message <- renderUI(NULL)
    observeEvent(input$grant_admin_btn, {
      grant_app_admin(as.character(input$grant_target_user), as.character(input$grant_target_app), auth$user_id())
      output$grant_admin_message <- renderUI(div(style = "color: #1a7d1a;", "Granted."))
      refresh_trigger(refresh_trigger() + 1)
    })

    output$revoke_target_user_ui <- renderUI({
      req(input$revoke_target_app)
      refresh_trigger()
      admins <- get_app_admins(as.character(input$revoke_target_app))
      if (nrow(admins) == 0) return(helpText("No admins on this app yet."))
      selectInput("revoke_target_user", "Current admin", choices = setNames(admins$user_id, admins$email))
    })

    observeEvent(input$revoke_admin_btn, {
      req(input$revoke_target_user)
      rows_of_user_roles <- check_if_last_admin(as.character(input$revoke_target_app))

      if (rows_of_user_roles <= 1) {
        output$app_admin_revoked <- renderUI({ helpText("Last admin, please do not remove.") })
        return(NULL)
      }
      revoke_app_admin(as.character(input$revoke_target_user), as.character(input$revoke_target_app))
      output$app_admin_revoked <- renderUI({ helpText("Admin rights revoked.") })
      refresh_trigger(refresh_trigger() + 1)
    })

    output$account_status_message <- renderUI(NULL)
    observeEvent(input$save_account_status_btn, {
      req(input$status_target_user)
      target_id <- as.character(input$status_target_user)

      if (input$status_target_value != "active") {
        console_app_id <- get_admin_console_app_id()
        if (identical(target_id, auth$user_id())) {
          output$account_status_message <- renderUI(helpText("You cannot disable your own account."))
          return()
        }
        is_console_admin <- target_id %in% get_app_admins(console_app_id)$user_id
        if (is_console_admin && check_if_last_admin(console_app_id) <= 1) {
          output$account_status_message <- renderUI(helpText("This is the last admin, please do not disable."))
          return()
        }
      }

      set_user_status(target_id, input$status_target_value)
      output$account_status_message <- renderUI(NULL)
      refresh_trigger(refresh_trigger() + 1)
    })

    observeEvent(input$delete_app_btn, {
      req(input$delete_target_app)
      target <- get_all_apps()
      target <- target[target$app_id == as.character(input$delete_target_app), ]
      req(nrow(target) == 1)
      pending_delete_app$app_id <- target$app_id[1]
      pending_delete_app$app_key <- target$app_key[1]
      pending_delete_app$name <- target$name[1]

      showModal(modalDialog(
        title = paste0("Delete app '", target$name[1], "'?"),
        p("This permanently deletes the app along with its roles, permissions, and all user/group access to it. This cannot be undone."),
        p(strong("Type the app key to confirm: "), code(target$app_key[1])),
        textInput("delete_app_confirm_key", NULL, placeholder = "app key"),
        uiOutput("delete_app_confirm_message"),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("confirm_delete_app_btn", "Delete permanently", class = "btn-danger")
        )
      ))
    })

    output$delete_app_confirm_message <- renderUI(NULL)
    observeEvent(input$confirm_delete_app_btn, {
      req(pending_delete_app$app_id)
      if (!identical(trimws(input$delete_app_confirm_key), pending_delete_app$app_key)) {
        output$delete_app_confirm_message <- renderUI(div(style = "color: #b00020;", "Key doesn't match. Please re-type the exact app key to confirm."))
        return()
      }
      delete_app(pending_delete_app$app_id)
      removeModal()
      pending_delete_app$app_id <- NULL
      pending_delete_app$app_key <- NULL
      pending_delete_app$name <- NULL
      refresh_trigger(refresh_trigger() + 1)
    })

    # ====================================================================
    # REGULAR-APP CONTEXT: manage this app's admins, roles, permissions,
    # and per-app user access/roles. All scoped to `app_id`.
    # ====================================================================

    app_panel_ui <- function(app_id) {
      all_users <- get_all_users()
      all_groups <- get_all_groups()
      admins <- get_app_admins(app_id)
      roles <- get_roles_for_app(app_id)
      perms <- get_permissions_for_app(app_id)
      admin_role_id <- get_app_admin_role(app_id)
      deletable_roles <- roles[!(roles$role_id %in% admin_role_id), ]
      deletable_perms <- perms[perms$permission_name != "admin", ]

      tagList(
        wellPanel(
          h4("Admins for this app"),
          p(paste("Current:", paste(admins$email, collapse = ", "))),
          selectInput("new_app_admin_user", "Add admin", choices = setNames(all_users$user_id, all_users$email), selected = keep_selected(input$new_app_admin_user, all_users$user_id)),
          actionButton("add_app_admin_btn", "Add as admin", class = "btn-sm btn-primary"),
          if (nrow(admins) > 0) {
            tagList(
              selectInput("remove_app_admin_user", "Remove admin", choices = setNames(admins$user_id, admins$email), selected = keep_selected(input$remove_app_admin_user, admins$user_id)),
              actionButton("remove_app_admin_btn", "Remove", class = "btn-sm"),
              uiOutput("app_admin_removed_message")
            )
          }
        ),
        wellPanel(
          h4("Roles"),
          p(paste("Existing:", if (nrow(roles) == 0) "none yet" else paste(roles$role_name, collapse = ", "))),
          textInput("new_role_name", "New role name"),
          textInput("new_role_description", "Description (optional)"),
          actionButton("create_role_btn", "Create role", class = "btn-sm btn-primary"),
          uiOutput("create_role_message"),
          hr(),
          if (nrow(deletable_roles) == 0) {
            helpText("No deletable roles yet.")
          } else {
            tagList(
              selectInput("delete_target_role", "Delete role", choices = setNames(deletable_roles$role_id, deletable_roles$role_name), selected = keep_selected(input$delete_target_role, deletable_roles$role_id)),
              actionButton("delete_role_btn", "Delete role", class = "btn-sm btn-danger")
            )
          }
        ),
        wellPanel(
          h4("Permissions"),
          p(paste("Existing:", if (nrow(perms) == 0) "none yet" else paste(perms$permission_name, collapse = ", "))),
          textInput("new_permission_key", "New permission key (e.g. 'invoice.delete')"),
          textInput("new_permission_desc", "Description (optional)"),
          actionButton("create_permission_btn", "Create permission", class = "btn-sm btn-primary"),
          uiOutput("create_permission_message"),
          hr(),
          if (nrow(deletable_perms) == 0) {
            helpText("No deletable permissions yet.")
          } else {
            tagList(
              selectInput("delete_target_permission", "Delete permission", choices = setNames(deletable_perms$permission_id, deletable_perms$permission_name), selected = keep_selected(input$delete_target_permission, deletable_perms$permission_id)),
              actionButton("delete_permission_btn", "Delete permission", class = "btn-sm btn-danger")
            )
          }
        ),
        wellPanel(
          h4("Assign permissions to a role"),
          if (nrow(roles) == 0) {
            helpText("Create a role first.")
          } else {
            tagList(
              selectInput("perm_assign_role", "Role", choices = setNames(roles$role_id, roles$role_name), selected = keep_selected(input$perm_assign_role, roles$role_id)),
              uiOutput("perm_assign_checkboxes"),
              actionButton("save_role_permissions_btn", "Save permissions for this role", class = "btn-sm btn-primary")
            )
          }
        ),
        wellPanel(
          h4("Manage a user's access & roles for this app"),
          selectInput("manage_user", "User", choices = setNames(all_users$user_id, all_users$email), selected = keep_selected(input$manage_user, all_users$user_id)),
          uiOutput("user_access_roles_ui"),
          uiOutput("user_access_roles_message")
        ),
        wellPanel(
          h4("Manage a group's access & roles for this app"),
          if (nrow(all_groups) == 0) {
            helpText("No groups exist yet. Create one in Groups Management.")
          } else {
            tagList(
              selectInput("manage_group", "Group", choices = setNames(all_groups$group_id, all_groups$name), selected = keep_selected(input$manage_group, all_groups$group_id)),
              uiOutput("group_access_ui")
            )
          }
        )
      )
    }

    # ---- admins for this app ----

    observeEvent(input$add_app_admin_btn, {
      grant_app_admin(as.character(input$new_app_admin_user), managing_app_id(), auth$user_id())
      refresh_trigger(refresh_trigger() + 1)
    })

    output$app_admin_removed_message <- renderUI(NULL)
    observeEvent(input$remove_app_admin_btn, {
      req(input$remove_app_admin_user)
      app_id <- managing_app_id()
      if (check_if_last_admin(app_id) <= 1) {
        output$app_admin_removed_message <- renderUI(helpText("Last admin, please do not remove."))
        return(NULL)
      }
      revoke_app_admin(as.character(input$remove_app_admin_user), app_id)
      refresh_trigger(refresh_trigger() + 1)
    })

    # ---- roles ----

    output$create_role_message <- renderUI(NULL)
    observeEvent(input$create_role_btn, {
      app_id <- managing_app_id()
      role_name <- trimws(input$new_role_name)
      description <- trimws(input$new_role_description)
      msg <- NULL
      if (role_name == "") {
        msg <- "Role name can't be empty."
      } else if (nchar(role_name) < 4) {
        msg <- "Role name must be at least 4 characters."
      } else if (!grepl("^[a-zA-Z0-9_ -]+$", role_name)) {
        msg <- "Role name can only contain letters, numbers, spaces, - and _."
      } else if (role_name_exists(app_id, role_name)) {
        msg <- "This app already has a role with that name."
      }
      if (!is.null(msg)) {
        output$create_role_message <- renderUI(div(style = "color: #b00020;", msg))
        return()
      }
      create_role(role_name, description, app_id)
      output$create_role_message <- renderUI(div(style = "color: #1a7d1a;", "Role created."))
      updateTextInput(session, "new_role_name", value = "")
      updateTextInput(session, "new_role_description", value = "")
      refresh_trigger(refresh_trigger() + 1)
    })

    # ---- permissions ----

    output$create_permission_message <- renderUI(NULL)
    observeEvent(input$create_permission_btn, {
      app_id <- managing_app_id()
      key <- trimws(input$new_permission_key)
      desc <- trimws(input$new_permission_desc)
      msg <- NULL
      if (key == "") {
        msg <- "Permission key can't be empty."
      } else if (!grepl("^[a-zA-Z0-9_.\\-]+$", key)) {
        msg <- "Permission key can only contain letters, numbers, '.', '-' and '_'."
      } else if (permission_name_exists(app_id, key)) {
        msg <- "This app already has a permission with that key."
      }
      if (!is.null(msg)) {
        output$create_permission_message <- renderUI(div(style = "color: #b00020;", msg))
        return()
      }
      create_permission(key, desc, app_id)
      output$create_permission_message <- renderUI(div(style = "color: #1a7d1a;", "Permission created."))
      updateTextInput(session, "new_permission_key", value = "")
      updateTextInput(session, "new_permission_desc", value = "")
      refresh_trigger(refresh_trigger() + 1)
    })

    observeEvent(input$delete_role_btn, {
      req(input$delete_target_role)
      app_id <- managing_app_id()
      target <- get_roles_for_app(app_id)
      target <- target[target$role_id == as.character(input$delete_target_role), ]
      req(nrow(target) == 1)
      pending_delete_role$role_id <- target$role_id[1]
      pending_delete_role$role_name <- target$role_name[1]

      showModal(modalDialog(
        title = paste0("Delete role '", target$role_name[1], "'?"),
        p("This permanently deletes the role, its permission assignments, and removes it from any user who currently holds it. This cannot be undone."),
        p(strong("Type the role name to confirm: "), code(target$role_name[1])),
        textInput("delete_role_confirm_name", NULL, placeholder = "role name"),
        uiOutput("delete_role_confirm_message"),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("confirm_delete_role_btn", "Delete permanently", class = "btn-danger")
        )
      ))
    })

    output$delete_role_confirm_message <- renderUI(NULL)
    observeEvent(input$confirm_delete_role_btn, {
      req(pending_delete_role$role_id)
      if (!identical(trimws(input$delete_role_confirm_name), pending_delete_role$role_name)) {
        output$delete_role_confirm_message <- renderUI(div(style = "color: #b00020;", "Name doesn't match. Please re-type the exact role name to confirm."))
        return()
      }
      delete_role(pending_delete_role$role_id)
      removeModal()
      pending_delete_role$role_id <- NULL
      pending_delete_role$role_name <- NULL
      refresh_trigger(refresh_trigger() + 1)
    })

    observeEvent(input$delete_permission_btn, {
      req(input$delete_target_permission)
      app_id <- managing_app_id()
      target <- get_permissions_for_app(app_id)
      target <- target[target$permission_id == as.character(input$delete_target_permission), ]
      req(nrow(target) == 1)
      pending_delete_permission$permission_id <- target$permission_id[1]
      pending_delete_permission$permission_name <- target$permission_name[1]

      showModal(modalDialog(
        title = paste0("Delete permission '", target$permission_name[1], "'?"),
        p("This permanently deletes the permission and removes it from any role it's assigned to. This cannot be undone."),
        p(strong("Type the permission name to confirm: "), code(target$permission_name[1])),
        textInput("delete_permission_confirm_name", NULL, placeholder = "permission name"),
        uiOutput("delete_permission_confirm_message"),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("confirm_delete_permission_btn", "Delete permanently", class = "btn-danger")
        )
      ))
    })

    output$delete_permission_confirm_message <- renderUI(NULL)
    observeEvent(input$confirm_delete_permission_btn, {
      req(pending_delete_permission$permission_id)
      if (!identical(trimws(input$delete_permission_confirm_name), pending_delete_permission$permission_name)) {
        output$delete_permission_confirm_message <- renderUI(div(style = "color: #b00020;", "Name doesn't match. Please re-type the exact permission name to confirm."))
        return()
      }
      delete_permission(pending_delete_permission$permission_id)
      removeModal()
      pending_delete_permission$permission_id <- NULL
      pending_delete_permission$permission_name <- NULL
      refresh_trigger(refresh_trigger() + 1)
    })

    # ---- role -> permissions ----

    output$perm_assign_checkboxes <- renderUI({
      req(input$perm_assign_role)
      refresh_trigger()
      app_id <- managing_app_id()
      perms <- get_permissions_for_app(app_id)
      if (nrow(perms) == 0) return(helpText("Create a permission first."))
      current <- get_role_permission_ids(as.character(input$perm_assign_role))
      checkboxGroupInput(
        "perm_assign_checks", "Permissions",
        choices = setNames(perms$permission_id, perms$permission_name),
        selected = current
      )
    })

    observeEvent(input$save_role_permissions_btn, {
      req(input$perm_assign_role)
      set_role_permissions(as.character(input$perm_assign_role), as.character(input$perm_assign_checks))
      refresh_trigger(refresh_trigger() + 1)
    })

    # ---- per-user access + roles for this app ----

    output$user_access_roles_ui <- renderUI({
      req(input$manage_user)
      refresh_trigger()
      app_id <- managing_app_id()
      uid <- as.character(input$manage_user)
      roles <- get_roles_for_app(app_id)

      current <- get_user_app_access_status(uid, app_id)
      current_access <- current$status == "active"
      current_roles <- get_user_role_ids_for_app(uid, app_id)
      current_is_temporary <- !is.na(current$valid_from) || !is.na(current$valid_until)

      tagList(
        checkboxInput("user_has_access", "Has access to this app", value = current_access),
        checkboxInput("user_access_is_temporary", "Temporary access (limit to a date range)", value = current_is_temporary),
        conditionalPanel(
          condition = "input.user_access_is_temporary",
          helpText("Leave a field blank for an open-ended start/end."),
          dateInput("user_access_valid_from", "Valid from", value = na_date_to_null(current$valid_from)),
          dateInput("user_access_valid_until", "Valid until", value = na_date_to_null(current$valid_until))
        ),
        if (nrow(roles) > 0) {
          checkboxGroupInput(
            "user_roles_for_app", "Roles for this app",
            choices = setNames(roles$role_id, roles$role_name),
            selected = current_roles
          )
        } else {
          helpText("No roles defined for this app yet.")
        },
        actionButton("save_user_access_roles_btn", "Save", class = "btn-sm btn-primary")
      )
    })

    output$user_access_roles_message <- renderUI(NULL)
    observeEvent(input$save_user_access_roles_btn, {
      req(input$manage_user)
      app_id <- managing_app_id()
      uid <- as.character(input$manage_user)
      new_role_ids <- as.character(input$user_roles_for_app)

      admin_role_id <- get_app_admin_role(app_id)
      is_currently_admin <- admin_role_id %in% get_user_role_ids_for_app(uid, app_id)
      would_remove_admin <- is_currently_admin && !(admin_role_id %in% new_role_ids)

      if (would_remove_admin && check_if_last_admin(app_id) <= 1) {
        output$user_access_roles_message <- renderUI(helpText("Last admin, please do not remove."))
        return()
      }

      is_temporary <- isTRUE(input$user_access_is_temporary)
      set_user_app_access_for_app(uid, app_id, isTRUE(input$user_has_access),
                                   valid_from = if (is_temporary) input$user_access_valid_from else NULL,
                                   valid_until = if (is_temporary) input$user_access_valid_until else NULL)
      set_user_roles_for_app(uid, app_id, new_role_ids)
      output$user_access_roles_message <- renderUI(NULL)
      refresh_trigger(refresh_trigger() + 1)
    })

    # ---- per-group access for this app ----

    output$group_access_ui <- renderUI({
      req(input$manage_group)
      refresh_trigger()
      app_id <- managing_app_id()
      gid <- as.character(input$manage_group)
      roles <- get_roles_for_app(app_id)

      current <- get_group_app_access_status(gid, app_id)
      current_access <- current$status == "active"
      current_roles <- get_group_role_ids_for_app(gid, app_id)
      current_is_temporary <- !is.na(current$valid_from) || !is.na(current$valid_until)

      tagList(
        checkboxInput("group_has_access", "Has access to this app", value = current_access),
        checkboxInput("group_access_is_temporary", "Temporary access (limit to a date range)", value = current_is_temporary),
        conditionalPanel(
          condition = "input.group_access_is_temporary",
          helpText("Leave a field blank for an open-ended start/end."),
          dateInput("group_access_valid_from", "Valid from", value = na_date_to_null(current$valid_from)),
          dateInput("group_access_valid_until", "Valid until", value = na_date_to_null(current$valid_until))
        ),
        if (nrow(roles) > 0) {
          checkboxGroupInput(
            "group_roles_for_app", "Roles for this app",
            choices = setNames(roles$role_id, roles$role_name),
            selected = current_roles
          )
        } else {
          helpText("No roles defined for this app yet.")
        },
        actionButton("save_group_access_btn", "Save", class = "btn-sm btn-primary")
      )
    })

    observeEvent(input$save_group_access_btn, {
      req(input$manage_group)
      app_id <- managing_app_id()
      gid <- as.character(input$manage_group)
      is_temporary <- isTRUE(input$group_access_is_temporary)
      set_group_app_access_for_app(gid, app_id, isTRUE(input$group_has_access),
                                    valid_from = if (is_temporary) input$group_access_valid_from else NULL,
                                    valid_until = if (is_temporary) input$group_access_valid_until else NULL)
      set_group_roles_for_app(gid, app_id, as.character(input$group_roles_for_app))
      refresh_trigger(refresh_trigger() + 1)
    })

    # ====================================================================
    # GROUPS CONTEXT: create groups, manage membership. Independently
    # grantable via the console's existing "Grant/Revoke app_admin rights"
    # UI, targeting the "Groups Management" pseudo-app.
    # ====================================================================

    groups_panel_ui <- function() {
      all_groups <- get_all_groups()
      all_users <- get_all_users()
      org_units <- get_org_units()

      tagList(
        wellPanel(
          h4("Create a new group"),
          textInput("new_group_key", "Group key (unique, e.g. 'reporting-team')"),
          textInput("new_group_name", "Display name"),
          textInput("new_group_description", "Description"),
          radioButtons("new_group_type", "Type",
            choices = c("Standard" = "standard", "Organizational Unit" = "org_unit"), inline = TRUE),
          helpText("Organizational Unit groups are mutually exclusive -- assigning a user to one automatically removes any other. Use the panel below to assign users, not the generic membership panel."),
          actionButton("create_group_btn", "Create group", class = "btn-sm btn-primary"),
          uiOutput("create_group_message")
        ),
        wellPanel(
          h4("Set a user's organizational unit"),
          if (nrow(org_units) == 0) {
            helpText("No Organizational Unit groups exist yet -- create one above first.")
          } else {
            tagList(
              selectInput("org_unit_target_user", "User", choices = setNames(all_users$user_id, all_users$email), selected = keep_selected(input$org_unit_target_user, all_users$user_id)),
              uiOutput("org_unit_select_ui"),
              actionButton("save_org_unit_btn", "Save", class = "btn-sm btn-primary"),
              uiOutput("save_org_unit_message")
            )
          }
        ),
        wellPanel(
          h4("Group membership"),
          if (nrow(all_groups) == 0) {
            helpText("Create a group first.")
          } else {
            tagList(
              selectInput("membership_target_group", "Group", choices = setNames(all_groups$group_id, all_groups$name), selected = keep_selected(input$membership_target_group, all_groups$group_id)),
              uiOutput("group_members_ui"),
              selectInput("add_member_user", "Add user", choices = setNames(all_users$user_id, all_users$email), selected = keep_selected(input$add_member_user, all_users$user_id)),
              actionButton("add_group_member_btn", "Add to group", class = "btn-sm btn-primary"),
              uiOutput("add_group_member_message")
            )
          }
        ),
        wellPanel(
          h4("Delete a group"),
          helpText("Permanently deletes the group and all its memberships. This cannot be undone."),
          if (nrow(all_groups) == 0) {
            helpText("No groups to delete yet.")
          } else {
            tagList(
              selectInput("delete_target_group", "Group", choices = setNames(all_groups$group_id, all_groups$name), selected = keep_selected(input$delete_target_group, all_groups$group_id)),
              actionButton("delete_group_btn", "Delete group", class = "btn-sm btn-danger")
            )
          }
        )
      )
    }

    output$create_group_message <- renderUI(NULL)
    observeEvent(input$create_group_btn, {
      key <- trimws(input$new_group_key)
      group_name <- trimws(input$new_group_name)
      description <- trimws(input$new_group_description)
      msg <- NULL
      if (key == "" || group_name == "") {
        msg <- "Group key and name are both required."
      } else if (nchar(key) < 4) {
        msg <- "Group key must be at least 4 characters."
      } else if (nchar(group_name) < 4) {
        msg <- "Group name must be at least 4 characters."
      } else if (!grepl("^[a-z0-9_\\-]+$", key)) {
        msg <- "Group key can only contain lowercase letters, numbers, - and _."
      } else if (group_key_exists(key)) {
        msg <- "That group key is already in use."
      }
      if (!is.null(msg)) {
        output$create_group_message <- renderUI(div(style = "color: #b00020;", msg))
        return()
      }
      create_group(key, group_name, description, group_type = input$new_group_type)
      output$create_group_message <- renderUI(div(style = "color: #1a7d1a;", paste0("Group '", group_name, "' created.")))
      updateTextInput(session, "new_group_key", value = "")
      updateTextInput(session, "new_group_name", value = "")
      updateTextInput(session, "new_group_description", value = "")
      refresh_trigger(refresh_trigger() + 1)
    })

    output$org_unit_select_ui <- renderUI({
      req(input$org_unit_target_user)
      refresh_trigger()
      org_units <- get_org_units()
      current <- get_user_org_unit(as.character(input$org_unit_target_user))
      selectInput("org_unit_select", "Organizational Unit",
        choices = setNames(org_units$group_id, org_units$name),
        selected = if (nrow(current) > 0) current$group_id[1] else org_units$group_id[1])
    })

    output$save_org_unit_message <- renderUI(NULL)
    observeEvent(input$save_org_unit_btn, {
      req(input$org_unit_target_user, input$org_unit_select)
      set_user_org_unit(as.character(input$org_unit_target_user), as.character(input$org_unit_select), auth$user_id())
      output$save_org_unit_message <- renderUI(div(style = "color: #1a7d1a;", "Saved."))
      refresh_trigger(refresh_trigger() + 1)
    })

    output$group_members_ui <- renderUI({
      req(input$membership_target_group)
      refresh_trigger()
      members <- get_group_members(as.character(input$membership_target_group))
      if (nrow(members) == 0) {
        return(helpText("No members in this group yet."))
      }
      tagList(
        p(paste("Current members:", paste(members$email, collapse = ", "))),
        selectInput("remove_member_user", "Remove member", choices = setNames(members$user_id, members$email)),
        actionButton("remove_group_member_btn", "Remove", class = "btn-sm"),
        uiOutput("remove_group_member_message")
      )
    })

    output$add_group_member_message <- renderUI(NULL)
    observeEvent(input$add_group_member_btn, {
      req(input$membership_target_group, input$add_member_user)
      add_user_to_group(as.character(input$membership_target_group), as.character(input$add_member_user), auth$user_id())
      output$add_group_member_message <- renderUI(div(style = "color: #1a7d1a;", "Added."))
      refresh_trigger(refresh_trigger() + 1)
    })

    observeEvent(input$remove_group_member_btn, {
      req(input$membership_target_group, input$remove_member_user)
      remove_user_from_group(as.character(input$membership_target_group), as.character(input$remove_member_user))
      output$remove_group_member_message <- renderUI(div(style = "color: #1a7d1a;", "Removed."))
      refresh_trigger(refresh_trigger() + 1)
    })

    observeEvent(input$delete_group_btn, {
      req(input$delete_target_group)
      target <- get_all_groups()
      target <- target[target$group_id == as.character(input$delete_target_group), ]
      req(nrow(target) == 1)
      pending_delete_group$group_id <- target$group_id[1]
      pending_delete_group$group_key <- target$group_key[1]
      pending_delete_group$name <- target$name[1]

      showModal(modalDialog(
        title = paste0("Delete group '", target$name[1], "'?"),
        p("This permanently deletes the group and removes all its memberships. This cannot be undone."),
        p(strong("Type the group key to confirm: "), code(target$group_key[1])),
        textInput("delete_group_confirm_key", NULL, placeholder = "group key"),
        uiOutput("delete_group_confirm_message"),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("confirm_delete_group_btn", "Delete permanently", class = "btn-danger")
        )
      ))
    })

    output$delete_group_confirm_message <- renderUI(NULL)
    observeEvent(input$confirm_delete_group_btn, {
      req(pending_delete_group$group_id)
      if (!identical(trimws(input$delete_group_confirm_key), pending_delete_group$group_key)) {
        output$delete_group_confirm_message <- renderUI(div(style = "color: #b00020;", "Key doesn't match. Please re-type the exact group key to confirm."))
        return()
      }
      delete_group(pending_delete_group$group_id)
      removeModal()
      pending_delete_group$group_id <- NULL
      pending_delete_group$group_key <- NULL
      pending_delete_group$name <- NULL
      refresh_trigger(refresh_trigger() + 1)
    })

    # ====================================================================
    # ACTIVITY CONTEXT: read-only view over the audit log. Independently
    # grantable via the console's "Grant/Revoke app_admin rights" UI,
    # targeting the "User Activity" pseudo-app. Shows nothing useful unless
    # audit logging is enabled (authClient::is_audit_log_enabled()).
    # ====================================================================

    activity_panel_ui <- function() {
      all_users <- get_all_users()
      org_units <- get_org_units()

      tagList(
        div(class = "activity-metric-toggle",
          radioButtons("activity_metric", NULL,
            choices = c("Unique users" = "unique", "Total connections" = "total"),
            inline = TRUE)
        ),
        wellPanel(
          h4("Overall"),
          uiOutput("activity_overall_stats")
        ),
        wellPanel(
          h4("Per app"),
          tableOutput("activity_app_table")
        ),
        # Genuinely absent from the page when off, not just hidden --
        # this whole block is simply left out of the tagList().
        if (isTRUE(.pkgenv$show_activity_detail)) {
          tagList(
            wellPanel(
              h4("Activity detail"),
              selectInput("activity_detail_scope", "Scope",
                choices = c("Everyone" = "all", "Specific user" = "user", "Specific org unit" = "org_unit")),
              conditionalPanel(
                condition = "input.activity_detail_scope == 'user'",
                selectInput("activity_detail_user", "User", choices = setNames(all_users$user_id, all_users$email))
              ),
              if (nrow(org_units) > 0) {
                conditionalPanel(
                  condition = "input.activity_detail_scope == 'org_unit'",
                  selectInput("activity_detail_org_unit", "Org unit", choices = setNames(org_units$group_id, org_units$name))
                )
              } else {
                conditionalPanel(
                  condition = "input.activity_detail_scope == 'org_unit'",
                  helpText("No organizational units exist yet.")
                )
              },
              uiOutput("activity_detail_summary")
            ),
            wellPanel(
              h4("Recent activity"),
              DT::DTOutput("activity_recent_table")
            )
          )
        } else {
          NULL
        }
      )
    }

    metric_suffix <- reactive({
      if (identical(input$activity_metric, "total")) "connections" else "unique_users"
    })

    output$activity_overall_stats <- renderUI({
      req(is_activity_context())
      counts <- get_overall_activity_counts()
      suffix <- metric_suffix()
      tagList(
        p(paste("Last 7 days:", counts[[paste0(suffix, "_7d")]])),
        p(paste("Last 30 days:", counts[[paste0(suffix, "_30d")]]))
      )
    })

    output$activity_app_table <- renderTable({
      req(is_activity_context())
      by_app <- get_app_activity_by_window()
      suffix <- metric_suffix()
      data.frame(
        App = by_app$app_name,
        `Last 7 days` = by_app[[paste0(suffix, "_7d")]],
        `Last 30 days` = by_app[[paste0(suffix, "_30d")]],
        check.names = FALSE
      )
    })

    output$activity_detail_summary <- renderUI({
      req(is_activity_context())
      scope <- input$activity_detail_scope
      if (identical(scope, "user")) {
        req(input$activity_detail_user)
        summary <- get_activity_summary_for_user(as.character(input$activity_detail_user))
        tagList(
          p(paste("Last seen:", if (is.na(summary$last_seen)) "never" else summary$last_seen)),
          p(paste("Connections last 7 days:", summary$connections_7d)),
          p(paste("Connections last 30 days:", summary$connections_30d))
        )
      } else if (identical(scope, "org_unit")) {
        req(input$activity_detail_org_unit)
        summary <- get_activity_summary_for_org_unit(as.character(input$activity_detail_org_unit))
        tagList(
          p(paste("Last seen:", if (is.na(summary$last_seen)) "never" else summary$last_seen)),
          p(paste("Unique users last 7 days:", summary$unique_users_7d)),
          p(paste("Unique users last 30 days:", summary$unique_users_30d)),
          p(paste("Connections last 7 days:", summary$connections_7d)),
          p(paste("Connections last 30 days:", summary$connections_30d))
        )
      } else {
        NULL
      }
    })

    output$activity_recent_table <- DT::renderDT({
      req(is_activity_context())
      scope <- if (isTRUE(.pkgenv$show_activity_detail)) input$activity_detail_scope else "all"
      recent <- if (identical(scope, "user") && !is.null(input$activity_detail_user)) {
        get_recent_audit_events(200, user_id = as.character(input$activity_detail_user))
      } else if (identical(scope, "org_unit") && !is.null(input$activity_detail_org_unit)) {
        get_recent_audit_events(200, org_unit_group_id = as.character(input$activity_detail_org_unit))
      } else {
        get_recent_audit_events(200)
      }
      names(recent) <- c("User", "App", "Event", "When")
      recent
    }, options = list(pageLength = 15), rownames = FALSE)
  }
}
