import Foundation

/// Why the head lane stopped before it could settle its latest demand.
public enum GaryxRecentHeadStall: Equatable, Sendable {
    case networkFailure
    case interrupted
    case supersededByReset
    case identityReplacement
    case racedLocalMutation
}

/// Who owns the next transition out of an owed/stale phase.
public enum GaryxRecentHeadDemand: Equatable, Sendable {
    /// A `GaryxRecentFeedEffect.requestHead` is already queued with the
    /// gateway-scope owner.
    case immediate
    /// The last transport failed. Only a new explicit user intent re-arms it.
    case userAction
}

/// Opaque proof that the head transport corresponding to a phase was minted
/// by `GaryxRecentHeadState.beginAttempt()`.
///
/// There is deliberately no public or package-visible initializer. Callers can
/// carry and return an attempt, but cannot fabricate an in-flight phase.
public struct GaryxRecentHeadAttempt: Equatable, Sendable {
    fileprivate let epoch: UInt64
    fileprivate let sequence: UInt64

    fileprivate init(epoch: UInt64, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }
}

/// Complete head-lane state. There is intentionally no "unprimed and idle"
/// case: unknown content is either in flight or has an explicitly owned debt.
public enum GaryxRecentHeadPhase: Equatable, Sendable {
    case priming(GaryxRecentHeadAttempt)
    case primingOwed(GaryxRecentHeadStall, GaryxRecentHeadDemand)
    case ready
    case refreshing(GaryxRecentHeadAttempt)
    case readyStale(GaryxRecentHeadStall, GaryxRecentHeadDemand)

    public var isPrimed: Bool {
        switch self {
        case .priming, .primingOwed:
            return false
        case .ready, .refreshing, .readyStale:
            return true
        }
    }

    public var activeAttempt: GaryxRecentHeadAttempt? {
        switch self {
        case .priming(let attempt), .refreshing(let attempt):
            return attempt
        case .primingOwed, .ready, .readyStale:
            return nil
        }
    }

    public var isRefreshing: Bool {
        activeAttempt != nil
    }

    public var demand: GaryxRecentHeadDemand? {
        switch self {
        case .primingOwed(_, let demand), .readyStale(_, let demand):
            return demand
        case .priming, .ready, .refreshing:
            return nil
        }
    }

    public var stall: GaryxRecentHeadStall? {
        switch self {
        case .primingOwed(let stall, _), .readyStale(let stall, _):
            return stall
        case .priming, .ready, .refreshing:
            return nil
        }
    }

    public var awaitsUserAction: Bool {
        demand == .userAction
    }

    public var owesImmediateRequest: Bool {
        demand == .immediate
    }
}

/// Core-internal mint/consume surface for `GaryxRecentHeadAttempt`.
///
/// Keeping this reducer internal prevents another module from copying a feed's
/// state and minting an attempt without going through an owning domain.
struct GaryxRecentHeadState: Equatable, Sendable {
    private(set) var phase: GaryxRecentHeadPhase

    private var epoch: UInt64
    private var nextSequence: UInt64

    init(initialStall: GaryxRecentHeadStall = .supersededByReset) {
        phase = .primingOwed(initialStall, .immediate)
        epoch = 0
        nextSequence = 1
    }

    /// Claims a queued request and turns its debt into an opaque in-flight
    /// proof. Active attempts coalesce structurally.
    mutating func beginAttempt() -> GaryxRecentHeadAttempt? {
        guard phase.activeAttempt == nil else { return nil }
        let attempt = GaryxRecentHeadAttempt(
            epoch: epoch,
            sequence: nextSequence
        )
        nextSequence &+= 1
        phase = phase.isPrimed ? .refreshing(attempt) : .priming(attempt)
        return attempt
    }

    @discardableResult
    mutating func settleSuccess(_ attempt: GaryxRecentHeadAttempt) -> Bool {
        guard phase.activeAttempt == attempt, attempt.epoch == epoch else {
            return false
        }
        phase = .ready
        return true
    }

    @discardableResult
    mutating func settle(
        _ attempt: GaryxRecentHeadAttempt,
        stalledBy stall: GaryxRecentHeadStall,
        demand: GaryxRecentHeadDemand
    ) -> Bool {
        guard phase.activeAttempt == attempt, attempt.epoch == epoch else {
            return false
        }
        phase = phase.isPrimed
            ? .readyStale(stall, demand)
            : .primingOwed(stall, demand)
        return true
    }

    /// Invalidates every outstanding attempt and installs a new owned debt.
    mutating func reset(
        stalledBy stall: GaryxRecentHeadStall = .supersededByReset
    ) {
        epoch &+= 1
        phase = .primingOwed(stall, .immediate)
    }

    /// Invalidates an active attempt while retaining whether the domain has
    /// already committed rows.
    mutating func invalidate(
        stalledBy stall: GaryxRecentHeadStall,
        demand: GaryxRecentHeadDemand = .immediate
    ) {
        let wasPrimed = phase.isPrimed
        epoch &+= 1
        phase = wasPrimed
            ? .readyStale(stall, demand)
            : .primingOwed(stall, demand)
    }

    /// Records a new immediate obligation without discarding committed rows.
    mutating func oweImmediate(
        stalledBy stall: GaryxRecentHeadStall
    ) {
        guard phase.activeAttempt == nil else { return }
        phase = phase.isPrimed
            ? .readyStale(stall, .immediate)
            : .primingOwed(stall, .immediate)
    }

    /// Last-resort escape hatch for an executor that did not converge within
    /// the measured threshold.
    @discardableResult
    mutating func downgradeImmediateDemandToUserAction() -> Bool {
        switch phase {
        case .primingOwed(let stall, .immediate):
            phase = .primingOwed(stall, .userAction)
            return true
        case .readyStale(let stall, .immediate):
            phase = .readyStale(stall, .userAction)
            return true
        case .priming, .primingOwed(_, .userAction), .ready, .refreshing,
             .readyStale(_, .userAction):
            return false
        }
    }
}

/// Shared rendering contract for Recent and Favorites.
public protocol GaryxRecentHeadDomain: Sendable {
    var headPhase: GaryxRecentHeadPhase { get }
    var rows: [String] { get }
    var footerState: GaryxHomeLoadMoreFooterState { get }
}

public struct GaryxRecentThreadFeedPresentation: Equatable, Sendable {
    public var headPhase: GaryxRecentHeadPhase
    public var footerState: GaryxHomeLoadMoreFooterState

    public init(
        headPhase: GaryxRecentHeadPhase,
        footerState: GaryxHomeLoadMoreFooterState = .hidden
    ) {
        self.headPhase = headPhase
        self.footerState = footerState
    }

    public init<Domain: GaryxRecentHeadDomain>(_ domain: Domain) {
        self.init(
            headPhase: domain.headPhase,
            footerState: domain.footerState
        )
    }

    public var isPrimed: Bool {
        headPhase.isPrimed
    }

    public var isRefreshingHead: Bool {
        headPhase.isRefreshing
    }

    public var headFailure: Bool {
        headPhase.awaitsUserAction
    }

    public var showsInitialSkeleton: Bool {
        !headPhase.isPrimed
            && (headPhase.isRefreshing || headPhase.owesImmediateRequest)
    }

    func placeholder(rowsAreEmpty: Bool) -> GaryxHomeRecentPlaceholder {
        guard rowsAreEmpty else { return .none }
        switch headPhase {
        case .priming, .refreshing:
            return .loadingSkeleton(rowCount: 6)
        case .primingOwed(_, .immediate), .readyStale(_, .immediate):
            return .loadingSkeleton(rowCount: 6)
        case .primingOwed(_, .userAction), .readyStale(_, .userAction):
            return .unavailable
        case .ready:
            return .empty
        }
    }
}
