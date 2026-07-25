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
/// Two hard rules keep the existing scroll contracts intact:
///
/// 1. **Only measured rows may collapse.** A collapsed run's height is derived
///    from real content-space measurements (`minY` of the row after the run
///    minus `minY` of the run's first row), which already includes inter-row
///    spacing. Nothing is ever estimated: estimated row heights are exactly
///    what broke `defaultScrollAnchor(.bottom)` and scroll-to-tail in the
///    reverted v1 attempt, because the synthetic bottom anchor landed inside
///    phantom space.
/// 2. **The tail and the reading window always render.** The tail rows own
///    bottom anchoring and streaming; rows within the viewport plus an
///    overscan margin own the reader's experience. Only fully off-screen,
///    already-measured runs collapse.
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
        public var measuredMinY: [String: CGFloat]
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
            viewportTopInContent: CGFloat,
            viewportHeight: CGFloat,
            overscan: CGFloat,
            pinnedTailRowCount: Int = 8,
            pinnedLeadingRowCount: Int = 2,
            suspendsCollapsing: Bool = false
        ) {
            self.rowIDs = rowIDs
            self.measuredMinY = measuredMinY
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

        // A row may collapse only when its own span AND its successor's start
        // are known, because the spacer height comes from those measurements.
        func spanEnd(after index: Int) -> CGFloat? {
            guard index + 1 < rowIDs.count else { return nil }
            return input.measuredMinY[rowIDs[index + 1]]
        }

        var collapsible = [Bool](repeating: false, count: rowIDs.count)
        for (index, rowID) in rowIDs.enumerated() {
            guard index >= pinnedLeadingUpperBound, index < pinnedTailLowerBound else {
                continue
            }
            guard let minY = input.measuredMinY[rowID], let end = spanEnd(after: index) else {
                continue
            }
            // Fully outside the live band, in either direction.
            collapsible[index] = end <= liveTop || minY >= liveBottom
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
            // Height of the whole run: from the first collapsed row's start to
            // the next rendered row's start. Content-space positions are
            // scroll-invariant, so this is exactly the space the run occupied,
            // spacing included.
            let start = input.measuredMinY[rowIDs[runStart]] ?? 0
            let end = spanEnd(after: runEnd) ?? start
            let height = max(0, end - start)
            if height > 0 {
                segments.append(
                    .spacer(
                        height: height,
                        collapsedRowIDs: Array(rowIDs[runStart...runEnd])
                    )
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

    /// Rows the plan lays out, in order — the projection the view needs.
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
