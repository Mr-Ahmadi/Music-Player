//
//  OfflineMusicPlayerTests.swift
//  OfflineMusicPlayerTests
//
//  Created by Ali Ahmadi on 9/26/25.
//

import XCTest
import AVFoundation
@testable import OfflineMusicPlayer

final class OfflineMusicPlayerTests: XCTestCase {

    var player: AudioPlayer!

    private let url1 = URL(fileURLWithPath: "/tmp/song1.mp3")
    private let url2 = URL(fileURLWithPath: "/tmp/song2.mp3")
    private let url3 = URL(fileURLWithPath: "/tmp/song3.mp3")

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: "savedTracks")
        UserDefaults.standard.removeObject(forKey: "userPlayQueue")
        player = AudioPlayer()
        player.tracks = []
        player.labelFilterIds = []
        player.clearQueue()

        PlaybackPreferences.shared.shuffleEnabled = false
        PlaybackPreferences.shared.repeatMode = .all
        PlaybackPreferences.shared.playbackRate = 1.0
        SleepTimer.shared.cancel()
    }

    override func tearDownWithError() throws {
        SleepTimer.shared.cancel()
        player = nil
        UserDefaults.standard.removeObject(forKey: "savedTracks")
        UserDefaults.standard.removeObject(forKey: "userPlayQueue")
    }

    // MARK: - Track management
    func testRemoveTrack() {
        player.tracks = [url1, url2]
        player.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(player.tracks, [url2])
    }

    func testRemovingTrackAlsoDropsItFromTheUpNextQueue() {
        player.tracks = [url1, url2, url3]
        player.addToQueue(url2)
        XCTAssertEqual(player.userQueue, [url2])

        player.remove(atOffsets: IndexSet(integer: 1))
        XCTAssertFalse(player.userQueue.contains(url2), "Deleted tracks must not linger in the queue")
    }

    // MARK: - Up Next queue
    func testPlayNextJumpsTheLineAndDeduplicates() {
        player.tracks = [url1, url2, url3]
        player.addToQueue(url2)
        player.addToQueue(url3)
        XCTAssertEqual(player.userQueue, [url2, url3])

        player.playNext(url3)
        XCTAssertEqual(player.userQueue, [url3, url2], "playNext moves an existing entry to the front")
    }

    func testAddToQueueIgnoresDuplicates() {
        player.tracks = [url1]
        player.addToQueue(url1)
        player.addToQueue(url1)
        XCTAssertEqual(player.userQueue.count, 1)
    }

    func testQueueReorderAndClear() {
        player.tracks = [url1, url2, url3]
        player.addToQueue(url1)
        player.addToQueue(url2)
        player.addToQueue(url3)

        player.moveInQueue(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(player.userQueue, [url3, url1, url2])

        player.removeFromQueue(atOffsets: IndexSet(integer: 1))
        XCTAssertEqual(player.userQueue, [url3, url2])

        player.clearQueue()
        XCTAssertTrue(player.userQueue.isEmpty)
    }

    func testQueueSurvivesReload() {
        player.tracks = [url1, url2]
        player.addToQueue(url2)

        let saved = UserDefaults.standard.array(forKey: "userPlayQueue") as? [String]
        XCTAssertEqual(saved, ["song2.mp3"])
    }

    // MARK: - Shuffle
    func testShuffleOrderContainsEveryTrackExactlyOnce() {
        player.tracks = [url1, url2, url3]
        PlaybackPreferences.shared.shuffleEnabled = true

        let order = player.playbackOrder()
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(Set(order), Set(player.tracks))
    }

    func testPlaybackOrderMatchesLibraryWhenShuffleIsOff() {
        player.tracks = [url1, url2, url3]
        PlaybackPreferences.shared.shuffleEnabled = false
        XCTAssertEqual(player.playbackOrder(), [url1, url2, url3])
    }

    func testShuffleOrderIsRebuiltWhenTheLibraryChanges() {
        player.tracks = [url1, url2]
        PlaybackPreferences.shared.shuffleEnabled = true
        _ = player.playbackOrder()

        player.tracks = [url1, url2, url3]
        XCTAssertEqual(Set(player.playbackOrder()), Set([url1, url2, url3]))
    }

    // MARK: - Label filter
    func testPlayQueueRespectsLabelFilter() {
        player.tracks = [url1, url2]
        let label = MusicLabel(name: "Test", color: "#FF0000")
        MusicMetadataManager.shared.addLabel(label)
        MusicMetadataManager.shared.addLabel(labelId: label.id, to: url1.lastPathComponent)

        let expectation = expectation(description: "metadata applied")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        player.labelFilterIds = [label.id]
        XCTAssertEqual(player.getPlayQueue(), [url1])

        player.labelFilterIds = []
        MusicMetadataManager.shared.removeLabel(id: label.id)
    }

    // MARK: - Seeking
    func testSeekDoesNotCrashWithoutAudio() {
        player.seek(to: 5.0)
        XCTAssertEqual(player.progress, 0, accuracy: 0.001)
    }

    // MARK: - Repeat mode
    func testRepeatModeCyclesOffAllOne() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    // MARK: - Playback preferences
    func testPlaybackRateIsClampedToASafeRange() {
        let prefs = PlaybackPreferences.shared
        prefs.playbackRate = 4.0
        XCTAssertEqual(prefs.playbackRate, 2.0)

        prefs.playbackRate = 0.1
        XCTAssertEqual(prefs.playbackRate, 0.5)

        prefs.playbackRate = 1.0
    }

    func testRateLabelDropsTrailingZeroes() {
        XCTAssertEqual(PlaybackPreferences.label(for: 1.0), "1×")
        XCTAssertEqual(PlaybackPreferences.label(for: 1.25), "1.25×")
    }

    // MARK: - Equalizer
    func testApplyingAPresetSetsEveryBand() {
        let eq = EqualizerSettings.shared
        guard let rock = EQPreset.preset(withId: "rock") else { return XCTFail("missing preset") }

        eq.apply(preset: rock)
        XCTAssertEqual(eq.gains.count, EqualizerSettings.bandCount)
        XCTAssertEqual(eq.gains, rock.gains)
        XCTAssertEqual(eq.presetId, "rock")
        XCTAssertTrue(eq.isEnabled, "Choosing a preset should switch the equalizer on")
    }

    func testEditingABandSwitchesToCustom() {
        let eq = EqualizerSettings.shared
        eq.apply(preset: EQPreset.builtIn[0])
        eq.setGain(6, forBand: 2)

        XCTAssertEqual(eq.gains[2], 6)
        XCTAssertEqual(eq.presetId, EQPreset.custom.id)
    }

    func testBandGainsAreClamped() {
        let eq = EqualizerSettings.shared
        eq.setGain(99, forBand: 0)
        XCTAssertEqual(eq.gains[0], EqualizerSettings.gainRange.upperBound)

        eq.setGain(-99, forBand: 0)
        XCTAssertEqual(eq.gains[0], EqualizerSettings.gainRange.lowerBound)
    }

    func testResetToFlatZeroesEverything() {
        let eq = EqualizerSettings.shared
        eq.apply(preset: EQPreset.builtIn[1])
        eq.preamp = 4
        eq.resetToFlat()

        XCTAssertEqual(eq.gains, Array(repeating: 0, count: EqualizerSettings.bandCount))
        XCTAssertEqual(eq.preamp, 0)
    }

    func testEveryBuiltInPresetCoversAllBands() {
        for preset in EQPreset.builtIn {
            XCTAssertEqual(preset.gains.count, EqualizerSettings.bandCount, "\(preset.name) has the wrong band count")
        }
    }

    func testFrequencyLabels() {
        XCTAssertEqual(EqualizerSettings.label(forFrequency: 250), "250")
        XCTAssertEqual(EqualizerSettings.label(forFrequency: 16000), "16k")
    }

    // MARK: - Sleep timer
    func testSleepTimerStartsAndCancels() {
        let timer = SleepTimer.shared
        timer.start(.minutes(15))

        XCTAssertTrue(timer.isActive)
        XCTAssertFalse(timer.stopsAtEndOfTrack)
        XCTAssertEqual(timer.remaining ?? 0, 900, accuracy: 2)

        timer.cancel()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.displayText)
    }

    func testEndOfTrackTimerFiresOnceThenClears() {
        let timer = SleepTimer.shared
        timer.start(.endOfTrack)

        XCTAssertTrue(timer.stopsAtEndOfTrack)
        XCTAssertTrue(timer.shouldStopAfterCurrentTrack())
        XCTAssertFalse(timer.isActive, "Firing should disarm the timer")
        XCTAssertFalse(timer.shouldStopAfterCurrentTrack())
    }

    func testExtendingAddsTime() {
        let timer = SleepTimer.shared
        timer.start(.minutes(10))
        timer.extend(byMinutes: 5)

        XCTAssertEqual(timer.remaining ?? 0, 900, accuracy: 2)
        timer.cancel()
    }

    func testDurationTimerDisplaysMinutesAndSeconds() {
        let timer = SleepTimer.shared
        timer.start(.minutes(5))
        XCTAssertEqual(timer.displayText, "5:00")
        timer.cancel()

        timer.start(.minutes(90))
        XCTAssertEqual(timer.displayText, "1:30:00")
        timer.cancel()
    }

    // MARK: - Metadata
    func testMetadataDecodesLibrariesSavedBeforeFavoritesExisted() throws {
        let legacy = """
        {"id":"song.mp3","displayName":"Song","labels":["a"]}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MusicMetadata.self, from: legacy)
        XCTAssertEqual(decoded.displayName, "Song")
        XCTAssertEqual(decoded.labels, ["a"])
        XCTAssertFalse(decoded.isFavorite)
        XCTAssertEqual(decoded.rating, 0)
        XCTAssertEqual(decoded.resumePosition, 0)
    }

    func testMetadataRoundTripsNewFields() throws {
        let original = MusicMetadata(id: "a.mp3", displayName: "A", labels: [], isFavorite: true, rating: 4, resumePosition: 120)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MusicMetadata.self, from: data)

        XCTAssertTrue(decoded.isFavorite)
        XCTAssertEqual(decoded.rating, 4)
        XCTAssertEqual(decoded.resumePosition, 120)
    }

    func testResumePositionIsOnlyKeptForLongTracksStoppedInTheMiddle() {
        let manager = MusicMetadataManager.shared

        // Too short to be worth resuming.
        manager.setResumePosition(90, duration: 200, for: "short.mp3")
        // A long podcast stopped halfway.
        manager.setResumePosition(400, duration: 3600, for: "long.mp3")
        // Effectively finished.
        manager.setResumePosition(3595, duration: 3600, for: "finished.mp3")

        let expectation = expectation(description: "writes applied")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(manager.resumePosition(for: "short.mp3"), 0)
        XCTAssertEqual(manager.resumePosition(for: "long.mp3"), 400)
        XCTAssertEqual(manager.resumePosition(for: "finished.mp3"), 0)

        for name in ["short.mp3", "long.mp3", "finished.mp3"] {
            manager.removeMusicMetadata(fileName: name)
        }
    }

    // MARK: - Track tags
    func testTagSubtitleJoinsArtistAndAlbum() {
        var tags = TrackTags()
        XCTAssertNil(tags.subtitle)

        tags.artist = "Kova"
        XCTAssertEqual(tags.subtitle, "Kova")

        tags.album = "Blue Hours"
        XCTAssertEqual(tags.subtitle, "Kova — Blue Hours")
    }

    func testArtworkGradientIsStablePerTrack() {
        let a = TrackArtworkView.gradientColors(for: "song.mp3")
        let b = TrackArtworkView.gradientColors(for: "song.mp3")
        let c = TrackArtworkView.gradientColors(for: "other.mp3")

        XCTAssertEqual(a, b, "The same file must always get the same colours")
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Engine integration
    /// Plays a real file through the whole graph (player -> time pitch -> EQ -> mixer)
    /// to prove the chain is wired up and the position clock advances.
    func testPlaysARealFileThroughTheAudioGraph() throws {
        let fileName = try makeTestTone(named: "engine-tone.wav", seconds: 3)
        let url = audioDirectory.appendingPathComponent(fileName)
        player.tracks = [url]

        player.play(url: url)
        XCTAssertTrue(waitUntil(timeout: 5) { self.player.isPlaying && self.player.duration > 0 },
                      "Playback should start and report a duration")
        XCTAssertEqual(player.duration, 3, accuracy: 0.3)

        let start = player.progress
        XCTAssertTrue(waitUntil(timeout: 5) { self.player.progress > start + 0.4 },
                      "The playback position should advance")

        player.pause()
        XCTAssertFalse(player.isPlaying)

        try? FileManager.default.removeItem(at: url)
    }

    func testChangingSpeedKeepsPlaybackRunning() throws {
        let fileName = try makeTestTone(named: "speed-tone.wav", seconds: 3)
        let url = audioDirectory.appendingPathComponent(fileName)
        player.tracks = [url]

        player.play(url: url)
        XCTAssertTrue(waitUntil(timeout: 5) { self.player.isPlaying })

        PlaybackPreferences.shared.playbackRate = 1.5
        let start = player.progress
        XCTAssertTrue(waitUntil(timeout: 5) { self.player.progress > start + 0.4 },
                      "Audio should keep playing after a speed change")

        PlaybackPreferences.shared.playbackRate = 1.0
        player.pause()
        try? FileManager.default.removeItem(at: url)
    }

    func testSeekMovesThePlaybackPosition() throws {
        let fileName = try makeTestTone(named: "seek-tone.wav", seconds: 6)
        let url = audioDirectory.appendingPathComponent(fileName)
        player.tracks = [url]

        player.play(url: url)
        XCTAssertTrue(waitUntil(timeout: 5) { self.player.duration > 0 })

        player.seek(to: 4.0)
        XCTAssertTrue(waitUntil(timeout: 3) { self.player.progress >= 3.5 },
                      "Seeking should jump the position forward")

        player.pause()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Test helpers
    private var audioDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = library.appendingPathComponent("Audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a short sine tone into the app's audio directory, where the player looks for tracks.
    private func makeTestTone(named name: String, seconds: Double) throws -> String {
        let url = audioDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let sampleRate = 44100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = 0.2 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return name
    }

    /// Spins the run loop until `condition` holds, so timer-driven state can settle.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
