import Foundation

// MARK: - Playback Event
struct PlaybackEvent: Codable, Equatable {
    let trackId: String
    let timestamp: Date
    let duration: TimeInterval
    
    var hour: Int { Calendar.current.component(.hour, from: timestamp) }
    var weekday: Int { Calendar.current.component(.weekday, from: timestamp) }
}

// MARK: - Listening Stats
struct TrackStats {
    let trackId: String
    let playCount: Int
    let totalListenTime: TimeInterval
    let lastPlayed: Date?
    let playsByHour: [Int: Int]  // hour (0-23) -> count
    let playsByWeekday: [Int: Int]  // weekday (1-7) -> count
}

struct HourDayInsight {
    let hour: Int
    let weekday: Int
    let playCount: Int
    let topTracks: [(trackId: String, count: Int)]
}

// MARK: - Smart Suggestion
struct SmartSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let trackIds: [String]
    let suggestionType: SuggestionType
    
    enum SuggestionType {
        case morningCommute
        case eveningRelax
        case weekendFavorites
        case workFocus
        case mostPlayed
        case rediscover
    }
}

// MARK: - Playback Analytics Manager
final class PlaybackAnalytics: ObservableObject {
    static let shared = PlaybackAnalytics()
    
    private let eventsKey = "playbackAnalyticsEvents"
    private let maxEvents = 5000
    
    @Published private(set) var events: [PlaybackEvent] = []
    
    private init() {
        loadEvents()
    }
    
    // MARK: - Record Play
    func recordPlay(trackId: String, duration: TimeInterval) {
        let event = PlaybackEvent(
            trackId: trackId,
            timestamp: Date(),
            duration: duration
        )
        
        DispatchQueue.main.async {
            self.events.append(event)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
            self.saveEvents()
        }
    }
    
    // MARK: - Persistence
    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: eventsKey)
    }
    
    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: eventsKey),
              let decoded = try? JSONDecoder().decode([PlaybackEvent].self, from: data) else {
            return
        }
        events = decoded
    }
    
    // MARK: - Stats
    func trackStats(for trackId: String) -> TrackStats {
        let trackEvents = events.filter { $0.trackId == trackId }
        var playsByHour: [Int: Int] = [:]
        var playsByWeekday: [Int: Int] = [:]
        
        for event in trackEvents {
            playsByHour[event.hour, default: 0] += 1
            playsByWeekday[event.weekday, default: 0] += 1
        }
        
        return TrackStats(
            trackId: trackId,
            playCount: trackEvents.count,
            totalListenTime: trackEvents.reduce(0) { $0 + $1.duration },
            lastPlayed: trackEvents.last?.timestamp,
            playsByHour: playsByHour,
            playsByWeekday: playsByWeekday
        )
    }
    
    func topTracks(limit: Int = 10) -> [(trackId: String, count: Int)] {
        let counts = Dictionary(grouping: events, by: { $0.trackId })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
        
        return Array(counts.prefix(limit)).map { (trackId: $0.key, count: $0.value) }
    }
    
    func hotHoursAndDays() -> [HourDayInsight] {
        var hourDayCounts: [String: (count: Int, tracks: [String: Int])] = [:]
        
        for event in events {
            let key = "\(event.hour)-\(event.weekday)"
            if hourDayCounts[key] == nil {
                hourDayCounts[key] = (0, [:])
            }
            hourDayCounts[key]?.count += 1
            hourDayCounts[key]?.tracks[event.trackId, default: 0] += 1
        }
        
        return hourDayCounts
            .map { key, value in
                let parts = key.split(separator: "-")
                let hour = Int(parts[0]) ?? 0
                let weekday = Int(parts[1]) ?? 1
                let topTracks = value.tracks.sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { (trackId: $0.key, count: $0.value) }
                
                return HourDayInsight(
                    hour: hour,
                    weekday: weekday,
                    playCount: value.count,
                    topTracks: Array(topTracks)
                )
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(5)
            .map { $0 }
    }
    
    func peakListeningHour() -> Int? {
        let hourCounts = Dictionary(grouping: events, by: { $0.hour })
            .mapValues { $0.count }
        return hourCounts.max(by: { $0.value < $1.value })?.key
    }
    
    func peakListeningWeekday() -> Int? {
        let weekdayCounts = Dictionary(grouping: events, by: { $0.weekday })
            .mapValues { $0.count }
        return weekdayCounts.max(by: { $0.value < $1.value })?.key
    }
    
    // MARK: - Smart Suggestions
    func generateSuggestions(availableTrackIds: [String]) -> [SmartSuggestion] {
        var suggestions: [SmartSuggestion] = []
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentWeekday = calendar.component(.weekday, from: now)
        
        // Most played tracks
        let top = topTracks(limit: 5)
        if !top.isEmpty {
            suggestions.append(SmartSuggestion(
                title: "Your Top Picks",
                message: "Songs you play the most",
                trackIds: top.map { $0.trackId }.filter { availableTrackIds.contains($0) },
                suggestionType: .mostPlayed
            ))
        }
        
        // Time-based: Morning (6-11)
        if currentHour >= 6 && currentHour < 12 {
            let morningTracks = hotHoursAndDays()
                .filter { $0.hour >= 6 && $0.hour < 12 }
                .flatMap { $0.topTracks.map { $0.trackId } }
                .filter { availableTrackIds.contains($0) }
            
            if !morningTracks.isEmpty {
                suggestions.append(SmartSuggestion(
                    title: "Morning Vibes",
                    message: "Perfect for your morning routine",
                    trackIds: Array(Set(morningTracks)).prefix(5).map { $0 },
                    suggestionType: .morningCommute
                ))
            }
        }
        
        // Time-based: Evening (18-23)
        if currentHour >= 18 {
            let eveningTracks = hotHoursAndDays()
                .filter { $0.hour >= 18 }
                .flatMap { $0.topTracks.map { $0.trackId } }
                .filter { availableTrackIds.contains($0) }
            
            if !eveningTracks.isEmpty {
                suggestions.append(SmartSuggestion(
                    title: "Evening Relaxation",
                    message: "Your unwind playlist",
                    trackIds: Array(Set(eveningTracks)).prefix(5).map { $0 },
                    suggestionType: .eveningRelax
                ))
            }
        }
        
        // Weekend vs Weekday
        if currentWeekday == 1 || currentWeekday == 7 {
            let weekendTracks = hotHoursAndDays()
                .filter { $0.weekday == 1 || $0.weekday == 7 }
                .flatMap { $0.topTracks.map { $0.trackId } }
                .filter { availableTrackIds.contains($0) }
            
            if !weekendTracks.isEmpty {
                suggestions.append(SmartSuggestion(
                    title: "Weekend Favorites",
                    message: "Songs you love on weekends",
                    trackIds: Array(Set(weekendTracks)).prefix(5).map { $0 },
                    suggestionType: .weekendFavorites
                ))
            }
        }
        
        // Work hours (9-17 on weekdays)
        if currentHour >= 9 && currentHour < 17 && currentWeekday >= 2 && currentWeekday <= 6 {
            let workTracks = hotHoursAndDays()
                .filter { $0.hour >= 9 && $0.hour < 17 && $0.weekday >= 2 && $0.weekday <= 6 }
                .flatMap { $0.topTracks.map { $0.trackId } }
                .filter { availableTrackIds.contains($0) }
            
            if !workTracks.isEmpty {
                suggestions.append(SmartSuggestion(
                    title: "Focus Mode",
                    message: "Your work session soundtrack",
                    trackIds: Array(Set(workTracks)).prefix(5).map { $0 },
                    suggestionType: .workFocus
                ))
            }
        }
        
        // Rediscover: played before but not in top
        let allPlayedIds = Set(events.map { $0.trackId })
        let rediscover = allPlayedIds
            .subtracting(Set(top.prefix(10).map { $0.trackId }))
            .filter { availableTrackIds.contains($0) }
        
        if !rediscover.isEmpty {
            suggestions.append(SmartSuggestion(
                title: "Rediscover",
                message: "You haven't played these lately",
                trackIds: Array(rediscover).shuffled().prefix(5).map { $0 },
                suggestionType: .rediscover
            ))
        }
        
        return suggestions
    }
    
    // MARK: - Helpers
    static func weekdayName(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        var components = DateComponents()
        components.weekday = weekday
        if let date = Calendar.current.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) {
            return formatter.string(from: date)
        }
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][min(max(0, weekday - 1), 6)]
    }
    
    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0..<12: return "\(hour == 0 ? 12 : hour) AM"
        case 12: return "12 PM"
        default: return "\(hour - 12) PM"
        }
    }
}
