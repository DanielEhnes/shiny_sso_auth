# Installs authClient and accessConsole directly from GitHub. Both live as
# subdirectories of this repo rather than at its root, so a plain
# remotes::install_github("DanielEhnes/shiny_sso_auth") won't find either
# package on its own -- each needs its own `subdir`.
#
# Usage:
#   source("install.R")
#   install_shiny_sso_auth()

install_shiny_sso_auth <- function(repo = "DanielEhnes/shiny_sso_auth", ref = NULL, ...) {
  if (!requireNamespace("remotes", quietly = TRUE)) {
    install.packages("remotes")
  }

  # authClient first -- accessConsole depends on it.
  remotes::install_github(repo, subdir = "authClient", ref = ref, ...)
  remotes::install_github(repo, subdir = "accessConsole", ref = ref, ...)

  invisible(TRUE)
}
