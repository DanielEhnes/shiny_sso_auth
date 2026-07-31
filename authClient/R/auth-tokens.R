# Not exported -- internal building blocks for auth-sessions.R.
# digest::hmac() has no CSPRNG and base R's RNG isn't fit for bearer tokens,
# so random bytes come from openssl::rand_bytes() specifically.
new_raw_secret <- function(n_bytes = 32) {
  paste(sprintf("%02x", as.integer(openssl::rand_bytes(n_bytes))), collapse = "")
}

hash_secret <- function(secret_hex, key = Sys.getenv("AUTH_SESSION_SECRET")) {
  if (identical(key, "")) {
    stop("AUTH_SESSION_SECRET is not set. Every app sharing SSO sessions must be configured with the same secret.")
  }
  digest::hmac(key = key, object = secret_hex, algo = "sha256", serialize = FALSE)
}
