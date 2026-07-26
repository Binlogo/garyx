import Combine
import SwiftUI
import UIKit
import XCTest
@testable import GaryxMobile

/// Diagnostic probe for the "browse a while, then the composer stops accepting
/// taps" report: drives the production coordinator + real UIKit adapter
/// through browse-time event sequences (scene interruptions, route commit and
/// terminal orderings, canonical-top flips) and asserts the composer always
/// returns to an input-ready state.
@MainActor
final class GaryxComposerBrowseFocusProbeTests: XCTestCase {
    private struct Harness {
        let directory: URL
        let coordinator: GaryxComposerPayloadCoordinator
        let adapter: GaryxComposerOrderedTextView
        let occurrenceID: GaryxRouteInstanceID
        let key: GaryxComposerKey
        let scope: GaryxGatewayScope
    }

    private func makeThreadHarness(
        threadID: String = "probe-thread"
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("garyx-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = try GaryxComposerPayloadCoordinator(
            applicationSupportDirectory: directory
        )
        let scope = GaryxGatewayScope(identity: "probe-gateway", epoch: 1)
        let key = GaryxComposerKey.thread(threadID)
        await coordinator.activate(scope: scope, key: key)
        let occurrenceID = GaryxRouteInstanceID(rawValue: "probe-occurrence")
        let adapter = makeWiredAdapter(
            coordinator: coordinator,
            occurrenceID: occurrenceID,
            key: key
        )
        coordinator.register(adapter, isCanonicalTop: true)
        return Harness(
            directory: directory,
            coordinator: coordinator,
            adapter: adapter,
            occurrenceID: occurrenceID,
            key: key,
            scope: scope
        )
    }

    /// Real production wiring: ordered text and producer-terminal callbacks
    /// reach the coordinator exactly as GaryxComposerUIKitField installs them.
    private func makeWiredAdapter(
        coordinator: GaryxComposerPayloadCoordinator,
        occurrenceID: GaryxRouteInstanceID,
        key: GaryxComposerKey
    ) -> GaryxComposerOrderedTextView {
        let adapter = GaryxComposerOrderedTextView(
            occurrenceID: occurrenceID,
            composerKey: key
        )
        adapter.onOrderedText = { [weak coordinator] text, identity in
            coordinator?.acceptText(text, identity: identity)
        }
        adapter.onProducerTerminal = { [weak coordinator] producer in
            coordinator?.producerReachedTerminal(producer, occurrenceID: occurrenceID)
        }
        return adapter
    }

    /// Waits for the asynchronous activation/finalization pipeline (real
    /// SQLite persistence) to settle, then asserts the composer accepts
    /// input again. Polling, not a fixed yield count: the durable close and
    /// the re-activation both run on background persistence turns.
    private func assertInputReady(
        _ harness: Harness,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if harness.coordinator.inputConfiguration()?.isReadOnly == false,
               harness.adapter.isLive,
               harness.adapter.isEditable,
               harness.adapter.isInputReady {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let configuration = harness.coordinator.inputConfiguration()
        XCTAssertNotNil(configuration, "\(label): coordinator lost its configuration", file: file, line: line)
        XCTAssertEqual(
            configuration?.isReadOnly, false,
            "\(label): configuration stuck read-only", file: file, line: line
        )
        XCTAssertTrue(harness.adapter.isLive, "\(label): adapter not live", file: file, line: line)
        XCTAssertTrue(harness.adapter.isEditable, "\(label): adapter not editable", file: file, line: line)
        XCTAssertTrue(harness.adapter.isInputReady, "\(label): adapter not input-ready", file: file, line: line)
    }

    private func drainMainActor(_ turns: Int = 20) async {
        for _ in 0..<turns { await Task.yield() }
    }

    func testBaselineThreadComposerIsInputReady() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await assertInputReady(harness, "baseline")
    }

    /// Scene inactive/active cycle exactly as handleScenePhase wires it.
    func testSceneCycleWhileBrowsingRestoresInput() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        for round in 1...3 {
            harness.coordinator.sceneDidBecomeInactive()
            harness.coordinator.cancelPendingInput(.sceneInactive)
            await drainMainActor()
            harness.coordinator.sceneDidBecomeActive()
            await drainMainActor()
            await assertInputReady(harness, "scene cycle round \(round)")
        }
    }

    /// Scene cycle racing the initial activation await.
    func testSceneCycleDuringActivationRestoresInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("garyx-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try GaryxComposerPayloadCoordinator(
            applicationSupportDirectory: directory
        )
        let scope = GaryxGatewayScope(identity: "probe-gateway", epoch: 1)
        let key = GaryxComposerKey.thread("race-thread")
        let occurrenceID = GaryxRouteInstanceID(rawValue: "race-occurrence")
        let adapter = makeWiredAdapter(
            coordinator: coordinator,
            occurrenceID: occurrenceID,
            key: key
        )

        let activation = Task { await coordinator.activate(scope: scope, key: key) }
        coordinator.sceneDidBecomeInactive()
        coordinator.cancelPendingInput(.sceneInactive)
        coordinator.sceneDidBecomeActive()
        await activation.value
        coordinator.register(adapter, isCanonicalTop: true)
        await drainMainActor()

        let harness = Harness(
            directory: directory, coordinator: coordinator, adapter: adapter,
            occurrenceID: occurrenceID, key: key, scope: scope
        )
        await assertInputReady(harness, "scene cycle during activation")
    }

    /// Interactive-back COMMIT away from the thread, then push back into the
    /// same thread: the second visit must be input-ready.
    func testCommitAwayThenReturnRestoresInput() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        // Pop commit: thread -> home (home has no composer key).
        harness.coordinator.routeCommitReleased(
            sourceOccurrenceID: harness.occurrenceID,
            sourceKey: harness.key,
            destinationOccurrenceID: nil,
            destinationKey: nil
        )
        harness.coordinator.routeReachedTerminal(
            GaryxPresentationTerminalState(outcome: .committed, visibility: .visible)
        )
        await drainMainActor(60)

        // Push back into the same thread (new occurrence), as the container
        // does: commitReleased(home -> thread) then terminal then activate.
        let secondOccurrence = GaryxRouteInstanceID(rawValue: "probe-occurrence-2")
        let secondAdapter = makeWiredAdapter(
            coordinator: harness.coordinator,
            occurrenceID: secondOccurrence,
            key: harness.key
        )
        harness.coordinator.routeCommitReleased(
            sourceOccurrenceID: nil,
            sourceKey: nil,
            destinationOccurrenceID: secondOccurrence,
            destinationKey: harness.key
        )
        harness.coordinator.register(secondAdapter, isCanonicalTop: true)
        harness.coordinator.routeReachedTerminal(
            GaryxPresentationTerminalState(outcome: .committed, visibility: .visible)
        )
        await drainMainActor(60)

        let second = Harness(
            directory: harness.directory, coordinator: harness.coordinator,
            adapter: secondAdapter, occurrenceID: secondOccurrence,
            key: harness.key, scope: harness.scope
        )
        await assertInputReady(second, "return visit")
    }

    /// Interactive-back gesture CANCELLED mid-browse (started then abandoned):
    /// no commit was released, but the container publishes a cancelled
    /// terminal. The still-visible thread must stay input-ready.
    func testCancelledBackGestureKeepsInputReady() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.coordinator.routeReachedTerminal(
            GaryxPresentationTerminalState(outcome: .cancelled, visibility: .visible)
        )
        await drainMainActor()
        await assertInputReady(harness, "cancelled back gesture")

        // And a scene cycle right after the cancel.
        harness.coordinator.sceneDidBecomeInactive()
        harness.coordinator.cancelPendingInput(.sceneInactive)
        harness.coordinator.sceneDidBecomeActive()
        await drainMainActor()
        await assertInputReady(harness, "scene cycle after cancelled gesture")
    }

    /// Commit-released back gesture whose terminal never arrives (container
    /// torn down / interrupted mid-settle), then the user lands in the thread
    /// again. This must not permanently brick the composer.
    func testCommitWithoutTerminalThenReactivateRestoresInput() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.coordinator.routeCommitReleased(
            sourceOccurrenceID: harness.occurrenceID,
            sourceKey: harness.key,
            destinationOccurrenceID: nil,
            destinationKey: nil
        )
        // Terminal never arrives. User later re-enters the thread; the stack
        // re-activates the composer key.
        await drainMainActor(40)
        await harness.coordinator.activate(scope: harness.scope, key: harness.key)
        let secondOccurrence = GaryxRouteInstanceID(rawValue: "probe-occurrence-2")
        let secondAdapter = makeWiredAdapter(
            coordinator: harness.coordinator,
            occurrenceID: secondOccurrence,
            key: harness.key
        )
        harness.coordinator.register(secondAdapter, isCanonicalTop: true)
        await drainMainActor(40)

        let second = Harness(
            directory: harness.directory, coordinator: harness.coordinator,
            adapter: secondAdapter, occurrenceID: secondOccurrence,
            key: harness.key, scope: harness.scope
        )
        await assertInputReady(second, "reactivate after missing terminal")
    }

    /// Canonical-top flip while browsing (route context refresh publishes a
    /// non-top frame then returns to top) must re-grant the adapter.
    func testCanonicalTopFlipRestoresInput() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.coordinator.register(harness.adapter, isCanonicalTop: false)
        await drainMainActor()
        harness.coordinator.register(harness.adapter, isCanonicalTop: true)
        await drainMainActor()
        await assertInputReady(harness, "canonical top flip")
    }

    /// The full user path behind "browsed a while, now the composer won't
    /// accept taps": pushing INTO a thread also tracks a route activation
    /// (sourceKey == nil branch). If the renderer never delivers that
    /// transition's terminal, advance never runs, the thread key is never
    /// activated, and the composer is dead from the moment the thread opens.
    /// Leaving and re-entering the thread must recover.
    func testPushIntoThreadWithLostTerminalRecoversOnReentry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("garyx-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try GaryxComposerPayloadCoordinator(
            applicationSupportDirectory: directory
        )
        let scope = GaryxGatewayScope(identity: "probe-gateway", epoch: 1)
        let key = GaryxComposerKey.thread("probe-thread")
        // Production invariant: the app activates the home/new-thread draft
        // before any thread push, so the active gateway scope is installed.
        await coordinator.activate(scope: scope, key: .draft("home-draft"))

        // Push home -> thread commits, but the terminal is lost.
        let occurrenceID = GaryxRouteInstanceID(rawValue: "probe-occurrence")
        coordinator.routeCommitReleased(
            sourceOccurrenceID: nil,
            sourceKey: nil,
            destinationOccurrenceID: occurrenceID,
            destinationKey: key
        )
        let adapter = makeWiredAdapter(
            coordinator: coordinator,
            occurrenceID: occurrenceID,
            key: key
        )
        coordinator.register(adapter, isCanonicalTop: true)
        await drainMainActor(40)
        // The stalled activation means the thread key is never activated:
        // the conversation composer renders its non-interactive fallback and
        // the registered adapter stays read-only — the reported symptom
        // while the user browses the freshly opened thread.
        XCTAssertFalse(coordinator.routeKeyMatchesActiveSession(key))
        XCTAssertFalse(adapter.isInputReady)
        XCTAssertFalse(adapter.isLive)

        // User leaves (new pop commit) and re-enters the thread.
        coordinator.routeCommitReleased(
            sourceOccurrenceID: occurrenceID,
            sourceKey: nil,
            destinationOccurrenceID: nil,
            destinationKey: nil
        )
        coordinator.routeReachedTerminal(
            GaryxPresentationTerminalState(outcome: .committed, visibility: .visible)
        )
        await drainMainActor(40)
        let secondOccurrence = GaryxRouteInstanceID(rawValue: "probe-occurrence-2")
        coordinator.routeCommitReleased(
            sourceOccurrenceID: nil,
            sourceKey: nil,
            destinationOccurrenceID: secondOccurrence,
            destinationKey: key
        )
        let secondAdapter = makeWiredAdapter(
            coordinator: coordinator,
            occurrenceID: secondOccurrence,
            key: key
        )
        coordinator.register(secondAdapter, isCanonicalTop: true)
        coordinator.routeReachedTerminal(
            GaryxPresentationTerminalState(outcome: .committed, visibility: .visible)
        )
        await drainMainActor(60)

        let second = Harness(
            directory: directory, coordinator: coordinator, adapter: secondAdapter,
            occurrenceID: secondOccurrence, key: key, scope: scope
        )
        await assertInputReady(second, "re-entry after lost push terminal")
    }

    /// Scene reactivation must also settle an abandoned activation so a
    /// backgrounded-and-returned app recovers without any navigation.
    func testSceneReactivationSettlesAbandonedActivation() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        // A pop away commits but its terminal is lost.
        harness.coordinator.routeCommitReleased(
            sourceOccurrenceID: harness.occurrenceID,
            sourceKey: harness.key,
            destinationOccurrenceID: nil,
            destinationKey: nil
        )
        await drainMainActor(40)

        // The user backgrounds and returns; a later activation (route stack
        // reactivating the visible key) must run instead of queueing forever.
        harness.coordinator.sceneDidBecomeInactive()
        harness.coordinator.cancelPendingInput(.sceneInactive)
        await drainMainActor(20)
        harness.coordinator.sceneDidBecomeActive()
        await drainMainActor(40)
        await harness.coordinator.activate(scope: harness.scope, key: harness.key)
        let secondOccurrence = GaryxRouteInstanceID(rawValue: "probe-occurrence-2")
        let secondAdapter = makeWiredAdapter(
            coordinator: harness.coordinator,
            occurrenceID: secondOccurrence,
            key: harness.key
        )
        harness.coordinator.register(secondAdapter, isCanonicalTop: true)
        await drainMainActor(40)

        let second = Harness(
            directory: harness.directory, coordinator: harness.coordinator,
            adapter: secondAdapter, occurrenceID: secondOccurrence,
            key: harness.key, scope: harness.scope
        )
        await assertInputReady(second, "scene reactivation settle")
    }

    /// Scene cycle interleaved with a canonical-top flip: the inactive freeze
    /// lands between the non-top revoke and the top re-grant.
    func testSceneCycleInterleavedWithTopFlipRestoresInput() async throws {
        let harness = try await makeThreadHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.coordinator.register(harness.adapter, isCanonicalTop: false)
        harness.coordinator.sceneDidBecomeInactive()
        harness.coordinator.cancelPendingInput(.sceneInactive)
        await drainMainActor()
        harness.coordinator.sceneDidBecomeActive()
        harness.coordinator.register(harness.adapter, isCanonicalTop: true)
        await drainMainActor()
        await assertInputReady(harness, "scene cycle interleaved with top flip")
    }
}
