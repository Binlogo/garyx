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

## Every terminal funnels through staging

The copy can be observed on the stream while the run later dies on a
terminal that never reaches result processing. All three terminals stage
through one helper (`stage_connection_interruption_if_seen`):

- the ordinary errored result path (after quota classification declines);
- the stream-idle backstop (`claude stream idle for …`);
- the SDK receive-error return.

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

Gateway (`quota_resend.rs`):

- `parses_connection_interruption_as_a_non_quota_retry` — projection keeps
  the marker, the timer stays armed, and `reached_type_is_quota_verdict`
  pins the auto-switch gate (false for `connection_interrupted`, true for
  quota verdicts).
