import Combine
import SwiftUI

/// Narrow observable state for the one app-root Capsule detail owner.
///
/// Feature surfaces submit Core requests here; they never attach their own
/// sheets, overlays, safe-area canvases, or dismissal owners.
@MainActor
final class GaryxCapsuleDetailPresentationStore: ObservableObject {
    @Published var request: GaryxCapsuleDetailPresentationRequest?

    func present(
        _ selection: GaryxCapsulePreviewSelection,
        from entryPoint: GaryxCapsuleDetailEntryPoint
    ) {
        request = GaryxCapsuleDetailPresentationRequest(
            selection: selection,
            entryPoint: entryPoint
        )
    }

    func dismiss() {
        request = nil
    }

    func dismiss(ifPresenting capsuleID: String) {
        guard request?.selection.id == capsuleID else { return }
        dismiss()
    }
}

/// The single presentation owner for focused Capsule detail.
///
/// This modifier stays attached to `GaryxRootView`; both the transcript and
/// Capsules surface drive its request store, so they necessarily receive the
/// same system full-screen container and safe-area environment.
private struct GaryxCapsuleDetailPresentationOwnerModifier: ViewModifier {
    @ObservedObject var store: GaryxCapsuleDetailPresentationStore

    func body(content: Content) -> some View {
        content.garyxFullScreenCover(item: $store.request) { request in
            focusedPreview(for: request)
        }
    }

    @ViewBuilder
    private func focusedPreview(
        for request: GaryxCapsuleDetailPresentationRequest
    ) -> some View {
        switch request.configuration {
        case .rootFullScreenCover:
            GaryxCapsuleFocusedPreviewView(selection: request.selection)
        }
    }
}

extension View {
    func garyxCapsuleDetailPresentationOwner(
        store: GaryxCapsuleDetailPresentationStore
    ) -> some View {
        modifier(GaryxCapsuleDetailPresentationOwnerModifier(store: store))
    }
}
