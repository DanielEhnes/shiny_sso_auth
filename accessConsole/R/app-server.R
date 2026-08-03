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
    # other self-service settings later) is hidden until logged in, and
    # re-hidden on logout -- there's nothing useful to show there otherwise.
    hideTab(inputId = "main_nav", target = "account_tab")
    observe({
      if (isTRUE(auth$logged_in())) {
        showTab(inputId = "main_nav", target = "account_tab")
      } else {
        hideTab(inputId = "main_nav", target = "account_tab")
      }
    })

    output$change_password_area <- renderUI({
      req(auth$checked())
      if (!auth$logged_in()) return(NULL)
      authClient::changePasswordUI("console_pw")
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
          fluidRow(
            column(10, h4(paste("Logged in as", auth$username()))),
            column(2, actionButton("admin_logout_btn", "Log out"))
          ),
          div(em("You don't administer any apps yet. Ask a Admin Console admin to grant you rights."))
        ))
      }

      fluidPage(
        fluidRow(
          column(8, h4(paste("Logged in as", auth$username()))),
          column(4, actionButton("admin_logout_btn", "Log out"))
        ),
        hr(),
        selectInput(
          "managing_app", "Managing:",
          choices = setNames(admin_apps$app_id, admin_apps$name),
          selected = keep_selected(input$managing_app, admin_apps$app_id),
          width = "100%"
        ),
        uiOutput("app_management_ui")
      )
    })

    observeEvent(input$admin_logout_btn, {
      auth$logout()
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

    # --------------------------------------------------------------------
    # Branch: console context vs. groups context vs. regular-app context
    # --------------------------------------------------------------------

    output$app_management_ui <- renderUI({
      req(auth$logged_in())
      refresh_trigger()
      if (is_console_context()) {
        console_panel_ui()
      } else if (is_groups_context()) {
        groups_panel_ui()
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
      deletable_apps <- all_apps[!(all_apps$app_key %in% c(ADMIN_CONSOLE_KEY, GROUPS_ADMIN_KEY)), ]

      tagList(
        wellPanel(
          h4("Create a new app"),
          textInput("new_app_key", "App key (unique, e.g. 'invoicing')"),
          textInput("new_app_name", "Display name"),
          textInput("new_app_description", "Description"),
          actionButton("create_app_btn", "Create app", class = "btn-sm btn-primary"),
          uiOutput("create_app_message")
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
          actionButton("save_account_status_btn", "Update account status", class = "btn-sm")
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
      app_id <- create_app(key, app_name, description)
      permission_id <- create_permission("admin", paste0("App Admin Role for ", app_name), app_id)
      role_id <- create_role(paste0(key, "_admin"), paste0("Admin Role for ", app_name), app_id)
      set_role_permissions(role_id, c(permission_id))
      output$create_app_message <- renderUI(div(style = "color: #1a7d1a;", paste0("App '", app_name, "' created.")))
      updateTextInput(session, "new_app_key", value = "")
      updateTextInput(session, "new_app_name", value = "")
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

    observeEvent(input$save_account_status_btn, {
      req(input$status_target_user)
      set_user_status(as.character(input$status_target_user), input$status_target_value)
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

      current_access <- get_user_app_access_status(uid, app_id) == "active"
      current_roles <- get_user_role_ids_for_app(uid, app_id)

      tagList(
        checkboxInput("user_has_access", "Has access to this app", value = current_access),
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

      set_user_app_access_for_app(uid, app_id, isTRUE(input$user_has_access))
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

      current_access <- get_group_app_access_status(gid, app_id) == "active"
      current_roles <- get_group_role_ids_for_app(gid, app_id)

      tagList(
        checkboxInput("group_has_access", "Has access to this app", value = current_access),
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
      set_group_app_access_for_app(gid, app_id, isTRUE(input$group_has_access))
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

      tagList(
        wellPanel(
          h4("Create a new group"),
          textInput("new_group_key", "Group key (unique, e.g. 'reporting-team')"),
          textInput("new_group_name", "Display name"),
          textInput("new_group_description", "Description"),
          actionButton("create_group_btn", "Create group", class = "btn-sm btn-primary"),
          uiOutput("create_group_message")
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
      create_group(key, group_name, description)
      output$create_group_message <- renderUI(div(style = "color: #1a7d1a;", paste0("Group '", group_name, "' created.")))
      updateTextInput(session, "new_group_key", value = "")
      updateTextInput(session, "new_group_name", value = "")
      updateTextInput(session, "new_group_description", value = "")
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
  }
}
