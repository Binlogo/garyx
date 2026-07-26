# iOS Composer Route-Activation Review Debt

Status: recorded while fixing the "browse a while, then the conversation
composer stops accepting taps" report (composer route-activation abandonment,
`GaryxComposerPayloadCoordinator.settleAbandonedRouteActivation`). The
findings below are adjacent and pre-existing, are not introduced by that fix,
and need separate investigation before any code change.

## 1. `routeCommitReleased(sourceKey: nil)` overwrites a tracked activation

The `sourceKey == nil` branch of
`GaryxComposerPayloadCoordinator.routeCommitReleased` assigns a fresh
`RouteActivation` without checking whether one is already tracked. With the
abandonment settle in place this can only happen when the previous activation
has reached its terminal but its asynchronous close finalization is still
running (`finalizationTask != nil`): a fast follow-up navigation from a
composer-less source (home → thread) then replaces the tracked activation
while the finalization loop is still reading `self.routeActivation`, so the
old close's `closeAcknowledged()` bookkeeping is applied to the new
activation's state machine.

Observed convergence: the in-flight finalization persists the old session's
input durably (keyed by sessionID, unaffected by the overwrite), and the new
activation's own terminal re-runs advance, so user-visible state settles in
the timings exercised so far. The overwrite is still a latent
state-attribution hazard and deserves an explicit ownership rule (reject,
queue, or settle-then-replace) instead of silent replacement.

Evidence: `GaryxComposerBrowseFocusProbeTests.
testPushIntoThreadWithLostTerminalRecoversOnReentry` passes even with the
abandonment settle disabled, because this overwrite path incidentally clears
the stalled activation.

## 2. Renderer terminal delivery is still a timing contract

The composer fix makes the coordinator self-healing when a route transition's
terminal callback never arrives, and every container path inspected during
the investigation (settle completion, forced scene-inactive terminal,
route/gateway invalidation, hard snap) does deliver terminals. No concrete
in-repo dropped-terminal producer was identified; the known candidates are
renderer teardown between commit release and terminal (e.g. container
dismantle during logout/root replacement) and any future early return in
`GaryxRouteStackContainer.finalizeTerminal`'s callers. If such a path is ever
identified, fix it at the container as well; the coordinator settle is the
structural backstop, not a license to drop terminals.
