import Foundation

/// Plans which transcript rows are laid out and which collapse into
/// exact-height spacers.
///
/// Measured cost, not theory: with an eager stack every layout pass sizes
/// every resident row, so a 60-row window spent 98.9% of the main thread
/// during streaming even after row bodies stopped rebuilding — SwiftUI layout
/// (`sizeThatFits`) became the top hotspot (#TASK-2703 baseline, #TASK-2704
/// retest). Cutting the laid-out row count is the remaining lever.
///
/// Three hard rules keep the existing scroll contracts intact:
///
/// 1. **Only measured rows may collapse**, and a run's height is the sum of
///    the rows' own measured HEIGHTS plus the stack spacing the collapse
///    removes. Heights are intrinsic: a collapsed row's content does not
///    change, so its cached height stays valid however much the layout above
///    it moves. Deriving the height from position differences instead
///    (successor `minY` minus run-start `minY`) silently mixes two layout
///    generations, because a collapsed row stops reporting its position while
///    live rows keep updating theirs — review #TASK-2707 BLOCKER-2. Nothing
///    is ever estimated either way: estimated heights are what broke
///    `defaultScrollAnchor(.bottom)` in the reverted v1 attempt.
/// 2. **The tail and the reading window always render.** The tail rows own
///    bottom anchoring and streaming; rows within the viewport plus an
///    overscan margin own the reader's experience. Only fully off-screen,
///    already-measured runs collapse.
/// 3. **The plan never decides what exists.** It only proposes which rows
///    collapse; the view renders from the row list and treats an unmentioned
///    row as live, so a stale plan can delay a collapse but can never hide
///    content — review #TASK-2707 BLOCKER-1.
public struct GaryxTranscriptWindowPlanner: Equatable, Sendable {
    /// One entry of the planned layout, in order.
    public enum Segment: Equatable, Sendable {
        /// Lay this row out normally.
        case row(id: String)
        /// Replace a contiguous run of collapsed rows with a spacer of
        /// exactly the height they occupied.
        case spacer(height: CGFloat, collapsedRowIDs: [String])
    }

    public struct Input: Equatable, Sendable {
        /// Row ids in transcript order (oldest first).
        public var rowIDs: [String]
        /// Content-space `minY` per row, for rows measured at least once.
        /// Used to place rows against the viewport, never to derive heights.
        public var measuredMinY: [String: CGFloat]
        /// Measured height per row. A row may only collapse when its own
        /// height is known.
        public var measuredHeight: [String: CGFloat]
        /// Spacing the enclosing stack puts between rows. Collapsing N rows
        /// into one spacer removes N-1 of those gaps.
        public var rowSpacing: CGFloat
        /// Content-space Y of the viewport's top edge.
        public var viewportTopInContent: CGFloat
        public var viewportHeight: CGFloat
        /// Extra margin kept live above and below the viewport.
        public var overscan: CGFloat
        /// Trailing rows that always render (bottom anchoring, streaming).
        public var pinnedTailRowCount: Int
        /// Leading rows that always render while older history can load, so
        /// the prepend boundary and its reading anchor stay measurable.
        public var pinnedLeadingRowCount: Int
        /// Set when a reading-anchor restore is in flight: collapsing anything
        /// during a prepend would move the ruler the restore depends on.
        public var suspendsCollapsing: Bool

        public init(
            rowIDs: [String],
            measuredMinY: [String: CGFloat],
            measuredHeight: [String: CGFloat],
            rowSpacing: CGFloat,
            viewportTopInContent: CGFloat,
            viewportHeight: CGFloat,
            overscan: CGFloat,
            pinnedTailRowCount: Int = 8,
            pinnedLeadingRowCount: Int = 2,
            suspendsCollapsing: Bool = false
        ) {
            self.rowIDs = rowIDs
            self.measuredMinY = measuredMinY
            self.measuredHeight = measuredHeight
            self.rowSpacing = rowSpacing
            self.viewportTopInContent = viewportTopInContent
            self.viewportHeight = viewportHeight
            self.overscan = overscan
            self.pinnedTailRowCount = pinnedTailRowCount
            self.pinnedLeadingRowCount = pinnedLeadingRowCount
            self.suspendsCollapsing = suspendsCollapsing
        }
    }

    public init() {}

    /// Rows whose measured span intersects the viewport plus overscan, plus
    /// the pinned leading/tail rows, render; every other maximal run of
    /// consecutive measured rows collapses into one exact-height spacer.
    public static func plan(_ input: Input) -> [Segment] {
        let rowIDs = input.rowIDs
        guard !rowIDs.isEmpty else { return [] }
        guard !input.suspendsCollapsing, input.viewportHeight > 0 else {
            return rowIDs.map { .row(id: $0) }
        }

        let liveTop = input.viewportTopInContent - max(0, input.overscan)
        let liveBottom = input.viewportTopInContent + input.viewportHeight
            + max(0, input.overscan)
        let pinnedLeadingUpperBound = max(0, input.pinnedLeadingRowCount)
        let pinnedTailLowerBound = rowIDs.count - max(0, input.pinnedTailRowCount)

        // A row may collapse only when both its position and its own height
        // are known: the position decides whether it is off-screen, the height
        // is what the spacer replaces.
        var collapsible = [Bool](repeating: false, count: rowIDs.count)
        for (index, rowID) in rowIDs.enumerated() {
            guard index >= pinnedLeadingUpperBound, index < pinnedTailLowerBound else {
                continue
            }
            guard let minY = input.measuredMinY[rowID],
                  let height = input.measuredHeight[rowID] else {
                continue
            }
            // Fully outside the live band, in either direction.
            collapsible[index] = (minY + height) <= liveTop || minY >= liveBottom
        }

        var segments: [Segment] = []
        var index = 0
        while index < rowIDs.count {
            guard collapsible[index] else {
                segments.append(.row(id: rowIDs[index]))
                index += 1
                continue
            }
            let runStart = index
            var runEnd = index
            while runEnd + 1 < rowIDs.count, collapsible[runEnd + 1] {
                runEnd += 1
            }
            // Height of the whole run: the rows' own measured heights plus
            // the stack gaps the collapse removes (N rows become 1 view, so
            // N-1 gaps disappear). Both terms are generation-independent.
            let collapsedIDs = Array(rowIDs[runStart...runEnd])
            let heights = collapsedIDs.compactMap { input.measuredHeight[$0] }
            let height = heights.reduce(0, +)
                + CGFloat(max(0, collapsedIDs.count - 1)) * max(0, input.rowSpacing)
            if height > 0, heights.count == collapsedIDs.count {
                segments.append(
                    .spacer(height: height, collapsedRowIDs: collapsedIDs)
                )
            } else {
                // Degenerate measurement: render rather than risk a height of
                // zero collapsing real content.
                for rowIndex in runStart...runEnd {
                    segments.append(.row(id: rowIDs[rowIndex]))
                }
            }
            index = runEnd + 1
        }
        return segments
    }

    /// Rows the plan lays out, in order. Diagnostic/test projection: the view
    /// walks its own row list and consults the plan only for collapses, so it
    /// never depends on this.
    public static func renderedRowIDs(_ segments: [Segment]) -> [String] {
        segments.compactMap { segment in
            switch segment {
            case .row(let id):
                return id
            case .spacer:
                return nil
            }
        }
    }

    /// Total collapsed height, for assertions and diagnostics.
    public static func collapsedHeight(_ segments: [Segment]) -> CGFloat {
        segments.reduce(into: 0) { total, segment in
            if case .spacer(let height, _) = segment {
                total += height
            }
        }
    }
}
