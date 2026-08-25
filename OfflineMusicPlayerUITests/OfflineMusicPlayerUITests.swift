//
//  OfflineMusicPlayerUITests.swift
//  OfflineMusicPlayerUITests
//
//  Created by Ali Ahmadi on 9/26/25.
//

import XCTest

final class OfflineMusicPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Start from a known-empty library every run. Arguments of the form
        // "-key value" are read by UserDefaults ahead of anything on disk, so the
        // tests don't inherit whatever state the simulator happened to be left in.
        app.launchArguments += [
            "-savedTracks", "()",
            "-libraryFavoritesOnly", "NO",
            "-librarySortOrder", "custom",
            "-playbackShuffleEnabled", "NO",
            "-userPlayQueue", "()"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAppLaunches() {
        XCTAssert(app.windows.firstMatch.exists)
    }

    func testNavigationTitleExists() {
        let navTitle = app.navigationBars["Library"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Navigation title should be visible")
    }

    func testImportButtonExists() {
        XCTAssertTrue(app.buttons["Import"].waitForExistence(timeout: 5), "Import button should be in the toolbar")
    }

    func testEmptyStateDisplayed() {
        let emptyStateText = app.staticTexts["No Tracks"]
        XCTAssertTrue(emptyStateText.waitForExistence(timeout: 5), "Empty state should be shown when no tracks")
    }

    func testPlayPauseButtonExists() {
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "The mini player should offer a play button")
    }

    // MARK: - New playback controls
    func testMiniPlayerExposesShuffleAndQueue() {
        XCTAssertTrue(app.buttons["Shuffle off"].waitForExistence(timeout: 5), "Shuffle toggle should be in the mini player")
        XCTAssertTrue(app.buttons["Up next"].exists, "Queue button should be in the mini player")
    }

    func testShuffleButtonTogglesState() {
        let shuffleOff = app.buttons["Shuffle off"]
        XCTAssertTrue(shuffleOff.waitForExistence(timeout: 5))
        shuffleOff.tap()

        XCTAssertTrue(app.buttons["Shuffle on"].waitForExistence(timeout: 3), "Tapping shuffle should switch it on")
    }

    func testSettingsExposesEqualizerAndSleepTimer() {
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Equalizer"].waitForExistence(timeout: 5), "Settings should link to the equalizer")
        XCTAssertTrue(app.staticTexts["Sleep Timer"].exists, "Settings should link to the sleep timer")
        XCTAssertTrue(app.staticTexts["Speed"].exists, "Settings should expose playback speed")
    }

    func testEqualizerScreenShowsPresets() {
        app.buttons["Settings"].tap()
        app.staticTexts["Equalizer"].tap()

        XCTAssertTrue(app.buttons["Flat preset"].waitForExistence(timeout: 5), "Equalizer should offer presets")
        XCTAssertTrue(app.buttons["Rock preset"].exists)
    }

    func testSleepTimerCanBeArmedAndCancelled() {
        app.buttons["Settings"].tap()
        app.staticTexts["Sleep Timer"].tap()

        let endOfTrack = app.buttons["End of track"]
        XCTAssertTrue(endOfTrack.waitForExistence(timeout: 5), "Sleep timer should offer presets")
        endOfTrack.tap()

        // Choosing an option arms the timer and pops back to Settings, where the
        // row now reports what is armed.
        let sleepRow = app.staticTexts["Sleep Timer"]
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 5), "Picking an option should return to Settings")
        XCTAssertTrue(app.staticTexts["End of track"].exists, "The Settings row should show the armed timer")

        sleepRow.tap()
        let turnOff = app.buttons["Turn Off Timer"]
        XCTAssertTrue(turnOff.waitForExistence(timeout: 5), "An armed timer should offer a way to cancel it")
        turnOff.tap()

        XCTAssertTrue(endOfTrack.waitForExistence(timeout: 5), "Cancelling should return to the preset list")
    }
}
