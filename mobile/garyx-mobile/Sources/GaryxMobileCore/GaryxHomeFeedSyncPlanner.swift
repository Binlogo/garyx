import Foundation

public enum GaryxHomeFeedVisibility: Equatable, Sendable {
    case foregroundVisible
    case foregroundHidden
    case background
}

public enum GaryxHomeFeedConnection: Equatable, Sendable {
    case ready
    case checking
    case down
}

public enum GaryxHomeFeedQueuedHeadRequest: Equatable, Sendable {
    case none
    case runnable
    case waitingForActiveHead
    case waitingForLoadMore
}

public struct GaryxHomeFeedDemand: Equatable, Sendable {
    public var phase: GaryxRecentHeadPhase
    public var hasPendingUserIntent: Bool
    public var queuedHeadRequest: GaryxHomeFeedQueuedHeadRequest

    public init(
        phase: GaryxRecentHeadPhase,
        hasPendingUserIntent: Bool = false,
        queuedHeadRequest: GaryxHomeFeedQueuedHeadRequest = .none
    ) {
        self.phase = phase
        self.hasPendingUserIntent = hasPendingUserIntent
        self.queuedHeadRequest = queuedHeadRequest
    }
}

public struct GaryxHomeFeedSyncState: Equatable, Sendable {
    public var lastRefreshStartedAt: Date?
    public var immediateOwedSince: Date?

    public init(
        lastRefreshStartedAt: Date? = nil,
        immediateOwedSince: Date? = nil
    ) {
        self.lastRefreshStartedAt = lastRefreshStartedAt
        self.immediateOwedSince = immediateOwedSince
    }
}

public enum GaryxHomeFeedRefreshReason: Equatable, Sendable {
    case immediateDebt
    case userIntent
    case queuedHeadRequest
    case visibleCadence
    case hiddenCadence
}

public enum GaryxHomeFeedExternalWake: Equatable, Sendable {
    case connection
    case visibility
    case activeHeadCompletion
    case loadMoreCompletion
    case userIntent
}

public enum GaryxHomeFeedSyncAction: Equatable, Sendable {
    case waitForExternalWake(GaryxHomeFeedExternalWake)
    case refreshNow(GaryxHomeFeedRefreshReason)
    case sleep(until: Date)
    case downgradeImmediateDemand
}

/// Pure scheduling kernel. Visibility selects cadence only; it never owns or
/// terminates the synchronization lifecycle.
public enum GaryxHomeFeedSyncPlanner {
    public static let visibleInterval: TimeInterval = 10
    public static let hiddenInterval: TimeInterval = 60

    public static func next(
        state: GaryxHomeFeedSyncState,
        demand: GaryxHomeFeedDemand,
        visibility: GaryxHomeFeedVisibility,
        connection: GaryxHomeFeedConnection,
        now: Date,
        immediateDemandTimeout: TimeInterval
    ) -> GaryxHomeFeedSyncAction {
        if demand.phase.owesImmediateRequest,
           let owedSince = state.immediateOwedSince {
            let deadline = owedSince.addingTimeInterval(immediateDemandTimeout)
            if deadline <= now {
                return .downgradeImmediateDemand
            }
            if visibility == .background || connection != .ready {
                return .sleep(until: deadline)
            }
        }

        guard visibility != .background else {
            return .waitForExternalWake(.visibility)
        }
        guard connection == .ready else {
            return .waitForExternalWake(.connection)
        }

        if demand.hasPendingUserIntent {
            return .refreshNow(.userIntent)
        }

        switch demand.queuedHeadRequest {
        case .none:
            break
        case .runnable:
            return .refreshNow(.queuedHeadRequest)
        case .waitingForActiveHead:
            if demand.phase.owesImmediateRequest,
               let owedSince = state.immediateOwedSince {
                return .sleep(
                    until: owedSince.addingTimeInterval(immediateDemandTimeout)
                )
            }
            return .waitForExternalWake(.activeHeadCompletion)
        case .waitingForLoadMore:
            if demand.phase.owesImmediateRequest,
               let owedSince = state.immediateOwedSince {
                return .sleep(
                    until: owedSince.addingTimeInterval(immediateDemandTimeout)
                )
            }
            return .waitForExternalWake(.loadMoreCompletion)
        }

        if demand.phase.owesImmediateRequest {
            return .refreshNow(.immediateDebt)
        }

        if demand.phase.isRefreshing {
            return .waitForExternalWake(.activeHeadCompletion)
        }
        if demand.phase.awaitsUserAction {
            return .waitForExternalWake(.userIntent)
        }

        let interval: TimeInterval
        let reason: GaryxHomeFeedRefreshReason
        switch visibility {
        case .foregroundVisible:
            interval = visibleInterval
            reason = .visibleCadence
        case .foregroundHidden:
            interval = hiddenInterval
            reason = .hiddenCadence
        case .background:
            return .waitForExternalWake(.visibility)
        }

        guard let lastRefreshStartedAt = state.lastRefreshStartedAt else {
            return .refreshNow(reason)
        }
        let deadline = lastRefreshStartedAt.addingTimeInterval(interval)
        return deadline <= now ? .refreshNow(reason) : .sleep(until: deadline)
    }
}
