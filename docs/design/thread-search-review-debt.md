# Thread Search Review Debt

## Existing provider-auth test timing flake

- Source: `garyx-gateway/src/provider_auth.rs:990-1013`
- Observed while running `cargo test -p garyx-gateway --lib`: the managed-auth
  test exhausted its polling window with a `Submitted` snapshot even though the
  child had already reported exit code 0. An immediate exact-test rerun passed.
- Disposition: unrelated to the thread-title search paths. Investigate the
  auth-completion notification/polling handshake in a separate task; do not
  change it as part of thread search.
