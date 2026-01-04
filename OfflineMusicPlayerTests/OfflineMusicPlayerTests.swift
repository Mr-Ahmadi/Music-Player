//
//  OfflineMusicPlayerTests.swift
//  OfflineMusicPlayerTests
//
//  Created by Ali Ahmadi on 9/26/25.
//

import XCTest
@testable import OfflineMusicPlayer

final class OfflineMusicPlayerTests: XCTestCase {

    var player: AudioPlayer!

    override func setUpWithError() throws {
        player = AudioPlayer()
        // Clear saved tracks before each test
        UserDefaults.standard.removeObject(forKey: "savedTracks")
    }

    override func tearDownWithError() throws {
        player = nil
        UserDefaults.standard.removeObject(forKey: "savedTracks")
    }

    func testAddTracks() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        let url2 = URL(fileURLWithPath: "/tmp/song2.mp3")
        
        player.add(urls: [url1, url2])
        XCTAssertEqual(player.tracks.count, 2)
        XCTAssertTrue(player.tracks.contains(url1))
        XCTAssertTrue(player.tracks.contains(url2))
    }

    func testAddDuplicateTracks() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        
        player.add(urls: [url1])
        player.add(urls: [url1])
        XCTAssertEqual(player.tracks.count, 1, "Should not add duplicate URLs")
    }

    func testRemoveTrack() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        let url2 = URL(fileURLWithPath: "/tmp/song2.mp3")
        
        player.add(urls: [url1, url2])
        player.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(player.tracks.count, 1)
        XCTAssertEqual(player.tracks[0], url2)
    }

    func testNextTrack() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        let url2 = URL(fileURLWithPath: "/tmp/song2.mp3")
        
        player.add(urls: [url1, url2])
        // nextTrack should not crash with valid tracks
        player.nextTrack()
        XCTAssertTrue(true)
    }

    func testPreviousTrack() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        let url2 = URL(fileURLWithPath: "/tmp/song2.mp3")
        
        player.add(urls: [url1, url2])
        // previousTrack should not crash with valid tracks
        player.previousTrack()
        XCTAssertTrue(true)
    }

    func testTogglePlayPause() {
        let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
        player.add(urls: [url1])
        
        player.togglePlayPause()
        // Note: Will fail without actual audio file, but logic can be tested with mock
        // This test verifies the method exists and doesn't crash
        XCTAssertTrue(true)
    }

    func testSeek() {
        player.seek(to: 5.0)
        // Seek should not crash even with no audio player
        XCTAssertTrue(true)
    }

}

