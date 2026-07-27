import Foundation
import XCTest
@testable import GaryxMobile

@MainActor
final class GaryxCatalogRefreshIntegrationTests: XCTestCase {
    private var sessions: [URLSession] = []
    private var models: [GaryxMobileModel] = []

    override func tearDown() async throws {
        for model in models {
            var outstandingTasks: [Task<Void, Never>] = [
                model.catalogRefreshInFlight?.task,
                model.sceneRefreshTask,
                model.selectedThreadRecoveryTask,
                model.selectedThreadHistoryRetryTask,
                model.selectedThreadReconcileTask,
                model.backgroundCommittedRunReconcileTask,
                model.selectedThreadStreamTask,
                model.selectedThreadStreamFlushTask,
                model.selectedThreadStreamDrainTask,
                model.threadFavoritesSnapshotTask,
            ].compactMap { $0 }
            outstandingTasks.append(
                contentsOf: model.completedThreadHistoryHydrationTasks.values
            )
            outstandingTasks.append(
                contentsOf: model.botThreadHydrationTasks.values.flatMap(\.values)
            )
            outstandingTasks.forEach { $0.cancel() }
            model.resetGatewayRuntimeState()
            for task in outstandingTasks {
                await task.value
            }
            await model.homeFeedSyncCoordinator.waitForTransportIdleForTesting()
            await model.homeProjectionGateway.waitForIdleForTesting()
        }
        models.removeAll()
        sessions.forEach { $0.invalidateAndCancel() }
        sessions.removeAll()
        GaryxCatalogURLProtocolStub.requestHandler = nil
        try await super.tearDown()
    }

    func testB1HomePullAllIssuesOnlySelectedRecentFeed() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let coordinator = prepareHome(model, filter: .all)
        recorder.reset()

        await performHomePull(model)
        await coordinator.waitForTransportIdleForTesting()

        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            ["/api/recent-threads?limit=30&tasks=include"]
        )
        XCTAssertTrue(recorder.catalogPaths.isEmpty)
    }

    func testB2HomePullChatsIssuesOnlySelectedRecentFeed() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let coordinator = prepareHome(model, filter: .nonTask)
        recorder.reset()

        await performHomePull(model)
        await coordinator.waitForTransportIdleForTesting()

        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            ["/api/recent-threads?limit=30&tasks=exclude"]
        )
        XCTAssertTrue(recorder.catalogPaths.isEmpty)
    }

    func testB3HomePullFavoritesIssuesOnlySnapshot() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let coordinator = prepareHome(model, filter: .favorites)
        recorder.reset()

        await performHomePull(model)
        await coordinator.waitForTransportIdleForTesting()
        await coordinator.waitForFavoritesConvergence()

        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            ["/api/thread-favorites/snapshot"]
        )
        XCTAssertTrue(recorder.catalogPaths.isEmpty)
    }

    func testB4FilterSwitchesNeverIssueCatalogRequests() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let coordinator = prepareHome(model, filter: .all)
        recorder.reset()
        model.connectionState = .ready(version: "test")

        for filter in [
            GaryxRecentThreadFilter.nonTask,
            .favorites,
            .all,
        ] {
            model.selectRecentThreadFilter(filter)
            await model.requestHomeFeedRefresh(source: .userAction)
            await coordinator.waitForTransportIdleForTesting()
        }
        await coordinator.waitForFavoritesConvergence()

        XCTAssertTrue(recorder.catalogPaths.isEmpty)
        XCTAssertTrue(
            Set(recorder.entries.map(\.path)).isSubset(
                of: [
                    "/api/recent-threads",
                    "/api/thread-favorites/snapshot",
                    "/api/thread-pins",
                    "/api/thread-summaries",
                ]
            )
        )
    }

    func testB5ConnectRefreshStillRunsForcedCatalogSweep() async {
        let recorder = GaryxCatalogRequestRecorder()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock)

        await model.connectAndRefresh()

        XCTAssertEqual(recorder.catalogPaths, garyxCatalogSweepPaths)
        XCTAssertEqual(model.lastSuccessfulCatalogSweepCompletedAt, clock.now)
        XCTAssertEqual(
            model.lastSuccessfulCatalogSweepRuntimeGeneration,
            model.gatewayRequestToken
        )
    }

    func testB6ManagementPullRemainsForcedWithinTTL() async {
        let recorder = GaryxCatalogRequestRecorder()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock)

        await model.refreshRemoteState(.forced)
        let firstCounts = recorder.catalogPathCounts
        clock.now.addTimeInterval(1)
        await model.refreshRemoteState(.forced)

        for path in garyxCatalogSweepPaths {
            XCTAssertEqual(
                recorder.catalogPathCounts[path],
                (firstCounts[path] ?? 0) + 1,
                "forced management refresh must re-fetch \(path)"
            )
        }
    }

    func testB7BotEditReadbackRemainsForcedWithinTTL() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock)
        await model.refreshRemoteState(.forced)
        clock.now.addTimeInterval(1)
        recorder.reset()

        let original = GaryxConfiguredBotAccountSettings(
            channel: "test",
            accountId: "main",
            displayName: "Test Bot",
            enabled: true,
            agentId: nil,
            workspaceDir: nil,
            workspaceMode: "local",
            config: [:]
        )
        let saved = await model.saveConfiguredBotAccount(
            GaryxConfiguredBotAccountInput(
                channel: "test",
                accountId: "main",
                displayName: "Edited Test Bot",
                enabled: true,
                agentId: nil,
                workspaceDir: nil,
                workspaceMode: "local",
                config: [:]
            ),
            original: original
        )

        XCTAssertTrue(saved)
        let entries = recorder.entries
        let settingsWriteIndex = try XCTUnwrap(
            entries.firstIndex {
                $0.method == "PUT" && $0.path == "/api/settings"
            }
        )
        let readbackPaths = Set(
            entries.suffix(from: entries.index(after: settingsWriteIndex))
                .filter { $0.method == "GET" && garyxCatalogSweepPaths.contains($0.path) }
                .map(\.path)
        )
        XCTAssertEqual(readbackPaths, garyxCatalogSweepPaths)
    }

    func testB8ComposerEnsureThreadIsSilentWithinTTL() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock)
        await model.connectAndRefresh()
        XCTAssertNotNil(model.lastSuccessfulCatalogSweepCompletedAt)
        recorder.reset()
        preparePendingBotDraft(model)

        _ = try await model.ensureSelectedThread()

        XCTAssertTrue(recorder.catalogPaths.isEmpty)
        XCTAssertTrue(
            Set(recorder.entries.map(\.path)).isSuperset(
                of: ["/api/threads", "/api/bot/bind"]
            )
        )
    }

    func testB9ComposerEnsureThreadSweepsPastTTL() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock)
        await model.connectAndRefresh()
        XCTAssertNotNil(model.lastSuccessfulCatalogSweepCompletedAt)
        clock.now.addTimeInterval(GaryxCatalogRefreshPolicy.defaultTTL + 1)
        recorder.reset()
        preparePendingBotDraft(model)

        _ = try await model.ensureSelectedThread()

        XCTAssertEqual(recorder.catalogPaths, garyxCatalogSweepPaths)
    }

    func testB10ConcurrentIntentsCoalesceOntoOneSweep() async {
        let recorder = GaryxCatalogRequestRecorder()
        let gate = GaryxCatalogRequestGate()
        let model = makeModel(recorder: recorder, gate: gate)

        let initial = Task { @MainActor in
            await model.refreshRemoteState(.forced)
        }
        await gate.waitUntilFirstPathStarted()

        var joinersEntered = 0
        let forcedJoiner = Task { @MainActor in
            joinersEntered += 1
            await model.refreshRemoteState(.forced)
        }
        let staleJoiner = Task { @MainActor in
            joinersEntered += 1
            await model.refreshRemoteState(.staleGated)
        }
        while joinersEntered < 2 {
            await Task.yield()
        }
        gate.release()

        await initial.value
        await forcedJoiner.value
        await staleJoiner.value
        XCTAssertNil(model.catalogRefreshInFlight)
        XCTAssertNotNil(model.lastSuccessfulCatalogSweepCompletedAt)
        for path in garyxCatalogSweepPaths {
            XCTAssertEqual(
                recorder.catalogPathCounts[path],
                1,
                "single-flight must issue \(path) once"
            )
        }
    }

    func testB11SupersededSweepDoesNotStampFreshness() async {
        let recorder = GaryxCatalogRequestRecorder()
        let gate = GaryxCatalogRequestGate()
        let clock = GaryxCatalogTestClock()
        let model = makeModel(recorder: recorder, clock: clock, gate: gate)

        let superseded = Task { @MainActor in
            await model.refreshRemoteState(.forced)
        }
        await gate.waitUntilFirstPathStarted()
        model.resetGatewayRuntimeState()
        model.activateCurrentGatewayScope()
        gate.release()
        await superseded.value

        XCTAssertNil(model.lastSuccessfulCatalogSweepCompletedAt)
        await model.refreshRemoteState(.staleGated)
        for path in garyxCatalogSweepPaths {
            XCTAssertEqual(
                recorder.catalogPathCounts[path],
                2,
                "a superseded sweep must leave \(path) stale"
            )
        }
        XCTAssertEqual(model.lastSuccessfulCatalogSweepCompletedAt, clock.now)
    }

    func testB12RestoredCatalogKeepsHomeAvatarWithoutPullSweep() async throws {
        let suiteName = "GaryxCatalogRefreshIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            "http://gateway.example.test",
            forKey: GaryxMobileSettingsKeys.gatewayUrl
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let avatarDataURL =
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let cacheWriter = GaryxMobileModel(defaults: defaults)
        cacheWriter.agents = [
            GaryxAgentSummary(
                id: "agent-avatar",
                displayName: "Avatar Agent",
                providerType: "test",
                model: "test-model",
                avatarDataUrl: avatarDataURL
            ),
        ]
        cacheWriter.persistCatalogCacheSnapshot()

        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(
            defaults: defaults,
            recorder: recorder,
            recentAgentId: "agent-avatar"
        )
        XCTAssertEqual(model.agents.first?.avatarDataUrl, avatarDataURL)
        let coordinator = prepareHome(model, filter: .all)
        recorder.reset()

        await performHomePull(model)
        await coordinator.waitForTransportIdleForTesting()

        let thread = try XCTUnwrap(model.cachedThreadSummary(for: "thread-home"))
        let identity = model.widgetAgentIdentity(for: thread)
        XCTAssertEqual(identity.id, "agent-avatar")
        XCTAssertEqual(identity.avatarDataUrl, avatarDataURL)
        XCTAssertTrue(recorder.catalogPaths.isEmpty)
        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            ["/api/recent-threads?limit=30&tasks=include"]
        )
    }

    func testB13HomePullCommitsSelectedFeedWithoutDroppingPinnedSection() async throws {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let runtime = GaryxThreadRuntimeSummary(
            agentId: "agent-current",
            providerType: "test",
            model: "test-model"
        )
        let pinnedOutsidePage = makeThread(
            id: "thread-pinned-outside-page",
            title: "Cached Pinned Thread",
            updatedAt: "2026-07-26T11:00:00Z"
        )
        let selected = makeThread(
            id: "thread-home",
            title: "Previous Home Thread",
            updatedAt: "2026-07-26T12:00:00Z",
            threadRuntime: runtime
        )
        model.seedThreadSummariesForTesting(
            [pinnedOutsidePage, selected],
            recentThreadIds: [selected.id]
        )
        model.applyPinnedThreadIds([pinnedOutsidePage.id])
        model.selectedThread = selected
        model.draftThreadTitle = selected.title
        let coordinator = prepareHome(model, filter: .all)
        recorder.reset()

        await performHomePull(model)
        await coordinator.waitForTransportIdleForTesting()

        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            ["/api/recent-threads?limit=30&tasks=include"]
        )
        XCTAssertEqual(model.pinnedThreadIds, [pinnedOutsidePage.id])
        XCTAssertEqual(
            model.homeThreadListStore.presentationSnapshot.sections.pinned.map(\.id),
            [pinnedOutsidePage.id]
        )
        XCTAssertEqual(
            model.cachedThreadSummary(for: pinnedOutsidePage.id),
            pinnedOutsidePage
        )
        let refreshed = try XCTUnwrap(model.cachedThreadSummary(for: selected.id))
        XCTAssertEqual(refreshed.title, "Home Thread")
        XCTAssertEqual(refreshed.threadRuntime, runtime)
        XCTAssertEqual(model.selectedThread?.title, "Home Thread")
        XCTAssertEqual(model.draftThreadTitle, "Home Thread")
    }

    func testConcurrentPullDoesNotNarrowQueuedUserAction() async {
        let recorder = GaryxCatalogRequestRecorder()
        let model = makeModel(recorder: recorder)
        let coordinator = prepareHome(model, filter: .all)
        recorder.reset()

        let userAction = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userAction)
        }
        while !coordinator.hasPendingUserIntentForTesting(.userAction) {
            await Task.yield()
        }
        let pull = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        while !coordinator.hasPendingUserIntentForTesting(.userPullToRefresh) {
            await Task.yield()
        }
        model.connectionState = .ready(version: "test")

        await userAction.value
        await pull.value
        await coordinator.waitForTransportIdleForTesting()
        await coordinator.waitForFavoritesConvergence()

        XCTAssertEqual(
            Set(recorder.entries.map(\.target)),
            [
                "/api/recent-threads?limit=30&tasks=include",
                "/api/thread-favorites/snapshot",
                "/api/thread-pins",
                "/api/thread-summaries?limit=1",
            ]
        )
        XCTAssertTrue(recorder.catalogPaths.isEmpty)
    }

    private func makeThread(
        id: String,
        title: String,
        updatedAt: String,
        threadRuntime: GaryxThreadRuntimeSummary? = nil
    ) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: title,
            createdAt: nil,
            updatedAt: updatedAt,
            lastMessagePreview: "",
            workspacePath: nil,
            messageCount: nil,
            agentId: nil,
            providerType: nil,
            recentRunId: nil,
            activeRunId: nil,
            runState: nil,
            worktreePath: nil,
            threadRuntime: threadRuntime
        )
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        recorder: GaryxCatalogRequestRecorder,
        clock: GaryxCatalogTestClock = GaryxCatalogTestClock(),
        gate: GaryxCatalogRequestGate? = nil,
        recentAgentId: String? = nil
    ) -> GaryxMobileModel {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "GaryxCatalogRefreshIntegrationTests.\(UUID().uuidString)"
            resolvedDefaults = UserDefaults(suiteName: suiteName)!
            resolvedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults.set(
                "http://gateway.example.test",
                forKey: GaryxMobileSettingsKeys.gatewayUrl
            )
        }
        let session = makeSession { request in
            recorder.record(request)
            if let path = request.url?.path, garyxCatalogSweepPaths.contains(path) {
                gate?.waitUntilReleased(path: path)
            }
            return try garyxCatalogStubResponse(
                request,
                recentAgentId: recentAgentId
            )
        }
        let model = GaryxMobileModel(
            defaults: resolvedDefaults,
            gatewayClientFactory: { configuration in
                GaryxGatewayClient(
                    configuration: configuration,
                    session: session,
                    retryPolicy: .disabled
                )
            },
            catalogRefreshNow: { clock.now }
        )
        models.append(model)
        return model
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        GaryxCatalogURLProtocolStub.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GaryxCatalogURLProtocolStub.self]
        configuration.httpMaximumConnectionsPerHost = 32
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        return session
    }

    private func prepareHome(
        _ model: GaryxMobileModel,
        filter: GaryxRecentThreadFilter
    ) -> GaryxHomeFeedSyncCoordinator {
        if let ticket = model.threadFavoritesState.activeSnapshotTicket {
            model.runThreadFavoritesEffects(
                model.threadFavoritesProvider.failSnapshot(ticket: ticket)
            )
        }
        model.homeFeedSyncCoordinator.deactivateScope()
        model.recentThreadFeeds.select(filter)
        let coordinator = GaryxHomeFeedSyncCoordinator(
            initialEffects: [],
            immediateDemandTimeout: GaryxMobileModel.homeFeedImmediateDemandTimeout,
            scopeToken: model.gatewayRequestToken
        )
        model.homeFeedSyncCoordinator = coordinator
        coordinator.attach(model)
        coordinator.updateHomeVisibility(true)
        model.connectionState = .checking
        return coordinator
    }

    private func performHomePull(_ model: GaryxMobileModel) async {
        let pull = Task { @MainActor in
            await model.requestHomeFeedRefresh(source: .userPullToRefresh)
        }
        while !model.homeFeedSyncCoordinator.hasPendingUserIntentForTesting(
            .userPullToRefresh
        ) {
            await Task.yield()
        }
        model.connectionState = .ready(version: "test")
        await pull.value
    }

    private func preparePendingBotDraft(_ model: GaryxMobileModel) {
        model.pendingBotId = GaryxMobileModel.botSelectorId(
            channel: "test",
            accountId: "main"
        )
        model.pendingBotWorkspace = nil
        model.pendingBotAgentId = nil
        model.pendingBotDraftGeneration = model.selectedThreadDraftGeneration
    }
}

private let garyxCatalogSweepPaths: Set<String> = [
    "/api/custom-agents",
    "/api/skills",
    "/api/settings",
    "/api/automations",
    "/api/commands/shortcuts",
    "/api/mcp-servers",
    "/api/channel-endpoints",
    "/api/workspaces",
    "/api/configured-bots",
    "/api/bot-consoles",
    "/api/channels/plugins",
    "/api/capsules",
]

private final class GaryxCatalogTestClock {
    var now = Date(timeIntervalSinceReferenceDate: 20_000)
}

private struct GaryxCatalogRecordedRequest: Equatable {
    var method: String
    var path: String
    var target: String
}

private final class GaryxCatalogRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [GaryxCatalogRecordedRequest] = []

    var entries: [GaryxCatalogRecordedRequest] {
        lock.withLock { storedEntries }
    }

    var catalogPaths: Set<String> {
        Set(entries.lazy.map(\.path).filter(garyxCatalogSweepPaths.contains))
    }

    var catalogPathCounts: [String: Int] {
        entries.reduce(into: [:]) { counts, entry in
            guard garyxCatalogSweepPaths.contains(entry.path) else { return }
            counts[entry.path, default: 0] += 1
        }
    }

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? (lhs.value ?? "") < (rhs.value ?? "")
                    : lhs.name < rhs.name
            }
            .map { item in
                "\(item.name)=\(item.value ?? "")"
            }
            .joined(separator: "&") ?? ""
        let target = query.isEmpty ? url.path : "\(url.path)?\(query)"
        lock.withLock {
            storedEntries.append(
                GaryxCatalogRecordedRequest(
                    method: request.httpMethod ?? "GET",
                    path: url.path,
                    target: target
                )
            )
        }
    }

    func reset() {
        lock.withLock {
            storedEntries.removeAll()
        }
    }
}

private final class GaryxCatalogRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var startedPaths: Set<String> = []
    private var firstPathWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilReleased(path: String) {
        condition.lock()
        startedPaths.insert(path)
        let waiter = firstPathWaiter
        firstPathWaiter = nil
        condition.broadcast()
        condition.unlock()
        waiter?.resume()
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilFirstPathStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if startedPaths.isEmpty {
                precondition(firstPathWaiter == nil)
                firstPathWaiter = continuation
                condition.unlock()
            } else {
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class GaryxCatalogURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum GaryxCatalogStubError: Error {
    case missingURL
    case invalidResponse
}

private func garyxCatalogStubResponse(
    _ request: URLRequest,
    recentAgentId: String?
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url else {
        throw GaryxCatalogStubError.missingURL
    }
    let data: Data
    let statusCode: Int
    switch (request.httpMethod ?? "GET", url.path) {
    case ("GET", "/api/status"):
        statusCode = 200
        data = Data(#"{"status":"ok","version":"test"}"#.utf8)
    case ("GET", "/api/chat/health"):
        statusCode = 200
        data = Data(#"{"status":"ok","channel":"api","bridge_ready":true}"#.utf8)
    case ("GET", "/api/custom-agents"):
        statusCode = 200
        data = Data(#"{"agents":[]}"#.utf8)
    case ("GET", "/api/skills"):
        statusCode = 200
        data = Data(#"{"skills":[]}"#.utf8)
    case ("GET", "/api/settings"):
        statusCode = 200
        data = Data(
            #"""
            {"channels":{"test":{"accounts":{"main":{"name":"Test Bot","enabled":true,"workspace_mode":"local","config":{}}}}}}
            """#.utf8
        )
    case ("PUT", "/api/settings"):
        statusCode = 200
        data = Data(#"{"ok":true,"warnings":[],"errors":[]}"#.utf8)
    case ("GET", "/api/automations"):
        statusCode = 200
        data = Data(#"{"automations":[]}"#.utf8)
    case ("GET", "/api/commands/shortcuts"):
        statusCode = 200
        data = Data(#"{"commands":[]}"#.utf8)
    case ("GET", "/api/mcp-servers"):
        statusCode = 200
        data = Data(#"{"servers":[]}"#.utf8)
    case ("GET", "/api/channel-endpoints"):
        statusCode = 200
        data = Data(#"{"endpoints":[]}"#.utf8)
    case ("GET", "/api/workspaces"):
        statusCode = 200
        data = Data(#"{"workspaces":[],"workspace_state_initialized":true}"#.utf8)
    case ("GET", "/api/configured-bots"):
        statusCode = 200
        data = Data(#"{"bots":[]}"#.utf8)
    case ("GET", "/api/bot-consoles"):
        statusCode = 200
        data = Data(#"{"bots":[]}"#.utf8)
    case ("GET", "/api/channels/plugins"):
        statusCode = 200
        data = Data(#"{"plugins":[]}"#.utf8)
    case ("GET", "/api/capsules"):
        statusCode = 200
        data = Data(#"{"capsules":[]}"#.utf8)
    case ("GET", "/api/recent-threads"):
        statusCode = 200
        let agentField = recentAgentId.map { #","agent_id":"\#($0)""# } ?? ""
        data = Data(
            #"""
            {
              "threads":[{
                "thread_id":"thread-home",
                "title":"Home Thread",
                "last_active_at":"2026-07-27T12:00:00Z",
                "last_message_preview":"",
                "activity_seq":1\#(agentField)
              }],
              "count":1,
              "limit":30,
              "total":1,
              "has_more":false,
              "next_cursor":null,
              "store_incarnation_id":"11111111-1111-4111-8111-111111111111",
              "server_boot_id":"22222222-2222-4222-8222-222222222222"
            }
            """#.utf8
        )
    case ("GET", "/api/thread-pins"):
        statusCode = 200
        data = Data(#"{"thread_ids":[],"revision":1}"#.utf8)
    case ("GET", "/api/thread-favorites/snapshot"):
        statusCode = 200
        data = Data(
            #"""
            {
              "store_incarnation_id":"11111111-1111-4111-8111-111111111111",
              "server_boot_id":"22222222-2222-4222-8222-222222222222",
              "revision":1,
              "thread_ids":[],
              "favorites":[],
              "recent":{"threads":[],"total":0,"truncated":false}
            }
            """#.utf8
        )
    case ("GET", "/api/thread-summaries"):
        statusCode = 404
        data = Data()
    case ("POST", "/api/threads"):
        statusCode = 200
        data = Data(
            #"""
            {
              "thread_id":"thread-created",
              "title":"Created Thread",
              "last_active_at":"2026-07-27T12:00:00Z",
              "last_message_preview":""
            }
            """#.utf8
        )
    case ("POST", "/api/bot/bind"):
        statusCode = 200
        data = Data(
            #"""
            {
              "ok":true,
              "bot_id":"test:main",
              "channel":"test",
              "account_id":"main",
              "thread_id":"thread-created"
            }
            """#.utf8
        )
    case ("POST", "/api/channels/plugins/test/validate_account"):
        statusCode = 200
        data = Data(#"{"validated":true,"message":"ok"}"#.utf8)
    default:
        statusCode = 404
        data = Data()
    }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ) else {
        throw GaryxCatalogStubError.invalidResponse
    }
    return (response, data)
}
