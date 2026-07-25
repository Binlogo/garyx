# Thread Search Review Debt

## Existing provider-auth test timing flake

- Source: `garyx-gateway/src/provider_auth.rs:990-1013`
- Observed while running `cargo test -p garyx-gateway --lib`: the managed-auth
  test exhausted its polling window with a `Submitted` snapshot even though the
  child had already reported exit code 0. An immediate exact-test rerun passed.
- Disposition: unrelated to the thread-title search paths and tracked
  separately as `#TASK-2739`; do not change it as part of thread search.

## Superseded iOS design still documents the four-field corpus

- Source: `docs/design/ios-thread-list-unification.md:74-112`
- The older design still specifies title/workspace/agent/preview matching and a
  `search_text` projection. `docs/design/thread-search.md` D1 now supersedes
  that contract with title-only `search_title`, leaving the two design documents
  contradictory.
- Disposition: tracked separately as `#TASK-2737`; do not rewrite that feature's
  historical design as part of this backend implementation.

## Tier 1 changed-mode reports pass after running zero tests

- Source: `scripts/test/rust_tier1_fast.sh:99-103,151-169`
- `--changed` derives targets only from the dirty tree. After changes are
  committed, a clean worktree selects no packages, skips command execution, and
  still emits `STATUS=pass`, so the report can be mistaken for test evidence.
- Disposition: tracked separately as `#TASK-2738`. For this implementation, use
  the gateway library suite as the substantive Rust validation and run
  changed-mode before committing.
