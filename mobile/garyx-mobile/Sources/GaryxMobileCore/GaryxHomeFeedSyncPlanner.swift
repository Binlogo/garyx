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

public struct GaryxHomeFeedDemand: Equatable, Sendable {
    public var phase: GaryxRecentHeadPhase
    public var hasPendingUserIntent: Bool

    public init(
        phase: GaryxRecentHeadPhase,
        hasPendingUserIntent: Bool = false
    ) {
        self.phase = phase
        self.hasPendingUserIntent = hasPendingUserIntent
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
    case visibleCadence
    case hiddenCadence
}

public enum GaryxHomeFeedSyncAction: Equatable, Sendable {
    case none
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

        guard visibility != .background else { return .none }
        guard connection == .ready else { return .none }

        if demand.hasPendingUserIntent {
            return .refreshNow(.userIntent)
        }

        if demand.phase.owesImmediateRequest {
            return .refreshNow(.immediateDebt)
        }

        if demand.phase.isRefreshing || demand.phase.awaitsUserAction {
            return .none
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
            return .none
        }

        guard let lastRefreshStartedAt = state.lastRefreshStartedAt else {
            return .refreshNow(reason)
        }
        let deadline = lastRefreshStartedAt.addingTimeInterval(interval)
        return deadline <= now ? .refreshNow(reason) : .sleep(until: deadline)
    }
}
