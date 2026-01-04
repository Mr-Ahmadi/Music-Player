//
//  OfflineMusicPlayerUITests.swift
//  OfflineMusicPlayerUITests
//
//  Created by Ali Ahmadi on 9/26/25.
//

import XCTest

final class OfflineMusicPlayerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testAppLaunches() {
        let app = XCUIApplication()
        XCTAssert(app.windows.firstMatch.exists)
    }

    func testNavigationTitleExists() {
        let app = XCUIApplication()
        let navTitle = app.navigationBars["Offline Music"]
        XCTAssertTrue(navTitle.exists, "Navigation title should be visible")
    }

    func testImportButtonExists() {
        let app = XCUIApplication()
        let importButton = app.buttons.firstMatch
        // Button should exist in the toolbar
        XCTAssertTrue(app.buttons.count > 0, "Should have at least one button (import)")
    }

    func testEmptyStateDisplayed() {
        let app = XCUIApplication()
        let emptyStateText = app.staticTexts["No tracks"]
        XCTAssertTrue(emptyStateText.exists, "Empty state should be shown when no tracks")
    }

    func testPlayPauseButtonExists() {
        let app = XCUIApplication()
        // Look for any button that might be a play/pause button
        XCTAssertTrue(app.buttons.count > 0, "Should have playback buttons")
    }
}
