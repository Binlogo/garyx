public struct GaryxConnectRefreshPlan: Equatable, Sendable {
    public enum CriticalStep: Equatable, Sendable {
        case selectedHomeFeed
    }

    public enum BackgroundDomain: CaseIterable, Equatable, Hashable, Sendable {
        case routeRestoration
        case agentTargets
        case catalogSweep
        case codingUsage
    }

    public var criticalSteps: [CriticalStep]
    public var concurrentBackgroundDomains: [BackgroundDomain]

    public init(
        criticalSteps: [CriticalStep],
        concurrentBackgroundDomains: [BackgroundDomain]
    ) {
        self.criticalSteps = criticalSteps
        self.concurrentBackgroundDomains = concurrentBackgroundDomains
    }

    public static let afterSuccessfulProbe = Self(
        criticalSteps: [.selectedHomeFeed],
        concurrentBackgroundDomains: BackgroundDomain.allCases
    )
}
