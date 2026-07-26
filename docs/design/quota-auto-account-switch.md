# Quota Auto Account Switch

Companion to `claude-code-multi-account-profiles.md` and
`codex-multi-account-profiles.md`. Those designs added provider-owned managed
accounts, a manual switcher, and the durable SQL quota-recovery wake on
selection change. This design makes the switch automatic: when a run is cut
off by the provider's usage quota, the gateway looks at every configured
account for that provider, and if another account still has allowance it
commits one selection change. That single committed change reuses the existing
account-switch recovery wake, so every quota-paused thread of the provider
resumes at once.

## Requirements (2026-07-26)

- Trigger on quota-limit detection: when a rate-limited run commits, evaluate
  whether another account of the same provider has remaining allowance.
- Per-provider eligibility policy:
  - Claude Code: the candidate must have remaining 5-hour session allowance
    AND remaining weekly allowance. When the blocked run was using a model
    with an independent scoped weekly bucket (currently Fable), that scoped
    bucket must also have remaining allowance on the candidate.
  - Codex: the candidate must have remaining allowance on its reported
    windows (in practice the weekly window; any window the usage API reports
    is required).
- Switch once per exhaustion: no matter how many threads hit the limit at the
  same time, exactly one selection change commits. All blocked threads are
  then resumed by the existing account-switch wake — no new wake mechanism.

## Non-goals

- No Gateway-side scheduling fairness, load-balancing, or rotation policy.
  The trigger is quota exhaustion only.
- No desktop/mobile UI in this pass. The gate is a config field; a settings
  toggle can follow.
- No durable auto-switch journal. Auto-switch is a best-effort acceleration
  layered over the durable recovery rows: if the gateway restarts between
  block and evaluation, the rows still recover through the ordinary timer /
  manual / manual-switch wakes.
- Antigravity and other providers without managed accounts are out of scope.

## Where the trigger lives

The committed `run_complete/rate_limited` control record is already the
canonical quota-block signal: `quota_resend::run_event_projection` parses it
into a `RecoveryPlan` and registers the durable
`quota_recovery_jobs` row. Auto-switch evaluation hooks immediately after a
successful registration in `register_plan` — never before the row is durable,
so the switch's expedite-all always covers the row that triggered it.

Evaluations run on a per-provider FIFO queue (a `tokio::sync::Mutex` held
across one evaluation; the event projection loop only spawns tasks). Rate
limit events are rare, and serializing per provider is what makes
switch-once reasoning local.

## Knowing which account actually blocked

Runs snapshot their provider environment at start, so a run that blocks may
have been using an account that is no longer the active selection. The
policy needs the blocked account identity, and the provider is the ground
truth — usage APIs lag.

`ProviderRateLimit` gains two additive optional fields, filled by the
provider at staging time and persisted in the control payload:

- `account_dir`: the run's `CLAUDE_CONFIG_DIR` / the app-server slot's
  `CODEX_HOME` from the launch snapshot. Absent = system default profile.
- `model`: the run's model (actual model when reported, otherwise the
  configured model), used only for the scoped-bucket check.

The gateway maps `account_dir` back to a managed account id through its own
managed-root layout (`managed_account_dir(config_path, id)`); the bridge stays
path-dumb. Old events without the fields degrade to "the blocked account is
the current selection", which is the pre-enrichment assumption.

## Evaluation policy

Inputs: canonical provider, blocked account (mapped id / system default /
unknown), blocked model, current selection, configured accounts, per-account
usage (existing cached resolvers: `resolve_claude_usage_for_config_dir`,
`resolve_codex_usage_for_home`). The blocked account's usage cache entry is
invalidated first so a stale "has allowance" reading cannot resurrect it.

Eligibility of a candidate account:

- usage reading available (stale cache fallbacks do not qualify), and
- every reported general window (`session`, `weekly`) has
  `remaining_percent > 0`, and
- if the blocked model matches one of the candidate's scoped limits by model
  name (e.g. Fable), that scoped window has `remaining_percent > 0`.
  A scoped limit with `is_active: false` but usable scope and percentage
  counts by its percentage, per the existing usage contract. A candidate
  that reports no matching scoped bucket carries no scoped requirement.

Decision:

- Blocked account == current selection (or unknown): consider all other
  accounts (system default included). If any is eligible, switch to the best
  one — ranked by the minimum remaining percentage across its required
  windows, descending; ties break by name then id for determinism. If none is
  eligible, do nothing: rows stay parked for the timer / manual wakes.
- Blocked account != current selection (a stale-snapshot straggler): the
  fleet already switched. If the current selection is eligible, expedite just
  the triggering thread's waiting row (`wake_reason = account_switch`) — it
  will retry on the new selection. If the current selection is not eligible,
  fall through to the switch evaluation above (exclude both the blocked
  account and the current selection from candidates).

## Switch-once mechanics

The selection commit goes through the same serialized `mutate_config` path as
the manual switcher, with a compare-and-swap guard: the closure aborts as a
no-op unless `active_account_id` still equals the selection observed when the
evaluation started. Concurrent manual switches, concurrent evaluations, and
replayed events therefore collapse to one committed change; the CAS no-op
also preserves the "selecting the already-active account must not wake quota
recovery" contract.

A committed auto-switch runs exactly the manual switch effects —
`spawn_claude_account_switch_effects` (session reconcile + expedite-all +
projection repair) or `spawn_codex_account_switch_effects` — so wake behavior,
ordering, and durability are identical to a user-initiated switch.

## Loop safety

A wake retries the thread on the current selection. If that retry blocks, its
rate-limit event carries the *current* account as blocked, which removes it
from the candidate set — the evaluation either switches to a third account or
parks. Every account can be consumed at most once per reset window, so the
chain terminates; a stale usage reading costs at most one wasted retry before
the provider's own verdict corrects it.

## Configuration

`provider_accounts.claude_code.auto_switch_on_quota` and
`provider_accounts.codex.auto_switch_on_quota`, default `true`. The gate is
read at evaluation time; flipping it requires no restart. With a single
configured profile the evaluation finds no candidates and is a no-op.

## Failure behavior

- Usage probe failure for a candidate: that candidate is ineligible this
  round; the evaluation continues with the rest.
- All candidates ineligible / probe failures: rows stay parked; the timer and
  manual wakes are untouched.
- Selection commit failure (config write error): logged; rows stay parked.
- Gateway restart between block and evaluation: no auto-switch for that
  event; durable recovery is unaffected.

## Verification

- `garyx-models`: `ProviderRateLimit` control-value round-trip with the new
  optional fields; absent-field decoding stays compatible.
- Bridge: staged rate limits carry the launch snapshot's account dir and the
  run model (Claude `CLAUDE_CONFIG_DIR`, Codex slot `CODEX_HOME`).
- Gateway policy unit tests: the Claude 5h/weekly/scoped matrix (including
  `is_active: false` scoped buckets), the Codex weekly rule, ranking
  determinism, blocked==current vs straggler decisions, config gate off,
  no-candidate parking.
- Switch-once: concurrent evaluations against one exhaustion commit exactly
  one selection change (CAS property test through the serialized config
  mutation), and the straggler path expedites without switching.
- SQL: thread expedite with `account_switch` reason.
