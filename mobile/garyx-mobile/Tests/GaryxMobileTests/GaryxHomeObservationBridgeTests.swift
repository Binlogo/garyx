import Observation
import XCTest
@testable import GaryxMobile

@MainActor
final class GaryxHomeObservationBridgeTests: XCTestCase {
    func testConversationWritesDoNotInvalidateStaticHomeStoreReadsButHomeWritesDo() {
        let model = makeModel()
        let thread = makeThread(id: "thread-home-observation")
        model.selectedThread = thread
        let store = model.homeObservationStore

        var conversationInvalidations = 0
        trackStaticHomeReads(store) {
            conversationInvalidations += 1
        }

        model.setRenderSnapshot(
            GaryxRenderSnapshot(
                basedOnSeq: 1,
                rows: [],
                tailActivity: .thinking
            ),
            for: thread.id
        )
        model.setMessages([
            GaryxMobileMessage(
                id: "message-1",
                role: .assistant,
                text: "streaming",
                isStreaming: true
            )
        ], for: thread.id)

        XCTAssertEqual(conversationInvalidations, 0)

        var homeInvalidations = 0
        trackStaticHomeReads(store) {
            homeInvalidations += 1
        }

        // Drive a home pagination write through the real path: priming the
        // pager flips hasMoreThreadSummaries/footer state, and the pager's
        // didSet republishes the observation-store pagination snapshot.
        var feeds = model.recentThreadFeeds
        primeRecentFeedState(
            &feeds,
            ids: ["thread-pagination"],
            hasMore: true,
            nextCursor: "cursor-30"
        )
        model.recentThreadFeeds = feeds

        XCTAssertEqual(homeInvalidations, 1)
    }

    func testHomeThreadListStorePublishesFromActorSnapshotsWithoutLegacyDerivation() async throws {
        try XCTSkipIf(
            !HomeProjectionLiveSourceConfiguration.usesActorSnapshots,
            "Actor cutover bridge assertions are not meaningful while the rollback env flag is disabled."
        )
        let model = makeModel()
        let thread = makeThread(id: "thread-actor-home")

        model.seedThreadSummariesForTesting([thread])
        primeRecentFeed(model, ids: [thread.id])
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertEqual(model.homeThreadListStore.snapshot.sections.allRows.map(\.id), [thread.id])
        XCTAssertEqual(model.homeThreadListStore.acceptedInputCount, 0)
        XCTAssertGreaterThan(model.homeThreadListStore.acceptedActorSnapshotCount, 0)
        XCTAssertEqual(
            model.homeThreadListStore.sectionDerivationCount,
            0,
            "Actor-backed live rendering must not derive home sections in the legacy main-actor store."
        )
    }

    func testCommittedRunStateDeltaDoesNotAlsoEmitFullCaptureFromDictionaryDidSet() async throws {
        try XCTSkipIf(
            !HomeProjectionLiveSourceConfiguration.usesActorSnapshots,
            "Actor cutover bridge assertions are not meaningful while the rollback env flag is disabled."
        )
        let model = makeModel()
        let thread = makeThread(id: "thread-committed-delta")

        model.seedThreadSummariesForTesting([thread])
        primeRecentFeed(model, ids: [thread.id])
        await model.homeProjectionGateway.waitForIdleForTesting()
        let baselineEmitCount = model.homeProjectionGateway.snapshotEmitCount

        model.applyTranscriptRunState(
            GaryxTranscriptRunState(busy: true, activeRunId: "run-committed-delta", activity: .thinking),
            threadId: thread.id
        )
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertEqual(model.homeProjectionGateway.snapshotEmitCount, baselineEmitCount + 1)
        let row = try XCTUnwrap(model.homeThreadListStore.snapshot.sections.allRows.first { $0.id == thread.id })
        XCTAssertTrue(row.presentation.isRunning)
        XCTAssertEqual(model.homeThreadListStore.acceptedInputCount, 0)
        XCTAssertEqual(model.homeThreadListStore.sectionDerivationCount, 0)
    }

    func testDebugSnapshotSeedsScopedWorkspaceMembership() {
        let model = makeModel()

        model.loadDebugSnapshot(recentFilter: .all)

        let store = model.workspaceThreadListStore(path: "/workspace/garyx")
        XCTAssertTrue(store.snapshot.isPrimed)
        XCTAssertEqual(store.snapshot.rows.map(\.id), ["thread-history", "thread-task-board"])
    }

    func testModelRegistersRecentResidentsAndProjectsHubMotionIntoWorkspaceStore() {
        let model = makeModel()
        model.loadDebugSnapshot(recentFilter: .all)
        let store = model.workspaceThreadListStore(path: "/workspace/garyx")

        XCTAssertEqual(
            model.threadMutationHubStore.value.residents["recent:all"]?.orderedThreadIds,
            model.recentThreadFeeds.allFeed.orderedThreadIds
        )
        XCTAssertNotNil(model.threadMutationHubStore.value.residents["recent:non_task"])

        let mutationId: GaryxThreadMutationID = "test-workspace-archive"
        XCTAssertTrue(model.threadMutationHubStore.value.began(
            mutationId: mutationId,
            kind: .archive(threadId: "thread-history"),
            gatewayRuntimeEpoch: model.threadMutationHubStore.value.gatewayRuntimeEpoch
        ))
        model.refreshResidentThreadListStores()
        XCTAssertEqual(store.snapshot.motionById["thread-history"], .archiving)

        XCTAssertTrue(model.threadMutationHubStore.value.rolledBack(
            mutationId: mutationId,
            gatewayRuntimeEpoch: model.threadMutationHubStore.value.gatewayRuntimeEpoch
        ))
        model.refreshResidentThreadListStores()
        XCTAssertTrue(store.snapshot.motionById.isEmpty)
        XCTAssertEqual(store.snapshot.rows.map(\.id), ["thread-history", "thread-task-board"])
    }

    func testWorkspaceStoreTracksSelectionAndAutomationTargetCapabilities() throws {
        let model = makeModel()
        model.loadDebugSnapshot(recentFilter: .all)
        let store = model.workspaceThreadListStore(path: "/workspace/garyx")
        let thread = try XCTUnwrap(store.snapshot.rows.first { $0.id == "thread-task-board" })

        XCTAssertEqual(store.snapshot.selectedThreadId, "thread-history")
        XCTAssertEqual(store.snapshot.capabilitiesById[thread.id]?.canArchive, true)

        model.selectedThread = thread
        XCTAssertEqual(store.snapshot.selectedThreadId, thread.id)

        model.automations = [
            GaryxAutomationSummary(
                id: "automation-target",
                label: "Targeted automation",
                prompt: "Test",
                agentId: nil,
                workspacePath: "/workspace/garyx",
                targetThreadId: thread.id
            )
        ]
        XCTAssertEqual(store.snapshot.capabilitiesById[thread.id]?.canArchive, false)
        XCTAssertEqual(
            store.snapshot.capabilitiesById[thread.id]?.archiveStrategy,
            GaryxThreadArchiveStrategy.none
        )
    }

    func testHomeThreadSearchRowsPublishOffWindowFavoriteAndRunState() throws {
        let model = makeModel()
        let thread = makeThread(id: "thread-search-outside-home-window")
        let store = model.homeThreadSearchRowsStore

        XCTAssertFalse(
            model.homeThreadListStore.snapshot.sections.allRows.contains {
                $0.id == thread.id
            }
        )
        var row = try XCTUnwrap(store.rows(for: [thread]).first)
        XCTAssertFalse(row.presentation.isFavorite)
        XCTAssertFalse(row.presentation.isRunning)
        XCTAssertTrue(row.capabilities.canArchive)

        let favoritePublishCount = store.publishCount
        model.setThreadFavorite(thread.id, desired: true)

        XCTAssertGreaterThan(store.publishCount, favoritePublishCount)
        row = try XCTUnwrap(store.rows(for: [thread]).first)
        XCTAssertTrue(row.presentation.isFavorite)

        let runPublishCount = store.publishCount
        model.applyTranscriptRunState(
            GaryxTranscriptRunState(
                busy: true,
                activeRunId: "run-search-result",
                activity: .thinking
            ),
            threadId: thread.id
        )

        XCTAssertGreaterThan(store.publishCount, runPublishCount)
        row = try XCTUnwrap(store.rows(for: [thread]).first)
        XCTAssertTrue(row.presentation.isRunning)
        XCTAssertFalse(row.capabilities.canArchive)
        XCTAssertEqual(row.capabilities.archiveStrategy, .none)
    }

    func testHomeThreadSearchRowsScopeTracksEveryGatewayActivation() async {
        let model = makeModel()
        let store = model.homeThreadSearchRowsStore
        let initialToken = model.gatewayRequestToken

        XCTAssertEqual(store.context.gatewayRequestToken, initialToken)
        XCTAssertTrue(store.context.isGatewayScopeActive)
        let exitPublishCount = store.publishCount
        model.exitCurrentGatewayScope(.suspend)

        XCTAssertNotEqual(model.gatewayRequestToken, initialToken)
        XCTAssertEqual(store.context.gatewayRequestToken, model.gatewayRequestToken)
        XCTAssertFalse(store.context.isGatewayScopeActive)
        XCTAssertGreaterThan(store.publishCount, exitPublishCount)
        do {
            _ = try await model.fetchHomeThreadSearchPage(
                GaryxHomeThreadSearchEndpointRequest(
                    query: "Test thread",
                    cursor: nil
                ),
                gatewayRequestToken: model.gatewayRequestToken
            )
            XCTFail("a suspended gateway scope must not start search transport")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let suspendedToken = model.gatewayRequestToken
        let activationPublishCount = store.publishCount
        model.gatewayURL = "http://127.0.0.1:31338"
        model.activateCurrentGatewayScope()

        XCTAssertNotEqual(model.gatewayRequestToken, suspendedToken)
        XCTAssertEqual(store.context.gatewayRequestToken, model.gatewayRequestToken)
        XCTAssertTrue(store.context.isGatewayScopeActive)
        XCTAssertGreaterThan(store.publishCount, activationPublishCount)
    }

    func testHomeThreadSearchDismissalRetainsQueryUntilMorphCompletes() {
        let model = makeModel()
        let store = GaryxHomeThreadSearchStore()

        store.beginPresentation()
        store.updateQuery("Project thread", model: model)
        store.beginDismissal()

        XCTAssertEqual(store.queryText, "Project thread")
        XCTAssertEqual(store.state.query, "Project thread")

        store.completeDismissal()

        XCTAssertEqual(store.queryText, "")
        XCTAssertNil(store.state.query)
        XCTAssertEqual(store.state.presentation, .prompt)
    }

    private func makeModel() -> GaryxMobileModel {
        let suiteName = "GaryxHomeObservationBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("http://127.0.0.1:31337", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        return GaryxMobileModel(defaults: defaults)
    }

    private func makeThread(id: String) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: "Observation Thread",
            createdAt: nil,
            updatedAt: nil,
            lastMessagePreview: "",
            workspacePath: nil,
            messageCount: nil,
            agentId: nil,
            providerType: nil,
            recentRunId: nil,
            activeRunId: nil,
            runState: nil,
            worktreePath: nil
        )
    }

    private func primeRecentFeed(_ model: GaryxMobileModel, ids: [String]) {
        var feeds = model.recentThreadFeeds
        primeRecentFeedState(&feeds, ids: ids)
        model.recentThreadFeeds = feeds
    }

    private func primeRecentFeedState(
        _ feeds: inout GaryxRecentThreadFeeds,
        ids: [String],
        hasMore: Bool = false,
        nextCursor: String? = nil
    ) {
        let effects = feeds.requestHeadEffects(
            filter: .all,
            source: .userAction
        )
        guard let request = effects.compactMap({ effect -> GaryxRecentHeadRequest? in
            guard case .requestHead(let request) = effect else { return nil }
            return request
        }).first,
        let ticket = feeds.beginHeadRequest(
            request,
            gatewayScope: "http://127.0.0.1:31337",
            runtimeEpoch: 1
        ) else {
            return XCTFail("expected an owned Recent head request")
        }
        _ = feeds.completeHead(
            ticket,
            result: .page(
                makeGaryxTestRecentRefreshBundle(
                    threadIds: ids,
                    hasMore: hasMore,
                    nextCursor: nextCursor
                )
            )
        )
    }

    private func trackStaticHomeReads(
        _ store: GaryxHomeObservationStore,
        onChange: @escaping () -> Void
    ) {
        withObservationTracking {
            _ = store.isGatewayConfigured
            _ = store.connectionState
            _ = store.debugShowsGatewaySwitcher
            _ = store.showsSettings
            _ = store.lastError
            _ = store.isLoadingMoreThreads
            _ = store.hasMoreThreadSummaries
        } onChange: {
            onChange()
        }
    }
}

func makeGaryxTestRecentRefreshBundle(
    threadIds: [String],
    storeIncarnationId: String = "11111111-1111-4111-8111-111111111111",
    serverBootId: String = "22222222-2222-4222-8222-222222222222",
    hasMore: Bool = false,
    nextCursor: String? = nil
) -> GaryxRecentThreadRefreshBundle {
    let page = GaryxRecentThreadFeedPage(
        storeIncarnationId: storeIncarnationId,
        serverBootId: serverBootId,
        rows: threadIds.enumerated().map { index, threadId in
            GaryxRecentThreadFeedRow(
                id: threadId,
                activitySeq: Int64(threadIds.count - index)
            )
        },
        hasMore: hasMore,
        nextCursor: nextCursor
    )
    return GaryxRecentThreadRefreshBundle(
        primaryPages: [page],
        verificationPage: page
    )
}
