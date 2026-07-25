import XCTest
@testable import GaryxMobileCore

/// Contract for transcript row windowing.
///
/// The planner exists to cut the number of laid-out rows (SwiftUI layout is
/// the top remaining hotspot: 98.9% main-thread occupancy during streaming
/// even after row bodies stopped rebuilding — #TASK-2704). It must do so
/// without ever estimating a height, because estimated heights are what broke
/// bottom anchoring in the reverted v1 attempt.
final class GaryxTranscriptWindowPlannerTests: XCTestCase {
    /// 20 rows, 100pt tall each, laid out from content-space y = 0.
    private func uniformInput(
        rowCount: Int = 20,
        rowHeight: CGFloat = 100,
        measuredRows: Range<Int>? = nil,
        viewportTopInContent: CGFloat,
        viewportHeight: CGFloat = 800,
        overscan: CGFloat = 200,
        pinnedTailRowCount: Int = 3,
        pinnedLeadingRowCount: Int = 1,
        suspendsCollapsing: Bool = false
    ) -> GaryxTranscriptWindowPlanner.Input {
        let ids = (0..<rowCount).map { "row-\($0)" }
        var measured: [String: CGFloat] = [:]
        var heights: [String: CGFloat] = [:]
        for index in measuredRows ?? 0..<rowCount {
            measured[ids[index]] = CGFloat(index) * rowHeight
            heights[ids[index]] = rowHeight
        }
        return .init(
            rowIDs: ids,
            measuredMinY: measured,
            measuredHeight: heights,
            rowSpacing: 0,
            viewportTopInContent: viewportTopInContent,
            viewportHeight: viewportHeight,
            overscan: overscan,
            pinnedTailRowCount: pinnedTailRowCount,
            pinnedLeadingRowCount: pinnedLeadingRowCount,
            suspendsCollapsing: suspendsCollapsing
        )
    }

    func testCollapsedHeightExactlyReplacesTheRowsItHides() {
        // Reader parked at the bottom of a 20x100pt transcript.
        let input = uniformInput(viewportTopInContent: 1_200)
        let segments = GaryxTranscriptWindowPlanner.plan(input)
        let rendered = GaryxTranscriptWindowPlanner.renderedRowIDs(segments)

        XCTAssertLessThan(rendered.count, 20, "off-screen rows must collapse")
        // Total height is preserved exactly: collapsed spacers plus rendered
        // rows must equal the original content height, or every scroll
        // position and the bottom anchor would shift.
        let collapsedRows = 20 - rendered.count
        XCTAssertEqual(
            GaryxTranscriptWindowPlanner.collapsedHeight(segments),
            CGFloat(collapsedRows) * 100,
            accuracy: 0.001
        )
    }

    func testRowsInsideViewportAndOverscanAlwaysRender() {
        let input = uniformInput(viewportTopInContent: 900)
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        // Viewport covers 900..1700, overscan widens it to 700..1900:
        // rows 7 through 18 by construction.
        for index in 7...18 {
            XCTAssertTrue(rendered.contains("row-\(index)"), "row-\(index) is live")
        }
    }

    func testPinnedTailAlwaysRendersEvenWhenScrolledFarAway() {
        // Reader at the very top; the tail is far below the live band.
        let input = uniformInput(viewportTopInContent: 0)
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        for index in 17...19 {
            XCTAssertTrue(
                rendered.contains("row-\(index)"),
                "the tail owns bottom anchoring and must stay laid out"
            )
        }
    }

    func testPinnedLeadingRowsAlwaysRenderForThePrependBoundary() {
        let input = uniformInput(viewportTopInContent: 1_200)
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        XCTAssertTrue(rendered.contains("row-0"), "history boundary stays measurable")
    }

    func testUnmeasuredRowsNeverCollapse() {
        // Rows 5...9 were never measured (cold open never laid them out).
        var input = uniformInput(viewportTopInContent: 1_500)
        for index in 5...9 {
            input.measuredMinY.removeValue(forKey: "row-\(index)")
            input.measuredHeight.removeValue(forKey: "row-\(index)")
        }
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        for index in 5...9 {
            XCTAssertTrue(
                rendered.contains("row-\(index)"),
                "collapsing an unmeasured row would require estimating its height"
            )
        }
    }

    func testRowWithoutAMeasuredHeightNeverCollapses() {
        // A row's own height is what the spacer replaces.
        var input = uniformInput(viewportTopInContent: 1_500)
        input.measuredHeight.removeValue(forKey: "row-4")
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        XCTAssertTrue(rendered.contains("row-4"), "no height means no spacer")
    }

    func testCollapsedHeightUsesRowHeightsAndTheGapsItRemoves() {
        // Heights are intrinsic and generation-independent; collapsing N rows
        // into one view also removes N-1 stack gaps (review #TASK-2707
        // BLOCKER-2 rejected deriving this from position differences).
        let ids = (0..<10).map { "row-\($0)" }
        var minY: [String: CGFloat] = [:]
        var heights: [String: CGFloat] = [:]
        for (index, id) in ids.enumerated() {
            minY[id] = CGFloat(index) * 114
            heights[id] = 100
        }
        let input = GaryxTranscriptWindowPlanner.Input(
            rowIDs: ids,
            measuredMinY: minY,
            measuredHeight: heights,
            rowSpacing: 14,
            viewportTopInContent: 900,
            viewportHeight: 300,
            overscan: 0,
            pinnedTailRowCount: 1,
            pinnedLeadingRowCount: 0
        )
        let segments = GaryxTranscriptWindowPlanner.plan(input)
        guard case .spacer(let height, let collapsed) = segments.first else {
            return XCTFail("leading off-screen run must collapse")
        }
        XCTAssertEqual(
            height,
            CGFloat(collapsed.count) * 100 + CGFloat(collapsed.count - 1) * 14,
            accuracy: 0.001
        )
    }

    func testStaleUpstreamGrowthDoesNotChangeACollapsedRunsHeight() {
        // The exact BLOCKER-2 scenario: a live row above grows, so every
        // position below shifts, but the collapsed run's height must not move.
        let ids = (0..<12).map { "row-\($0)" }
        var minY: [String: CGFloat] = [:]
        var heights: [String: CGFloat] = [:]
        for (index, id) in ids.enumerated() {
            minY[id] = CGFloat(index) * 100
            heights[id] = 100
        }
        let before = GaryxTranscriptWindowPlanner.Input(
            rowIDs: ids,
            measuredMinY: minY,
            measuredHeight: heights,
            rowSpacing: 0,
            viewportTopInContent: 900,
            viewportHeight: 200,
            overscan: 0,
            pinnedTailRowCount: 1,
            pinnedLeadingRowCount: 0
        )
        let heightBefore = GaryxTranscriptWindowPlanner.collapsedHeight(
            GaryxTranscriptWindowPlanner.plan(before)
        )

        // A live row gained 300pt: only rendered rows re-report, so the
        // collapsed rows keep their (still correct) heights.
        var after = before
        after.measuredMinY["row-11"] = 1_400
        let heightAfter = GaryxTranscriptWindowPlanner.collapsedHeight(
            GaryxTranscriptWindowPlanner.plan(after)
        )
        XCTAssertEqual(heightBefore, heightAfter, accuracy: 0.001)
    }

    func testProductionPinnedBudgetsKeepTheTailAndBoundaryLive() {
        // Guard the values the transcript actually passes (review N1).
        let input = uniformInput(
            rowCount: 60,
            viewportTopInContent: 0,
            pinnedTailRowCount: 6,
            pinnedLeadingRowCount: 2
        )
        let rendered = Set(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            )
        )
        for index in 54...59 {
            XCTAssertTrue(rendered.contains("row-\(index)"))
        }
        XCTAssertTrue(rendered.contains("row-0"))
        XCTAssertTrue(rendered.contains("row-1"))
    }

    func testSuspendedCollapsingRendersEverything() {
        // A reading-anchor restore is in flight: collapsing would move the
        // ruler the restore measures against.
        let input = uniformInput(viewportTopInContent: 1_200, suspendsCollapsing: true)
        XCTAssertEqual(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            ).count,
            20
        )
        XCTAssertEqual(
            GaryxTranscriptWindowPlanner.collapsedHeight(
                GaryxTranscriptWindowPlanner.plan(input)
            ),
            0
        )
    }

    func testUnmeasuredViewportRendersEverything() {
        let input = uniformInput(viewportTopInContent: 0, viewportHeight: 0)
        XCTAssertEqual(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            ).count,
            20
        )
    }

    func testCollapsedRunsAreContiguousAndOrderIsPreserved() {
        let input = uniformInput(rowCount: 40, viewportTopInContent: 2_000)
        let segments = GaryxTranscriptWindowPlanner.plan(input)

        // Order: flattening the plan must reproduce the transcript order.
        var flattened: [String] = []
        for segment in segments {
            switch segment {
            case .row(let id):
                flattened.append(id)
            case .spacer(_, let collapsed):
                flattened.append(contentsOf: collapsed)
            }
        }
        XCTAssertEqual(flattened, input.rowIDs)

        // No two spacers may sit next to each other: runs are maximal.
        for (lhs, rhs) in zip(segments, segments.dropFirst()) {
            if case .spacer = lhs, case .spacer = rhs {
                XCTFail("adjacent spacers mean a run was not maximal")
            }
        }
    }

    func testEmptyTranscriptPlansNothing() {
        let input = GaryxTranscriptWindowPlanner.Input(
            rowIDs: [],
            measuredMinY: [:],
            measuredHeight: [:],
            rowSpacing: 14,
            viewportTopInContent: 0,
            viewportHeight: 800,
            overscan: 200
        )
        XCTAssertTrue(GaryxTranscriptWindowPlanner.plan(input).isEmpty)
    }

    func testShortTranscriptFullyPinnedRendersEverything() {
        // Fewer rows than the pinned leading + tail budget.
        let input = uniformInput(
            rowCount: 4,
            viewportTopInContent: 0,
            pinnedTailRowCount: 3,
            pinnedLeadingRowCount: 1
        )
        XCTAssertEqual(
            GaryxTranscriptWindowPlanner.renderedRowIDs(
                GaryxTranscriptWindowPlanner.plan(input)
            ).count,
            4
        )
    }

    func testVariableRowHeightsCollapseToTheirRealSpan() {
        // Rows of 50, 300, 120, 80... no stack spacing in this fixture.
        let ids = (0..<10).map { "row-\($0)" }
        let starts: [CGFloat] = [0, 50, 350, 470, 550, 900, 1_000, 1_400, 1_500, 1_800]
        var measured: [String: CGFloat] = [:]
        var heights: [String: CGFloat] = [:]
        for (index, id) in ids.enumerated() {
            measured[id] = starts[index]
            heights[id] = (index + 1 < starts.count ? starts[index + 1] : starts[index] + 100)
                - starts[index]
        }
        let input = GaryxTranscriptWindowPlanner.Input(
            rowIDs: ids,
            measuredMinY: measured,
            measuredHeight: heights,
            rowSpacing: 0,
            viewportTopInContent: 1_400,
            viewportHeight: 400,
            overscan: 0,
            pinnedTailRowCount: 1,
            pinnedLeadingRowCount: 0
        )
        let segments = GaryxTranscriptWindowPlanner.plan(input)
        // row-6 spans 1_000..1_400 and the viewport starts at 1_400, so it is
        // fully off-screen too: rows 0...6 collapse and the spacer equals the
        // span up to row-7's start — 1_400pt of real, variable-height content.
        guard case .spacer(let height, let collapsed) = segments.first else {
            return XCTFail("leading off-screen run must collapse")
        }
        XCTAssertEqual(height, 1_400, accuracy: 0.001)
        XCTAssertEqual(collapsed, Array(ids[0...6]))
    }
}
