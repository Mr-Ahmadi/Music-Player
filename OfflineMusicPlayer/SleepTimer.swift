import Foundation
import Combine

// MARK: - Sleep Timer Option
enum SleepTimerOption: Hashable, Identifiable {
    case minutes(Int)
    case endOfTrack

    var id: String {
        switch self {
        case .minutes(let m): return "m\(m)"
        case .endOfTrack: return "endOfTrack"
        }
    }

    var title: String {
        switch self {
        case .minutes(let m):
            if m % 60 == 0 { return "\(m / 60) hour\(m == 60 ? "" : "s")" }
            return "\(m) minutes"
        case .endOfTrack:
            return "End of track"
        }
    }

    static let presets: [SleepTimerOption] = [
        .minutes(5), .minutes(10), .minutes(15), .minutes(20),
        .minutes(30), .minutes(45), .minutes(60), .minutes(90),
        .minutes(120), .endOfTrack
    ]
}

// MARK: - Sleep Timer
/// Counts down and then asks the player to fade out and pause.
/// Deliberately holds no reference to `AudioPlayer` — the player installs
/// `onFire` so the timer stays testable and free of retain cycles.
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// Currently armed option, or nil when the timer is off.
    @Published private(set) var option: SleepTimerOption?
    /// Seconds left for a duration-based timer. Nil for `.endOfTrack`.
    @Published private(set) var remaining: TimeInterval?

    /// Invoked on the main thread when the countdown reaches zero.
    var onFire: (() -> Void)?

    var isActive: Bool { option != nil }
    /// True when playback should stop once the current track finishes.
    var stopsAtEndOfTrack: Bool { option == .endOfTrack }

    private var ticker: Timer?
    private var fireDate: Date?

    private init() {}

    // MARK: - Control
    func start(_ option: SleepTimerOption) {
        cancel()
        self.option = option

        switch option {
        case .endOfTrack:
            remaining = nil
        case .minutes(let minutes):
            let seconds = TimeInterval(minutes * 60)
            remaining = seconds
            fireDate = Date().addingTimeInterval(seconds)
            startTicking()
        }
    }

    /// Adds more time to a running duration timer (no-op for end-of-track).
    func extend(byMinutes minutes: Int) {
        guard case .minutes(let current)? = option, let fireDate else { return }
        let newFire = fireDate.addingTimeInterval(TimeInterval(minutes * 60))
        self.fireDate = newFire
        self.option = .minutes(current + minutes)
        remaining = newFire.timeIntervalSinceNow
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        fireDate = nil
        option = nil
        remaining = nil
    }

    /// Called by the player when a track finishes, so an `.endOfTrack` timer can fire.
    /// Returns true when playback should stop instead of advancing.
    func shouldStopAfterCurrentTrack() -> Bool {
        guard stopsAtEndOfTrack else { return false }
        cancel()
        return true
    }

    // MARK: - Countdown
    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Keep counting down while the user scrolls a list.
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    private func tick() {
        guard let fireDate else { return }
        let left = fireDate.timeIntervalSinceNow
        if left <= 0 {
            let fire = onFire
            cancel()
            fire?()
        } else {
            remaining = left
        }
    }

    // MARK: - Display
    /// "12:04" style label for the remaining time, or the option name for end-of-track.
    var displayText: String? {
        guard let option else { return nil }
        switch option {
        case .endOfTrack:
            return "End of track"
        case .minutes:
            guard let remaining else { return nil }
            let total = max(0, Int(remaining.rounded()))
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
