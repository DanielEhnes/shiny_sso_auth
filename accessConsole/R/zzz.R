# Package-private connection, set once by run_admin_console(). All db-*.R
# functions close over .pkgenv$con rather than taking an explicit `con`
# parameter -- deliberate for this package (unlike authClient): a single
# internal-tool app with ~50 join-heavy functions and ~30 observeEvent call
# sites, where threading a connection through every signature would buy
# little for real regression risk.
.pkgenv <- new.env(parent = emptyenv())

ADMIN_CONSOLE_KEY <- "admin_console"
GROUPS_ADMIN_KEY <- "groups_admin"
BASIC_USER_GROUP_KEY <- "basic_user"
