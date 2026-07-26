import XCTest
@testable import GaryxMobileCore

@MainActor
final class GaryxProviderModelCatalogStoreTests: XCTestCase {
    func testFailedRefreshKeepsPreviousSnapshot() async throws {
        let store = GaryxProviderModelCatalogStore()
        let healthy = try providerModels(healthyCatalogJSON)

        let initial = await store.refresh(providerType: "claude_code") { healthy }
        XCTAssertEqual(initial, .updated)
        let failed = await store.refresh(providerType: "claude_code") {
            throw CatalogTestError.failed
        }
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(store.modelsByProvider["claude_code"], healthy)
    }

    func testSuccessfulRefreshRepairsRowsAndLabelsWithoutRestart() async throws {
        let store = GaryxProviderModelCatalogStore()
        let degraded = try capturedDegradedProviderModels()
        let healthy = try providerModels(healthyCatalogJSON)

        _ = await store.refresh(providerType: "claude_code") { degraded }
        let stale = try XCTUnwrap(store.modelsByProvider["claude_code"])
        XCTAssertEqual(
            GaryxThreadModelOverridePresentation.modelLabel(
                providerModels: stale,
                model: "claude-opus-5"
            ),
            "claude-opus-5"
        )
        XCTAssertEqual(
            GaryxThreadModelOverridePresentation.reasoningEffortPickerOptions(
                providerModels: stale,
                model: "claude-opus-5",
                effectiveReasoningEffort: "max",
                defaultRowLabel: "Agent default"
            ).map(\.id),
            ["", "max"]
        )

        let outcome = await store.refresh(providerType: "claude_code") { healthy }
        XCTAssertEqual(outcome, .updated)
        let refreshed = try XCTUnwrap(store.modelsByProvider["claude_code"])
        XCTAssertEqual(
            GaryxThreadModelOverridePresentation.modelLabel(
                providerModels: refreshed,
                model: "claude-opus-5"
            ),
            "Claude Opus 5"
        )
        XCTAssertEqual(
            GaryxThreadModelOverridePresentation.reasoningEffortPickerOptions(
                providerModels: refreshed,
                model: "claude-opus-5",
                effectiveReasoningEffort: "max",
                defaultRowLabel: "Agent default"
            ).map(\.id),
            ["", "low", "high", "max"]
        )
    }

    func testConcurrentRefreshesShareOneInFlightRequest() async throws {
        let gate = ProviderCatalogLoadGate()
        let store = GaryxProviderModelCatalogStore()
        let models = try providerModels(healthyCatalogJSON)

        let first = Task {
            await store.refresh(providerType: "claude_code") {
                await gate.load()
            }
        }
        let firstRequestStarted = await waitForCallCount(1, gate: gate)
        XCTAssertTrue(firstRequestStarted)
        let second = Task {
            await store.refresh(providerType: "claude_code") {
                XCTFail("a concurrent waiter must reuse the existing request")
                return models
            }
        }
        await Task.yield()
        let callsWhileInFlight = await gate.callCount
        XCTAssertEqual(callsWhileInFlight, 1)

        await gate.resume(models)
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let finalCallCount = await gate.callCount
        XCTAssertEqual(firstOutcome, .updated)
        XCTAssertEqual(secondOutcome, .updated)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(store.modelsByProvider["claude_code"], models)
    }

    func testGatewayResetClearsSnapshotAndFencesLateResponse() async throws {
        let gate = ProviderCatalogLoadGate()
        let store = GaryxProviderModelCatalogStore()
        let models = try providerModels(healthyCatalogJSON)

        _ = await store.refresh(providerType: "claude_code") { models }
        let stale = Task {
            await store.refresh(providerType: "claude_code") {
                await gate.load()
            }
        }
        let staleRequestStarted = await waitForCallCount(1, gate: gate)
        XCTAssertTrue(staleRequestStarted)

        store.reset()
        XCTAssertTrue(store.modelsByProvider.isEmpty)
        await gate.resume(models)

        let staleOutcome = await stale.value
        XCTAssertEqual(staleOutcome, .superseded)
        XCTAssertTrue(store.modelsByProvider.isEmpty)
    }

    private func waitForCallCount(
        _ expected: Int,
        gate: ProviderCatalogLoadGate
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await gate.callCount >= expected {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func providerModels(_ json: String) throws -> GaryxProviderModels {
        try JSONDecoder().decode(GaryxProviderModels.self, from: Data(json.utf8))
    }

    private func capturedDegradedProviderModels() throws -> GaryxProviderModels {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "provider-models-claude-code-degraded",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(GaryxProviderModels.self, from: Data(contentsOf: url))
    }

    private let healthyCatalogJSON = """
    {
        "provider_type": "claude_code",
        "supports_model_selection": true,
        "models": [
            {
                "id": "claude-opus-5",
                "label": "Claude Opus 5",
                "recommended": true,
                "supported_reasoning_efforts": [
                    { "id": "low", "label": "Low", "recommended": false },
                    { "id": "high", "label": "High", "recommended": true },
                    { "id": "max", "label": "Max", "recommended": false }
                ]
            }
        ],
        "supports_reasoning_effort_selection": true,
        "reasoning_efforts": [
            { "id": "low", "label": "Low", "recommended": false },
            { "id": "high", "label": "High", "recommended": true },
            { "id": "max", "label": "Max", "recommended": false }
        ],
        "supports_service_tier_selection": false,
        "service_tiers": [],
        "default_model": "claude-opus-5",
        "source": "claude_code_discovery"
    }
    """
}

private enum CatalogTestError: Error {
    case failed
}

private actor ProviderCatalogLoadGate {
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<GaryxProviderModels, Never>] = []

    func load() async -> GaryxProviderModels {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(_ models: GaryxProviderModels) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: models)
    }
}
