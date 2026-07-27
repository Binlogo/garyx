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

    private func resetTrace() throws {
        _ = try request(path: "reset", method: "POST")
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
