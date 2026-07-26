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

## Send-time keyboard dismissal races the optimistic append (unresolved)

Recorded 2026-07-26 after four failed review rounds (#TASK-2721). Not shipped;
branch `gary/send-flash` abandoned at `1beeaed17`.

Symptom: sending while the keyboard is up and the reader is at the bottom
intermittently makes the transcript jump backwards and snap back (7/15 on the
shipped build, up to 260pt of same-row travel).

Cause chain, fully attributed: the send commit freezes the composer read-only,
`isEditable = false` implicitly resigns first responder (#TASK-2713 LLDB), so
the keyboard collapse rides along with persistence and its viewport change
lands in the same frame as the optimistic row's content growth. The bottom
anchor resolves against the stale viewport, then the viewport settles a frame
later and the position is pulled back.

Why the four attempts failed — all of them tried to *time* the dismissal
against an unknown layout completion instead of observing it:

1. `isFocused = false` — the representable only acts on false->true edges, so
   nothing dismissed at all (15/15 keyboard stayed up; the clean reversal
   count was a false green).
2. `Task.yield()` after `sendDraft()` — that awaits the network dispatch, so
   the dismissal was bound to request latency, and a yield is not a frame.
3. Empty `CATransaction` completion — fires 0.019-0.077ms later, still ahead
   of the next display-link tick, so the appended row was not presented
   (8/15 reversals).
4. One `CADisplayLink` tick + a liveness-generation guard — SwiftUI row
   materialization can still land after that tick on a large thread (3/15
   reversals), and the generation guard cancelled queued freezes during
   ordinary presentation reconciliation, so only 5/15 dismissals ran.

### Fifth attempt, and what it disproved (2026-07-26)

Attempt 5 stopped scheduling anything and instead suspended the size-change
bottom anchor for the window UIKit reports as "keyboard geometry in flight"
(`keyboardWillChangeFrame` set, `keyboardDidShow`/`DidHide` cleared), settling
once when the window closed. Review #TASK-2750 measured 14/15 reversals — worse
than the unfixed build — and the frame traces explain why, which is the useful
part:

**The premise of all five attempts is wrong.** The 235pt same-row jump lands in
the SAME frame as both the viewport release and the content growth. Those are
not two separable events that arrive in some order we can influence; UIKit's
keyboard geometry change and SwiftUI's content update are reconciled inside one
layout pass. Suspending the anchor does not decouple them, and no barrier can,
because there is nothing to sit between.

Attempt 5 also introduced a worse hazard: `keyboardWillChangeFrame` has its own
`keyboardDidChangeFrame` counterpart, which was not observed. Injecting a
standard frame-only pair into the running binary left the window open for over
12 seconds with no DidShow/DidHide following, i.e. tail-following silently dead
for the rest of that window — a candidate bar or floating keyboard could trigger
exactly that shape in production. A single Bool also cannot express overlapping
windows, and the state was not cleared on thread switch.

So the next attempt must not try to order the append against the keyboard at
all. Two directions that do not depend on ordering:

1. **Own the motion.** Compensate the transcript's bottom content inset by
   exactly the keyboard height as it collapses, so the scrollable geometry the
   anchor sees never changes; then animate that compensation away as one
   deliberate, settled motion after both the append and the keyboard have
   finished. The reposition becomes ours instead of a stale-viewport
   resolution.
2. **Remove the trigger.** The keyboard only collapses because the read-only
   freeze resigns first responder. If the freeze never touches first responder
   and dismissal is an explicit product decision with its own sequencing, the
   viewport change stops coinciding with the append by construction. This is a
   visible behavior change and needs the boss's call.

The earlier causal-handshake idea below is still worth trying, but note the
frame evidence above: if the append and the keyboard truly share one layout
pass, a "row is laid out" signal may arrive too late to help.

The original framing, for reference: make the handshake **causal, not
temporal**. The transcript already measures its content edges after layout;
have it publish "the appended row is laid out" for the send in flight, and let
the composer's freeze wait on that signal rather than on any clock. Failing
that, the alternative is to remove the coupling entirely so ordering cannot
matter — e.g. the freeze never touches first responder and dismissal is an
explicit product step with its own settled sequencing.

Acceptance criteria are already defined and measurable: >=15 sends (return key
and send button), zero reversals, keyboard dismissed 15/15, and a frame
sequence whose shape matches the idle "focus the field, do nothing, dismiss"
control.
