import Foundation
import XCTest
@testable import GaryxMobile

@MainActor
final class GaryxGatewayRequestTokenTests: XCTestCase {
    func testQueuedInputFallbackDoesNotCrossGatewayRuntime() async throws {
        let streamInputStarted = expectation(description: "Gateway A queued input request started")
        let streamInputGate = DispatchSemaphore(value: 0)
        let replacementChatStarts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (url.host, url.path) {
            case ("gateway-a.example.test", "/api/chat/stream-input"):
                streamInputStarted.fulfill()
                guard streamInputGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"inactive"}"#.utf8)
                )
            case ("gateway-b.example.test", "/api/chat/start"):
                replacementChatStarts.increment()
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"accepted","run_id":"run-on-b","thread_id":"shared-thread"}"#.utf8)
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            streamInputGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway-a.example.test"
        let sharedThread = makeThread(id: "shared-thread", title: "Shared thread ID")
        model.seedThreadSummariesForTesting([sharedThread])
        model.selectedThread = sharedThread
        let queuedInputTask = Task { @MainActor in
            await model.queueRemoteInput("Queue on Gateway A", attachments: [], in: sharedThread)
        }
        await fulfillment(of: [streamInputStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        model.seedThreadSummariesForTesting([sharedThread])
        model.selectedThread = sharedThread
        streamInputGate.signal()
        await queuedInputTask.value

        XCTAssertEqual(
            replacementChatStarts.value,
            0,
            "Gateway A's fallback input must not start a chat on Gateway B"
        )
        XCTAssertTrue(model.pendingQueuedInputsByIntentId.isEmpty)
    }

    func testSameURLHeaderChangeRotatesGatewayRequestToken() async throws {
        let replacementConnectStarted = expectation(description: "replacement header connect request started")
        let replacementConnectGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard url.path == "/api/status",
                  request.value(forHTTPHeaderField: "X-Environment") == "B" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            replacementConnectStarted.fulfill()
            guard replacementConnectGate.wait(timeout: .now() + 5) == .success else {
                throw GaryxRefreshStubError.timedOut
            }
            return try garyxStubResponse(
                request,
                statusCode: 503,
                data: Data(#"{"error":"replacement gateway unavailable"}"#.utf8)
            )
        }
        defer {
            replacementConnectGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayHeaders = "X-Environment=A"
        model.loadGatewayScopedUserState(fallbackToLegacy: false)
        let originalGeneration = model.gatewayRequestToken

        model.gatewayHeaders = "X-Environment=B"
        let connectTask = Task { @MainActor in
            await model.connectAndRefresh()
        }
        await fulfillment(of: [replacementConnectStarted], timeout: 2)

        XCTAssertNotEqual(model.gatewayRequestToken, originalGeneration)

        replacementConnectGate.signal()
        await connectTask.value
    }

    func testSameURLCredentialChangeInvalidatesInFlightDraftCreation() async throws {
        let createStarted = expectation(description: "credential A create request started")
        let replacementConnectStarted = expectation(description: "credential B connect request started")
        let createGate = DispatchSemaphore(value: 0)
        let replacementConnectGate = DispatchSemaphore(value: 0)
        let replacementChatStarts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let environment = request.value(forHTTPHeaderField: "X-Environment")
            switch (url.path, authorization, environment) {
            case ("/api/threads", "Bearer token-a", "stable"):
                createStarted.fulfill()
                guard createGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"thread_id":"thread-from-a","title":"Credential A thread"}"#.utf8)
                )
            case ("/api/status", "Bearer token-b", "stable"):
                replacementConnectStarted.fulfill()
                guard replacementConnectGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 503,
                    data: Data(#"{"error":"replacement gateway unavailable"}"#.utf8)
                )
            case ("/api/chat/start", "Bearer token-b", "stable"):
                replacementChatStarts.increment()
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"accepted","run_id":"run-on-b","thread_id":"thread-from-a"}"#.utf8)
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            createGate.signal()
            replacementConnectGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway.example.test"
        model.gatewayAuthToken = "token-a"
        model.gatewayHeaders = "X-Environment=stable"
        model.loadGatewayScopedUserState(fallbackToLegacy: false)
        let sendTask = Task { @MainActor in
            await model.send("Hello from credential A")
        }
        await fulfillment(of: [createStarted], timeout: 2)

        model.gatewayAuthToken = "token-b"
        let connectTask = Task { @MainActor in
            await model.connectAndRefresh()
        }
        await fulfillment(of: [replacementConnectStarted], timeout: 2)
        createGate.signal()
        await sendTask.value

        XCTAssertEqual(
            replacementChatStarts.value,
            0,
            "a same-URL credential change must invalidate the old create request"
        )
        XCTAssertNil(model.selectedThread)
        XCTAssertEqual(model.threadSummaryCache.count, 0)

        replacementConnectGate.signal()
        await connectTask.value
    }

    func testChatStartResponseDoesNotCommitAfterGatewaySwitch() async throws {
        let chatStartStarted = expectation(description: "Gateway A chat start request started")
        let chatStartGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard url.host == "gateway-a.example.test", url.path == "/api/chat/start" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            chatStartStarted.fulfill()
            guard chatStartGate.wait(timeout: .now() + 5) == .success else {
                throw GaryxRefreshStubError.timedOut
            }
            return try garyxStubResponse(
                request,
                data: Data(#"{"status":"accepted","run_id":"run-on-a","thread_id":"thread-on-a"}"#.utf8)
            )
        }
        defer {
            chatStartGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway-a.example.test"
        let thread = makeThread(id: "thread-on-a", title: "Gateway A thread")
        model.seedThreadSummariesForTesting([thread])
        model.selectedThread = thread
        let sendTask = Task { @MainActor in
            await model.send("Hello on Gateway A")
        }
        await fulfillment(of: [chatStartStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        chatStartGate.signal()
        await sendTask.value

        XCTAssertTrue(model.runTracker.busyThreadIds.isEmpty)
        XCTAssertNil(model.selectedThread)
        XCTAssertEqual(model.threadSummaryCache.count, 0)
        XCTAssertNil(model.lastError)
    }

    func testDraftThreadCreationDoesNotStartChatOnReplacementGateway() async throws {
        let createStarted = expectation(description: "Gateway A create request started")
        let createGate = DispatchSemaphore(value: 0)
        let replacementChatStarts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (url.host, url.path) {
            case ("gateway-a.example.test", "/api/threads"):
                createStarted.fulfill()
                guard createGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"thread_id":"thread-from-a","title":"Gateway A thread"}"#.utf8)
                )
            case ("gateway-b.example.test", "/api/chat/start"):
                replacementChatStarts.increment()
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"started","run_id":"run-on-b","thread_id":"thread-from-a"}"#.utf8)
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            createGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway-a.example.test"
        let sendTask = Task { @MainActor in
            await model.send("Hello from the draft")
        }
        await fulfillment(of: [createStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        createGate.signal()
        await sendTask.value

        XCTAssertEqual(
            replacementChatStarts.value,
            0,
            "a thread created by Gateway A must never be sent to Gateway B"
        )
        XCTAssertNil(model.selectedThread)
        XCTAssertEqual(model.threadSummaryCache.count, 0)
        XCTAssertNil(model.lastError)
    }

    func testDirectThreadCreationDoesNotCommitResponseFromSupersededGateway() async throws {
        let createStarted = expectation(description: "Gateway A direct create request started")
        let createGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard url.host == "gateway-a.example.test", url.path == "/api/threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            createStarted.fulfill()
            guard createGate.wait(timeout: .now() + 5) == .success else {
                throw GaryxRefreshStubError.timedOut
            }
            return try garyxStubResponse(
                request,
                data: Data(#"{"thread_id":"thread-from-a","title":"Gateway A thread"}"#.utf8)
            )
        }
        defer {
            createGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway-a.example.test"
        let createTask = Task { @MainActor in
            await model.createThread(workspaceOverride: nil)
        }
        await fulfillment(of: [createStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        createGate.signal()
        await createTask.value

        XCTAssertNil(model.selectedThread)
        XCTAssertEqual(model.threadSummaryCache.count, 0)
        XCTAssertNil(model.lastError)
    }

    func testOptimisticTitleResponseDoesNotCrossGatewayRuntime() async throws {
        let updateStarted = expectation(description: "Gateway A title update started")
        let updateGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard url.host == "gateway-a.example.test",
                  url.path == "/api/threads/shared-thread",
                  request.httpMethod == "PATCH" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            updateStarted.fulfill()
            guard updateGate.wait(timeout: .now() + 5) == .success else {
                throw GaryxRefreshStubError.timedOut
            }
            return try garyxStubResponse(
                request,
                data: Data(#"{"thread_id":"shared-thread","title":"Gateway A title"}"#.utf8)
            )
        }
        defer {
            updateGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.gatewayURL = "http://gateway-a.example.test"
        let original = makeThread(id: "shared-thread", title: "Original")
        model.seedThreadSummariesForTesting([original])
        model.selectedThread = original
        let updateTask = Task { @MainActor in
            await model.renameSelectedThread(to: "Optimistic A title")
        }
        await fulfillment(of: [updateStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        let replacement = makeThread(id: "shared-thread", title: "Gateway B title")
        model.seedThreadSummariesForTesting([replacement])
        model.selectedThread = replacement
        updateGate.signal()
        await updateTask.value

        XCTAssertEqual(model.cachedThreadSummary(for: replacement.id)?.title, replacement.title)
        XCTAssertEqual(model.selectedThread?.title, replacement.title)
        XCTAssertNil(model.lastError)
    }

    private func makeModel(session: URLSession) -> GaryxMobileModel {
        let suiteName = "GaryxGatewayRequestTokenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            "http://gateway.example.test",
            forKey: GaryxMobileSettingsKeys.gatewayUrl
        )
        return GaryxMobileModel(
            defaults: defaults,
            gatewayClientFactory: { configuration in
                GaryxGatewayClient(
                    configuration: configuration,
                    session: session,
                    retryPolicy: .disabled
                )
            }
        )
    }

    private func makeThread(id: String, title: String) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: title,
            createdAt: nil,
            updatedAt: "2026-07-07T02:00:00Z",
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

    private func makeStubSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        GaryxRecentThreadsURLProtocolStub.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GaryxRecentThreadsURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

/// TASK-1802: head refresh owns its filter-keyed pager ticket through the
/// final pre-commit await. Pins the App orchestration and #TASK-1804 archive
/// interleavings with an in-process URL loading stub.
@MainActor
final class GaryxHomeThreadListRefreshCommitTests: XCTestCase {
    private var homeFeedTestModels: [GaryxMobileModel] = []

    override func tearDown() {
        for model in homeFeedTestModels {
            model.homeFeedSyncCoordinator.deactivateScope()
            model.cancelThreadFavoritesSnapshotTransport()
            model.connectRefreshBackgroundTask?.cancel()
            model.sceneRefreshTask?.cancel()
        }
        homeFeedTestModels.removeAll()
        GaryxRecentThreadsURLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testR1ParkedPendingDoesNotFreezeFilterSwitchIntent() async throws {
        let session = makeIntentPassthroughStubSession()
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }
        let model = makeModel(session: session)
        prepareParkedChatsRequest(on: model)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = installHomeFeedCoordinator(
            model,
            now: { now },
            automaticallyEvaluatesWakeSignals: false
        )
        coordinator.updateConnection(.ready(version: "test"))

        model.selectRecentThreadFilter(.nonTask)
        let intentParked = await yieldUntil {
            coordinator.hasPendingUserIntentForTesting(.userAction)
        }
        XCTAssertTrue(
            intentParked,
            "the real filter-switch path must park its user intent before evaluation"
        )
        coordinator.evaluateForTesting()

        XCTAssertEqual(
            coordinator.startedHeadRequestCountForTesting(.nonTask),
            1,
            "R1: the parked Chats request and filter intent must merge and dispatch immediately"
        )
        XCTAssertFalse(
            coordinator.hasPendingUserIntentForTesting(.userAction),
            "R1: immediate dispatch must consume the filter-switch intent"
        )
        await stopHomeFeedTestModel(model)
    }

    func testR2VisibilityFlipIsIrrelevantAfterImmediateIntentDispatch() async throws {
        let session = makeIntentPassthroughStubSession()
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }
        let model = makeModel(session: session)
        prepareParkedChatsRequest(on: model)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = installHomeFeedCoordinator(
            model,
            now: { now },
            automaticallyEvaluatesWakeSignals: false
        )
        coordinator.updateConnection(.ready(version: "test"))

        model.selectRecentThreadFilter(.nonTask)
        let intentParked = await yieldUntil {
            coordinator.hasPendingUserIntentForTesting(.userAction)
        }
        XCTAssertTrue(intentParked)
        coordinator.evaluateForTesting()
        XCTAssertEqual(
            coordinator.startedHeadRequestCountForTesting(.nonTask),
            1,
            "R2: the intent must already be dispatched before the owner's workaround"
        )

        _ = model.recentThreadFeeds.consumePendingHeadRequestForTesting(
            filter: .nonTask
        )
        coordinator.updateHomeVisibility(false)
        coordinator.updateHomeVisibility(true)
        coordinator.evaluateForTesting()
        XCTAssertEqual(
            coordinator.startedHeadRequestCountForTesting(.nonTask),
            1,
            "R2: leaving and returning Home must not be required or duplicate the request"
        )
        await stopHomeFeedTestModel(model)
    }

    func testR3CadenceSurvivesInternallyParkedHeadRequest() async throws {
        let session = makeIntentPassthroughStubSession()
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }
        let model = makeModel(session: session)
        prepareParkedChatsRequest(on: model)
        model.recentThreadFeeds.select(.nonTask)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = installHomeFeedCoordinator(
            model,
            now: { now },
            automaticallyEvaluatesWakeSignals: false
        )
        coordinator.updateConnection(.ready(version: "test"))

        coordinator.evaluateForTesting()
        await coordinator.waitForTransportIdleForTesting()
        coordinator.evaluateForTesting()

        XCTAssertEqual(
            coordinator.startedHeadRequestCountForTesting(.nonTask),
            1,
            "R3: visible cadence must claim and dispatch the parked request"
        )
        XCTAssertTrue(
            coordinator.hasScheduledTimerForTesting(),
            "R3: once the refresh settles, visible cadence must remain scheduled"
        )
        await stopHomeFeedTestModel(model)
    }

    func testP3FavoritesIntentConvergesWhenSnapshotIsAlreadyInFlight() async throws {
        let snapshotStarted = expectation(description: "first favorites snapshot started")
        let snapshotGate = DispatchSemaphore(value: 0)
        let snapshotRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-favorites/snapshot"):
                if snapshotRequests.increment() == 1 {
                    snapshotStarted.fulfill()
                    guard snapshotGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: ["thread-favorite"])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-favorite"])
                )
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            snapshotGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let coordinator = model.homeFeedSyncCoordinator
        model.connectionState = .ready(version: "test")
        await fulfillment(of: [snapshotStarted], timeout: 2)

        model.selectRecentThreadFilter(.favorites)
        let intentParked = await yieldUntil {
            coordinator.hasPendingUserIntentForTesting(.userAction)
        }
        XCTAssertTrue(intentParked)

        snapshotGate.signal()
        await coordinator.waitForFavoritesConvergence()

        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .favorites)
        XCTAssertEqual(model.threadFavoritesState.headPhase, .ready)
        XCTAssertEqual(model.threadFavoritesState.rawThreadIds, ["thread-favorite"])
        XCTAssertFalse(coordinator.hasPendingUserIntentForTesting(.userAction))
        XCTAssertGreaterThanOrEqual(
            snapshotRequests.value,
            2,
            "the in-flight snapshot must settle and run a post-intent convergence"
        )
        await stopHomeFeedTestModel(model)
    }

    func testCommitDoesNotResurrectThreadArchivedDuringBackfillAwait() throws {
        let model = makeModel()
        let pinned = makeThread(id: "thread-pinned", title: "Pinned build")
        let recent = makeThread(id: "thread-recent", title: "Recent chat")
        let incoming = makeThread(id: "thread-new", title: "New arrival")
        model.seedThreadSummariesForTesting([pinned, recent])
        model.applyPinnedThreadIds([pinned.id])
        primeRecentFeed(model, ids: [pinned.id, recent.id], filter: .all)

        // The refresh ticket is captured before the archive races the
        // pre-await page snapshot.
        let ticket = try issueRecentHead(model, filter: .all)

        // Pre-await captures, exactly like refreshThreads: the page and the
        // pins arrived while `thread-pinned` was still live.
        let page = try makeRecentThreadsPage(threads: [pinned, recent, incoming])

        // Backfill await window: the gateway accepts the archive and the app
        // commits its one local removal while this older page is suspended.
        model.pendingThreadArchives.startArchive(threadId: pinned.id)
        model.pendingThreadArchives.commitArchive(threadId: pinned.id)
        model.removeArchivedThreadLocally(pinned.id)

        // The refresh resumes, but the filter-owned pager rejects every
        // pre-await snapshot before the app-layer commit can run.
        let completion = model.recentThreadFeeds.completeHead(
            ticket,
            result: .page(
                makeGaryxTestRecentRefreshBundle(
                    threadIds: page.threads.map(\.id),
                    storeIncarnationId: page.storeIncarnationId,
                    serverBootId: page.serverBootId,
                    hasMore: page.hasMore,
                    nextCursor: page.nextCursor
                )
            )
        )
        XCTAssertEqual(completion.outcome, .abandonedLocalMutation)

        XCTAssertFalse(
            model.pinnedThreadIds.contains(pinned.id),
            "a pre-await pins snapshot must not resurrect an archived thread"
        )
        XCTAssertFalse(
            model.allRecentThreadIds.contains(pinned.id),
            "a pre-await page snapshot must not resurrect an archived thread"
        )
        XCTAssertFalse(
            model.residentRecentThreadSummaries.contains { $0.id == pinned.id },
            "pre-await fetched summaries must not resurrect an archived thread"
        )
        XCTAssertEqual(model.allRecentThreadIds, [recent.id])
        XCTAssertNil(model.cachedThreadSummary(for: incoming.id))
    }

    func testCommitAppliesPinsPageAndThreadsWithoutPendingArchives() throws {
        let model = makeModel()
        let pinned = makeThread(id: "thread-pinned", title: "Pinned build")
        let recent = makeThread(id: "thread-recent", title: "Recent chat")
        let page = try makeRecentThreadsPage(threads: [pinned, recent])

        let ticket = try issueRecentHead(model, filter: .all)
        let completion = model.recentThreadFeeds.completeHead(
            ticket,
            result: .page(
                makeGaryxTestRecentRefreshBundle(
                    threadIds: page.threads.map(\.id),
                    storeIncarnationId: page.storeIncarnationId,
                    serverBootId: page.serverBootId,
                    hasMore: page.hasMore,
                    nextCursor: page.nextCursor
                )
            )
        )
        XCTAssertEqual(completion.outcome, .applied)

        model.commitRefreshedRecentThreadsPage(
            pinsPageThreadIds: [pinned.id],
            fetchedThreads: [pinned, recent],
            previousThreadSummaries: [],
            previouslyRemoteBusyThreadIds: [],
            selectionIdForThisRefresh: nil,
            runtimeGeneration: model.gatewayRequestToken
        )

        XCTAssertEqual(model.pinnedThreadIds, [pinned.id])
        XCTAssertEqual(model.allRecentThreadIds, [pinned.id, recent.id])
        XCTAssertEqual(
            model.residentRecentThreadSummaries.map(\.id).sorted(),
            [pinned.id, recent.id].sorted()
        )
    }

    /// The archive-resolved interleaving (review #TASK-1804 round 3) is
    /// gated in Core (`abandonedLocalMutation`); what the app must
    /// guarantee is that local list surgery actually marks the pager.
    func testLocalListSurgeryMarksThePagerMutationSequence() {
        let model = makeModel()
        let thread = makeThread(id: "thread-surgery", title: "Doomed")
        model.seedThreadSummariesForTesting([thread])
        model.applyPinnedThreadIds([thread.id])
        primeRecentFeed(model, ids: [thread.id], filter: .all)
        primeRecentFeed(model, ids: [thread.id], filter: .nonTask)

        let allBase = model.recentThreadFeeds.allFeed.pager.localMutationSequence
        let chatsBase = model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence
        model.removeArchivedThreadLocally(thread.id)
        XCTAssertGreaterThan(
            model.recentThreadFeeds.allFeed.pager.localMutationSequence,
            allBase,
            "archive/delete local removal must invalidate the All feed"
        )
        XCTAssertGreaterThan(
            model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence,
            chatsBase,
            "archive/delete local removal must invalidate the Chats feed"
        )

        let allAfterRemove = model.recentThreadFeeds.allFeed.pager.localMutationSequence
        let chatsAfterRemove = model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence
        model.removePinnedThreadIdLocally(thread.id)
        XCTAssertGreaterThan(
            model.recentThreadFeeds.allFeed.pager.localMutationSequence,
            allAfterRemove,
            "pin removal must invalidate the All feed"
        )
        XCTAssertGreaterThan(
            model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence,
            chatsAfterRemove,
            "pin removal must invalidate the Chats feed"
        )
    }

    func testAllOwnedConsumersAndSidebarSummaryIgnoreTheVisibleChatsFilter() throws {
        let model = makeModel()
        let task = makeThread(id: "thread-task", title: "Task backing thread")
        let chat = makeThread(id: "thread-chat", title: "Chat thread")
        model.seedThreadSummariesForTesting([task, chat])
        primeRecentFeed(model, ids: [task.id, chat.id], filter: .all)
        primeRecentFeed(model, ids: [chat.id], filter: .nonTask)
        model.recentThreadFeeds.select(.nonTask)

        XCTAssertEqual(model.visibleRecentThreads.map(\.id), [chat.id])
        XCTAssertEqual(model.allRecentThreads.map(\.id), [task.id, chat.id])
        XCTAssertEqual(try XCTUnwrap(model.sidebarThreadSummary(for: task.id)).id, task.id)
    }

    func testSummaryOnlyTitleUpdateDoesNotRebuildEitherFeedOrder() {
        let model = makeModel()
        let task = makeThread(id: "thread-task", title: "Old task title")
        let chat = makeThread(id: "thread-chat", title: "Chat thread")
        model.seedThreadSummariesForTesting([task, chat])
        primeRecentFeed(model, ids: [task.id, chat.id], filter: .all)
        primeRecentFeed(model, ids: [chat.id], filter: .nonTask)

        XCTAssertTrue(model.applyThreadTitleUpdate(threadId: task.id, title: "New task title"))
        XCTAssertEqual(model.allRecentThreadIds, [task.id, chat.id])
        XCTAssertEqual(model.recentThreadFeeds.nonTaskFeed.orderedThreadIds, [chat.id])
        XCTAssertEqual(model.cachedThreadSummary(for: task.id)?.title, "New task title")
    }

    func testChatsRefreshStartsOneAuxiliaryAllRequestWithoutExtendingSelectedRefresh() async throws {
        let auxiliaryStarted = expectation(description: "auxiliary All request started")
        let auxiliaryGate = DispatchSemaphore(value: 0)
        let allRequestCount = GaryxLockedCounter()
        let chatsPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-chat", title: "Chat thread"),
        ])
        let allPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-task", title: "Task thread"),
            (id: "thread-chat", title: "Chat thread"),
        ])
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if components.path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: Data(#"{"thread_ids":[]}"#.utf8))
            }
            guard components.path == "/api/recent-threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            let tasks = components.queryItems?.first(where: { $0.name == "tasks" })?.value
            if tasks == GaryxRecentThreadFilter.all.tasksQueryValue {
                let requestIndex = allRequestCount.increment()
                if requestIndex == 1 {
                    auxiliaryStarted.fulfill()
                    guard auxiliaryGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(request, data: allPage)
            }
            XCTAssertEqual(tasks, GaryxRecentThreadFilter.nonTask.tasksQueryValue)
            return try garyxStubResponse(request, data: chatsPage)
        }
        defer {
            auxiliaryGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.recentThreadFeeds.select(.nonTask)
        model.connectionState = .ready(version: "test")
        let selectedRefresh = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }

        await fulfillment(of: [auxiliaryStarted], timeout: 2)
        await selectedRefresh.value

        XCTAssertEqual(model.visibleRecentThreadIds, ["thread-chat"])
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertTrue(
            model.recentThreadFeeds.allFeed.presentation.isRefreshingHead,
            "the selected pull spinner must finish while the independent All request is still in flight"
        )

        // A second selected refresh is allowed, but the filter-owned All gate
        // must coalesce its auxiliary request.
        await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        XCTAssertEqual(allRequestCount.value, 1)

        auxiliaryGate.signal()
        let auxiliarySettled = await waitUntil {
            model.allRecentThreadIds == ["thread-task", "thread-chat"]
                && !model.recentThreadFeeds.allFeed.presentation.isRefreshingHead
        }
        XCTAssertTrue(auxiliarySettled)

        XCTAssertEqual(model.allRecentThreadIds, ["thread-task", "thread-chat"])
        XCTAssertEqual(
            model.visibleRecentThreadIds,
            ["thread-chat"],
            "the auxiliary result may update All and the shared cache, never the selected Chats membership"
        )
        XCTAssertNil(model.lastError)
    }

    func testChatsAuxiliaryFailureOnlyMarksAllFeed() async throws {
        let auxiliaryStarted = expectation(description: "failing auxiliary All request started")
        let auxiliaryGate = DispatchSemaphore(value: 0)
        let auxiliaryRequests = GaryxLockedCounter()
        let chatsPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-chat", title: "Chat thread"),
        ])
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if components.path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: Data(#"{"thread_ids":[]}"#.utf8))
            }
            guard components.path == "/api/recent-threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            let tasks = components.queryItems?.first(where: { $0.name == "tasks" })?.value
            if tasks == GaryxRecentThreadFilter.all.tasksQueryValue {
                if auxiliaryRequests.increment() == 1 {
                    auxiliaryStarted.fulfill()
                    guard auxiliaryGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 400,
                    data: Data(#"{"error":"synthetic auxiliary failure"}"#.utf8)
                )
            }
            return try garyxStubResponse(request, data: chatsPage)
        }
        defer {
            auxiliaryGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.recentThreadFeeds.select(.nonTask)
        model.connectionState = .ready(version: "test")
        let selectedRefresh = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        await fulfillment(of: [auxiliaryStarted], timeout: 2)
        await selectedRefresh.value
        let selectedPresentation = model.recentThreadFeeds.selectedPresentation

        auxiliaryGate.signal()
        let auxiliarySettled = await waitUntil {
            model.recentThreadFeeds.allFeed.headFailure
        }
        XCTAssertTrue(auxiliarySettled)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.visibleRecentThreadIds, ["thread-chat"])
        XCTAssertEqual(model.recentThreadFeeds.selectedPresentation, selectedPresentation)
        XCTAssertTrue(model.recentThreadFeeds.allFeed.headFailure)
    }

    func testAuxiliaryFailureFromPreviousGatewayDoesNotToastAfterReset() async throws {
        let auxiliaryStarted = expectation(description: "old gateway auxiliary request started")
        let auxiliaryGate = DispatchSemaphore(value: 0)
        let chatsPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-chat", title: "Chat thread"),
        ])
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if components.path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: Data(#"{"thread_ids":[]}"#.utf8))
            }
            guard components.path == "/api/recent-threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            let tasks = components.queryItems?.first(where: { $0.name == "tasks" })?.value
            if tasks == GaryxRecentThreadFilter.all.tasksQueryValue {
                auxiliaryStarted.fulfill()
                guard auxiliaryGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 400,
                    data: Data(#"{"error":"old gateway failed"}"#.utf8)
                )
            }
            return try garyxStubResponse(request, data: chatsPage)
        }
        defer {
            auxiliaryGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let oldCoordinator = model.homeFeedSyncCoordinator
        model.recentThreadFeeds.select(.nonTask)
        model.connectionState = .ready(version: "test")
        let selectedRefresh = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        await fulfillment(of: [auxiliaryStarted], timeout: 2)
        await selectedRefresh.value

        let oldGeneration = model.gatewayRequestToken
        model.resetGatewayRuntimeState()
        XCTAssertNotEqual(model.gatewayRequestToken, oldGeneration)
        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .nonTask)

        auxiliaryGate.signal()
        await oldCoordinator.waitForTransportIdleForTesting()

        XCTAssertNil(
            model.lastError,
            "an old gateway failure must be dropped while reset preserves the selected filter"
        )
        XCTAssertEqual(
            model.recentThreadFeeds.selectedPresentation?.headPhase,
            .primingOwed(.supersededByReset, .immediate)
        )
    }

    func testRestoredChatsFilterOwnsInitialSnapshotAndFirstVisibleRefresh() async throws {
        let suiteName = "GaryxHomeThreadListRefreshCommitTests.restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("http://gateway.example.test", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        defaults.set("nonTask", forKey: GaryxMobileSettingsKeys.recentThreadFilter)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selectedRequestStarted = expectation(description: "restored Chats request started")
        let selectedRequestCount = GaryxLockedCounter()
        let chatsPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-restored-chat", title: "Restored chat"),
        ])
        let allPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-restored-task", title: "Restored task"),
            (id: "thread-restored-chat", title: "Restored chat"),
        ])
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if components.path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: Data(#"{"thread_ids":[]}"#.utf8))
            }
            guard components.path == "/api/recent-threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            let tasks = components.queryItems?.first(where: { $0.name == "tasks" })?.value
            if tasks == GaryxRecentThreadFilter.nonTask.tasksQueryValue {
                if selectedRequestCount.increment() == 1 {
                    selectedRequestStarted.fulfill()
                }
                return try garyxStubResponse(request, data: chatsPage)
            }
            XCTAssertEqual(tasks, GaryxRecentThreadFilter.all.tasksQueryValue)
            return try garyxStubResponse(request, data: allPage)
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(defaults: defaults, session: session)
        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .nonTask)
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertEqual(model.homeThreadListStore.snapshot.selectedRecentFilter, .nonTask)
        XCTAssertEqual(
            model.homeProjectionGateway.snapshotEmitCount,
            1,
            "model init must not publish an intermediate All snapshot"
        )

        model.connectionState = .ready(version: "test")
        let refresh = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        await fulfillment(of: [selectedRequestStarted], timeout: 2)
        await refresh.value
        let auxiliarySettled = await waitUntil {
            model.allRecentThreadIds == [
                "thread-restored-task",
                "thread-restored-chat",
            ]
        }
        XCTAssertTrue(auxiliarySettled)

        XCTAssertEqual(model.visibleRecentThreadIds, ["thread-restored-chat"])
        XCTAssertEqual(
            model.allRecentThreadIds,
            ["thread-restored-task", "thread-restored-chat"]
        )
    }

    func testSelectingFavoritesUsesSnapshotAndAuxiliaryAllWithoutFavoritesRecentRequest() async throws {
        let suiteName = "GaryxHomeThreadListRefreshCommitTests.favorites.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("http://gateway.example.test", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let favoritesSnapshotStarted = expectation(description: "favorites snapshot started")
        let allRecentStarted = expectation(description: "auxiliary All requests started")
        allRecentStarted.expectedFulfillmentCount = 2
        let pinsStarted = expectation(description: "pins request started")
        let favoritesSnapshots = GaryxLockedCounter()
        let allRecentRequests = GaryxLockedCounter()
        let pinsRequests = GaryxLockedCounter()
        let unexpectedRecentRequests = GaryxLockedCounter()
        let allPage = try makeRecentThreadsPageData(rows: [
            (id: "thread-favorite", title: "Favorite thread"),
            (id: "thread-other", title: "Other thread"),
        ])
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "GET", components.path == "/api/thread-favorites/snapshot" {
                if favoritesSnapshots.increment() == 1 {
                    favoritesSnapshotStarted.fulfill()
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: ["thread-favorite"])
                )
            }
            if request.httpMethod == "GET", components.path == "/api/thread-pins" {
                if pinsRequests.increment() == 1 {
                    pinsStarted.fulfill()
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: ["thread-favorite"], revision: 3)
                )
            }
            guard components.path == "/api/recent-threads" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            let tasks = components.queryItems?.first(where: { $0.name == "tasks" })?.value
            guard tasks == GaryxRecentThreadFilter.all.tasksQueryValue else {
                unexpectedRecentRequests.increment()
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            if allRecentRequests.increment() <= 2 {
                allRecentStarted.fulfill()
            }
            return try garyxStubResponse(request, data: allPage)
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(defaults: defaults, session: session)
        model.selectRecentThreadFilter(.favorites)
        model.connectionState = .ready(version: "test")

        await fulfillment(
            of: [favoritesSnapshotStarted, allRecentStarted, pinsStarted],
            timeout: 2
        )
        let favoritesSettled = await waitUntil {
            model.threadFavoritesState.rawThreadIds == ["thread-favorite"]
                && model.allRecentThreadIds == ["thread-favorite", "thread-other"]
        }
        XCTAssertTrue(favoritesSettled)

        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .favorites)
        XCTAssertEqual(
            defaults.string(forKey: GaryxMobileSettingsKeys.recentThreadFilter),
            "favorites"
        )
        XCTAssertEqual(unexpectedRecentRequests.value, 0)
        XCTAssertGreaterThanOrEqual(favoritesSnapshots.value, 1)
        XCTAssertGreaterThanOrEqual(allRecentRequests.value, 2)
        XCTAssertEqual(model.visibleRecentThreadIds, ["thread-favorite"])
        XCTAssertEqual(model.allRecentThreadIds, ["thread-favorite", "thread-other"])
        XCTAssertEqual(model.pinnedThreadIds, ["thread-favorite"])
        await stopHomeFeedTestModel(model)
    }

    func testChatsFavoritesChatsRefreshesNonTaskOnReturn() async throws {
        let favoritesRequests = GaryxLockedCounter()
        let allRequests = GaryxLockedCounter()
        let nonTaskRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                favoritesRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let tasks = components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value
                if tasks == GaryxRecentThreadFilter.nonTask.tasksQueryValue {
                    nonTaskRequests.increment()
                    return try garyxStubResponse(
                        request,
                        data: try garyxRecentThreadsData(ids: ["thread-chat-current"])
                    )
                }
                XCTAssertEqual(tasks, GaryxRecentThreadFilter.all.tasksQueryValue)
                allRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-all-current"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        model.recentThreadFeeds.select(.nonTask)
        primeRecentFeed(model, ids: ["thread-chat-cached"], filter: .nonTask)
        primeRecentFeed(model, ids: ["thread-all-cached"], filter: .all)
        let coordinator = installHomeFeedCoordinator(model)

        model.selectRecentThreadFilter(.favorites)
        coordinator.updateConnection(.ready(version: "test"))
        let favoritesSettled = await waitUntil {
            favoritesRequests.value >= 1
                && allRequests.value > 0
                && model.threadFavoritesState.headPhase == .ready
        }
        XCTAssertTrue(favoritesSettled)
        XCTAssertEqual(nonTaskRequests.value, 0)

        model.selectRecentThreadFilter(.nonTask)
        let chatsSettled = await waitUntil {
            nonTaskRequests.value > 0
                && model.recentThreadFeeds.nonTaskFeed.headPhase == .ready
                && model.visibleRecentThreadIds.first == "thread-chat-current"
        }
        XCTAssertTrue(chatsSettled)
        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .nonTask)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none
        )
        await stopHomeFeedTestModel(model)
    }

    func testFavoritesSnapshotFailureSurfacesUnavailableAndManualRetryRecovers() async throws {
        let requests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard request.httpMethod == "GET",
                  url.path == "/api/thread-favorites/snapshot" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            if requests.increment() == 1 {
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"snapshot unavailable"}"#.utf8)
                )
            }
            return try garyxStubResponse(
                request,
                data: try garyxFavoritesSnapshotData(ids: [])
            )
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.recentThreadFeeds.select(.favorites)
        model.connectionState = .ready(version: "test")
        let failed = await waitUntil {
            model.threadFavoritesState.snapshotFailed
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertTrue(model.selectedRecentFeedPresentation.headFailure)

        model.refreshThreadFavoritesSnapshot()
        let recovered = await waitUntil {
            model.threadFavoritesState.rawRevision == 1
                && !model.threadFavoritesState.snapshotFailed
        }
        XCTAssertTrue(recovered)
        XCTAssertTrue(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertFalse(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertEqual(requests.value, 2)
    }

    func testAwaitableFavoritesSnapshotWaitsForNetworkSettlement() async throws {
        let snapshotStarted = expectation(description: "favorites snapshot started")
        let snapshotGate = DispatchSemaphore(value: 0)
        let snapshots = GaryxLockedCounter()
        let settled = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "GET", url.path == "/api/thread-summaries" {
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
            if request.httpMethod == "GET", url.path == "/api/thread-favorites/snapshot" {
                if snapshots.increment() == 1 {
                    snapshotStarted.fulfill()
                    guard snapshotGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: ["thread-favorite"])
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            snapshotGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.connectionState = .ready(version: "test")
        let refresh = Task { @MainActor in
            await model.refreshThreadFavoritesSnapshotAndWait()
            settled.increment()
        }
        await fulfillment(of: [snapshotStarted], timeout: 2)

        XCTAssertEqual(settled.value, 0)
        snapshotGate.signal()
        await refresh.value

        XCTAssertEqual(settled.value, 1)
        XCTAssertEqual(model.threadFavoritesState.rawThreadIds, ["thread-favorite"])
    }

    func testFavoritesIncarnationChangeOwnsImmediateRecentReplacement() async throws {
        let firstIncarnation = "11111111-1111-4111-8111-111111111111"
        let secondIncarnation = "33333333-3333-4333-8333-333333333333"
        let snapshots = GaryxLockedCounter()
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                recentRequests.increment()
                let incarnation = snapshots.value < 2
                    ? firstIncarnation
                    : secondIncarnation
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(
                        ids: ["thread-current"],
                        storeIncarnationId: incarnation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                let incarnation = snapshots.increment() == 1
                    ? firstIncarnation
                    : secondIncarnation
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(
                        ids: [],
                        storeIncarnationId: incarnation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.connectionState = .ready(version: "test")
        let firstSnapshotSettled = await waitUntil {
            model.threadFavoritesState.storeIncarnationId == firstIncarnation
        }
        XCTAssertTrue(firstSnapshotSettled)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        primeRecentFeed(model, ids: ["old-thread"], filter: .all)
        let oldEpoch = model.threadFavoritesState.runtimeEpoch
        let interrupted = try issueRecentHead(model, filter: .all)
        XCTAssertTrue(model.recentThreadFeeds.allFeed.pager.isRefreshingHead)
        let recentRequestsBeforeReset = recentRequests.value

        model.refreshThreadFavoritesSnapshot()
        let replacementSnapshotSettled = await waitUntil {
            model.threadFavoritesState.runtimeEpoch == oldEpoch + 1
                && model.threadFavoritesState.storeIncarnationId == secondIncarnation
                && model.recentThreadFeeds.allFeed.headPhase == .ready
                && recentRequests.value > recentRequestsBeforeReset
        }
        XCTAssertTrue(replacementSnapshotSettled)

        XCTAssertFalse(model.recentThreadFeeds.allFeed.pager.isRefreshingHead)
        XCTAssertEqual(
            model.recentThreadFeeds.allFeed.orderedThreadIds,
            ["thread-current"]
        )
        XCTAssertEqual(
            model.recentThreadFeeds.completeHead(
                interrupted,
                result: .page(
                    makeGaryxTestRecentRefreshBundle(threadIds: ["stale-thread"])
                )
            ).outcome,
            .abandonedStaleEpoch
        )
        XCTAssertEqual(
            model.recentThreadFeeds.allFeed.headPhase,
            .ready,
            "identity replacement must automatically execute and settle its recovery obligation"
        )
    }

    func testLegacyColdStartInstallsFavoritesScopeBeforeFastSnapshotCanRaceRecent() async throws {
        let suiteName = "GaryxColdStartScopeOrderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            "http://gateway.example.test/",
            forKey: GaryxMobileSettingsKeys.legacyGatewayURL
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recentStarted = expectation(description: "cold-start Recent request started")
        let recentGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                if recentRequests.increment() == 1 {
                    recentStarted.fulfill()
                    guard recentGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            recentGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = GaryxMobileModel(
            defaults: defaults,
            gatewayClientFactory: { configuration in
                GaryxGatewayClient(
                    configuration: configuration,
                    session: session,
                    retryPolicy: .disabled
                )
            }
        )
        homeFeedTestModels.append(model)
        let expectedScope = "http://gateway.example.test"
        XCTAssertEqual(model.gatewayURL, "http://gateway.example.test/")
        XCTAssertEqual(model.threadFavoritesState.gatewayScope, expectedScope)
        XCTAssertFalse(model.threadFavoritesState.gatewayScope.isEmpty)
        let runtimeEpochAtInitCompletion = model.threadFavoritesState.runtimeEpoch
        let pagerEpochAtInitCompletion = model.recentThreadFeeds.allFeed.pager.epoch

        model.connectionState = .ready(version: "test")
        await fulfillment(of: [recentStarted], timeout: 2)
        let fastFavoritesSnapshotSettled = await waitUntil {
            model.threadFavoritesState.storeIncarnationId
                == GaryxTask2783CapturedGeneration.beforeRotation.storeIncarnationId
        }
        XCTAssertTrue(fastFavoritesSnapshotSettled)

        XCTAssertEqual(model.threadFavoritesState.gatewayScope, expectedScope)
        XCTAssertEqual(model.threadFavoritesState.runtimeEpoch, runtimeEpochAtInitCompletion)
        XCTAssertEqual(
            model.recentThreadFeeds.allFeed.pager.epoch,
            pagerEpochAtInitCompletion,
            "the fast Favorites lane must not reset the already-scoped cold-start Recent ticket"
        )
        XCTAssertTrue(model.recentThreadFeeds.allFeed.pager.isRefreshingHead)

        recentGate.signal()
        let recentSettled = await waitUntil {
            model.selectedRecentFeedPresentation.isPrimed
                && !model.selectedRecentFeedPresentation.isRefreshingHead
        }
        XCTAssertTrue(recentSettled)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertFalse(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none
        )
    }

    func testColdStartHomeVisibilityFalseThenTrueRearmsModelReconcileLoop() async throws {
        let session = makeStubSession { request in
            try garyxStubResponse(request, statusCode: 503, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }
        let model = makeModel(session: session)
        XCTAssertFalse(GaryxHomeThreadListSnapshot.empty.isHomeVisible)

        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertTrue(
            model.homeThreadListStore.snapshot.isHomeVisible,
            "the model's init-time actor capture must project Home before a ready shell can mount"
        )

        model.connectionState = .ready(version: "test")
        let headSettled = await waitUntil {
            model.selectedRecentFeedPresentation.headFailure
        }
        XCTAssertTrue(headSettled)
        model.startBackgroundCommittedRunReconcileLoop()
        XCTAssertNotNil(model.backgroundCommittedRunReconcileTask)

        let restoredThread = makeThread(
            id: "thread::1000000150",
            title: "Synthetic restored thread"
        )
        _ = model.showSelectedThread(
            restoredThread,
            invalidatesPendingThreadOpen: false,
            source: .replace
        )
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertFalse(model.isHomeVisible)
        XCTAssertFalse(model.homeThreadListStore.snapshot.isHomeVisible)
        XCTAssertNil(
            model.backgroundCommittedRunReconcileTask,
            "the restored conversation must disarm the Home-only 15-second loop"
        )

        model.returnHome()
        // An attached production route container invokes this projection at
        // renderer-idle after the pop. The headless test drives that same
        // callback explicitly.
        model.applyCanonicalRouteProjection(model.productionRouteStore.path)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.isHomeVisible)
        XCTAssertTrue(
            model.homeThreadListStore.snapshot.isHomeVisible,
            "the same false -> true value used by .task(id:) must be published after the pop"
        )
        XCTAssertNotNil(
            model.backgroundCommittedRunReconcileTask,
            "the Home projection must rearm the model-side reconcile loop"
        )
        model.cancelBackgroundCommittedRunReconcileLoop()
    }

    func testColdStartRestoreSuccessPrimesBeforePushAndManualReturnRearmsHome() async throws {
        let restoredThreadId = "thread::1000000001"
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/threads/history"):
                return try garyxStubResponse(
                    request,
                    data: Data(
                        #"{"ok":true,"messages":[],"pending_user_inputs":[]}"#.utf8
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.persistLastOpenedThreadId(restoredThreadId)
        model.persistLastSessionRestorable(true)
        model.connectionState = .ready(version: "test")
        let feedPrimed = await waitUntil {
            model.selectedRecentFeedPresentation.isPrimed
        }
        XCTAssertTrue(feedPrimed)

        await model.restoreLastOpenedThreadIfNeeded()
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(
            model.selectedRecentFeedPresentation.isPrimed,
            "the real restore path refreshes Recent before it pushes an uncached thread"
        )
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none
        )
        XCTAssertFalse(model.isHomeVisible)
        XCTAssertFalse(model.homeThreadListStore.snapshot.isHomeVisible)

        model.returnHome()
        // The production route renderer publishes this committed pop at idle.
        model.applyCanonicalRouteProjection(model.productionRouteStore.path)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.isHomeVisible)
        XCTAssertTrue(model.homeThreadListStore.snapshot.isHomeVisible)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none,
            "returning Home reveals the page that the restore refresh already primed"
        )
        model.connectionState = .ready(version: "test")
        model.startBackgroundCommittedRunReconcileLoop()
        XCTAssertNotNil(model.backgroundCommittedRunReconcileTask)
        model.cancelBackgroundCommittedRunReconcileLoop()
    }

    func testColdStartRestoreFailureStillLoadsHomeFeed() async throws {
        let recentStarted = expectation(description: "cold Home head started")
        let recentGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let pointThreadReads = GaryxLockedCounter()
        let missingRestoreThreadId = "thread::missing-restore"
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                if recentRequests.increment() == 1 {
                    recentStarted.fulfill()
                    guard recentGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", let path) where path == "/api/threads/\(missingRestoreThreadId)":
                pointThreadReads.increment()
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            recentGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.persistLastOpenedThreadId(missingRestoreThreadId)
        model.persistLastSessionRestorable(true)
        model.connectionState = .ready(version: "test")
        await fulfillment(of: [recentStarted], timeout: 2)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertNotNil(model.selectedRecentFeedPresentation.headPhase.activeAttempt)

        await model.restoreLastOpenedThreadIfNeeded()
        XCTAssertEqual(pointThreadReads.value, 1)
        XCTAssertFalse(
            model.selectedRecentFeedPresentation.isPrimed,
            "the missing restore settles while the independent cold Home head is still in flight"
        )

        recentGate.signal()
        let feedPrimed = await waitUntil {
            model.selectedRecentFeedPresentation.headPhase == .ready
        }
        XCTAssertTrue(feedPrimed)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertEqual(pointThreadReads.value, 1)
        XCTAssertEqual(recentRequests.value, 2)
        XCTAssertTrue(model.isHomeVisible)
        XCTAssertTrue(model.homeThreadListStore.snapshot.isHomeVisible)
        XCTAssertTrue(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertFalse(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertEqual(model.allRecentThreadIds, ["thread::1000000001"])
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none,
            "a deleted restore target cannot prevent the independent Home owner from loading data"
        )
        model.connectionState = .ready(version: "test")
        model.startBackgroundCommittedRunReconcileLoop()
        XCTAssertNotNil(model.backgroundCommittedRunReconcileTask)
        model.cancelBackgroundCommittedRunReconcileLoop()
    }

    func testColdStartRecentFailureStaysHomeWithUnavailableNotSkeleton() async throws {
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                return try garyxStubResponse(
                    request,
                    statusCode: 503,
                    data: Data(#"{"error":"temporarily unavailable"}"#.utf8)
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.connectionState = .ready(version: "test")
        let feedFailed = await waitUntil {
            model.selectedRecentFeedPresentation.headFailure
        }
        XCTAssertTrue(feedFailed)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.isHomeVisible)
        XCTAssertTrue(model.homeThreadListStore.snapshot.isHomeVisible)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertTrue(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .unavailable,
            "a failed cold head must become an explicit retry surface, never idle loading"
        )
    }

    func testColdStartRestoreCancellationStaysHomeWithRefreshGateReleased() async throws {
        let recentStarted = expectation(description: "restore Recent request started")
        let recentGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                if recentRequests.increment() == 1 {
                    recentStarted.fulfill()
                    guard recentGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            recentGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.persistLastOpenedThreadId("thread::1000000001")
        model.persistLastSessionRestorable(true)
        model.connectionState = .ready(version: "test")
        let restore = Task { @MainActor in
            await model.restoreLastOpenedThreadIfNeeded()
        }
        await fulfillment(of: [recentStarted], timeout: 2)

        restore.cancel()
        recentGate.signal()
        await restore.value
        let ownerSettled = await waitUntil {
            model.selectedRecentFeedPresentation.isPrimed
                && !model.selectedRecentFeedPresentation.isRefreshingHead
        }
        XCTAssertTrue(ownerSettled)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.isHomeVisible)
        XCTAssertTrue(model.homeThreadListStore.snapshot.isHomeVisible)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertNotEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .loadingSkeleton(rowCount: 6),
            "Task cancellation must settle the owned request instead of leaving an idle skeleton"
        )
        model.connectionState = .ready(version: "test")
        model.startBackgroundCommittedRunReconcileLoop()
        XCTAssertNotNil(model.backgroundCommittedRunReconcileTask)
        model.cancelBackgroundCommittedRunReconcileLoop()
    }

    func testHomeFeedSelfConvergesWithoutThreadBackedBotRefreshSideEffect() async throws {
        let coldHeadStarted = expectation(description: "cold Home head started")
        let coldHeadGate = DispatchSemaphore(value: 0)
        let allRecentRequests = GaryxLockedCounter()
        let pointThreadReads = GaryxLockedCounter()
        let botThreadId = "thread::bot-cache-miss"
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let tasks = components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value
                if tasks == GaryxRecentThreadFilter.all.tasksQueryValue,
                   allRecentRequests.increment() == 1 {
                    coldHeadStarted.fulfill()
                    guard coldHeadGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", let path) where path == "/api/threads/\(botThreadId)":
                pointThreadReads.increment()
                return try garyxStubResponse(
                    request,
                    data: Data(
                        #"""
                        {
                          "thread_id":"thread::bot-cache-miss",
                          "label":"Cache-miss bot thread",
                          "thread_type":"chat",
                          "message_count":0
                        }
                        """#.utf8
                    )
                )
            case ("GET", "/api/threads/history"):
                return try garyxStubResponse(
                    request,
                    data: Data(
                        #"{"ok":true,"messages":[],"pending_user_inputs":[]}"#.utf8
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            coldHeadGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .loadingSkeleton(rowCount: 6)
        )
        model.connectionState = .ready(version: "test")
        await fulfillment(of: [coldHeadStarted], timeout: 2)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertNotNil(
            model.selectedRecentFeedPresentation.headPhase.activeAttempt,
            "the cache-miss bot path must begin while the cold Home head is genuinely in flight"
        )
        let group = GaryxMobileBotGroup(
            id: "test-channel::test-account",
            channel: "test-channel",
            channelDisplayName: "Test Channel",
            accountId: "test-account",
            title: "Test Bot",
            subtitle: "Test Channel Bot",
            agentId: nil,
            rootBehavior: "open_main",
            status: "idle",
            endpointCount: 1,
            boundEndpointCount: 1,
            workspaceDir: nil,
            mainThreadId: botThreadId,
            defaultOpenThreadId: botThreadId,
            endpoints: [],
            conversationNodes: [],
            iconDataUrl: nil
        )

        await model.openBotGroup(group)
        XCTAssertEqual(
            pointThreadReads.value,
            1,
            "the test must exercise the uncached point-read branch that used to own a hidden refresh"
        )
        XCTAssertEqual(
            allRecentRequests.value,
            1,
            "opening the bot must not start or queue another All refresh"
        )
        XCTAssertFalse(model.isHomeVisible)

        coldHeadGate.signal()
        let feedPrimed = await waitUntil {
            model.selectedRecentFeedPresentation.headPhase == .ready
                && model.allRecentThreadIds == ["thread::1000000001"]
        }
        XCTAssertTrue(feedPrimed)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(
            allRecentRequests.value,
            2,
            "the coordinator owns exactly one primary + verification cycle; the bot owns none"
        )

        model.returnHome()
        model.applyCanonicalRouteProjection(model.productionRouteStore.path)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.selectedRecentFeedPresentation.isPrimed)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none,
            "the gateway-scope owner converges while Home is hidden and remains ready on return"
        )
    }

    func testColdStartRecentIdentityInterruptionSchedulesAReplacementRefresh() async throws {
        let recentStarted = expectation(description: "cold-start recent request started")
        let recentGate = DispatchSemaphore(value: 0)
        let replacementGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let snapshotRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                let generation: GaryxTask2783CapturedGeneration =
                    snapshotRequests.increment() == 1 ? .beforeRotation : .afterRotation
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: generation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                switch recentRequests.increment() {
                case 1:
                    recentStarted.fulfill()
                    guard recentGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                case 2:
                    guard replacementGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                default:
                    break
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .afterRotation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            recentGate.signal()
            replacementGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        XCTAssertNil(
            model.threadFavoritesState.storeIncarnationId,
            "the reproduction must begin at the real cold-start identity state"
        )
        model.connectionState = .ready(version: "test")
        await fulfillment(of: [recentStarted], timeout: 2)
        let interruptedAttempt = try XCTUnwrap(
            model.recentThreadFeeds.allFeed.headPhase.activeAttempt
        )
        let favoritesEstablishedIdentity = await waitUntil {
            model.threadFavoritesState.storeIncarnationId
                == GaryxTask2783CapturedGeneration.beforeRotation.storeIncarnationId
        }
        XCTAssertTrue(favoritesEstablishedIdentity)

        recentGate.signal()
        let identityRecoverySettled = await waitUntil {
            model.threadFavoritesState.storeIncarnationId
                == GaryxTask2783CapturedGeneration.afterRotation.storeIncarnationId
                && model.threadFavoritesState.activeSnapshotTicket == nil
                && model.threadFavoritesSnapshotTask == nil
        }
        XCTAssertTrue(identityRecoverySettled)

        let replacementIssued = await waitUntil(timeout: 0.5) {
            guard let activeAttempt =
                model.recentThreadFeeds.allFeed.headPhase.activeAttempt else {
                return false
            }
            return activeAttempt != interruptedAttempt
        }
        let presentation = model.selectedRecentFeedPresentation
        let placeholder = model.homeThreadListStore.presentationSnapshot.recentPlaceholder
        XCTAssertTrue(
            replacementIssued,
            """
            REPRO: the cold-start recent response was identity-interrupted and \
            terminated with placeholder=\(placeholder), \
            isRefreshingHead=\(presentation.isRefreshingHead), \
            recentRequests=\(recentRequests.value). No replacement refresh was scheduled.
            """
        )
        if replacementIssued {
            replacementGate.signal()
            let replacementSettled = await waitUntil {
                model.recentThreadFeeds.allFeed.refreshCycle == 1
                    && model.recentThreadFeeds.allFeed.headPhase == .ready
            }
            XCTAssertTrue(replacementSettled)
        }
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.homeFeedSyncCoordinator.deactivateScope()
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
    }

    func testColdStartMatchingCapturedIdentitiesPrimeRecentWithoutInterruption() async throws {
        let allRecentRequests = GaryxLockedCounter()
        let nonTaskRecentRequests = GaryxLockedCounter()
        let snapshotRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                snapshotRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let tasks = components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value
                if tasks == GaryxRecentThreadFilter.all.tasksQueryValue {
                    allRecentRequests.increment()
                } else if tasks == GaryxRecentThreadFilter.nonTask.tasksQueryValue {
                    nonTaskRecentRequests.increment()
                } else {
                    XCTFail("cold-start Recent request must declare its feed filter")
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        XCTAssertNil(model.threadFavoritesState.storeIncarnationId)
        model.connectionState = .ready(version: "test")
        let settled = await waitUntil {
            model.threadFavoritesState.storeIncarnationId
                == GaryxTask2783CapturedGeneration.beforeRotation.storeIncarnationId
                && model.threadFavoritesState.activeSnapshotTicket == nil
                && model.threadFavoritesSnapshotTask == nil
                && model.selectedRecentFeedPresentation.isPrimed
        }
        XCTAssertTrue(settled)
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertEqual(model.recentThreadFeeds.allFeed.refreshCycle, 1)
        XCTAssertEqual(
            allRecentRequests.value,
            2,
            "one owned head cycle performs its primary read plus head verification"
        )
        XCTAssertEqual(nonTaskRecentRequests.value, 0)
        XCTAssertEqual(snapshotRequests.value, 1)
        XCTAssertFalse(model.selectedRecentFeedPresentation.isRefreshingHead)
        XCTAssertFalse(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none,
            "matching identities on both cold-start lanes must render the captured recent row"
        )
    }

    func testColdStartFavoritesIdentityResetSchedulesAReplacementRefresh() async throws {
        let snapshotStarted = expectation(description: "cold-start favorites snapshot started")
        let snapshotGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let snapshotRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783ThreadSummariesCaptureData(
                        generation: .beforeRotation
                    )
                )
            case ("GET", "/api/thread-favorites/snapshot"):
                if snapshotRequests.increment() == 1 {
                    snapshotStarted.fulfill()
                    guard snapshotGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783FavoritesSnapshotCaptureData(
                        generation: .afterRotation
                    )
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 29)
                )
            case ("GET", "/api/recent-threads"):
                recentRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxTask2783RecentThreadsCaptureData(
                        generation: .beforeRotation
                    )
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            snapshotGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        XCTAssertNil(
            model.threadFavoritesState.storeIncarnationId,
            "the reproduction must begin at the real cold-start identity state"
        )
        model.connectionState = .ready(version: "test")
        await fulfillment(of: [snapshotStarted], timeout: 2)
        let recentPrimed = await waitUntil {
            model.selectedRecentFeedPresentation.isPrimed
        }
        XCTAssertTrue(
            recentPrimed,
            "the recent lane must commit before the delayed favorites snapshot resets it"
        )
        let recentRequestsAtReset = recentRequests.value

        snapshotGate.signal()
        let identityRecoverySettled = await waitUntil {
            model.threadFavoritesState.storeIncarnationId
                == GaryxTask2783CapturedGeneration.afterRotation.storeIncarnationId
                && model.threadFavoritesState.activeSnapshotTicket == nil
                && model.threadFavoritesSnapshotTask == nil
        }
        XCTAssertTrue(identityRecoverySettled)
        await model.homeProjectionGateway.waitForIdleForTesting()

        let replacementIssued = await waitUntil(timeout: 0.5) {
            recentRequests.value > recentRequestsAtReset
        }
        let presentation = model.selectedRecentFeedPresentation
        let placeholder = model.homeThreadListStore.presentationSnapshot.recentPlaceholder
        XCTAssertTrue(
            replacementIssued,
            """
            REPRO: the delayed cold-start favorites snapshot reset the primed \
            recent feed and terminated with placeholder=\(placeholder), \
            isRefreshingHead=\(presentation.isRefreshingHead), \
            recentRequestsBeforeReset=\(recentRequestsAtReset), \
            recentRequestsAfterReset=\(recentRequests.value). \
            No replacement refresh was scheduled.
            """
        )
        model.homeFeedSyncCoordinator.deactivateScope()
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
    }

    func testCommittedArchiveFiltersALateFavoritesSnapshotEverywhere() async throws {
        let archivedId = "thread-archived-favorite"
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            guard request.httpMethod == "GET",
                  url.path == "/api/thread-favorites/snapshot" else {
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
            return try garyxStubResponse(
                request,
                data: try garyxFavoritesSnapshotData(
                    ids: [archivedId],
                    rows: [(id: archivedId, title: "Archived favorite")]
                )
            )
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.pendingThreadArchives.commitArchive(threadId: archivedId)
        model.recentThreadFeeds.select(.favorites)
        model.connectionState = .ready(version: "test")
        model.refreshThreadFavoritesSnapshot()
        let snapshotSettled = await waitUntil {
            model.threadFavoritesState.rawThreadIds == [archivedId]
        }
        XCTAssertTrue(snapshotSettled)

        XCTAssertTrue(model.favoriteThreads.isEmpty)
        XCTAssertFalse(model.visibleRecentThreadIds.contains(archivedId))
        XCTAssertFalse(
            model.residentRecentThreadSummaries.contains { $0.id == archivedId }
        )
    }

    func testGlobalSelectionPersistsAcrossModelAndGatewayReset() throws {
        let suiteName = "GaryxHomeThreadListRefreshCommitTests.persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("http://gateway-a.example.test", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = makeModel(defaults: defaults)
        model.gatewayURL = ""
        model.selectRecentThreadFilter(.nonTask)
        XCTAssertEqual(
            defaults.string(forKey: GaryxMobileSettingsKeys.recentThreadFilter),
            "nonTask"
        )
        XCTAssertNil(
            defaults.string(
                forKey: model.scopedSettingsKey(GaryxMobileSettingsKeys.recentThreadFilter)
            )
        )

        primeRecentFeed(model, ids: ["thread-task", "thread-chat"], filter: .all)
        primeRecentFeed(model, ids: ["thread-chat"], filter: .nonTask)
        let staleTicket = try issueRecentHead(model, filter: .nonTask)
        model.resetGatewayRuntimeState()

        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .nonTask)
        XCTAssertTrue(model.recentThreadFeeds.allFeed.orderedThreadIds.isEmpty)
        XCTAssertTrue(model.recentThreadFeeds.nonTaskFeed.orderedThreadIds.isEmpty)
        XCTAssertEqual(
            model.recentThreadFeeds.completeHead(
                staleTicket,
                result: .page(
                    makeGaryxTestRecentRefreshBundle(threadIds: ["stale-thread"])
                )
            ).outcome,
            .abandonedStaleEpoch
        )

        defaults.set("http://gateway-b.example.test", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        let relaunchedModel = makeModel(defaults: defaults)
        XCTAssertEqual(relaunchedModel.recentThreadFeeds.selectedFilter, .nonTask)
        XCTAssertEqual(
            try issueRecentHead(relaunchedModel).filter,
            .nonTask
        )
    }

    func testArchiveFailureKeepsListSnapshotStableUntilRemoteCommit() async throws {
        let archiveStarted = expectation(description: "archive request started")
        let archiveGate = DispatchSemaphore(value: 0)
        let archiveAttempts = GaryxLockedCounter()
        let favoritesSnapshots = GaryxLockedCounter()
        let allReplacements = GaryxLockedCounter()
        let chatsReplacements = GaryxLockedCounter()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                archiveAttempts.increment()
                if archiveAttempts.value == 1 {
                    archiveStarted.fulfill()
                    guard archiveGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"archive failed"}"#.utf8)
                )
            }
            if request.httpMethod == "GET", components.path == "/api/thread-favorites/snapshot" {
                favoritesSnapshots.increment()
            }
            if request.httpMethod == "GET", components.path == "/api/recent-threads" {
                switch components.queryItems?.first(where: { $0.name == "tasks" })?.value {
                case "include": allReplacements.increment()
                case "exclude": chatsReplacements.increment()
                default: break
                }
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            archiveGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        await settleInitialFavoritesSnapshot(model)
        favoritesSnapshots.reset()
        let archived = makeThread(id: "thread-archived", title: "Archived thread")
        let survivor = makeThread(id: "thread-survivor", title: "Surviving thread")
        model.seedThreadSummariesForTesting([archived, survivor])
        model.applyPinnedThreadIds([archived.id])
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .all)
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .nonTask)
        await model.homeProjectionGateway.waitForIdleForTesting()
        let initialSnapshot = model.homeThreadListStore.snapshot

        let archiveTask = Task { @MainActor in
            await model.archiveThreadRecord(threadId: archived.id)
        }
        await fulfillment(of: [archiveStarted], timeout: 2)

        // A refresh may finish while the remote operation is still pending.
        // It must keep the existing row visible until the archive commits.
        let concurrentRefresh = try issueRecentHead(model, filter: .all)
        XCTAssertEqual(
            model.recentThreadFeeds.completeHead(
                concurrentRefresh,
                result: .page(
                    makeGaryxTestRecentRefreshBundle(
                        threadIds: [archived.id, survivor.id]
                    )
                )
            ).outcome,
            .applied
        )
        model.commitRefreshedRecentThreadsPage(
            pinsPageThreadIds: [archived.id],
            fetchedThreads: [archived, survivor],
            previousThreadSummaries: [archived, survivor],
            previouslyRemoteBusyThreadIds: [],
            selectionIdForThisRefresh: nil,
            runtimeGeneration: model.gatewayRequestToken
        )
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertTrue(model.pendingThreadArchives.isRequestInFlight(threadId: archived.id))
        XCTAssertEqual(model.pinnedThreadIds, [archived.id])
        XCTAssertEqual(model.allRecentThreadIds, [archived.id, survivor.id])
        XCTAssertEqual(
            model.threadSummaryCache.summaries(for: [archived.id, survivor.id]),
            [archived, survivor]
        )
        XCTAssertEqual(
            model.homeThreadListStore.snapshot,
            initialSnapshot,
            "a remote archive that has not committed must not delete List rows"
        )
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .archiving)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.allRows.map(\.id),
            initialSnapshot.sections.allRows.map(\.id),
            "the optimistic exit keeps the physical List item alive until the remote commit"
        )

        archiveGate.signal()
        let archiveExhausted = await waitUntil {
            archiveAttempts.value == 6
        }
        XCTAssertTrue(archiveExhausted)
        await waitForAllRecentReplacementToQueue(model)
        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await archiveTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertFalse(model.pendingThreadArchives.contains(threadId: archived.id))
        XCTAssertEqual(model.pinnedThreadIds, [archived.id])
        XCTAssertEqual(model.allRecentThreadIds, [archived.id, survivor.id])
        XCTAssertEqual(
            model.threadSummaryCache.summaries(for: [archived.id, survivor.id]),
            [archived, survivor]
        )
        XCTAssertEqual(model.homeThreadListStore.snapshot.sections, initialSnapshot.sections)
        XCTAssertTrue(
            model.recentThreadFeeds.allFeed.headFailure,
            "an ambiguous archive must force a replacement even when reconstruction fails"
        )
        XCTAssertTrue(
            model.recentThreadFeeds.nonTaskFeed.headFailure,
            "the non-selected feed must be reconstructed too"
        )
        let reconstructionIssued = await waitUntil {
            favoritesSnapshots.value == 1
                && allReplacements.value == 1
                && chatsReplacements.value == 1
        }
        XCTAssertTrue(reconstructionIssued)
        XCTAssertEqual(favoritesSnapshots.value, 1)
        XCTAssertEqual(allReplacements.value, 1)
        XCTAssertEqual(chatsReplacements.value, 1)
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .stable)
        XCTAssertEqual(archiveAttempts.value, 6)
    }

    func testAmbiguousDeleteReconstructsFavoritesAndBothFeedsWithoutLocalDeletion() async throws {
        let deleteAttempts = GaryxLockedCounter()
        let favoritesSnapshots = GaryxLockedCounter()
        let allRequests = GaryxLockedCounter()
        let chatsRequests = GaryxLockedCounter()
        let visibleIds = ["thread-delete", "thread-survivor"]
        let recentData = try garyxRecentThreadsData(ids: visibleIds)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "DELETE",
               components.path.hasSuffix("/api/threads/thread-delete") {
                deleteAttempts.increment()
                throw URLError(.networkConnectionLost)
            }
            if request.httpMethod == "GET", components.path == "/api/thread-favorites/snapshot" {
                favoritesSnapshots.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            }
            if request.httpMethod == "GET", components.path == "/api/recent-threads" {
                switch components.queryItems?.first(where: { $0.name == "tasks" })?.value {
                case "include": allRequests.increment()
                case "exclude": chatsRequests.increment()
                default: break
                }
                return try garyxStubResponse(request, data: recentData)
            }
            if request.httpMethod == "GET", components.path == "/api/thread-pins" {
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        await settleInitialFavoritesSnapshot(model)
        favoritesSnapshots.reset()
        let deleted = makeThread(id: visibleIds[0], title: "Delete candidate")
        let survivor = makeThread(id: visibleIds[1], title: "Survivor")
        model.seedThreadSummariesForTesting([deleted, survivor])
        model.selectedThread = deleted
        primeRecentFeed(model, ids: visibleIds, filter: .all)
        primeRecentFeed(model, ids: visibleIds, filter: .nonTask)

        let deleteTask = Task { @MainActor in
            await model.deleteThread(deleted)
        }
        let deleteExhausted = await waitUntil {
            deleteAttempts.value == 6
        }
        XCTAssertTrue(deleteExhausted)
        await waitForAllRecentReplacementToQueue(model)
        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await deleteTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        let reconstructed = await waitUntil {
            favoritesSnapshots.value == 1
                && allRequests.value == 2
                && chatsRequests.value == 2
        }

        XCTAssertTrue(reconstructed)
        XCTAssertEqual(deleteAttempts.value, 6)
        XCTAssertEqual(favoritesSnapshots.value, 1)
        XCTAssertEqual(allRequests.value, 2, "primary + head verification")
        XCTAssertEqual(chatsRequests.value, 2, "primary + head verification")
        XCTAssertEqual(model.selectedThread?.id, deleted.id)
        XCTAssertNotNil(model.cachedThreadSummary(for: deleted.id))
        XCTAssertEqual(model.allRecentThreadIds, visibleIds)
        XCTAssertEqual(model.recentThreadFeeds.nonTaskFeed.orderedThreadIds, visibleIds)
        XCTAssertFalse(model.recentThreadFeeds.allFeed.forceReplacementPending)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.forceReplacementPending)
    }

    func testArchiveInProgressResendsSameIdentityThenCommitsUIOnce() async throws {
        let recorder = GaryxLockedLifecycleRequestRecorder()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                let attempt = try recorder.record(request)
                if attempt == 1 {
                    return try garyxStubResponse(
                        request,
                        statusCode: 409,
                        data: Data(
                            """
                            {
                              "kind": "garyx_api_error",
                              "operation": "thread_archive",
                              "code": "operation_in_progress",
                              "message": "still working"
                            }
                            """.utf8
                        )
                    )
                }
                return try garyxStubResponse(
                    request,
                    data: Data(
                        """
                        {
                          "operation_id": "\(recorder.values.last!.operationId)",
                          "outcome": "applied_changed",
                          "changed": true,
                          "archived": true,
                          "deleted": true,
                          "thread_id": "thread-archived",
                          "detached_endpoint_keys": []
                        }
                        """.utf8
                    )
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        let archived = makeThread(id: "thread-archived", title: "Archived thread")
        let survivor = makeThread(id: "thread-survivor", title: "Surviving thread")
        model.seedThreadSummariesForTesting([archived, survivor])
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .all)
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .nonTask)

        let archiveTask = Task { @MainActor in
            await model.archiveThreadRecord(threadId: archived.id)
        }
        let archiveCommitted = await waitUntil {
            model.pendingThreadArchives.isCommitted(threadId: archived.id)
        }
        XCTAssertTrue(archiveCommitted)
        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await archiveTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()

        XCTAssertEqual(recorder.values.count, 2)
        XCTAssertEqual(Set(recorder.values.map(\.operationId)).count, 1)
        XCTAssertEqual(
            Set(recorder.values.map(\.expectedStoreIncarnation)),
            ["11111111-1111-4111-8111-111111111111"]
        )
        XCTAssertEqual(model.allRecentThreadIds, [survivor.id])
        XCTAssertNil(model.cachedThreadSummary(for: archived.id))
        XCTAssertTrue(model.pendingThreadArchives.isCommitted(threadId: archived.id))
    }

    func testArchiveRejectedRestoresRowWithoutAmbiguousReconstruction() async throws {
        let attempts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                attempts.increment()
                return try garyxStubResponse(
                    request,
                    statusCode: 409,
                    data: Data(
                        """
                        {
                          "kind": "garyx_api_error",
                          "operation": "thread_archive",
                          "code": "rejected_conflict",
                          "message": "thread is active"
                        }
                        """.utf8
                    )
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        let archived = makeThread(id: "thread-archived", title: "Archived thread")
        model.seedThreadSummariesForTesting([archived])
        primeRecentFeed(model, ids: [archived.id], filter: .all)
        primeRecentFeed(model, ids: [archived.id], filter: .nonTask)

        await model.archiveThreadRecord(threadId: archived.id)

        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(model.allRecentThreadIds, [archived.id])
        XCTAssertEqual(model.cachedThreadSummary(for: archived.id), archived)
        XCTAssertFalse(model.pendingThreadArchives.contains(threadId: archived.id))
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .stable)
        XCTAssertEqual(model.lastError, "thread is active")
        XCTAssertFalse(model.recentThreadFeeds.allFeed.forceReplacementPending)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.forceReplacementPending)
        let transaction = model.threadMutationHubStore.value.transactions.values.first {
            $0.kind == .archive(threadId: archived.id)
        }
        XCTAssertEqual(transaction?.phase, .rolledBack(message: nil))
        XCTAssertTrue(
            model.threadMutationHubStore.value.residents.values.allSatisfy {
                $0.pending.isEmpty && $0.barrier == nil
            }
        )
    }

    func testArchiveWrongIncarnationReconstructsTheUnifiedThreadListDomain() async throws {
        let archiveAttempts = GaryxLockedCounter()
        let favoritesSnapshots = GaryxLockedCounter()
        let allRequests = GaryxLockedCounter()
        let chatsRequests = GaryxLockedCounter()
        let initialIncarnation = "11111111-1111-4111-8111-111111111111"
        let replacementIncarnation = "33333333-3333-4333-8333-333333333333"
        let visibleIds = ["thread-archive", "thread-survivor"]
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                archiveAttempts.increment()
                return try garyxStubResponse(
                    request,
                    statusCode: 409,
                    data: Data(
                        """
                        {
                          "kind": "garyx_api_error",
                          "operation": "thread_archive",
                          "code": "wrong_incarnation",
                          "message": "thread store identity changed",
                          "current_store_incarnation": "\(replacementIncarnation)"
                        }
                        """.utf8
                    )
                )
            }
            if request.httpMethod == "GET", components.path == "/api/thread-favorites/snapshot" {
                favoritesSnapshots.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(
                        ids: [],
                        storeIncarnationId: archiveAttempts.value == 0
                            ? initialIncarnation
                            : replacementIncarnation
                    )
                )
            }
            if request.httpMethod == "GET", components.path == "/api/recent-threads" {
                switch components.queryItems?.first(where: { $0.name == "tasks" })?.value {
                case "include": allRequests.increment()
                case "exclude": chatsRequests.increment()
                default: break
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(
                        ids: visibleIds,
                        storeIncarnationId: archiveAttempts.value == 0
                            ? initialIncarnation
                            : replacementIncarnation
                    )
                )
            }
            if request.httpMethod == "GET", components.path == "/api/thread-pins" {
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        let initialFavoritesTicket = try XCTUnwrap(
            model.threadFavoritesState.activeSnapshotTicket
        )
        let initialFavorites = model.threadFavoritesProvider.completeSnapshot(
            ticket: initialFavoritesTicket,
            snapshot: GaryxFavoriteSnapshot(
                page: GaryxFavoritePage(
                    storeIncarnationId: initialIncarnation,
                    serverBootId: "22222222-2222-4222-8222-222222222222",
                    revision: 1,
                    threadIds: []
                ),
                rows: []
            )
        )
        XCTAssertTrue(initialFavorites.accepted)
        model.runThreadFavoritesEffects(initialFavorites.effects)
        let archived = makeThread(id: visibleIds[0], title: "Archive candidate")
        let survivor = makeThread(id: visibleIds[1], title: "Survivor")
        model.seedThreadSummariesForTesting([archived, survivor])
        primeRecentFeed(model, ids: visibleIds, filter: .all)
        primeRecentFeed(model, ids: visibleIds, filter: .nonTask)

        let archiveTask = Task { @MainActor in
            await model.archiveThreadRecord(threadId: archived.id)
        }
        let archiveRejected = await waitUntil {
            archiveAttempts.value == 1
        }
        XCTAssertTrue(archiveRejected)
        await waitForAllRecentReplacementToQueue(model)
        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await archiveTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        let reconstructed = await waitUntil {
            favoritesSnapshots.value == 2
                && allRequests.value >= 1
                && chatsRequests.value >= 1
        }

        XCTAssertTrue(reconstructed)
        XCTAssertEqual(
            favoritesSnapshots.value,
            2,
            "the identity-changing snapshot owns one trailing snapshot in the replacement epoch"
        )
        XCTAssertEqual(archiveAttempts.value, 1)
        XCTAssertFalse(model.pendingThreadArchives.contains(threadId: archived.id))
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .stable)
        XCTAssertEqual(model.lastError, "thread store identity changed")
        XCTAssertEqual(model.recentThreadFeeds.allFeed.storeIncarnationId, replacementIncarnation)
        XCTAssertEqual(
            model.recentThreadFeeds.nonTaskFeed.storeIncarnationId,
            replacementIncarnation
        )
        XCTAssertFalse(model.recentThreadFeeds.allFeed.forceReplacementPending)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.forceReplacementPending)
    }

    func testArchiveCancellationRollsBackTheUnifiedMutationWithoutReconstruction() async throws {
        let archiveStarted = expectation(description: "archive retry lane started")
        let attempts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                attempts.increment()
                archiveStarted.fulfill()
                return try garyxStubResponse(
                    request,
                    statusCode: 409,
                    data: Data(
                        """
                        {
                          "kind": "garyx_api_error",
                          "operation": "thread_archive",
                          "code": "operation_in_progress",
                          "message": "still working"
                        }
                        """.utf8
                    )
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 5_000_000_000
        let archived = makeThread(id: "thread-cancelled", title: "Cancelled archive")
        model.seedThreadSummariesForTesting([archived])
        primeRecentFeed(model, ids: [archived.id], filter: .all)
        primeRecentFeed(model, ids: [archived.id], filter: .nonTask)

        let archiveTask = Task { @MainActor in
            await model.archiveThreadRecord(threadId: archived.id)
        }
        await fulfillment(of: [archiveStarted], timeout: 2)
        archiveTask.cancel()
        await archiveTask.value
        await model.homeProjectionGateway.waitForIdleForTesting()

        XCTAssertEqual(attempts.value, 1)
        XCTAssertFalse(model.pendingThreadArchives.contains(threadId: archived.id))
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .stable)
        XCTAssertFalse(model.recentThreadFeeds.allFeed.forceReplacementPending)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.forceReplacementPending)
        let transaction = model.threadMutationHubStore.value.transactions.values.first {
            $0.kind == .archive(threadId: archived.id)
        }
        XCTAssertEqual(transaction?.phase, .rolledBack(message: nil))
        XCTAssertNil(model.lastError)
    }

    func testDeleteRejectedRollsBackTheUnifiedMutationHub() async throws {
        let attempts = GaryxLockedCounter()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "DELETE", components.path.hasSuffix("/api/threads/thread-delete") {
                attempts.increment()
                return try garyxStubResponse(
                    request,
                    statusCode: 409,
                    data: Data(
                        """
                        {
                          "kind": "garyx_api_error",
                          "operation": "thread_delete",
                          "code": "rejected_conflict",
                          "message": "thread is still bound"
                        }
                        """.utf8
                    )
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        let deleted = makeThread(id: "thread-delete", title: "Delete candidate")
        model.seedThreadSummariesForTesting([deleted])
        model.selectedThread = deleted
        primeRecentFeed(model, ids: [deleted.id], filter: .all)
        primeRecentFeed(model, ids: [deleted.id], filter: .nonTask)

        await model.deleteThread(deleted)

        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(model.selectedThread?.id, deleted.id)
        XCTAssertNotNil(model.cachedThreadSummary(for: deleted.id))
        XCTAssertEqual(model.lastError, "thread is still bound")
        let transaction = model.threadMutationHubStore.value.transactions.values.first {
            $0.kind == .archive(threadId: deleted.id)
        }
        XCTAssertEqual(transaction?.phase, .rolledBack(message: "thread is still bound"))
        XCTAssertTrue(
            model.threadMutationHubStore.value.residents.values.allSatisfy {
                $0.pending.isEmpty && $0.barrier == nil
            }
        )
    }

    func testDeleteOperationIdConflictReconstructsBeforeClearingTheBarrier() async throws {
        let deleteAttempts = GaryxLockedCounter()
        let favoritesSnapshots = GaryxLockedCounter()
        let allRequests = GaryxLockedCounter()
        let chatsRequests = GaryxLockedCounter()
        let visibleIds = ["thread-delete", "thread-survivor"]
        let recentData = try garyxRecentThreadsData(ids: visibleIds)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "DELETE", components.path.hasSuffix("/api/threads/thread-delete") {
                deleteAttempts.increment()
                return try garyxStubResponse(
                    request,
                    statusCode: 409,
                    data: Data(
                        """
                        {
                          "kind": "garyx_api_error",
                          "operation": "thread_delete",
                          "code": "operation_id_conflict",
                          "message": "operation id was reused"
                        }
                        """.utf8
                    )
                )
            }
            if request.httpMethod == "GET", components.path == "/api/thread-favorites/snapshot" {
                favoritesSnapshots.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            }
            if request.httpMethod == "GET", components.path == "/api/recent-threads" {
                switch components.queryItems?.first(where: { $0.name == "tasks" })?.value {
                case "include": allRequests.increment()
                case "exclude": chatsRequests.increment()
                default: break
                }
                return try garyxStubResponse(request, data: recentData)
            }
            if request.httpMethod == "GET", components.path == "/api/thread-pins" {
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.lifecycleRetryDelayOverrideNanoseconds = 0
        await settleInitialFavoritesSnapshot(model)
        favoritesSnapshots.reset()
        let deleted = makeThread(id: visibleIds[0], title: "Delete candidate")
        let survivor = makeThread(id: visibleIds[1], title: "Survivor")
        model.seedThreadSummariesForTesting([deleted, survivor])
        model.selectedThread = deleted
        primeRecentFeed(model, ids: visibleIds, filter: .all)
        primeRecentFeed(model, ids: visibleIds, filter: .nonTask)

        let deleteTask = Task { @MainActor in
            await model.deleteThread(deleted)
        }
        let deleteRejected = await waitUntil {
            deleteAttempts.value == 1
        }
        XCTAssertTrue(deleteRejected)
        await waitForAllRecentReplacementToQueue(model)
        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await deleteTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        let reconstructed = await waitUntil {
            favoritesSnapshots.value == 1
                && allRequests.value == 2
                && chatsRequests.value == 2
        }

        XCTAssertTrue(reconstructed)
        XCTAssertEqual(deleteAttempts.value, 1)
        XCTAssertEqual(model.selectedThread?.id, deleted.id)
        XCTAssertNotNil(model.cachedThreadSummary(for: deleted.id))
        XCTAssertEqual(model.lastError, "operation id was reused")
        let transaction = model.threadMutationHubStore.value.transactions.values.first {
            $0.kind == .archive(threadId: deleted.id)
        }
        XCTAssertEqual(transaction?.phase, .ambiguous)
        XCTAssertTrue(
            model.threadMutationHubStore.value.residents.values.allSatisfy {
                $0.pending.isEmpty && $0.barrier == nil
            }
        )
        XCTAssertFalse(model.recentThreadFeeds.allFeed.forceReplacementPending)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.forceReplacementPending)
    }

    func testArchiveSuccessMakesOneListCommitAndInvalidatesEarlierRefresh() async throws {
        let archiveStarted = expectation(description: "archive request started")
        let archiveGate = DispatchSemaphore(value: 0)
        let recorder = GaryxLockedLifecycleRequestRecorder()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "POST", components.path.hasSuffix("/archive") {
                _ = try recorder.record(request)
                archiveStarted.fulfill()
                guard archiveGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(
                        """
                        {
                          "operation_id": "\(recorder.values.last!.operationId)",
                          "outcome": "applied_changed",
                          "changed": true,
                          "archived": true,
                          "deleted": true,
                          "thread_id": "thread-archived",
                          "detached_endpoint_keys": []
                        }
                        """.utf8
                    )
                )
            }
            // Post-archive catalog/list refreshes are irrelevant to this
            // interleaving and fail immediately so the real App flow can exit.
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            archiveGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let archived = makeThread(id: "thread-archived", title: "Archived thread")
        let survivor = makeThread(id: "thread-survivor", title: "Surviving thread")
        model.seedThreadSummariesForTesting([archived, survivor])
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .all)
        primeRecentFeed(model, ids: [archived.id, survivor.id], filter: .nonTask)
        let allMutationSequence = model.recentThreadFeeds.allFeed.pager.localMutationSequence
        let chatsMutationSequence = model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence

        let archiveTask = Task { @MainActor in
            await model.archiveThreadRecord(threadId: archived.id)
        }
        await fulfillment(of: [archiveStarted], timeout: 2)
        XCTAssertTrue(model.pendingThreadArchives.isRequestInFlight(threadId: archived.id))
        XCTAssertEqual(model.allRecentThreadIds, [archived.id, survivor.id])
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .archiving)

        // The request is pending but has not changed the List. Its single
        // success commit must invalidate this pre-commit server page.
        let staleTicket = try issueRecentHead(model, filter: .all)
        archiveGate.signal()
        let archiveCommitted = await waitUntil {
            model.pendingThreadArchives.isCommitted(threadId: archived.id)
        }
        XCTAssertTrue(
            archiveCommitted,
            "the real archive success path must commit its stale-response tombstone"
        )
        XCTAssertEqual(
            model.recentThreadFeeds.allFeed.pager.localMutationSequence,
            allMutationSequence + 1
        )
        XCTAssertEqual(
            model.recentThreadFeeds.nonTaskFeed.pager.localMutationSequence,
            chatsMutationSequence + 1
        )

        let completion = model.recentThreadFeeds.completeHead(
            staleTicket,
            result: .page(
                makeGaryxTestRecentRefreshBundle(
                    threadIds: [archived.id, survivor.id]
                )
            )
        )
        XCTAssertEqual(completion.outcome, .abandonedLocalMutation)
        model.homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
        XCTAssertEqual(model.allRecentThreadIds, [survivor.id])
        XCTAssertNil(model.cachedThreadSummary(for: archived.id))

        model.homeFeedSyncCoordinator.updateConnection(.ready(version: "test"))
        await archiveTask.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: archived.id), .stable)
        XCTAssertFalse(
            model.homeThreadListStore.presentationSnapshot.sections.allRows.contains { $0.id == archived.id }
        )
    }

    func testPinMovesPresentationSynchronouslyThenSettlesOnceAfterRemoteCommit() async throws {
        let pinStarted = expectation(description: "pin request started")
        let pinGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "PUT", components.path.hasSuffix("/api/thread-pins/thread-moved") {
                pinStarted.fulfill()
                guard pinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"thread_ids":["thread-moved"]}"#.utf8)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            pinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let first = makeThread(id: "thread-first", title: "First thread")
        let moved = makeThread(id: "thread-moved", title: "Moved thread")
        let last = makeThread(id: "thread-last", title: "Last thread")
        model.seedThreadSummariesForTesting([first, moved, last])
        primeRecentFeed(model, ids: [first.id, moved.id, last.id], filter: .all)
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertTrue(model.homeThreadListStore.snapshot.sections.pinned.isEmpty)

        model.togglePinnedThread(moved.id)

        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [moved.id],
            "the row must move in the same synchronous gesture turn, before the actor or network responds"
        )
        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: moved.id), .pinning)
        await fulfillment(of: [pinStarted], timeout: 2)

        pinGate.signal()
        let pinSettled = await waitUntil {
            model.homeThreadListStore.rowMotion(threadId: moved.id) == .stable
                && model.homeThreadListStore.snapshot.sections.pinned.map(\.id) == [moved.id]
        }
        XCTAssertTrue(pinSettled)
        XCTAssertEqual(model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id), [moved.id])
    }

    func testUnpinReturnsToFeedRelativePositionWithoutCountingPinnedRows() async throws {
        let unpinStarted = expectation(description: "unpin request started")
        let unpinGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "DELETE", components.path.hasSuffix("/api/thread-pins/thread-two") {
                unpinStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"thread_ids":["thread-zero","thread-one"]}"#.utf8)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let zero = makeThread(id: "thread-zero", title: "Pinned zero")
        let one = makeThread(id: "thread-one", title: "Pinned one")
        let two = makeThread(id: "thread-two", title: "Pinned two")
        let recentA = makeThread(id: "thread-recent-a", title: "Recent A")
        let recentB = makeThread(id: "thread-recent-b", title: "Recent B")
        model.seedThreadSummariesForTesting([zero, one, two, recentA, recentB])
        model.applyPinnedThreadIds([zero.id, one.id, two.id])
        primeRecentFeed(
            model,
            ids: [zero.id, one.id, two.id, recentA.id, recentB.id],
            filter: .all
        )
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertEqual(
            model.homeThreadListStore.snapshot.sections.recent.map(\.id),
            [recentA.id, recentB.id]
        )

        model.unpinThread(two.id)

        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [zero.id, one.id]
        )
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.recent.map(\.id),
            [two.id, recentA.id, recentB.id],
            "the raw feed's earlier pinned ids must not push the unpinned row down"
        )
        await fulfillment(of: [unpinStarted], timeout: 2)

        unpinGate.signal()
        let settled = await waitUntil {
            model.homeThreadListStore.rowMotion(threadId: two.id) == .stable
                && model.homeThreadListStore.snapshot.sections.recent.map(\.id)
                    == [two.id, recentA.id, recentB.id]
        }
        XCTAssertTrue(settled)
    }

    func testConcurrentPinFailuresRollBackOnlyTheirOwnThreads() async throws {
        let firstStarted = expectation(description: "first pin request started")
        let secondStarted = expectation(description: "second pin request started")
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "PUT", components.path.hasSuffix("/api/thread-pins/thread-first") {
                firstStarted.fulfill()
                guard firstGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"first pin failed"}"#.utf8)
                )
            }
            if request.httpMethod == "PUT", components.path.hasSuffix("/api/thread-pins/thread-second") {
                secondStarted.fulfill()
                guard secondGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"second pin failed"}"#.utf8)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstGate.signal()
            secondGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let first = makeThread(id: "thread-first", title: "First pin")
        let second = makeThread(id: "thread-second", title: "Second pin")
        model.seedThreadSummariesForTesting([first, second])
        primeRecentFeed(model, ids: [first.id, second.id], filter: .all)
        await model.homeProjectionGateway.waitForIdleForTesting()

        model.togglePinnedThread(first.id)
        model.togglePinnedThread(second.id)

        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [second.id, first.id]
        )
        await fulfillment(of: [firstStarted, secondStarted], timeout: 2)

        firstGate.signal()
        let firstRolledBack = await waitUntil {
            model.homeThreadListStore.rowMotion(threadId: first.id) == .stable
                && model.homeThreadListStore.rowMotion(threadId: second.id) == .pinning
                && model.pinnedThreadIds == [second.id]
        }
        XCTAssertTrue(firstRolledBack)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [second.id],
            "a failed first request must leave the second optimistic pin in place"
        )

        secondGate.signal()
        let secondRolledBack = await waitUntil {
            model.homeThreadListStore.rowMotion(threadId: second.id) == .stable
                && model.pinnedThreadIds.isEmpty
        }
        XCTAssertTrue(secondRolledBack)
        XCTAssertTrue(model.homeThreadListStore.presentationSnapshot.sections.pinned.isEmpty)
    }

    func testConcurrentPinAndUnpinFailuresRestoreOriginalPinnedOrder() async throws {
        let pinStarted = expectation(description: "pin request started")
        let unpinStarted = expectation(description: "unpin request started")
        let pinGate = DispatchSemaphore(value: 0)
        let unpinGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "PUT", components.path.hasSuffix("/api/thread-pins/thread-new") {
                pinStarted.fulfill()
                guard pinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, statusCode: 500, data: Data())
            }
            if request.httpMethod == "DELETE", components.path.hasSuffix("/api/thread-pins/thread-one") {
                unpinStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, statusCode: 500, data: Data())
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            pinGate.signal()
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let zero = makeThread(id: "thread-zero", title: "Pinned zero")
        let one = makeThread(id: "thread-one", title: "Pinned one")
        let two = makeThread(id: "thread-two", title: "Pinned two")
        let new = makeThread(id: "thread-new", title: "New pin")
        model.seedThreadSummariesForTesting([zero, one, two, new])
        model.applyPinnedThreadIds([zero.id, one.id, two.id])
        primeRecentFeed(model, ids: [zero.id, one.id, two.id, new.id], filter: .all)
        await model.homeProjectionGateway.waitForIdleForTesting()

        model.togglePinnedThread(new.id)
        model.unpinThread(one.id)

        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [new.id, zero.id, two.id]
        )
        await fulfillment(of: [pinStarted, unpinStarted], timeout: 2)

        pinGate.signal()
        let pinRolledBack = await waitUntil {
            model.pinnedThreadIds == [zero.id, two.id]
                && model.homeThreadListStore.rowMotion(threadId: one.id) == .pinning
        }
        XCTAssertTrue(pinRolledBack)

        unpinGate.signal()
        let unpinRolledBack = await waitUntil {
            model.pinnedThreadIds == [zero.id, one.id, two.id]
                && model.homeThreadListStore.rowMotion(threadId: one.id) == .stable
        }
        XCTAssertTrue(unpinRolledBack)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [zero.id, one.id, two.id],
            "The failed unpin must restore between its stable neighbors after the earlier pin fails."
        )
    }

    func testUnpinOutsideSelectedFilterCollapsesThenRestoresInPlaceOnFailure() async throws {
        let unpinStarted = expectation(description: "unpin request started")
        let unpinGate = DispatchSemaphore(value: 0)
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            if request.httpMethod == "DELETE", components.path.hasSuffix("/api/thread-pins/thread-pinned") {
                unpinStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"unpin failed"}"#.utf8)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let pinned = makeThread(id: "thread-pinned", title: "Pinned task")
        let chat = makeThread(id: "thread-chat", title: "Visible chat")
        model.seedThreadSummariesForTesting([pinned, chat])
        model.applyPinnedThreadIds([pinned.id])
        primeRecentFeed(model, ids: [pinned.id, chat.id], filter: .all)
        primeRecentFeed(model, ids: [chat.id], filter: .nonTask)
        model.recentThreadFeeds.select(.nonTask)
        await model.homeProjectionGateway.waitForIdleForTesting()

        model.unpinThread(pinned.id)

        XCTAssertEqual(model.homeThreadListStore.rowMotion(threadId: pinned.id), .leavingFilteredList)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [pinned.id],
            "the source item remains physically present while its content collapses"
        )
        await fulfillment(of: [unpinStarted], timeout: 2)

        unpinGate.signal()
        let unpinRolledBack = await waitUntil {
            model.homeThreadListStore.rowMotion(threadId: pinned.id) == .stable
                && model.pinnedThreadIds == [pinned.id]
        }
        XCTAssertTrue(unpinRolledBack)
        XCTAssertEqual(model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id), [pinned.id])
        XCTAssertEqual(model.homeThreadListStore.presentationSnapshot.sections.recent.map(\.id), [chat.id])
    }

    func testPinnedReorderLow200AfterHighGetResendsWithAcceptedFloor() async throws {
        try await assertPinnedReorderBelowFloorCompletion(statusCode: 200)
    }

    func testPinnedReorderLow409AfterHighGetResendsWithAcceptedFloor() async throws {
        try await assertPinnedReorderBelowFloorCompletion(statusCode: 409)
    }

    func testPinnedReorderPlainConflictMergesMembershipAndResendsOnce() async throws {
        let puts = GaryxLockedPinsPutRecorder()
        let conflict = try garyxPinsPageData(
            ids: ["thread-c", "thread-a", "thread-b"],
            revision: 11
        )
        let settledPage = try garyxPinsPageData(
            ids: ["thread-c", "thread-b", "thread-a"],
            revision: 12
        )
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                return try garyxStubResponse(
                    request,
                    statusCode: index == 1 ? 409 : 200,
                    data: index == 1 ? conflict : settledPage
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()

        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            puts.values,
            [
                GaryxRecordedPinsPut(
                    threadIds: ["thread-b", "thread-a"],
                    expectedRevision: 10
                ),
                GaryxRecordedPinsPut(
                    threadIds: ["thread-c", "thread-b", "thread-a"],
                    expectedRevision: 11
                ),
            ]
        )
        XCTAssertEqual(model.pinnedThreadIds, ["thread-c", "thread-b", "thread-a"])
    }

    func testPinsGetIssuedAfterDropCannotRevertAfterHigherAck() async throws {
        let putStarted = expectation(description: "reorder started")
        let staleGetStarted = expectation(description: "stale pins get started")
        let putGate = DispatchSemaphore(value: 0)
        let getGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let pinsGets = GaryxLockedCounter()
        let recent = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let ack = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 12)
        let stale = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 11)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                _ = try puts.record(request)
                putStarted.fulfill()
                guard putGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, data: ack)
            }
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recent)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                if pinsGets.increment() == 1 {
                    staleGetStarted.fulfill()
                    guard getGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(request, data: stale)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            putGate.signal()
            getGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [putStarted], timeout: 2)

        model.connectionState = .ready(version: "test")
        let refresh = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .backgroundLoop)
        }
        await fulfillment(of: [staleGetStarted], timeout: 2)
        putGate.signal()
        let ackSettled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
                && model.homeThreadListStore.pinnedOrderState.highestObservedRevision == 12
        }
        XCTAssertTrue(ackSettled)
        getGate.signal()
        await refresh.value

        XCTAssertEqual(model.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.highestObservedRevision, 12)
        XCTAssertEqual(puts.values.count, 1)
    }

    private func assertPinnedReorderBelowFloorCompletion(
        statusCode: Int
    ) async throws {
        let firstPutStarted = expectation(description: "first reorder started")
        let secondPutStarted = expectation(description: "floor-token reorder started")
        let firstPutGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let recentData = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let highPage = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 12)
        let lowPageIds = statusCode == 200
            ? ["thread-b", "thread-a"]
            : ["thread-a", "thread-b"]
        let lowPage = try garyxPinsPageData(ids: lowPageIds, revision: 11)
        let settledPage = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 13)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recentData)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: highPage)
            }
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    firstPutStarted.fulfill()
                    guard firstPutGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                    return try garyxStubResponse(
                        request,
                        statusCode: statusCode,
                        data: lowPage
                    )
                }
                secondPutStarted.fulfill()
                return try garyxStubResponse(request, data: settledPage)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstPutGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [firstPutStarted], timeout: 2)

        model.connectionState = .ready(version: "test")
        await model.requestHomeFeedRefresh(source: .backgroundLoop)
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.highestObservedRevision, 12)
        XCTAssertEqual(puts.values.count, 1, "the high page cannot dispatch beside the old flight")

        firstPutGate.signal()
        await fulfillment(of: [secondPutStarted], timeout: 2)
        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            puts.values,
            [
                GaryxRecordedPinsPut(threadIds: ["thread-b", "thread-a"], expectedRevision: 10),
                GaryxRecordedPinsPut(threadIds: ["thread-b", "thread-a"], expectedRevision: 12),
            ]
        )
    }

    func testPinnedOrderGatewaySwitchDropsLateOldResponseAndAcceptsRevisionZero() async throws {
        let oldPutStarted = expectation(description: "old gateway reorder started")
        let oldResponseReleased = expectation(description: "old gateway response released")
        let oldPutGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let newRecent = try garyxRecentThreadsData(ids: ["thread-new"])
        let newPins = try garyxPinsPageData(ids: ["thread-new"], revision: 0)
        let oldAck = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 101)
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "PUT", url.path == "/api/thread-pins" {
                _ = try puts.record(request)
                oldPutStarted.fulfill()
                guard oldPutGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                oldResponseReleased.fulfill()
                return try garyxStubResponse(request, data: oldAck)
            }
            if url.host == "new-gateway.example.test",
               request.httpMethod == "GET",
               url.path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: newRecent)
            }
            if url.host == "new-gateway.example.test",
               request.httpMethod == "GET",
               url.path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: newPins)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            oldPutGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 100)
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [oldPutStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://new-gateway.example.test"
        model.loadGatewayScopedUserState(fallbackToLegacy: false)
        model.connectionState = .ready(version: "test")
        await model.requestHomeFeedRefresh(source: .backgroundLoop)

        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.highestObservedRevision, 0)
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.presentedOrder, ["thread-new"])
        XCTAssertNil(model.homeThreadListStore.pinnedOrderState.outbox)

        oldPutGate.signal()
        await fulfillment(of: [oldResponseReleased], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(puts.values.count, 1, "a late old-identity page must not retry")
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.highestObservedRevision, 0)
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.presentedOrder, ["thread-new"])
    }

    func testHighRevisionRemotePinIsShownAfterLowRevisionLocalUnpinAck() async throws {
        let unpinStarted = expectation(description: "local unpin started")
        let unpinGate = DispatchSemaphore(value: 0)
        let collectionPuts = GaryxLockedCounter()
        let recent = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let highRemotePin = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 12)
        let lowLocalAck = try garyxPinsPageData(ids: ["thread-a"], revision: 11)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "DELETE", path == "/api/thread-pins/thread-b" {
                unpinStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, data: lowLocalAck)
            }
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recent)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: highRemotePin)
            }
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                collectionPuts.increment()
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.unpinThread("thread-b")
        await fulfillment(of: [unpinStarted], timeout: 2)

        model.connectionState = .ready(version: "test")
        await model.requestHomeFeedRefresh(source: .backgroundLoop)
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.presentedOrder, ["thread-a"])
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderState.highestObservedRevision, 12)

        unpinGate.signal()
        let resolved = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.liveMembershipIntentCount == 0
                && model.pinnedThreadIds == ["thread-b", "thread-a"]
        }
        XCTAssertTrue(resolved)
        await model.homeProjectionGateway.waitForIdleForTesting()
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            ["thread-b", "thread-a"]
        )
        XCTAssertEqual(collectionPuts.value, 0)
    }

    func testReorderWaitsForRealUnpinThenSendsOneReducedFreshFloorPut() async throws {
        let firstPutStarted = expectation(description: "initial reorder started")
        let unpinStarted = expectation(description: "unpin started")
        let followupPutStarted = expectation(description: "reduced reorder started")
        let firstPutGate = DispatchSemaphore(value: 0)
        let unpinGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let conflict = try garyxPinsPageData(
            ids: ["thread-a", "thread-b", "thread-c"],
            revision: 11
        )
        let unpinAck = try garyxPinsPageData(ids: ["thread-b", "thread-c"], revision: 12)
        let settle = try garyxPinsPageData(ids: ["thread-c", "thread-b"], revision: 13)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    firstPutStarted.fulfill()
                    guard firstPutGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                    return try garyxStubResponse(request, statusCode: 409, data: conflict)
                }
                followupPutStarted.fulfill()
                return try garyxStubResponse(request, data: settle)
            }
            if request.httpMethod == "DELETE", path == "/api/thread-pins/thread-a" {
                unpinStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, data: unpinAck)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstPutGate.signal()
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(
            model,
            ids: ["thread-a", "thread-b", "thread-c"],
            revision: 10
        )
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-c", "thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [firstPutStarted], timeout: 2)
        model.unpinThread("thread-a")
        await fulfillment(of: [unpinStarted], timeout: 2)

        firstPutGate.signal()
        let parked = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.pendingSync == .waitingForMembership
        }
        XCTAssertTrue(parked)
        XCTAssertEqual(puts.values.count, 1)

        unpinGate.signal()
        await fulfillment(of: [followupPutStarted], timeout: 2)
        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            puts.values,
            [
                GaryxRecordedPinsPut(
                    threadIds: ["thread-c", "thread-b", "thread-a"],
                    expectedRevision: 10
                ),
                GaryxRecordedPinsPut(
                    threadIds: ["thread-c", "thread-b"],
                    expectedRevision: 12
                ),
            ]
        )
    }

    func testFullUnpinClearsRealOutboxWithoutSendingEmptyCollectionPut() async throws {
        let firstPutStarted = expectation(description: "initial reorder started")
        let unpinsStarted = expectation(description: "both unpins started")
        unpinsStarted.expectedFulfillmentCount = 2
        let firstPutGate = DispatchSemaphore(value: 0)
        let unpinAGate = DispatchSemaphore(value: 0)
        let unpinBGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let conflict = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 11)
        let unpinA = try garyxPinsPageData(ids: ["thread-b"], revision: 12)
        let unpinB = try garyxPinsPageData(ids: [], revision: 13)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                _ = try puts.record(request)
                firstPutStarted.fulfill()
                guard firstPutGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, statusCode: 409, data: conflict)
            }
            if request.httpMethod == "DELETE", path == "/api/thread-pins/thread-a" {
                unpinsStarted.fulfill()
                guard unpinAGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, data: unpinA)
            }
            if request.httpMethod == "DELETE", path == "/api/thread-pins/thread-b" {
                unpinsStarted.fulfill()
                guard unpinBGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(request, data: unpinB)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstPutGate.signal()
            unpinAGate.signal()
            unpinBGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [firstPutStarted], timeout: 2)
        model.unpinThread("thread-a")
        model.unpinThread("thread-b")
        await fulfillment(of: [unpinsStarted], timeout: 2)

        firstPutGate.signal()
        let parked = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.pendingSync == .waitingForMembership
                && model.homeThreadListStore.pinnedOrderState.desiredOrder.isEmpty
        }
        XCTAssertTrue(parked)

        unpinAGate.signal()
        let oneIntent = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.liveMembershipIntentCount == 1
        }
        XCTAssertTrue(oneIntent)
        unpinBGate.signal()
        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
                && model.homeThreadListStore.pinnedOrderState.presentedOrder.isEmpty
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(puts.values.count, 1)
        XCTAssertTrue(puts.values.allSatisfy { !$0.threadIds.isEmpty })
    }

    func testConflictFullUnpinFailureRollbackDispatchesOneRecoveryPutAndDoesNotFlip() async throws {
        let firstPutStarted = expectation(description: "initial reorder started")
        let unpinsStarted = expectation(description: "both failing unpins started")
        unpinsStarted.expectedFulfillmentCount = 2
        let recoveryPutStarted = expectation(description: "rollback recovery reorder started")
        let firstPutGate = DispatchSemaphore(value: 0)
        let unpinGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let conflict = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 11)
        let recovered = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 12)
        let recent = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    firstPutStarted.fulfill()
                    guard firstPutGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                    return try garyxStubResponse(request, statusCode: 409, data: conflict)
                }
                recoveryPutStarted.fulfill()
                return try garyxStubResponse(request, data: recovered)
            }
            if request.httpMethod == "DELETE",
               path == "/api/thread-pins/thread-a" || path == "/api/thread-pins/thread-b" {
                unpinsStarted.fulfill()
                guard unpinGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"synthetic unpin failure"}"#.utf8)
                )
            }
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recent)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: recovered)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstPutGate.signal()
            unpinGate.signal()
            unpinGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [firstPutStarted], timeout: 2)
        model.unpinThread("thread-a")
        model.unpinThread("thread-b")
        await fulfillment(of: [unpinsStarted], timeout: 2)

        firstPutGate.signal()
        let parked = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.pendingSync == .waitingForMembership
                && model.homeThreadListStore.pinnedOrderState.desiredOrder.isEmpty
        }
        XCTAssertTrue(parked)
        unpinGate.signal()
        unpinGate.signal()

        await fulfillment(of: [recoveryPutStarted], timeout: 2)
        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
                && model.pinnedThreadIds == ["thread-b", "thread-a"]
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(puts.values.count, 2)
        XCTAssertEqual(
            puts.values.last,
            GaryxRecordedPinsPut(
                threadIds: ["thread-b", "thread-a"],
                expectedRevision: 11
            )
        )

        model.connectionState = .ready(version: "test")
        await model.requestHomeFeedRefresh(source: .backgroundLoop)
        XCTAssertEqual(model.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertEqual(puts.values.count, 2)
    }

    func testPinResponseBeforeOldReorderCoalescesUntilFlightThenFollowsUpOnce() async throws {
        let firstPutStarted = expectation(description: "old reorder started")
        let pinCompleted = expectation(description: "pin response returned")
        let followupPutStarted = expectation(description: "coalesced reorder started")
        let firstPutGate = DispatchSemaphore(value: 0)
        let puts = GaryxLockedPinsPutRecorder()
        let pinPage = try garyxPinsPageData(
            ids: ["thread-c", "thread-a", "thread-b"],
            revision: 12
        )
        let lowOldAck = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 11)
        let settled = try garyxPinsPageData(
            ids: ["thread-c", "thread-b", "thread-a"],
            revision: 13
        )
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    firstPutStarted.fulfill()
                    guard firstPutGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                    return try garyxStubResponse(request, data: lowOldAck)
                }
                followupPutStarted.fulfill()
                return try garyxStubResponse(request, data: settled)
            }
            if request.httpMethod == "PUT", path == "/api/thread-pins/thread-c" {
                pinCompleted.fulfill()
                return try garyxStubResponse(request, data: pinPage)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            firstPutGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let ids = ["thread-a", "thread-b", "thread-c"]
        model.seedThreadSummariesForTesting(ids.map { makeThread(id: $0, title: $0) })
        model.applyPinnedThreadIds(["thread-a", "thread-b"], revision: 10)
        primeRecentFeed(model, ids: ids, filter: .all)
        await model.homeProjectionGateway.waitForIdleForTesting()
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()
        await fulfillment(of: [firstPutStarted], timeout: 2)

        model.togglePinnedThread("thread-c")
        await fulfillment(of: [pinCompleted], timeout: 2)
        let coalesced = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.liveMembershipIntentCount == 0
                && model.homeThreadListStore.pinnedOrderState.pendingSync == .coalescedBehindFlight
        }
        XCTAssertTrue(coalesced)
        XCTAssertEqual(puts.values.count, 1)

        firstPutGate.signal()
        await fulfillment(of: [followupPutStarted], timeout: 2)
        let didSettle = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(didSettle)
        XCTAssertEqual(
            puts.values,
            [
                GaryxRecordedPinsPut(
                    threadIds: ["thread-b", "thread-a"],
                    expectedRevision: 10
                ),
                GaryxRecordedPinsPut(
                    threadIds: ["thread-c", "thread-b", "thread-a"],
                    expectedRevision: 12
                ),
            ]
        )
    }

    func testPermanentReorderFailurePausesUntilExplicitRefreshWithoutRollback() async throws {
        let puts = GaryxLockedPinsPutRecorder()
        let recent = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let oldPage = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 10)
        let settledPage = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 11)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    return try garyxStubResponse(
                        request,
                        statusCode: 405,
                        data: Data(#"{"error":"synthetic unsupported route"}"#.utf8)
                    )
                }
                return try garyxStubResponse(request, data: settledPage)
            }
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recent)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: oldPage)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        primePinnedModel(model, ids: ["thread-a", "thread-b"], revision: 10)
        model.beginPinnedOrderDrag()
        model.previewPinnedOrderDrag(["thread-b", "thread-a"])
        model.acceptPinnedOrderDrop()

        let paused = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.pendingSync
                == .pausedPermanent(statusCode: 405)
        }
        XCTAssertTrue(paused)
        XCTAssertEqual(model.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertEqual(model.homeThreadListStore.pinnedOrderSyncStatusLabel, "Sync pending")

        model.connectionState = .ready(version: "test")
        await model.requestHomeFeedRefresh(source: .backgroundLoop)
        XCTAssertEqual(puts.values.count, 1)
        XCTAssertEqual(model.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertNotNil(model.homeThreadListStore.pinnedOrderState.outbox)

        await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        let settled = await waitUntil {
            model.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(puts.values.count, 2)
        XCTAssertEqual(model.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertNil(model.homeThreadListStore.pinnedOrderSyncStatusLabel)
    }

    func testDurablePinnedOrderOutboxRestoresAcrossModelRestartAndDrains() async throws {
        let suiteName = "GaryxPinnedOrderOutboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("http://gateway.example.test", forKey: GaryxMobileSettingsKeys.gatewayUrl)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let puts = GaryxLockedPinsPutRecorder()
        let recent = try garyxRecentThreadsData(ids: ["thread-a", "thread-b"])
        let oldPage = try garyxPinsPageData(ids: ["thread-a", "thread-b"], revision: 10)
        let settledPage = try garyxPinsPageData(ids: ["thread-b", "thread-a"], revision: 11)
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if request.httpMethod == "PUT", path == "/api/thread-pins" {
                let index = try puts.record(request)
                if index == 1 {
                    return try garyxStubResponse(
                        request,
                        statusCode: 405,
                        data: Data(#"{"error":"synthetic old gateway"}"#.utf8)
                    )
                }
                return try garyxStubResponse(request, data: settledPage)
            }
            if request.httpMethod == "GET", path == "/api/recent-threads" {
                return try garyxStubResponse(request, data: recent)
            }
            if request.httpMethod == "GET", path == "/api/thread-pins" {
                return try garyxStubResponse(request, data: oldPage)
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let firstModel = makeModel(defaults: defaults, session: session)
        primePinnedModel(firstModel, ids: ["thread-a", "thread-b"], revision: 10)
        firstModel.beginPinnedOrderDrag()
        firstModel.previewPinnedOrderDrag(["thread-b", "thread-a"])
        firstModel.acceptPinnedOrderDrop()
        let paused = await waitUntil {
            firstModel.homeThreadListStore.pinnedOrderState.pendingSync
                == .pausedPermanent(statusCode: 405)
        }
        XCTAssertTrue(paused)
        XCTAssertNotNil(
            firstModel.pinnedOrderOutboxStore.loadPinnedOrderOutbox(
                gatewayIdentity: firstModel.currentGatewayScopeId
            )
        )

        let restoredModel = makeModel(defaults: defaults, session: session)
        XCTAssertEqual(restoredModel.pinnedThreadIds, ["thread-b", "thread-a"])
        XCTAssertEqual(restoredModel.homeThreadListStore.pinnedOrderState.pendingSync, .ready)
        restoredModel.connectionState = .ready(version: "test")
        await restoredModel.requestHomeFeedRefresh(source: .backgroundLoop)
        let settled = await waitUntil {
            restoredModel.homeThreadListStore.pinnedOrderState.outbox == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(puts.values.count, 2)
        XCTAssertNil(
            restoredModel.pinnedOrderOutboxStore.loadPinnedOrderOutbox(
                gatewayIdentity: restoredModel.currentGatewayScopeId
            )
        )
    }

    func testScopeOwnerTrailsAutomaticHeadImmediatelyAfterLoadMore() async throws {
        let loadMoreStarted = expectation(description: "load-more transport started")
        let loadMoreGate = DispatchSemaphore(value: 0)
        let loadMoreRequests = GaryxLockedCounter()
        let headRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            switch (request.httpMethod, components.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let cursor = components.queryItems?.first { $0.name == "cursor" }?.value
                if cursor != nil {
                    if loadMoreRequests.increment() == 1 {
                        loadMoreStarted.fulfill()
                        guard loadMoreGate.wait(timeout: .now() + 5) == .success else {
                            throw GaryxRefreshStubError.timedOut
                        }
                    }
                    return try garyxStubResponse(
                        request,
                        data: try garyxRecentThreadsData(ids: ["thread-tail"])
                    )
                }
                headRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-head", "thread-seed"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            loadMoreGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        let initial = try issueRecentHead(model, filter: .all)
        XCTAssertEqual(
            model.recentThreadFeeds.completeHead(
                initial,
                result: .page(
                    makeGaryxTestRecentRefreshBundle(
                        threadIds: ["thread-seed"],
                        hasMore: true,
                        nextCursor: "cursor-1"
                    )
                )
            ).outcome,
            .applied
        )
        let coordinator = installHomeFeedCoordinator(model)

        let loadMore = Task { @MainActor in
            await model.loadMoreThreads(trigger: .nearTail)
        }
        await fulfillment(of: [loadMoreStarted], timeout: 2)
        coordinator.updateConnection(.ready(version: "test"))
        let trailed = await waitUntil {
            model.recentThreadFeeds.allFeed.pendingHeadRequest != nil
        }
        XCTAssertTrue(trailed)
        XCTAssertEqual(headRequests.value, 0)

        loadMoreGate.signal()
        await loadMore.value
        let converged = await waitUntil {
            headRequests.value == 2
                && model.recentThreadFeeds.allFeed.headPhase == .ready
        }
        XCTAssertTrue(converged)
        XCTAssertEqual(
            model.recentThreadFeeds.allFeed.orderedThreadIds,
            ["thread-head", "thread-seed", "thread-tail"]
        )
        await stopHomeFeedTestModel(model)
    }

    func testUserPullDuringActiveHeadLeavesOneTrailingReplacement() async throws {
        let firstHeadStarted = expectation(description: "first head transport started")
        let firstHeadGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                if recentRequests.increment() == 1 {
                    firstHeadStarted.fulfill()
                    guard firstHeadGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-refreshed"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            firstHeadGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        primeRecentFeed(model, ids: ["thread-cached"], filter: .all)
        let coordinator = installHomeFeedCoordinator(model)
        coordinator.updateConnection(.ready(version: "test"))
        await fulfillment(of: [firstHeadStarted], timeout: 2)

        let pull = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        let trailed = await waitUntil {
            model.recentThreadFeeds.allFeed.pendingHeadRequest?.source
                == .userPullToRefresh
        }
        XCTAssertTrue(trailed)

        firstHeadGate.signal()
        await pull.value
        await coordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(recentRequests.value, 4, "two complete head cycles must run")
        XCTAssertEqual(model.recentThreadFeeds.allFeed.headPhase, .ready)
        XCTAssertEqual(model.allRecentThreadIds, ["thread-refreshed"])
        await stopHomeFeedTestModel(model)
    }

    func testBackgroundSuspendsIntentAndVisibilityPulseCannotKillOwner() async throws {
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                recentRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-foreground"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        primeRecentFeed(model, ids: ["thread-cached"], filter: .all)
        let coordinator = installHomeFeedCoordinator(model)
        coordinator.updateSceneBackgrounded(true)
        coordinator.updateHomeVisibility(false)
        coordinator.updateHomeVisibility(true)
        coordinator.updateConnection(.ready(version: "test"))

        let intent = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userAction)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recentRequests.value, 0)
        XCTAssertEqual(model.allRecentThreadIds, ["thread-cached"])
        XCTAssertEqual(model.selectedRecentFeedPresentation.headPhase, .ready)
        XCTAssertTrue(coordinator === model.homeFeedSyncCoordinator)

        coordinator.updateSceneBackgrounded(false)
        await intent.value
        await coordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(recentRequests.value, 2)
        XCTAssertEqual(
            model.allRecentThreadIds,
            ["thread-foreground", "thread-cached"]
        )
        XCTAssertTrue(coordinator === model.homeFeedSyncCoordinator)
        await stopHomeFeedTestModel(model)
    }

    func testShortAndLongBackgroundClassesEachRefreshOnForeground() async throws {
        let selectedRecentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let tasks = components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value
                if tasks == GaryxRecentThreadFilter.all.tasksQueryValue {
                    let requestIndex = selectedRecentRequests.increment()
                    return try garyxStubResponse(
                        request,
                        data: try garyxRecentThreadsData(
                            ids: ["thread-foreground-\(requestIndex)"]
                        )
                    )
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-chat"])
                )
            default:
                // Foreground synchronization has independent auxiliary
                // domains. Their failures do not own the Home feed contract.
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.connectionState = .ready(version: "test")
        let initialSettled = await waitUntil {
            model.recentThreadFeeds.allFeed.headPhase == .ready
                && selectedRecentRequests.value > 0
        }
        XCTAssertTrue(initialSettled)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        selectedRecentRequests.reset()

        // Elapsed background duration is deliberately not an input to the
        // foreground contract. Exercise both duration classes as two separate
        // background -> active occurrences without a wall-clock sleep.
        model.handleScenePhase(.background)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(selectedRecentRequests.value, 0)
        model.handleScenePhase(.active)
        let shortSettled = await waitUntil {
            selectedRecentRequests.value > 0
                && model.recentThreadFeeds.allFeed.headPhase == .ready
        }
        XCTAssertTrue(shortSettled)
        let requestsAfterShortBackground = selectedRecentRequests.value
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none
        )

        model.handleScenePhase(.background)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            selectedRecentRequests.value,
            requestsAfterShortBackground
        )
        model.handleScenePhase(.active)
        let longSettled = await waitUntil {
            selectedRecentRequests.value > requestsAfterShortBackground
                && model.recentThreadFeeds.allFeed.headPhase == .ready
        }
        XCTAssertTrue(longSettled)
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .none
        )
        await model.sceneRefreshTask?.value
        await stopHomeFeedTestModel(model)
    }

    func testImmediateDebtDowngradesToRetryAndDropsQueuedTransportAtDeadline() async throws {
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if path == "/api/thread-favorites/snapshot" {
                return try garyxStubResponse(
                    request,
                    statusCode: 500,
                    data: Data(#"{"error":"offline"}"#.utf8)
                )
            }
            return try garyxStubResponse(request, statusCode: 400, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        let coordinator = installHomeFeedCoordinator(
            model,
            initialEffects: [
                .requestHead(
                    GaryxRecentHeadRequest(
                        filter: .all,
                        source: .userAction,
                        forceReplacement: true
                    )
                ),
            ],
            immediateDemandTimeout: 0.05
        )

        let downgraded = await waitUntil {
            model.recentThreadFeeds.allFeed.headPhase
                == .primingOwed(.supersededByReset, .userAction)
        }
        XCTAssertTrue(downgraded)
        XCTAssertTrue(model.selectedRecentFeedPresentation.headFailure)
        XCTAssertFalse(model.selectedRecentFeedPresentation.showsInitialSkeleton)
        XCTAssertFalse(coordinator.hasQueuedHeadRequestForTesting(.all))
        XCTAssertNil(model.recentThreadFeeds.allFeed.headPhase.activeAttempt)
        await stopHomeFeedTestModel(model)
    }

    func testThreeSecondColdHeadKeepsAttemptProofUntilRowsArrive() async throws {
        let headStarted = expectation(description: "slow head transport started")
        let headGate = DispatchSemaphore(value: 0)
        let recentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                if recentRequests.increment() == 1 {
                    headStarted.fulfill()
                    guard headGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-slow"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            headGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await settleInitialFavoritesSnapshot(model)
        let coordinator = installHomeFeedCoordinator(
            model,
            initialEffects: [
                .requestHead(
                    GaryxRecentHeadRequest(
                        filter: .all,
                        source: .userAction,
                        forceReplacement: true
                    )
                ),
            ]
        )
        coordinator.updateConnection(.ready(version: "test"))
        await fulfillment(of: [headStarted], timeout: 2)
        XCTAssertNotNil(model.recentThreadFeeds.allFeed.headPhase.activeAttempt)
        XCTAssertTrue(model.selectedRecentFeedPresentation.showsInitialSkeleton)

        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertNotNil(model.recentThreadFeeds.allFeed.headPhase.activeAttempt)
        XCTAssertTrue(model.selectedRecentFeedPresentation.showsInitialSkeleton)

        headGate.signal()
        let converged = await waitUntil {
            model.recentThreadFeeds.allFeed.headPhase == .ready
                && model.allRecentThreadIds == ["thread-slow"]
        }
        XCTAssertTrue(converged)
        XCTAssertEqual(recentRequests.value, 2)
        await stopHomeFeedTestModel(model)
    }

    func testGatewayScopeRebuildCancelsOldOwnerAndRejectsLateRows() async throws {
        let suiteName = "GaryxHomeFeedScopeOwnerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            "http://gateway-a.example.test",
            forKey: GaryxMobileSettingsKeys.gatewayUrl
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldHeadStarted = expectation(description: "gateway A head started")
        let oldHeadGate = DispatchSemaphore(value: 0)
        let oldRequests = GaryxLockedCounter()
        let newRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads") where url.host == "gateway-a.example.test":
                if oldRequests.increment() == 1 {
                    oldHeadStarted.fulfill()
                    guard oldHeadGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-from-a"])
                )
            case ("GET", "/api/recent-threads") where url.host == "gateway-b.example.test":
                newRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-from-b"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            oldHeadGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(defaults: defaults, session: session)
        await settleInitialFavoritesSnapshot(model)
        let oldCoordinator = model.homeFeedSyncCoordinator
        model.connectionState = .ready(version: "gateway-a")
        await fulfillment(of: [oldHeadStarted], timeout: 2)

        model.resetGatewayRuntimeState()
        model.gatewayURL = "http://gateway-b.example.test"
        model.loadGatewayScopedUserState(fallbackToLegacy: false)
        let newCoordinator = model.homeFeedSyncCoordinator
        XCTAssertFalse(oldCoordinator === newCoordinator)
        model.connectionState = .ready(version: "gateway-b")
        let newScopeConverged = await waitUntil {
            model.allRecentThreadIds == ["thread-from-b"]
                && model.recentThreadFeeds.allFeed.headPhase == .ready
        }
        XCTAssertTrue(newScopeConverged)
        XCTAssertEqual(newRequests.value, 2)

        oldHeadGate.signal()
        await oldCoordinator.waitForTransportIdleForTesting()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.allRecentThreadIds, ["thread-from-b"])
        XCTAssertTrue(newCoordinator === model.homeFeedSyncCoordinator)
        await stopHomeFeedTestModel(model)
    }

    func testScopeOwnerQueuesFavoritesUntilConnectionIsReady() async throws {
        let favoritesRequests = GaryxLockedCounter()
        let selectedRecentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let path = url.path
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                favoritesRequests.increment()
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                if components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value == GaryxRecentThreadFilter.all.tasksQueryValue {
                    selectedRecentRequests.increment()
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: [])
                )
            default:
                return try garyxStubResponse(request, statusCode: 400, data: Data())
            }
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(favoritesRequests.value, 0)
        XCTAssertEqual(selectedRecentRequests.value, 0)
        XCTAssertNotNil(model.threadFavoritesState.headPhase.activeAttempt)
        XCTAssertNotNil(model.threadFavoritesState.activeSnapshotTicket)

        // Reproduce root-task / scene-phase connect overlap plus the stale
        // post-ready guard. The prime obligation belongs to the scope owner,
        // so these caller transitions can only wake it, never consume it.
        model.connectionState = .checking
        model.connectionState = .ready(version: "first")
        model.connectionState = .checking
        model.connectionState = .ready(version: "second")
        let settled = await waitUntil {
            favoritesRequests.value == 1
                && model.threadFavoritesState.headPhase == .ready
                && selectedRecentRequests.value == 2
                && model.recentThreadFeeds.allFeed.headPhase == .ready
        }
        XCTAssertTrue(settled)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(favoritesRequests.value, 1)
        XCTAssertEqual(model.recentThreadFeeds.allFeed.refreshCycle, 1)
        XCTAssertEqual(selectedRecentRequests.value, 2)
        await stopHomeFeedTestModel(model)
    }

    func testStalePostReadyConnectGuardCannotConsumeHomePrime() async throws {
        let agentRefreshStarted = expectation(
            description: "connect reached its post-ready agent refresh"
        )
        let agentRefreshGate = DispatchSemaphore(value: 0)
        let agentRefreshRequests = GaryxLockedCounter()
        let allRecentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/status"):
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"ok","version":"test"}"#.utf8)
                )
            case ("GET", "/api/chat/health"):
                return try garyxStubResponse(
                    request,
                    data: Data(
                        #"{"status":"ok","channel":"api","bridge_ready":true}"#.utf8
                    )
                )
            case ("GET", "/api/custom-agents"):
                if agentRefreshRequests.increment() == 1 {
                    agentRefreshStarted.fulfill()
                    guard agentRefreshGate.wait(timeout: .now() + 5) == .success else {
                        throw GaryxRefreshStubError.timedOut
                    }
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"agents":[]}"#.utf8)
                )
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                if components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value == GaryxRecentThreadFilter.all.tasksQueryValue {
                    allRecentRequests.increment()
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-ready-owner"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            agentRefreshGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        let connect = Task { @MainActor in
            await model.connectAndRefresh()
        }
        await fulfillment(of: [agentRefreshStarted], timeout: 2)
        guard case .ready = model.connectionState else {
            return XCTFail("connect must publish ready before the stale post-ready guard")
        }

        let successorRequestId = UUID()
        model.connectRefreshRequestId = successorRequestId
        agentRefreshGate.signal()
        await connect.value

        let converged = await waitUntil {
            model.recentThreadFeeds.allFeed.headPhase == .ready
                && model.allRecentThreadIds == ["thread-ready-owner"]
        }
        XCTAssertTrue(converged)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(allRecentRequests.value, 2)
        XCTAssertEqual(
            model.connectRefreshRequestId,
            successorRequestId,
            "the stale connect returned at its guard instead of clearing its successor"
        )
        await stopHomeFeedTestModel(model)
    }

    func testForegroundDuringColdConnectLeavesPrimeOwnedUntilReady() async throws {
        let statusStarted = expectation(description: "cold connect status started")
        let statusGate = DispatchSemaphore(value: 0)
        let allRecentRequests = GaryxLockedCounter()
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/status"):
                statusStarted.fulfill()
                guard statusGate.wait(timeout: .now() + 5) == .success else {
                    throw GaryxRefreshStubError.timedOut
                }
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"status":"ok","version":"test"}"#.utf8)
                )
            case ("GET", "/api/chat/health"):
                return try garyxStubResponse(
                    request,
                    data: Data(
                        #"{"status":"ok","channel":"api","bridge_ready":true}"#.utf8
                    )
                )
            case ("GET", "/api/custom-agents"):
                return try garyxStubResponse(
                    request,
                    data: Data(#"{"agents":[]}"#.utf8)
                )
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                let components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                if components.queryItems?
                    .first(where: { $0.name == "tasks" })?
                    .value == GaryxRecentThreadFilter.all.tasksQueryValue {
                    allRecentRequests.increment()
                }
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["thread-after-connect"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
        defer {
            statusGate.signal()
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        model.handleScenePhase(.background)
        let connect = Task { @MainActor in
            await model.connectAndRefresh()
        }
        await fulfillment(of: [statusStarted], timeout: 2)
        guard case .checking = model.connectionState else {
            return XCTFail("the foreground collision must occur during the cold connect")
        }
        let ownerAtCollision = model.homeFeedSyncCoordinator

        model.handleScenePhase(.active)
        XCTAssertTrue(ownerAtCollision === model.homeFeedSyncCoordinator)
        XCTAssertEqual(allRecentRequests.value, 0)
        XCTAssertTrue(
            model.recentThreadFeeds.allFeed.headPhase.owesImmediateRequest,
            "foregrounding while connect is checking must preserve the initial obligation"
        )

        statusGate.signal()
        await connect.value
        await model.sceneRefreshTask?.value
        let converged = await waitUntil {
            model.recentThreadFeeds.allFeed.headPhase == .ready
                && model.allRecentThreadIds == ["thread-after-connect"]
        }
        XCTAssertTrue(converged)
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
        XCTAssertEqual(allRecentRequests.value, 2)
        XCTAssertTrue(ownerAtCollision === model.homeFeedSyncCoordinator)
        await stopHomeFeedTestModel(model)
    }

    func testUnreachableGatewayPresentsSetupInsteadOfHomeSkeleton() async throws {
        let session = makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            if path == "/api/status" {
                throw URLError(.cannotConnectToHost)
            }
            return try garyxStubResponse(request, statusCode: 404, data: Data())
        }
        defer {
            GaryxRecentThreadsURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        let model = makeModel(session: session)
        await model.connectAndRefresh()

        guard case .failed = model.connectionState else {
            return XCTFail("an unreachable gateway must settle connectionState to failed")
        }
        XCTAssertEqual(
            model.homeObservationStore.rootSurface,
            .gatewaySetup,
            "the root branch must hide the unprimed Home feed behind connection setup"
        )
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.recentPlaceholder,
            .loadingSkeleton(rowCount: 6),
            "the Home reducer may retain its owned bootstrap debt, but it is not the visible root"
        )
        await stopHomeFeedTestModel(model)
    }

    private func primePinnedModel(
        _ model: GaryxMobileModel,
        ids: [String],
        revision: Int64
    ) {
        model.seedThreadSummariesForTesting(ids.map { makeThread(id: $0, title: $0) })
        model.applyPinnedThreadIds(ids, revision: revision)
        primeRecentFeed(model, ids: ids, filter: .all)
    }

    private func installHomeFeedCoordinator(
        _ model: GaryxMobileModel,
        initialEffects: [GaryxRecentFeedEffect] = [],
        immediateDemandTimeout: TimeInterval = GaryxMobileModel.homeFeedImmediateDemandTimeout,
        now: @escaping () -> Date = Date.init,
        automaticallyEvaluatesWakeSignals: Bool = true
    ) -> GaryxHomeFeedSyncCoordinator {
        model.homeFeedSyncCoordinator.deactivateScope()
        let coordinator = GaryxHomeFeedSyncCoordinator(
            initialEffects: initialEffects,
            immediateDemandTimeout: immediateDemandTimeout,
            scopeToken: model.gatewayRequestToken,
            now: now,
            automaticallyEvaluatesWakeSignals: automaticallyEvaluatesWakeSignals
        )
        model.homeFeedSyncCoordinator = coordinator
        coordinator.attach(model)
        coordinator.updateHomeVisibility(model.isHomeVisible)
        return coordinator
    }

    private func prepareParkedChatsRequest(on model: GaryxMobileModel) {
        if let ticket = model.threadFavoritesState.activeSnapshotTicket {
            model.runThreadFavoritesEffects(
                model.threadFavoritesProvider.failSnapshot(ticket: ticket)
            )
        }
        primeRecentFeed(model, ids: ["all-cached"], filter: .all)
        primeRecentFeed(model, ids: ["chat-cached"], filter: .nonTask)
        model.recentThreadFeeds.parkPendingHeadRequestForTesting(
            GaryxRecentHeadRequest(
                filter: .nonTask,
                source: .backgroundLoop,
                homeProjectionCommit: .none
            )
        )
        XCTAssertEqual(model.recentThreadFeeds.selectedFilter, .all)
        XCTAssertEqual(
            model.recentThreadFeeds.nonTaskFeed.pendingHeadRequest?.source,
            .backgroundLoop
        )
        XCTAssertEqual(model.recentThreadFeeds.nonTaskFeed.headPhase, .ready)
        XCTAssertFalse(model.recentThreadFeeds.nonTaskFeed.pager.isLoadingMore)
    }

    private func makeIntentPassthroughStubSession() -> URLSession {
        makeStubSession { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod, path) {
            case ("GET", "/api/thread-summaries"):
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            case ("GET", "/api/thread-favorites/snapshot"):
                return try garyxStubResponse(
                    request,
                    data: try garyxFavoritesSnapshotData(ids: [])
                )
            case ("GET", "/api/thread-pins"):
                return try garyxStubResponse(
                    request,
                    data: try garyxPinsPageData(ids: [], revision: 1)
                )
            case ("GET", "/api/recent-threads"):
                return try garyxStubResponse(
                    request,
                    data: try garyxRecentThreadsData(ids: ["chat-refreshed"])
                )
            default:
                return try garyxStubResponse(request, statusCode: 404, data: Data())
            }
        }
    }

    private func yieldUntil(
        maxYields: Int = 1_000,
        condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func stopHomeFeedTestModel(_ model: GaryxMobileModel) async {
        let favoritesTask = model.threadFavoritesSnapshotTask
        let connectBackgroundTask = model.connectRefreshBackgroundTask
        model.homeFeedSyncCoordinator.deactivateScope()
        model.cancelThreadFavoritesSnapshotTransport()
        connectBackgroundTask?.cancel()
        favoritesTask?.cancel()
        await connectBackgroundTask?.value
        await favoritesTask?.value
        await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        session: URLSession? = nil
    ) -> GaryxMobileModel {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "GaryxHomeThreadListRefreshCommitTests.\(UUID().uuidString)"
            resolvedDefaults = UserDefaults(suiteName: suiteName)!
            resolvedDefaults.removePersistentDomain(forName: suiteName)
        }
        if resolvedDefaults.string(forKey: GaryxMobileSettingsKeys.gatewayUrl) == nil {
            resolvedDefaults.set(
                "http://gateway.example.test",
                forKey: GaryxMobileSettingsKeys.gatewayUrl
            )
        }
        let clientFactory = session.map { session in
            { (configuration: GaryxGatewayConfiguration) in
                GaryxGatewayClient(
                    configuration: configuration,
                    session: session,
                    retryPolicy: .disabled
                )
            }
        }
        let model = GaryxMobileModel(
            defaults: resolvedDefaults,
            gatewayClientFactory: clientFactory
        )
        homeFeedTestModels.append(model)
        return model
    }

    private func settleInitialFavoritesSnapshot(_ model: GaryxMobileModel) async {
        if let ticket = model.threadFavoritesState.activeSnapshotTicket {
            model.runThreadFavoritesEffects(
                model.threadFavoritesProvider.failSnapshot(ticket: ticket)
            )
        }
        while let task = model.threadFavoritesSnapshotTask {
            await task.value
        }
        let settled = await waitUntil {
            let phase = model.threadFavoritesState.headPhase
            return phase.activeAttempt == nil && !phase.owesImmediateRequest
        }
        XCTAssertTrue(settled, "the scope-owned Favorites bootstrap must reach a terminal phase")
    }

    private func waitForAllRecentReplacementToQueue(_ model: GaryxMobileModel) async {
        let queued = await waitUntil {
            model.homeFeedSyncCoordinator.hasQueuedHeadRequestForTesting(.all)
                && model.homeFeedSyncCoordinator.hasQueuedHeadRequestForTesting(.nonTask)
        }
        XCTAssertTrue(queued, "both Recent replacement effects must reach the scope owner")
    }

    private func makeThread(id: String, title: String) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: title,
            createdAt: nil,
            updatedAt: "2026-07-07T02:00:00Z",
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

    private func primeRecentFeed(
        _ model: GaryxMobileModel,
        ids: [String],
        filter: GaryxRecentThreadFilter
    ) {
        let ticket = try! issueRecentHead(model, filter: filter)
        _ = model.recentThreadFeeds.completeHead(
            ticket,
            result: .page(
                makeGaryxTestRecentRefreshBundle(threadIds: ids)
            )
        )
    }

    private func issueRecentHead(
        _ model: GaryxMobileModel,
        filter: GaryxRecentThreadFilter? = nil
    ) throws -> GaryxRecentThreadRefreshTicket {
        let effects = model.recentThreadFeeds.requestHeadEffects(
            filter: filter,
            source: .userAction
        )
        var queuedRequest: GaryxRecentHeadRequest?
        for effect in effects {
            guard case .requestHead(let candidate) = effect else { continue }
            queuedRequest = candidate
            break
        }
        let request = try XCTUnwrap(queuedRequest)
        return try XCTUnwrap(
            model.recentThreadFeeds.beginHeadRequest(
                request,
                gatewayScope: model.threadFavoritesState.gatewayScope,
                runtimeEpoch: model.threadFavoritesState.runtimeEpoch
            )
        )
    }

    /// Decodes the same wire shape the gateway returns so the commit sees a
    /// real page, not a hand-built lookalike.
    private func makeRecentThreadsPage(threads: [GaryxThreadSummary]) throws -> GaryxRecentThreadsPage {
        let rows = threads.enumerated().map { index, thread in
            """
            {"thread_id": "\(thread.id)", "title": "\(thread.title)",
             "last_active_at": "2026-07-07T02:00:00Z", "last_message_preview": "",
             "activity_seq": \(threads.count - index)}
            """
        }
        let json = """
        {
          "threads": [\(rows.joined(separator: ","))],
          "count": \(threads.count), "limit": 30,
          "total": \(threads.count), "has_more": false, "next_cursor": null,
          "store_incarnation_id": "11111111-1111-4111-8111-111111111111",
          "server_boot_id": "22222222-2222-4222-8222-222222222222"
        }
        """
        return try JSONDecoder().decode(GaryxRecentThreadsPage.self, from: Data(json.utf8))
    }

    private func makeRecentThreadsPageData(rows: [(id: String, title: String)]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "threads": rows.enumerated().map { index, row in
                    [
                        "thread_id": row.id,
                        "title": row.title,
                        "last_active_at": "2026-07-07T02:00:00Z",
                        "last_message_preview": "",
                        "activity_seq": rows.count - index,
                    ]
                },
                "count": rows.count,
                "limit": 30,
                "total": rows.count,
                "has_more": false,
                "next_cursor": NSNull(),
                "store_incarnation_id": "11111111-1111-4111-8111-111111111111",
                "server_boot_id": "22222222-2222-4222-8222-222222222222",
            ]
        )
    }

    private func makeStubSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        GaryxRecentThreadsURLProtocolStub.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GaryxRecentThreadsURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private enum GaryxRefreshStubError: Error {
    case timedOut
    case missingURL
    case invalidResponse
}

private func garyxStubResponse(
    _ request: URLRequest,
    statusCode: Int = 200,
    data: Data
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url else { throw GaryxRefreshStubError.missingURL }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ) else {
        throw GaryxRefreshStubError.invalidResponse
    }
    return (response, data)
}

private func garyxPinsPageData(ids: [String], revision: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "thread_ids": ids,
            "revision": revision,
        ]
    )
}

private func garyxRecentThreadsData(
    ids: [String],
    storeIncarnationId: String = "11111111-1111-4111-8111-111111111111",
    hasMore: Bool = false,
    nextCursor: String? = nil
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "threads": ids.enumerated().map { index, id in
                [
                    "thread_id": id,
                    "title": id,
                    "last_active_at": "2026-07-07T02:00:00Z",
                    "last_message_preview": "",
                    "activity_seq": ids.count - index,
                ]
            },
            "count": ids.count,
            "limit": 30,
            "total": ids.count,
            "has_more": hasMore,
            "next_cursor": nextCursor ?? NSNull(),
            "store_incarnation_id": storeIncarnationId,
            "server_boot_id": "22222222-2222-4222-8222-222222222222",
        ]
    )
}

private func garyxFavoritesSnapshotData(
    ids: [String],
    rows: [(id: String, title: String)] = [],
    storeIncarnationId: String = "11111111-1111-4111-8111-111111111111"
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "store_incarnation_id": storeIncarnationId,
            "server_boot_id": "22222222-2222-4222-8222-222222222222",
            "revision": 1,
            "thread_ids": ids,
            "favorites": ids.map { id in
                [
                    "thread_id": id,
                    "favorited_at": "2026-07-16T08:00:00Z",
                ]
            },
            "recent": [
                "threads": rows.enumerated().map { index, row in
                    [
                        "thread_id": row.id,
                        "title": row.title,
                        "last_active_at": "2026-07-16T08:00:00Z",
                        "last_message_preview": "",
                        "activity_seq": rows.count - index,
                    ]
                },
                "total": rows.count,
                "truncated": false,
            ],
        ]
    )
}

/// Sanitized envelopes captured from the same SQLite store immediately before
/// and after `garyx gateway rotate-store-incarnation`. User rows are replaced
/// with public synthetic values; the wire keys and identity pairs are exact.
private struct GaryxTask2783CapturedGeneration {
    var storeIncarnationId: String
    var serverBootId: String

    static let beforeRotation = Self(
        storeIncarnationId: "40bb509a-1ba9-4367-9b02-185b0f225d14",
        serverBootId: "1b117b9d-ad35-4a9c-af1b-4a17de0420ef"
    )
    static let afterRotation = Self(
        storeIncarnationId: "520bea32-bc35-4ba2-a232-d875bd0f30fb",
        serverBootId: "7c0ced65-bc8f-46df-9324-9af560562cf3"
    )
}

private func garyxTask2783ThreadSummariesCaptureData(
    generation: GaryxTask2783CapturedGeneration
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "store_incarnation_id": generation.storeIncarnationId,
            "server_boot_id": generation.serverBootId,
            "threads": [],
            "has_more": false,
            "next_cursor": NSNull(),
        ]
    )
}

private func garyxTask2783RecentThreadsCaptureData(
    generation: GaryxTask2783CapturedGeneration
) throws -> Data {
    let threadId = "thread::1000000001"
    return try JSONSerialization.data(
        withJSONObject: [
            "threads": [[
                "active_run_id": NSNull(),
                "activity_seq": 1,
                "agent_id": "test-agent",
                "last_active_at": "2026-07-27T00:00:00Z",
                "last_message_preview": "Synthetic capture row",
                "message_count": 1,
                "provider_type": "codex_app_server",
                "recent_run_id": NSNull(),
                "recorded_at": "2026-07-27T00:00:00Z",
                "root_workspace_path": "/workspace/test",
                "run_state": NSNull(),
                "thread_id": threadId,
                "thread_runtime": NSNull(),
                "thread_type": "task",
                "title": "Test Thread",
                "updated_at": "2026-07-27T00:00:00Z",
                "workspace_dir": "/workspace/test",
                "workspace_origin": "explicit",
            ]],
            "count": 1,
            "limit": 30,
            "total": 1,
            "has_more": false,
            "next_cursor": NSNull(),
            "store_incarnation_id": generation.storeIncarnationId,
            "server_boot_id": generation.serverBootId,
        ]
    )
}

private func garyxTask2783FavoritesSnapshotCaptureData(
    generation: GaryxTask2783CapturedGeneration
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "store_incarnation_id": generation.storeIncarnationId,
            "server_boot_id": generation.serverBootId,
            "revision": 29,
            "thread_ids": [],
            "favorites": [],
            "recent": [
                "threads": [],
                "total": 0,
                "truncated": false,
            ],
            "summaries": [],
            "summaries_truncated": false,
        ]
    )
}

private func garyxRequestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }
    return data
}

private final class GaryxRecentThreadsURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let request = request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let (response, data) = try requestHandler(request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private final class GaryxLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        count += 1
        let next = count
        lock.unlock()
        return next
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

}

private struct GaryxRecordedLifecycleRequest: Equatable {
    var operationId: String
    var expectedStoreIncarnation: String
}

private final class GaryxLockedLifecycleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GaryxRecordedLifecycleRequest] = []

    @discardableResult
    func record(_ request: URLRequest) throws -> Int {
        let data = try XCTUnwrap(garyxRequestBodyData(from: request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let value = GaryxRecordedLifecycleRequest(
            operationId: try XCTUnwrap(object["operationId"] as? String),
            expectedStoreIncarnation: try XCTUnwrap(
                object["expectedStoreIncarnation"] as? String
            )
        )
        lock.lock()
        recorded.append(value)
        let count = recorded.count
        lock.unlock()
        return count
    }

    var values: [GaryxRecordedLifecycleRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private struct GaryxRecordedPinsPut: Equatable {
    var threadIds: [String]
    var expectedRevision: Int64
}

private final class GaryxLockedPinsPutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GaryxRecordedPinsPut] = []

    @discardableResult
    func record(_ request: URLRequest) throws -> Int {
        let data = try XCTUnwrap(garyxRequestBodyData(from: request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let value = GaryxRecordedPinsPut(
            threadIds: try XCTUnwrap(object["thread_ids"] as? [String]),
            expectedRevision: try XCTUnwrap((object["expected_revision"] as? NSNumber)?.int64Value)
        )
        lock.lock()
        recorded.append(value)
        let count = recorded.count
        lock.unlock()
        return count
    }

    var values: [GaryxRecordedPinsPut] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
