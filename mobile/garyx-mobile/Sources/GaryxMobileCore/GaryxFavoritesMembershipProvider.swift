import Combine
import Foundation

@MainActor
public final class GaryxFavoritesMembershipProvider: ObservableObject,
    GaryxThreadListMembershipProvider {
    @Published public private(set) var snapshot: GaryxThreadListMembershipSnapshot
    public private(set) var state: GaryxFavoritesState
    public private(set) var publishCount: Int = 0
    public private(set) var cancelledSnapshotTickets: [GaryxFavoritesSnapshotTicket] = []
    public private(set) var capabilityRuntimeEpoch: UInt64?

    public let cache: GaryxThreadSummaryCache
    public let leaseOwner: GaryxThreadSummaryLeaseOwner
    public var onCancelSnapshot: ((GaryxFavoritesSnapshotTicket) -> Void)?

    private let ownerId: String
    private var instanceId: UInt64

    public init(
        gatewayScope: String,
        cache: GaryxThreadSummaryCache,
        leaseOwner: GaryxThreadSummaryLeaseOwner,
        ownerId: String = "favorites",
        instanceId: UInt64 = 1
    ) {
        self.cache = cache
        self.leaseOwner = leaseOwner
        self.ownerId = ownerId
        self.instanceId = max(1, instanceId)
        capabilityRuntimeEpoch = nil
        let initialState = GaryxFavoritesState(gatewayScope: gatewayScope)
        state = initialState
        snapshot = GaryxThreadListMembershipSnapshot(
            identity: GaryxThreadListProviderIdentity(
                kind: .favorites,
                instanceId: max(1, instanceId)
            ),
            isPrimed: initialState.headPhase.isPrimed,
            isRefreshing: initialState.headPhase.isRefreshing,
            headFailure: initialState.headPhase.awaitsUserAction
        )
    }

    public var identity: GaryxThreadListProviderIdentity {
        GaryxThreadListProviderIdentity(kind: .favorites, instanceId: instanceId)
    }

    public var headPhase: GaryxRecentHeadPhase { state.headPhase }

    /// Cold-start consumers await the shared capability probe, then ask this
    /// owner for the one transport effect appropriate to that resolution.
    public func requestSnapshot(
        for resolution: GaryxThreadSummaryCapabilityResolution
    ) -> GaryxFavoritesCapabilityTransition {
        guard acceptCapabilityRuntimeEpoch(resolution.runtimeEpoch) else {
            return GaryxFavoritesCapabilityTransition(cancelledTicket: nil, effects: [])
        }
        let transition: GaryxFavoritesCapabilityTransition
        switch resolution.state {
        case .supported:
            transition = state.transitionToEnhancedSnapshots(
                capabilityGeneration: resolution.capabilityGeneration
            )
        case .unknown, .unsupported:
            transition = state.transitionToLegacySnapshots(
                capabilityGeneration: resolution.capabilityGeneration
            )
        }
        recordCancellation(transition.cancelledTicket)
        rebuildFromReducerState()
        return transition
    }

    /// Applies an unknown/unsupported -> supported transition. The canceled
    /// legacy ticket is immediately unowned; even a racing completion cannot
    /// write cache state before the enhanced replacement arrives.
    public func transitionToSupported(
        capabilityGeneration: UInt64
    ) -> GaryxFavoritesCapabilityTransition {
        let transition = state.transitionToEnhancedSnapshots(
            capabilityGeneration: capabilityGeneration
        )
        recordCancellation(transition.cancelledTicket)
        rebuildFromReducerState()
        return transition
    }

    /// Normal refreshes retain the capability flavor/generation selected by
    /// the shared probe. They use the reducer's existing coalescing fence.
    public func requestRefresh() -> [GaryxFavoritesEffect] {
        let effects = state.requestSnapshot()
        rebuildFromReducerState()
        return effects
    }

    public func completeSnapshot(
        ticket: GaryxFavoritesSnapshotTicket,
        snapshot response: GaryxFavoriteSnapshot
    ) -> GaryxFavoritesSnapshotCompletion {
        var candidate = state
        let decision = candidate.completeSnapshotDecision(
            ticket: ticket,
            snapshot: response
        )
        state = candidate
        guard decision.accepted else {
            rebuildFromReducerState()
            return decision
        }

        // One owner commit: write-through + lease swap + membership replace,
        // followed by exactly one observable publication.
        let writes = Self.uniqueSummaries(
            response.rows + (response.summaryLookupRows ?? [])
        )
        let candidateIds: [String]
        if response.hasEnhancedSummaries {
            candidateIds = state.renderableThreadIds
        } else {
            // Legacy behavior renders only the recent join; raw-only favorites
            // remain membership facts but are not naked rows.
            candidateIds = state.presentedRows.map(\.id)
        }
        leaseOwner.replaceFeed(
            ownerId: ownerId,
            threadIds: candidateIds,
            summaries: writes
        )
        let visibleIds = candidateIds.filter { cache.summary(for: $0) != nil }
        let next = GaryxThreadListMembershipSnapshot(
            identity: identity,
            orderedThreadIds: visibleIds,
            isPrimed: state.headPhase.isPrimed,
            isRefreshing: state.headPhase.isRefreshing,
            headFailure: state.headPhase.awaitsUserAction,
            footerState: .hidden
        )
        publish(next)
        return decision
    }

    public func failSnapshot(
        ticket: GaryxFavoritesSnapshotTicket
    ) -> [GaryxFavoritesEffect] {
        let effects = state.failSnapshot(ticket: ticket)
        rebuildFromReducerState()
        return effects
    }

    public func observeStoreIdentity(
        stamp: GaryxStoreResponseStamp,
        responseStoreIncarnationId: String
    ) -> (decision: GaryxStoreIdentityDecision, effects: [GaryxFavoritesEffect]) {
        let result = state.observeStoreIdentity(
            stamp: stamp,
            responseStoreIncarnationId: responseStoreIncarnationId
        )
        if result.decision == .scopeClear {
            instanceId &+= 1
        }
        rebuildFromReducerState()
        return result
    }

    public func toggle(threadId: String, desired: Bool) -> [GaryxFavoritesEffect] {
        let effects = state.toggle(threadId: threadId, desired: desired)
        rebuildFromReducerState()
        return effects
    }

    public func settle(
        ticket: GaryxFavoriteMutationTicket,
        settlement: GaryxFavoriteMutationSettlement
    ) -> [GaryxFavoritesEffect] {
        let effects = state.settle(ticket: ticket, settlement: settlement)
        rebuildFromReducerState()
        return effects
    }

    public func fireBackoff(_ stamp: GaryxFavoriteBackoffStamp) -> [GaryxFavoritesEffect] {
        let effects = state.fireBackoff(stamp)
        rebuildFromReducerState()
        return effects
    }

    public func replaceGatewayScope(_ gatewayScope: String) -> [GaryxFavoritesEffect] {
        instanceId &+= 1
        capabilityRuntimeEpoch = nil
        leaseOwner.evictFeed(ownerId: ownerId)
        let effects: [GaryxFavoritesEffect]
        if state.gatewayScope == gatewayScope {
            effects = state.resetGatewayRuntime(requestSnapshot: true)
        } else {
            effects = state.replaceGatewayScope(gatewayScope, requestSnapshot: true)
        }
        publish(
            GaryxThreadListMembershipSnapshot(
                identity: identity,
                orderedThreadIds: [],
                isPrimed: state.headPhase.isPrimed,
                isRefreshing: state.headPhase.isRefreshing,
                headFailure: state.headPhase.awaitsUserAction
            )
        )
        return effects
    }

    public func downgradeImmediateDemandToUserAction() -> Bool {
        let changed = state.downgradeImmediateDemandToUserAction()
        rebuildFromReducerState()
        return changed
    }

    private func rebuildFromReducerState() {
        let candidateIds = state.enhancedVisibleThreadIds == nil
            ? state.presentedRows.map(\.id)
            : state.renderableThreadIds
        leaseOwner.replaceFeed(ownerId: ownerId, threadIds: candidateIds, summaries: [])
        let visibleIds = candidateIds.filter { cache.summary(for: $0) != nil }
        publish(
            GaryxThreadListMembershipSnapshot(
                identity: identity,
                orderedThreadIds: visibleIds,
                isPrimed: state.headPhase.isPrimed,
                isRefreshing: state.headPhase.isRefreshing,
                headFailure: state.headPhase.awaitsUserAction,
                footerState: .hidden
            )
        )
    }

    private func publish(_ next: GaryxThreadListMembershipSnapshot) {
        guard snapshot != next else { return }
        snapshot = next
        publishCount += 1
    }

    private func recordCancellation(_ ticket: GaryxFavoritesSnapshotTicket?) {
        guard let ticket else { return }
        cancelledSnapshotTickets.append(ticket)
        onCancelSnapshot?(ticket)
    }

    private func acceptCapabilityRuntimeEpoch(_ candidate: UInt64) -> Bool {
        guard let current = capabilityRuntimeEpoch else {
            capabilityRuntimeEpoch = candidate
            return true
        }
        guard candidate >= current else { return false }
        capabilityRuntimeEpoch = candidate
        return true
    }

    private static func uniqueSummaries(
        _ summaries: [GaryxThreadSummary]
    ) -> [GaryxThreadSummary] {
        var seen = Set<String>()
        return summaries.reversed().compactMap { summary in
            guard seen.insert(summary.id).inserted else { return nil }
            return summary
        }.reversed()
    }
}
