import UIKit
import XCTest

final class HomeChromeInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFilterMenuOpensFromCircleEdgeDismissesAndSelectsChats() throws {
        let app = launchHome()
        let filter = app.buttons["Recent filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "Recent filter button")
        XCTAssertEqual(filter.value as? String, "All")

        tapTrailingCircleEdge(filter)
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Chats"].exists)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        XCTAssertFalse(app.buttons["Chats"].waitForExistence(timeout: 1))

        tapTrailingCircleEdge(filter)
        let chats = app.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        chats.tap()

        XCTAssertEqual(filter.value as? String, "Chats")
    }

    func testFabEdgeTapOpensNewThreadDraft() throws {
        let app = launchHome()
        let fab = app.buttons["New chat"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "Home new-chat FAB")

        XCTAssertEqual(fab.frame.width, 56, accuracy: 1)
        XCTAssertEqual(fab.frame.height, 56, accuracy: 1)
        XCTAssertEqual(app.frame.maxX - fab.frame.maxX, 20, accuracy: 2)

        tapTrailingCircleEdge(fab)
        XCTAssertTrue(
            app.buttons["Back"].waitForExistence(timeout: 5),
            "the FAB edge must open the existing new-thread draft instead of passing through"
        )
    }

    func testThreadSearchMorphsInPlaceFocusesAndCancels() throws {
        let app = launchHome()
        let search = app.buttons["home-thread-search-button"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Home thread-search button")
        XCTAssertEqual(search.frame.width, 44, accuracy: 1)
        XCTAssertEqual(search.frame.height, 44, accuracy: 1)
        let collapsedFrame = search.frame
        let collapsedScreenshot = app.screenshot()

        search.tap()

        let field = app.textFields["home-thread-search-field"]
        let cancel = app.buttons["home-thread-search-cancel"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "expanded thread-search field")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "expanded thread-search Cancel button")
        XCTAssertLessThan(
            field.frame.minX,
            collapsedFrame.minX,
            "the field must expand leftward from the trailing search-button anchor"
        )
        XCTAssertGreaterThan(
            cancel.frame.minX,
            field.frame.maxX,
            "the expanded field and Cancel control must occupy one ordered chrome surface"
        )
        XCTAssertTrue(
            app.staticTexts["Search threads by name"].waitForExistence(timeout: 5),
            "an empty query must show the prompt state"
        )
        XCTAssertFalse(
            app.buttons["Clear search"].exists,
            "an empty search field must not expose a clear control"
        )

        // Reproduce the reported settled state instead of sampling a morph
        // frame. The collapsed icon itself supplies the pixel mask, so the
        // check follows the exact SF Symbol geometry rendered on this runtime.
        Thread.sleep(forTimeInterval: 1.5)
        let expandedScreenshot = app.screenshot()
        try assertNoCollapsedSearchGlyphResidue(
            collapsedScreenshot: collapsedScreenshot,
            expandedScreenshot: expandedScreenshot,
            collapsedFrame: collapsedFrame,
            appFrame: app.frame
        )

        let attachment = XCTAttachment(screenshot: expandedScreenshot)
        attachment.name = "Home thread search expanded"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Sending text through the application requires the field to already
        // own keyboard focus; spaces also prove the no-request prompt path.
        app.typeText("   ")
        XCTAssertEqual(field.value as? String, "   ")
        XCTAssertTrue(app.staticTexts["Search threads by name"].exists)

        cancel.tap()

        XCTAssertTrue(search.waitForExistence(timeout: 5), "collapsed thread-search button")
        XCTAssertTrue(
            app.staticTexts["Thread History"].waitForExistence(timeout: 5),
            "Cancel must restore the Home recency list"
        )
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Search threads by name"].exists)
        XCTAssertEqual(search.frame.midX, collapsedFrame.midX, accuracy: 1)
        XCTAssertEqual(search.frame.midY, collapsedFrame.midY, accuracy: 1)

        let collapsedAttachment = XCTAttachment(screenshot: app.screenshot())
        collapsedAttachment.name = "Home thread search collapsed"
        collapsedAttachment.lifetime = .keepAlways
        add(collapsedAttachment)

        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertNotEqual(
            field.value as? String,
            "   ",
            "Cancel must clear the query before the next expansion"
        )
    }

    func testFabBandClearAreaStillScrollsList() throws {
        let app = launchHome(useScrollFixture: true)
        let fab = app.buttons["New chat"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "Home new-chat FAB")

        let leadingRow = app.staticTexts["Synthetic thread 0"].firstMatch
        XCTAssertTrue(leadingRow.waitForExistence(timeout: 10), "top synthetic row")
        let initialMinY = leadingRow.frame.minY

        let startPoint = CGPoint(x: 40, y: fab.frame.midY)
        XCTAssertFalse(fab.frame.contains(startPoint), "gesture must begin in clear chrome")
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: startPoint.x, dy: startPoint.y)).press(
            forDuration: 0.1,
            thenDragTo: origin.withOffset(
                CGVector(dx: startPoint.x, dy: max(120, startPoint.y - 260))
            )
        )

        let deadline = Date().addingTimeInterval(5)
        while leadingRow.isHittable,
              leadingRow.frame.minY >= initialMinY - 40,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(
            !leadingRow.isHittable || leadingRow.frame.minY < initialMinY - 40,
            "clear space beside the FAB must leave the underlying List scroll gesture available"
        )
    }

    func testThreadActionsUseLongPressMenuInsteadOfSwipeActions() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 7"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "archiveable unpinned thread row")

        row.press(forDuration: 0.8)

        let pinAction = app.buttons["Pin thread"]
        XCTAssertTrue(
            pinAction.waitForExistence(timeout: 5),
            "long-pressing a thread must present the pin action"
        )
        XCTAssertTrue(
            app.buttons["Archive thread"].waitForExistence(timeout: 5),
            "long-pressing a thread must present the destructive archive action"
        )
        XCTAssertEqual(
            pinAction.frame.width / app.frame.width,
            0.565,
            accuracy: 0.025,
            "the compact menu must preserve the reference image's screen-width proportion"
        )
        XCTAssertEqual(pinAction.frame.height, 44, accuracy: 2)
    }

    func testThreadHorizontalSwipeDoesNotRevealActionsOrOpenThread() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 7"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "unpinned thread row")

        row.swipeLeft()

        XCTAssertFalse(app.buttons["Pin thread"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["Favorite thread"].exists)
        XCTAssertFalse(app.buttons["Archive thread"].exists)
        XCTAssertFalse(app.buttons["Back"].exists)
        XCTAssertTrue(row.exists)
    }

    func testThresholdLongPressPresentsMenuWithoutOpeningThread() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 7"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "archiveable unpinned thread row")

        // Releasing just after the 0.36s recognition threshold is the human
        // path that can satisfy both the row tap and the simultaneous long
        // press. A deliberately long 0.8s XCTest press masks that race.
        row.press(forDuration: 0.42)

        XCTAssertTrue(
            app.buttons["Pin thread"].waitForExistence(timeout: 3),
            "a threshold long press must keep the action menu visible"
        )
        XCTAssertFalse(
            app.buttons["Back"].exists,
            "releasing a recognized long press must not also open the thread"
        )
        XCTAssertTrue(row.exists, "the pressed Home row must stay on the Home surface")
    }

    func testThreadRowShortTapStillOpensThread() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 7"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "tappable synthetic thread row")

        row.tap()

        XCTAssertTrue(
            app.buttons["Back"].waitForExistence(timeout: 5),
            "an ordinary short tap must still open the selected thread"
        )
        XCTAssertFalse(app.buttons["Pin thread"].exists)
    }

    func testPinnedThreadPinButtonRemainsDirectActionWithoutOpeningThread() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "pinned synthetic thread row")

        let unpinButtons = app.buttons.matching(identifier: "Unpin thread")
        XCTAssertGreaterThan(unpinButtons.count, 0, "Home keeps the direct Unpin affordance")

        unpinButtons.firstMatch.tap()

        XCTAssertFalse(
            app.buttons["Back"].waitForExistence(timeout: 1),
            "the direct Unpin action must not also open the thread"
        )
        XCTAssertTrue(row.exists, "the direct Unpin action must keep the row on Home")
    }

    func testThreadRowDragStillScrollsWithoutOpeningOrPresentingMenu() throws {
        let app = launchHome(useScrollFixture: true)
        let row = app.staticTexts["Synthetic thread 0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "top synthetic thread row")
        let initialMinY = row.frame.minY
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        start.press(
            forDuration: 0.1,
            thenDragTo: origin.withOffset(
                CGVector(dx: row.frame.midX, dy: max(120, row.frame.midY - 280))
            )
        )

        let deadline = Date().addingTimeInterval(5)
        while row.isHittable,
              row.frame.minY >= initialMinY - 40,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(
            !row.isHittable || row.frame.minY < initialMinY - 40,
            "dragging from a thread row must preserve the List scroll gesture"
        )
        XCTAssertFalse(app.buttons["Back"].exists)
        XCTAssertFalse(app.buttons["Pin thread"].exists)
    }

    private func launchHome(useScrollFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GARYX_MOBILE_DEBUG_SNAPSHOT"] = "1"
        app.launchEnvironment["GARYX_MOBILE_DEBUG_SIDEBAR"] = "1"
        if useScrollFixture {
            app.launchEnvironment["GARYX_MOBILE_HOME_SCROLL_PROBE"] = "1"
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["Garyx"].waitForExistence(timeout: 15))
        return app
    }

    private func tapTrailingCircleEdge(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
    }

    private func assertNoCollapsedSearchGlyphResidue(
        collapsedScreenshot: XCUIScreenshot,
        expandedScreenshot: XCUIScreenshot,
        collapsedFrame: CGRect,
        appFrame: CGRect
    ) throws {
        let collapsedImage = try XCTUnwrap(collapsedScreenshot.image.cgImage)
        let expandedImage = try XCTUnwrap(expandedScreenshot.image.cgImage)
        XCTAssertEqual(collapsedImage.width, expandedImage.width)
        XCTAssertEqual(collapsedImage.height, expandedImage.height)

        let collapsedData = try XCTUnwrap(collapsedImage.dataProvider?.data)
        let expandedData = try XCTUnwrap(expandedImage.dataProvider?.data)
        let collapsedBytes = try XCTUnwrap(CFDataGetBytePtr(collapsedData))
        let expandedBytes = try XCTUnwrap(CFDataGetBytePtr(expandedData))
        let collapsedBytesPerPixel = collapsedImage.bitsPerPixel / 8
        let expandedBytesPerPixel = expandedImage.bitsPerPixel / 8
        guard collapsedBytesPerPixel >= 3, expandedBytesPerPixel >= 3 else {
            XCTFail("search screenshot pixel format has fewer than three color bytes")
            return
        }

        let scaleX = CGFloat(collapsedImage.width) / appFrame.width
        let scaleY = CGFloat(collapsedImage.height) / appFrame.height
        let minX = max(
            0,
            Int(floor((collapsedFrame.minX - appFrame.minX) * scaleX))
        )
        let maxX = min(
            collapsedImage.width - 1,
            Int(ceil((collapsedFrame.maxX - appFrame.minX) * scaleX)) - 1
        )
        let minY = max(
            0,
            Int(floor((collapsedFrame.minY - appFrame.minY) * scaleY))
        )
        let maxY = min(
            collapsedImage.height - 1,
            Int(ceil((collapsedFrame.maxY - appFrame.minY) * scaleY)) - 1
        )
        let referenceOffset = Int((collapsedFrame.width * scaleX).rounded())

        var sourceBrightness: CGFloat = 0
        var referenceBrightness: CGFloat = 0
        var maskPixelCount = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let collapsedIndex = y * collapsedImage.bytesPerRow
                    + x * collapsedBytesPerPixel
                let maskBrightness = (
                    CGFloat(collapsedBytes[collapsedIndex])
                        + CGFloat(collapsedBytes[collapsedIndex + 1])
                        + CGFloat(collapsedBytes[collapsedIndex + 2])
                ) / 3
                guard maskBrightness < 128 else { continue }

                let referenceX = x - referenceOffset
                guard referenceX >= 0 else {
                    XCTFail("search residue reference sample falls outside the screenshot")
                    return
                }
                let sourceIndex = y * expandedImage.bytesPerRow
                    + x * expandedBytesPerPixel
                let referenceIndex = y * expandedImage.bytesPerRow
                    + referenceX * expandedBytesPerPixel
                sourceBrightness += (
                    CGFloat(expandedBytes[sourceIndex])
                        + CGFloat(expandedBytes[sourceIndex + 1])
                        + CGFloat(expandedBytes[sourceIndex + 2])
                ) / 3
                referenceBrightness += (
                    CGFloat(expandedBytes[referenceIndex])
                        + CGFloat(expandedBytes[referenceIndex + 1])
                        + CGFloat(expandedBytes[referenceIndex + 2])
                ) / 3
                maskPixelCount += 1
            }
        }

        guard maskPixelCount > 100 else {
            XCTFail("collapsed search glyph mask contained only \(maskPixelCount) pixels")
            return
        }
        let sourceMean = sourceBrightness / CGFloat(maskPixelCount)
        let referenceMean = referenceBrightness / CGFloat(maskPixelCount)
        let luminanceDip = referenceMean - sourceMean
        let report = String(
            format: "mask=%d source=%.3f reference=%.3f dip=%.3f",
            maskPixelCount,
            sourceMean,
            referenceMean,
            luminanceDip
        )
        let metricsAttachment = XCTAttachment(string: report)
        metricsAttachment.name = "Home search residue luminance"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)

        XCTAssertLessThan(
            luminanceDip,
            1,
            "the expanded search chrome must not redraw the collapsed magnifying-glass node (\(report))"
        )
    }
}
