# Mid-Response Connection Interruption Auto-Continue

Companion to `quota-auto-account-switch.md`. The Claude CLI surfaces a
transient network interruption as the terminal copy
"API Error: Connection closed mid-response. The response above may be
incomplete." Historically that left the run as a plain failure the user had
to nudge manually with a follow-up message. This design classifies it into
the same durable recovery pipeline as quota exhaustion so the gateway sends
one synthetic `continue` about a minute later.

## Requirements (2026-07-27)

- Recognize the CLI's mid-response interruption copy and schedule an
  automatic `continue` roughly one minute out, reusing the existing quota
  recovery infrastructure (durable SQLite row + timer wake + synthetic
  continue admission).
- A network blip is not a quota verdict: auto account switch must not
  evaluate for it.
- Bounded: a persistent outage must not loop forever.

## Detection

Per-segment, never aggregated: `StreamSignals.interruption_copy` is set when
ONE assistant message's own visible text contains
"connection closed mid-response" AND that segment is the CLI's own error
surface — it carries an assistant-level error classification, or its trimmed
text starts with "API Error:" (the synthetic error line). Ordinary content
that merely quotes the copy (agent conversations discussing this very
feature do) must not arm the retry. The `ResultMessage.errors` text is an
additional accepted source at the terminal.

## Every terminal funnels through one quota-first classifier

The copy can be observed on the stream while the run later dies on a
terminal that never reaches result processing. All three terminals — the
ordinary errored result path, the stream-idle backstop, and the SDK
receive-error return — call the same `stage_terminal_quota_context`, which
classifies quota FIRST (a rejected `rate_limit_event` or a paired API-429
usage-limit segment observed earlier is a quota verdict even on an early
terminal) and only then falls back to the interruption staging.

The interruption signal is per-turn: the real user-turn boundary (a queued
user input acknowledged mid-run) clears it, so an interruption from a
previous exchange can never classify a later unrelated failure. Tool-result
user messages do not clear it.

The bridge run graph consumes the stash on both the soft-failure and
hard-error persistence paths, so the terminal `run_complete` carries
`status = rate_limited` with the payload below either way.

## Payload and pipeline semantics

`ProviderRateLimit`:

- `reached_type = connection_interrupted` — the transient marker.
- `reset_at = now` — `register_plan`'s standard resend buffer (60s) lands
  the synthetic continue about one minute out; `will_auto_resend` derives
  from `reset_at` presence as usual.
- `window = None`, `message` = the CLI copy, `account_dir`/`model` as in the
  quota shapes.

Gateway: the recovery-plan projection carries `reached_type`, and
`reached_type_is_quota_verdict` is the single decision point gating quota
auto-switch — `connection_interrupted` never evaluates a switch. The timer
resend, manual Continue, and manual account switch behave exactly as for
quota rows (same durable row, same admission).

## Bound

At most 3 consecutive interruptions per thread retry automatically
(process-local streak, cleared by any successful attempt; a gateway restart
clears it, which only re-arms the bounded retry). The 4th consecutive
interruption stays a terminal failure for the user to inspect.

## Known presentation debt

Clients render the recovery row with the quota rate-limit card for the
~1 minute until the resend fires. A distinct "connection interrupted —
retrying" copy keyed off `reached_type` is recorded as follow-up client
work.

## Test cases

Bridge (stream-shape driven, `claude_provider/tests.rs`):

- `mid_response_interruption_stages_a_short_retry_with_streak_cap` — errors
  path stages with `reset_at ≈ now`; 4th consecutive stays terminal.
- `successful_attempt_resets_the_interruption_streak`.
- `mid_response_copy_before_idle_backstop_still_stages_recovery` — paused
  clock; copy segment then silence past the idle ceiling; the idle terminal
  still stages.
- `mid_response_copy_before_stream_error_still_stages_recovery` — SDK
  receive-error terminal stages.
- `quoted_interruption_copy_in_ordinary_content_does_not_stage` — quoting
  inside ordinary content never arms the retry.
- `plain_failures_do_not_stage_an_automatic_continue`.
- `quota_verdict_beats_interruption_on_the_stream_error_terminal` — every
  terminal classifies quota FIRST: a rejected `rate_limit_event` followed
  by the interruption copy and an SDK receive error stages the quota
  verdict, never the network retry.
- `interruption_copy_does_not_cross_the_user_turn_boundary` — the real
  user-turn boundary clears the per-turn interruption signal; a later
  unrelated failure in the next turn stays terminal.
- `tool_result_user_message_does_not_clear_the_interruption_signal` —
  tool-result user messages are part of the same turn and never clear the
  signal; moving the clear before the tool-result branch turns this red.
- `quota_verdict_beats_interruption_on_the_idle_terminal` — the idle
  backstop also classifies quota first; reverting it to the
  connection-only helper turns this red.

Gateway (`quota_resend.rs`):

- `parses_connection_interruption_as_a_non_quota_retry` — projection keeps
  the marker, the timer stays armed, and `reached_type_is_quota_verdict`
  pins the gate both ways.
- `registration_path_gates_auto_switch_on_the_quota_verdict` — end to end
  through the production `register_plan_with_auto_switch`: a connection
  interruption registers its durable row but never reaches auto-switch
  consideration (observed via the synchronous generation claim), while a
  quota verdict does. `auto_switch_context_for` is the single decision
  point the production path consumes; removing the gate turns this red.
- `serialized_rate_limit_contract_gates_auto_switch_end_to_end` — the
  bridge -> gateway marker contract guard: the `run_complete.rate_limit`
  payload comes from the REAL bridge serializer
  (`garyx_bridge::multi_provider::rate_limit_control_value`, exported as
  the wire contract), flows through the production parser and
  registration path, and pins both directions. Dropping `reached_type`
  from the serializer turns this red.
