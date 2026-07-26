# iOS Capsule Detail Presentation Review Debt

Status: recorded after the independent `#TASK-2772` review gave the
`#TASK-2767` Capsule-detail presentation fix a 100% PASS / SHIP verdict. These
items are unreachable cleanup debt, not defects in the reviewed fix, and must
remain a separate housekeeping change.

Both items are RESOLVED by the standalone housekeeping change for `#TASK-2773`:
the in-place presentation barrier and the focused-preview dismissal callback
were removed structurally with zero remaining references, and no replacement
seam was introduced. Dismissal stays owned solely by the app-root
`GaryxCapsuleDetailPresentationOwnerModifier`.

## Unused in-place presentation barrier — RESOLVED (#TASK-2773)

`GaryxInPlacePresentationBarrierModifier` and
`garyxInPlacePresentationBarrier(isPresented:)` remain in
`mobile/garyx-mobile/App/GaryxMobile/GaryxPresentationLeaseViews.swift`, but
their only caller was the Capsule gallery morph removed by `#TASK-2767`.
Repository-wide review found no remaining callers.

Impact: none at runtime today. Keeping a feature-specific presentation barrier
with no owner obscures the supported presentation topology and invites a future
surface to revive the retired in-place overlay model.

Follow-up direction: remove the modifier and view extension after confirming
zero callers against the integration base. Do not replace them with another
compatibility seam.

## Unreachable focused-preview dismissal callback — RESOLVED (#TASK-2773)

`GaryxCapsuleFocusedPreviewView.onRequestDismiss` defaults to `nil`, and the
single remaining construction site in
`GaryxCapsuleDetailPresentation.swift` does not supply it. The callback branches
in `GaryxMobileCapsuleViews.swift` are therefore unreachable.

Impact: none at runtime today. The unused callback is nevertheless a latent
second-dismissal-owner seam beside the app-root Capsule presentation owner.

Follow-up direction: remove the callback parameter and its unreachable
branches. Keep dismissal exclusively owned by the root full-screen
presentation.

## Guardrails for the standalone cleanup

- Do not change Capsule detail chrome, safe-area behavior, routes, or visual
  transitions.
- Preserve both dismissal destinations: Capsule-tab detail returns to the
  gallery; transcript detail returns to its conversation.
- Keep the app-root `GaryxCapsuleDetailPresentationOwnerModifier` as the sole
  focused-detail presentation owner.
- Run focused SwiftPM coverage, the full `swift test` suite, and a real
  `xcodebuild` for iPhone 17 Pro Max on iOS 26.5 in light mode.

Disposition: handle both items in one independent housekeeping task. Do not
fold them into the reviewed `#TASK-2767` implementation commit.

## Cleanup validation record (#TASK-2773)

Focused SwiftPM coverage (`GaryxCapsulePreviewLoadingTests`,
`GaryxCapsuleDragDismissTests`, `GaryxPresentationTransactionTests`,
`GaryxPresentationLeaseLeakReproTests`) passed 38/38, and the full
`swift test` suite passed 1615/1615. `xcodebuild` reported
`** BUILD SUCCEEDED **` for the app scheme against an iPhone 17 Pro Max on
iOS 26.5.

Both dismissal destinations were re-checked on that simulator in light mode
against the real local gateway, for the Close control and for the
drag-to-dismiss gesture that shares the same effect branch:

- Capsule-tab detail dismisses back to the Capsules gallery grid, with no
  focused-detail chrome left in the accessibility tree.
- Transcript detail dismisses back to the same conversation, keeping its
  thread header, composer, and capsule card.
