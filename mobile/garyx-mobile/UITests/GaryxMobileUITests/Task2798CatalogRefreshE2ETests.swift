import Foundation
import XCTest

/// Real-gateway acceptance coverage for the Home/catalog refresh split.
///
/// The simulator app is connected to the local tracing proxy on port 31338;
/// its `/__task2798` control routes reset, read, and snapshot the gesture
/// window while all other traffic is forwarded to the local gateway.
final class Task2798CatalogRefreshE2ETests: XCTestCase {
    private let controlBaseURL = URL(
        string: "http://127.0.0.1:31338/__task2798"
    )!

    override func setUpWithError() throws {
        continueAfterFailure = false
        do {
            _ = try request(path: "trace", method: "GET")
        } catch {
            throw XCTSkip(
                "TASK-2798 real-gateway E2E requires the local trace proxy on port 31338"
            )
        }
    }

    func testC1HomePullAgainstRealGateway() throws {
        let app = launchConnectedHome()
        let filter = app.buttons["Recent filter"]
        if filter.value as? String != "All" {
            filter.tap()
            let all = app.buttons["All"]
            XCTAssertTrue(all.waitForExistence(timeout: 5))
            all.tap()
            XCTAssertEqual(filter.value as? String, "All")
        }
        try waitForRequestCountToSettle(timeout: 10)
        let hadPinnedSection = app.staticTexts["Pinned"].exists
        try resetTrace()
        try pullToRefresh(in: app)

        _ = try waitForTrace(timeout: 3) { trace in
            completedStatus(for: "/api/recent-threads", in: trace) == 200
        }
        try waitForRequestCountToSettle(timeout: 2)
        let finalHomeTrace = try fetchTrace()
        let homePaths = finalHomeTrace.requests.compactMap(\.path)
        XCTAssertFalse(homePaths.isEmpty, "Home pull must issue the selected feed request")
        XCTAssertEqual(
            Set(homePaths),
            Set(["/api/recent-threads"]),
            "Home pull must not issue catalog or non-selected feed requests: \(homePaths)"
        )
        XCTAssertEqual(
            completedStatus(for: "/api/recent-threads", in: finalHomeTrace),
            200
        )
        XCTAssertEqual(
            app.staticTexts["Pinned"].exists,
            hadPinnedSection,
            "a selected-feed pull must preserve the cached pinned projection"
        )
        XCTAssertTrue(app.staticTexts["Recent"].exists)
        addScreenshot(named: "TASK-2798 C1 Home after pull", from: app)
        addTraceAttachment(named: "TASK-2798 C1 request trace", trace: finalHomeTrace)
        try snapshotTrace(named: "c1")
    }

    func testC2AgentsPullAgainstRealGateway() throws {
        let app = launchConnectedHome()
        let menu = app.buttons["Open menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        XCTAssertTrue(app.buttons["New Agent"].waitForExistence(timeout: 10))

        try waitForRequestCountToSettle(timeout: 10)
        try resetTrace()
        try pullToRefresh(in: app)

        let expectedCatalogPaths: Set<String> = [
            "/api/automations",
            "/api/bot-consoles",
            "/api/capsules",
            "/api/channel-endpoints",
            "/api/channels/plugins",
            "/api/commands/shortcuts",
            "/api/configured-bots",
            "/api/custom-agents",
            "/api/mcp-servers",
            "/api/settings",
            "/api/skills",
            "/api/workspaces",
        ]
        _ = try waitForTrace(timeout: 15) { trace in
            expectedCatalogPaths.allSatisfy {
                completedStatus(for: $0, in: trace) == 200
            }
        }
        try waitForRequestCountToSettle(timeout: 2)
        let finalAgentsTrace = try fetchTrace()
        for path in expectedCatalogPaths.sorted() {
            XCTAssertEqual(
                completedStatus(for: path, in: finalAgentsTrace),
                200,
                "Agents pull must complete \(path)"
            )
        }
        XCTAssertTrue(app.buttons["New Agent"].exists)
        addScreenshot(named: "TASK-2798 C2 Agents after pull", from: app)
        addTraceAttachment(named: "TASK-2798 C2 request trace", trace: finalAgentsTrace)
        try snapshotTrace(named: "c2")
    }

    func testTask2806S1ColdStartSelectedFeedPrecedesBackgroundDomains() throws {
        let app = launchConnectedHome()
        try selectFilter("All", in: app)
        try waitForRequestCountToSettle(timeout: 10)

        app.terminate()
        try resetTrace()
        let launchStartedAt = Date()
        app.launch()
        XCTAssertTrue(
            app.buttons["Recent filter"].waitForExistence(timeout: 20),
            "cold-start Home recent filter"
        )
        XCTAssertTrue(
            app.staticTexts["Recent"].waitForExistence(timeout: 20),
            "cold-start Home list"
        )
        let homeBecameVisibleAfter = Date().timeIntervalSince(launchStartedAt)
        let remainingCaptureWindow = 10 - Date().timeIntervalSince(launchStartedAt)
        if remainingCaptureWindow > 0 {
            Thread.sleep(forTimeInterval: remainingCaptureWindow)
        }

        let trace = try fetchTrace()
        let statusRequest = try XCTUnwrap(
            trace.requests.first { $0.path == "/api/status" }
        )
        let healthRequest = try XCTUnwrap(
            trace.requests.first { $0.path == "/api/chat/health" }
        )
        XCTAssertEqual(completedStatus(for: "/api/status", in: trace), 200)
        XCTAssertEqual(completedStatus(for: "/api/chat/health", in: trace), 200)
        XCTAssertLessThan(
            try XCTUnwrap(statusRequest.requestId),
            try XCTUnwrap(healthRequest.requestId)
        )

        let healthRequestId = try XCTUnwrap(healthRequest.requestId)
        let connectDomainRequests = trace.requests.filter { request in
            guard let requestId = request.requestId,
                  requestId > healthRequestId,
                  let path = request.path else {
                return false
            }
            return !coldStartIncidentalPaths.contains(path)
        }
        let firstConnectDomainRequest = try XCTUnwrap(connectDomainRequests.first)
        XCTAssertTrue(
            selectedHomeFeedPaths.contains(try XCTUnwrap(firstConnectDomainRequest.path)),
            "the first connect-owned data request after the probes must belong to the selected Home feed"
        )

        let firstRecentRequest = try XCTUnwrap(
            connectDomainRequests.first {
                $0.path == "/api/recent-threads"
                    && queryValue(named: "tasks", in: $0) == "include"
            }
        )
        let firstBackgroundRequest = try XCTUnwrap(
            connectDomainRequests.first {
                guard let path = $0.path else { return false }
                return coldStartBackgroundPaths.contains(path)
            }
        )
        XCTAssertLessThan(
            try XCTUnwrap(firstRecentRequest.requestId),
            try XCTUnwrap(firstBackgroundRequest.requestId),
            "the selected feed transport must start before agent targets, catalog, or usage"
        )
        XCTAssertEqual(
            completedStatus(
                requestId: try XCTUnwrap(firstRecentRequest.requestId),
                in: trace
            ),
            200
        )

        let observedCatalogPaths = Set(
            connectDomainRequests.compactMap(\.path)
                .filter(catalogPaths.contains)
        )
        XCTAssertEqual(
            observedCatalogPaths,
            catalogPaths,
            "the forced connect sweep must still cover all catalog paths"
        )
        XCTAssertTrue(
            connectDomainRequests.contains { $0.path == "/api/usage/coding" },
            "coding usage must still run in the background"
        )
        XCTAssertGreaterThanOrEqual(
            connectDomainRequests.filter { $0.path == "/api/custom-agents" }.count,
            2,
            "agent targets and the forced catalog sweep must both execute"
        )

        let recentResponse = try XCTUnwrap(
            response(
                requestId: try XCTUnwrap(firstRecentRequest.requestId),
                in: trace
            )
        )
        let recentResponseTimestamp = try XCTUnwrap(recentResponse.timestamp)
        XCTAssertTrue(
            trace.responses.contains { response in
                guard let requestId = response.requestId,
                      let request = trace.requests.first(where: {
                          $0.requestId == requestId
                      }),
                      let path = request.path,
                      catalogPaths.contains(path),
                      let timestamp = response.timestamp else {
                    return false
                }
                return timestamp > recentResponseTimestamp
            },
            "at least one catalog response must finish after the selected feed response"
        )
        XCTAssertLessThan(
            homeBecameVisibleAfter,
            10,
            "Home must render inside the captured cold-start window"
        )

        addScreenshot(named: "TASK-2806 S1 cold-start Home", from: app)
        addTraceAttachment(named: "TASK-2806 S1 first 10 seconds", trace: trace)
        try snapshotTrace(named: "task-2806-s1")
    }

    func testTask2806S2FilterSwitchStress() throws {
        let app = launchConnectedHome()
        try selectFilter("All", in: app)
        try waitForRequestCountToSettle(timeout: 10)
        try resetTrace()

        var completedCycles = 0
        func runCycle() throws {
            try selectFilterAndAwaitFeed("Chats", in: app)
            try selectFilterAndAwaitFeed("Favorites", in: app)
            try selectFilterAndAwaitFeed("All", in: app)
            completedCycles += 1
        }

        // Exercise the reported sequence immediately after a user pull.
        try pullToRefresh(in: app)
        try runCycle()

        // Exercise the owner's former workaround boundary, but require the
        // first switch after returning Home to converge without another route.
        try openFirstVisibleThread(in: app)
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(
            app.buttons["Recent filter"].waitForExistence(timeout: 10),
            "Home filter after returning from a thread"
        )
        try runCycle()
        addScreenshot(
            named: "TASK-2806 S2 converged after thread return",
            from: app
        )

        while completedCycles < 20 {
            try runCycle()
        }

        let trace = try fetchTrace()
        XCTAssertEqual(completedCycles, 20)
        XCTAssertEqual(app.buttons["Recent filter"].value as? String, "All")
        XCTAssertGreaterThanOrEqual(
            completedFeedRequestCount(filter: "Chats", in: trace),
            20,
            "every Chats selection must reach a successful feed request"
        )
        XCTAssertGreaterThanOrEqual(
            completedFeedRequestCount(filter: "Favorites", in: trace),
            20,
            "every Favorites selection must reach a successful snapshot request"
        )
        XCTAssertGreaterThanOrEqual(
            completedFeedRequestCount(filter: "All", in: trace),
            20,
            "every All selection must reach a successful feed request"
        )

        addTraceAttachment(named: "TASK-2806 S2 20-cycle trace", trace: trace)
        try snapshotTrace(named: "task-2806-s2")
    }

    private func launchConnectedHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.buttons["Recent filter"].waitForExistence(timeout: 20),
            "connected Home recent filter"
        )
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 20))
        return app
    }

    private var catalogPaths: Set<String> {
        [
            "/api/automations",
            "/api/bot-consoles",
            "/api/capsules",
            "/api/channel-endpoints",
            "/api/channels/plugins",
            "/api/commands/shortcuts",
            "/api/configured-bots",
            "/api/custom-agents",
            "/api/mcp-servers",
            "/api/settings",
            "/api/skills",
            "/api/workspaces",
        ]
    }

    private var selectedHomeFeedPaths: Set<String> {
        [
            "/api/thread-pins",
            "/api/thread-favorites/snapshot",
            "/api/recent-threads",
        ]
    }

    private var coldStartIncidentalPaths: Set<String> {
        [
            "/api/push/devices",
            "/api/workspaces/git-status",
        ]
    }

    private var coldStartBackgroundPaths: Set<String> {
        catalogPaths.union([
            "/api/usage/coding",
        ])
    }

    private func resetTrace() throws {
        _ = try request(path: "reset", method: "POST")
    }

    private func selectFilter(_ name: String, in app: XCUIApplication) throws {
        let filter = app.buttons["Recent filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        guard filter.value as? String != name else { return }
        filter.coordinate(
            withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)
        ).tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        try waitForFilterValue(name, in: app)
    }

    private func selectFilterAndAwaitFeed(
        _ name: String,
        in app: XCUIApplication
    ) throws {
        let traceBeforeSelection = try fetchTrace()
        let priorRequestId = traceBeforeSelection.requests
            .compactMap(\.requestId)
            .max() ?? 0
        try selectFilter(name, in: app)
        _ = try waitForTrace(timeout: 10) { trace in
            self.completedFeedRequestCount(
                filter: name,
                after: priorRequestId,
                in: trace
            ) > 0
        }
    }

    private func waitForFilterValue(
        _ name: String,
        in app: XCUIApplication
    ) throws {
        let filter = app.buttons["Recent filter"]
        let deadline = Date().addingTimeInterval(5)
        while filter.value as? String != name, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(filter.value as? String, name)
    }

    private func openFirstVisibleThread(in app: XCUIApplication) throws {
        let back = app.buttons["Back"]
        for verticalOffset in [0.36, 0.46, 0.56, 0.66] {
            app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: verticalOffset)
            ).tap()
            if back.waitForExistence(timeout: 2) {
                return
            }
        }
        XCTFail("a visible Home row must open a thread")
    }

    private func pullToRefresh(in app: XCUIApplication) throws {
        let collectionView = app.collectionViews.firstMatch
        let scrollSurface = collectionView.exists
            ? collectionView
            : app.scrollViews.firstMatch
        XCTAssertTrue(
            scrollSurface.waitForExistence(timeout: 2),
            "refreshable scroll surface"
        )
        let start = scrollSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)
        )
        let end = scrollSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)
        )
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    private func snapshotTrace(named name: String) throws {
        _ = try request(path: "snapshot?name=\(name)", method: "POST")
    }

    private func fetchTrace() throws -> Trace {
        let data = try request(path: "trace", method: "GET")
        return Trace(
            entries: try JSONDecoder().decode([TraceEntry].self, from: data)
        )
    }

    private func waitForTrace(
        timeout: TimeInterval,
        predicate: (Trace) -> Bool
    ) throws -> Trace {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try fetchTrace()
        while !predicate(latest), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            latest = try fetchTrace()
        }
        XCTAssertTrue(
            predicate(latest),
            "request trace did not reach the expected state: \(latest)"
        )
        return latest
    }

    private func waitForRequestCountToSettle(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previousCount = try fetchTrace().requests.count
        var unchangedSince = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let currentCount = try fetchTrace().requests.count
            if currentCount != previousCount {
                previousCount = currentCount
                unchangedSince = Date()
            } else if Date().timeIntervalSince(unchangedSince) >= 0.35 {
                return
            }
        }
        XCTFail("request count did not settle")
    }

    private func completedStatus(for path: String, in trace: Trace) -> Int? {
        let requestIds = trace.requests
            .filter { $0.path == path }
            .compactMap(\.requestId)
        return trace.responses
            .filter { requestIds.contains($0.requestId ?? -1) }
            .compactMap(\.status)
            .last
    }

    private func completedStatus(requestId: Int, in trace: Trace) -> Int? {
        response(requestId: requestId, in: trace)?.status
    }

    private func response(requestId: Int, in trace: Trace) -> TraceEntry? {
        trace.responses.last { $0.requestId == requestId }
    }

    private func queryValue(named name: String, in entry: TraceEntry) -> String? {
        guard let target = entry.target,
              let components = URLComponents(
                  string: "http://localhost\(target)"
              ) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }

    private func completedFeedRequestCount(
        filter: String,
        after requestId: Int = 0,
        in trace: Trace
    ) -> Int {
        let requestIds = trace.requests.compactMap { request -> Int? in
            guard let candidateId = request.requestId,
                  candidateId > requestId else {
                return nil
            }
            switch filter {
            case "All":
                return request.path == "/api/recent-threads"
                    && queryValue(named: "tasks", in: request) == "include"
                    ? candidateId
                    : nil
            case "Chats":
                return request.path == "/api/recent-threads"
                    && queryValue(named: "tasks", in: request) == "exclude"
                    ? candidateId
                    : nil
            case "Favorites":
                return request.path == "/api/thread-favorites/snapshot"
                    && queryValue(named: "include_summaries", in: request) == "true"
                    ? candidateId
                    : nil
            default:
                return nil
            }
        }
        let completedIds = Set(
            trace.responses.compactMap { response -> Int? in
                guard response.status == 200 else { return nil }
                return response.requestId
            }
        )
        return requestIds.filter(completedIds.contains).count
    }

    private func request(path: String, method: String) throws -> Data {
        let url = URL(string: "\(controlBaseURL.absoluteString)/\(path)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        let completion = expectation(description: "\(method) \(path)")
        var result: Result<(Data, URLResponse), Error>?
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(TraceError.missingResponse)
            }
            completion.fulfill()
        }.resume()
        wait(for: [completion], timeout: 5)
        let (data, response) = try XCTUnwrap(result).get()
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200 ... 299).contains(httpResponse.statusCode))
        return data
    }

    private func addScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func addTraceAttachment(named name: String, trace: Trace) {
        let data = try! JSONEncoder().encode(trace.entries)
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct Trace: CustomStringConvertible {
    let entries: [TraceEntry]

    var requests: [TraceEntry] {
        entries.filter { $0.type == "request" }
    }

    var responses: [TraceEntry] {
        entries.filter { $0.type == "response" }
    }

    var description: String {
        entries.description
    }
}

private struct TraceEntry: Codable, CustomStringConvertible {
    let type: String
    let requestId: Int?
    let timestamp: String?
    let method: String?
    let target: String?
    let status: Int?
    let bytes: Int?

    var path: String? {
        guard let target else { return nil }
        return URL(string: "http://localhost\(target)")?.path
    }

    var description: String {
        if type == "request" {
            return "\(requestId ?? -1):\(method ?? "?") \(target ?? "?")"
        }
        return "\(requestId ?? -1):\(status ?? -1) \(bytes ?? -1) bytes"
    }
}

private enum TraceError: Error {
    case missingResponse
}
