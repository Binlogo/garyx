import Foundation

/// Pure admission policy for the low-frequency mobile catalog sweep.
public enum GaryxCatalogRefreshPolicy {
    public enum Intent: Equatable, Sendable {
        case forced
        case staleGated
    }

    public enum Action: Equatable, Sendable {
        case startSweep
        case joinInFlight
        case skip
    }

    public static let defaultTTL: TimeInterval = 5 * 60

    public static func action(
        for intent: Intent,
        now: Date,
        lastSuccessfulSweepCompletedAt: Date?,
        ttl: TimeInterval = defaultTTL,
        isSweepInFlight: Bool
    ) -> Action {
        if isSweepInFlight {
            return .joinInFlight
        }
        if intent == .forced {
            return .startSweep
        }
        guard let lastSuccessfulSweepCompletedAt else {
            return .startSweep
        }
        return now.timeIntervalSince(lastSuccessfulSweepCompletedAt) >= ttl
            ? .startSweep
            : .skip
    }
}
