import Foundation
import XCTest
@testable import GaryxMobileCore

final class GaryxCatalogRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testStaleGatedWithinTTLskips() {
        XCTAssertEqual(
            action(
                intent: .staleGated,
                lastCompleted: now.addingTimeInterval(-60)
            ),
            .skip
        )
    }

    func testStaleGatedPastTTLsweeps() {
        XCTAssertEqual(
            action(
                intent: .staleGated,
                lastCompleted: now.addingTimeInterval(-6 * 60)
            ),
            .startSweep
        )
    }

    func testStaleGatedWithNoHistorySweeps() {
        XCTAssertEqual(
            action(intent: .staleGated, lastCompleted: nil),
            .startSweep
        )
    }

    func testForcedAlwaysSweepsWhenIdle() {
        XCTAssertEqual(
            action(
                intent: .forced,
                lastCompleted: now.addingTimeInterval(-1)
            ),
            .startSweep
        )
    }

    func testAnyRequestDuringInFlightJoins() {
        for intent in [
            GaryxCatalogRefreshPolicy.Intent.forced,
            .staleGated,
        ] {
            XCTAssertEqual(
                action(
                    intent: intent,
                    lastCompleted: now.addingTimeInterval(-60),
                    isSweepInFlight: true
                ),
                .joinInFlight
            )
        }
    }

    func testTTLBoundaryIsExclusiveStale() {
        XCTAssertEqual(
            action(
                intent: .staleGated,
                lastCompleted: now.addingTimeInterval(
                    -GaryxCatalogRefreshPolicy.defaultTTL
                )
            ),
            .startSweep
        )
    }

    private func action(
        intent: GaryxCatalogRefreshPolicy.Intent,
        lastCompleted: Date?,
        isSweepInFlight: Bool = false
    ) -> GaryxCatalogRefreshPolicy.Action {
        GaryxCatalogRefreshPolicy.action(
            for: intent,
            now: now,
            lastSuccessfulSweepCompletedAt: lastCompleted,
            isSweepInFlight: isSweepInFlight
        )
    }
}
