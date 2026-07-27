import XCTest
@testable import GaryxMobileCore

final class GaryxLastOpenedThreadRestorationPolicyTests: XCTestCase {
    func testPersistenceDecisionRemainsInCoreAndAlwaysAllowsSelectedThreads() {
        XCTAssertTrue(GaryxLastOpenedThreadRestorationPolicy.shouldPersistLastOpenedThread())
    }

    func testRestoresPersistedThreadWhenNavigationIsUnclaimed() {
        XCTAssertEqual(
            GaryxLastOpenedThreadRestorationPolicy.restoreThreadId(
                persistedLastOpenedThreadId: " thread::restored ",
                persistedLastSessionWasOnThread: true,
                selectedThreadId: nil,
                hasPendingMobileRoute: false,
                hasPendingThreadIntent: false,
                navigationState: GaryxMobileNavigationState(),
                sidebarVisible: false
            ),
            "thread::restored"
        )
    }

    func testDoesNotRestoreWhenAnotherNavigationClaimExists() {
        XCTAssertNil(
            GaryxLastOpenedThreadRestorationPolicy.restoreThreadId(
                persistedLastOpenedThreadId: "thread::restored",
                persistedLastSessionWasOnThread: true,
                selectedThreadId: nil,
                hasPendingMobileRoute: true,
                hasPendingThreadIntent: false,
                navigationState: GaryxMobileNavigationState(),
                sidebarVisible: false
            )
        )
    }

    func testCurrentSessionRequiresPresentedConversationAndThread() {
        XCTAssertTrue(
            GaryxLastOpenedThreadRestorationPolicy.isCurrentSessionRestorable(
                navigationState: GaryxMobileNavigationState(
                    activePanel: .chat,
                    presentsContent: true
                ),
                selectedThreadId: "thread::selected"
            )
        )
        XCTAssertFalse(
            GaryxLastOpenedThreadRestorationPolicy.isCurrentSessionRestorable(
                navigationState: GaryxMobileNavigationState(),
                selectedThreadId: "thread::selected"
            )
        )
    }

    func testInitialEmptyLoadingSnapshotDerivesRecentSkeletonRowsInCore() {
        let store = GaryxHomeThreadListStore()
        let input = GaryxHomeThreadListInput(
            sectionsInput: GaryxHomeThreadSectionsInput(
                threads: [],
                agents: [],
                automations: [],
                pinnedThreadIds: [],
                recentThreadIds: [],
                selectedThreadId: nil
            ),
            runningThreadIds: [],
            isHomeVisible: true,
            recentFeedPresentation: .init(headPhase: primingPhase())
        )

        XCTAssertTrue(store.apply(input))
        XCTAssertEqual(store.snapshot.recentPlaceholder, .loadingSkeleton(rowCount: 6))

        let unavailable = GaryxHomeThreadListInput(
            sectionsInput: input.sectionsInput,
            runningThreadIds: [],
            isHomeVisible: true,
            recentFeedPresentation: .init(
                headPhase: .primingOwed(.networkFailure, .userAction)
            )
        )
        XCTAssertTrue(store.apply(unavailable))
        XCTAssertEqual(store.snapshot.recentPlaceholder, .unavailable)
    }

    func testCachedRecentRowsSuppressSkeletonDuringRefresh() {
        let fixture = GaryxHomeListFixture.makeInputs(threadCount: 3, pinnedCount: 0, runningCount: 0)
        let store = GaryxHomeThreadListStore()
        let input = GaryxHomeThreadListInput(
            sectionsInput: GaryxHomeThreadSectionsInput(
                threads: fixture.threads,
                agents: fixture.agents,
                automations: fixture.automations,
                pinnedThreadIds: fixture.pinnedThreadIds,
                recentThreadIds: fixture.recentThreadIds,
                selectedThreadId: fixture.selectedThreadId
            ),
            runningThreadIds: [],
            isHomeVisible: true,
            recentFeedPresentation: .init(headPhase: refreshingPhase())
        )

        XCTAssertTrue(store.apply(input))
        XCTAssertEqual(store.snapshot.sections.recent.count, 3)
        XCTAssertEqual(store.snapshot.recentPlaceholder, .none)
    }

    private func primingPhase() -> GaryxRecentHeadPhase {
        var state = GaryxRecentHeadState()
        _ = state.beginAttempt()
        return state.phase
    }

    private func refreshingPhase() -> GaryxRecentHeadPhase {
        var state = GaryxRecentHeadState()
        let priming = state.beginAttempt()!
        _ = state.settleSuccess(priming)
        _ = state.beginAttempt()
        return state.phase
    }
}
