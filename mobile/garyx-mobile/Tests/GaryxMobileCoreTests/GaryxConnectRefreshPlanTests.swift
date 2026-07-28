import XCTest
@testable import GaryxMobileCore

final class GaryxConnectRefreshPlanTests: XCTestCase {
    func testSuccessfulProbeHasOnlySelectedFeedOnCriticalPath() {
        XCTAssertEqual(
            GaryxConnectRefreshPlan.afterSuccessfulProbe.criticalSteps,
            [.selectedHomeFeed]
        )
    }

    func testEveryNonFeedDomainIsOneConcurrentBackgroundUnit() {
        XCTAssertEqual(
            Set(
                GaryxConnectRefreshPlan.afterSuccessfulProbe
                    .concurrentBackgroundDomains
            ),
            Set(GaryxConnectRefreshPlan.BackgroundDomain.allCases)
        )
        XCTAssertEqual(
            GaryxConnectRefreshPlan.afterSuccessfulProbe
                .concurrentBackgroundDomains.count,
            4
        )
    }
}
