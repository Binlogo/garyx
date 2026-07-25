# iOS Send-Anchor Review Debt

Status: recorded during the adversarial review of `#TASK-2680`. The
send-anchored transcript implementation passed review. The finding below is
adjacent and pre-existing, is not caused by that implementation, and requires
separate investigation.

## New-thread title rewrite

During the required iPhone 17 Pro Max / iOS 26.5 light-mode walkthrough, a new
thread's first-send transcript behaved correctly, but its navigation title was
later replaced by a server-generated title unrelated to the submitted prompt.
The transcript rows, row identity, thinking handoff, send anchor, and scroll
geometry remained correct.

This observation is outside the send-anchor scope:

- The reviewed change does not modify thread title generation, title metadata,
  or title rendering.
- The behavior occurs after the transcript's local-send presentation and does
  not affect the send-anchored state machine.
- No title-path root cause was established during the scroll-focused review.

Disposition: RESOLVED as accepted behavior (2026-07-24). Deterministic
reproduction and root cause were established in a dedicated investigation:
the gateway first writes a prompt-derived label (`garyx_prompt`), and after
the run completes the bridge applies the provider's native session title
(Claude `ai-title`), which is generated from the metadata/memory-wrapped
first message and may therefore diverge from the submitted prompt
(`garyx-bridge/src/multi_provider/run_management/thread_title.rs`,
`should_apply_provider_thread_title`). The product owner reviewed the
mechanism and decided to KEEP provider titles: `ai-title` results are
generally satisfactory, and the provider override of `garyx_prompt` labels
is intentional accepted behavior. Do not remove or weaken the provider
thread-title path, and do not re-open this as a bug.

## Transcript window spacers and layout-environment changes

Recorded from the adversarial review of the transcript performance work
(#TASK-2707, NIT N13). Collapsed-row heights are cached as intrinsic values
measured in the layout environment that was current when the row last
rendered. A change to that environment — Dynamic Type, or any width change —
re-measures live rows but not collapsed ones, so a spacer keeps its
pre-change height until the reader scrolls that run back into the live band,
where it re-renders and re-measures.

This is self-limiting (the error only exists off-screen, and any replan after
the run becomes live corrects it) and it is the inherent cost of windowing by
measurement rather than by estimation. It is the only remaining path by which
a spacer height can be wrong. Fix, if it ever matters in practice: invalidate
the height cache on layout-environment identity change (Dynamic Type size,
container width) so affected runs render live once before collapsing again.

## Transcript row spacing is declared in two places

Same review, NIT N11. The transcript row stack declares
`VStack(alignment: .leading, spacing: 14)` while the window planner is fed
`transcriptRowSpacing = 14` from a separate constant several hundred lines
away. Changing the stack alone would silently shift every spacer by
(N-1) × delta, and no test would fail. Fix: have the stack consume the same
constant so the two cannot drift.
