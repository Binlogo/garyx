import XCTest
@testable import GaryxMobileCore

final class GaryxHomeFeedSyncPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let timeout: TimeInterval = 8

    func testVisibleAndHiddenCadencesOnlyChangeTheDeadline() {
        XCTAssertEqual(
            next(visibility: .foregroundVisible),
            .refreshNow(.visibleCadence)
        )
        XCTAssertEqual(
            next(
                state: .init(lastRefreshStartedAt: start),
                visibility: .foregroundVisible,
                now: start.addingTimeInterval(4)
            ),
            .sleep(until: start.addingTimeInterval(10))
        )
        XCTAssertEqual(
            next(
                state: .init(lastRefreshStartedAt: start),
                visibility: .foregroundVisible,
                now: start.addingTimeInterval(10)
            ),
            .refreshNow(.visibleCadence)
        )
        XCTAssertEqual(
            next(
                state: .init(lastRefreshStartedAt: start),
                visibility: .foregroundHidden,
                now: start.addingTimeInterval(10)
            ),
            .sleep(until: start.addingTimeInterval(60))
        )
        XCTAssertEqual(
            next(
                state: .init(lastRefreshStartedAt: start),
                visibility: .foregroundHidden,
                now: start.addingTimeInterval(60)
            ),
            .refreshNow(.hiddenCadence)
        )
    }

    func testVisibilityPulseNeverChangesOrConsumesDemand() {
        let demand = GaryxHomeFeedDemand(
            phase: .primingOwed(.supersededByReset, .immediate)
        )
        for visibility in [
            GaryxHomeFeedVisibility.foregroundVisible,
            .foregroundHidden,
            .foregroundVisible,
        ] {
            XCTAssertEqual(
                next(demand: demand, visibility: visibility),
                .refreshNow(.immediateDebt)
            )
        }
    }

    func testBackgroundAndNonReadyConnectionSuspendWithoutConsumingIntent() {
        let intent = GaryxHomeFeedDemand(
            phase: .primingOwed(.networkFailure, .userAction),
            hasPendingUserIntent: true
        )
        XCTAssertEqual(
            next(demand: intent, visibility: .background),
            .waitForExternalWake(.visibility)
        )
        XCTAssertEqual(
            next(demand: intent, connection: .checking),
            .waitForExternalWake(.connection)
        )
        XCTAssertEqual(
            next(demand: intent, connection: .down),
            .waitForExternalWake(.connection)
        )
        XCTAssertEqual(
            next(demand: intent),
            .refreshNow(.userIntent)
        )
    }

    func testImmediateDebtRefreshesUntilMeasuredDeadlineThenDowngrades() {
        let phase = GaryxRecentHeadPhase.primingOwed(
            .supersededByReset,
            .immediate
        )
        XCTAssertEqual(
            next(
                state: .init(immediateOwedSince: start),
                demand: .init(phase: phase),
                now: start.addingTimeInterval(timeout - 0.001)
            ),
            .refreshNow(.immediateDebt)
        )
        XCTAssertEqual(
            next(
                state: .init(immediateOwedSince: start),
                demand: .init(phase: phase),
                now: start.addingTimeInterval(timeout)
            ),
            .downgradeImmediateDemand
        )
        XCTAssertEqual(
            next(
                state: .init(immediateOwedSince: start),
                demand: .init(phase: phase),
                visibility: .background,
                connection: .down,
                now: start.addingTimeInterval(timeout - 1)
            ),
            .sleep(until: start.addingTimeInterval(timeout))
        )
        XCTAssertEqual(
            next(
                state: .init(immediateOwedSince: start),
                demand: .init(phase: phase),
                visibility: .background,
                connection: .down,
                now: start.addingTimeInterval(timeout)
            ),
            .downgradeImmediateDemand
        )
    }

    func testActiveAttemptAndUserActionFailureWaitForTheirOwner() {
        var state = GaryxRecentHeadState()
        let attempt = state.beginAttempt()!
        XCTAssertEqual(
            next(demand: .init(phase: state.phase)),
            .waitForExternalWake(.activeHeadCompletion)
        )
        _ = state.settle(
            attempt,
            stalledBy: .networkFailure,
            demand: .userAction
        )
        XCTAssertEqual(
            next(demand: .init(phase: state.phase)),
            .waitForExternalWake(.userIntent)
        )
        XCTAssertEqual(
            next(
                demand: .init(
                    phase: state.phase,
                    hasPendingUserIntent: true
                )
            ),
            .refreshNow(.userIntent)
        )
    }

    func testP4EveryTimerlessWaitNamesItsExternalWakeOwner() {
        var refreshing = GaryxRecentHeadState()
        _ = refreshing.beginAttempt()
        let cases: [
            (
                GaryxHomeFeedDemand,
                GaryxHomeFeedVisibility,
                GaryxHomeFeedConnection,
                GaryxHomeFeedSyncAction
            )
        ] = [
            (
                .init(phase: .ready, hasPendingUserIntent: true),
                .background,
                .ready,
                .waitForExternalWake(.visibility)
            ),
            (
                .init(phase: .ready, hasPendingUserIntent: true),
                .foregroundVisible,
                .down,
                .waitForExternalWake(.connection)
            ),
            (
                .init(
                    phase: refreshing.phase,
                    queuedHeadRequest: .waitingForActiveHead
                ),
                .foregroundVisible,
                .ready,
                .waitForExternalWake(.activeHeadCompletion)
            ),
            (
                .init(
                    phase: .ready,
                    queuedHeadRequest: .waitingForLoadMore
                ),
                .foregroundVisible,
                .ready,
                .waitForExternalWake(.loadMoreCompletion)
            ),
            (
                .init(phase: .readyStale(.networkFailure, .userAction)),
                .foregroundVisible,
                .ready,
                .waitForExternalWake(.userIntent)
            ),
        ]

        for (demand, visibility, connection, expected) in cases {
            XCTAssertEqual(
                next(
                    demand: demand,
                    visibility: visibility,
                    connection: connection
                ),
                expected
            )
        }
    }

    func testRunnableQueuedHeadPreemptsCadenceWhileBlockedImmediateHeadSleeps() {
        XCTAssertEqual(
            next(
                state: .init(lastRefreshStartedAt: start),
                demand: .init(
                    phase: .ready,
                    queuedHeadRequest: .runnable
                ),
                now: start.addingTimeInterval(1)
            ),
            .refreshNow(.queuedHeadRequest)
        )

        let deadline = start.addingTimeInterval(timeout)
        XCTAssertEqual(
            next(
                state: .init(immediateOwedSince: start),
                demand: .init(
                    phase: .readyStale(.interrupted, .immediate),
                    queuedHeadRequest: .waitingForLoadMore
                ),
                now: start.addingTimeInterval(1)
            ),
            .sleep(until: deadline)
        )
    }

    private func next(
        state: GaryxHomeFeedSyncState = .init(),
        demand: GaryxHomeFeedDemand = .init(phase: .ready),
        visibility: GaryxHomeFeedVisibility = .foregroundVisible,
        connection: GaryxHomeFeedConnection = .ready,
        now: Date? = nil
    ) -> GaryxHomeFeedSyncAction {
        GaryxHomeFeedSyncPlanner.next(
            state: state,
            demand: demand,
            visibility: visibility,
            connection: connection,
            now: now ?? start,
            immediateDemandTimeout: timeout
        )
    }
}
