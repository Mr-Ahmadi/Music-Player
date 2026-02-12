import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var analytics = PlaybackAnalytics.shared
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @State private var showTodayOnly = true
    @State private var refreshTimer: Timer?
    
    /// Display name for a track (fileName); used in history/insights.
    private func displayName(forTrackId trackId: String) -> String {
        metadataManager.getMetadata(for: trackId).displayName
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Today/All-time toggle
                    if !analytics.events.isEmpty {
                        HStack {
                            Spacer()
                            Picker("Time Period", selection: $showTodayOnly) {
                                Text("Today").tag(true)
                                Text("All-time").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 180)
                        }
                        .padding(.horizontal)
                    }
                    
                    if analytics.events.isEmpty && analytics.liveSession == nil {
                        emptyInsightsView
                    } else {
                        listeningOverviewSection
                        hotTimesSection
                        topTracksSection
                        suggestionsSection
                    }
                }
                .padding()
            }
            .navigationTitle("Listening Insights")
            .background(Color(UIColor.systemGroupedBackground))
            .onAppear {
                startRefreshTimer()
            }
            .onDisappear {
                stopRefreshTimer()
            }
        }
    }
    
    // MARK: - Refresh Timer
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Force view update by triggering objectWillChange
            analytics.objectWillChange.send()
        }
    }
    
    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: - Empty State
    private var emptyInsightsView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)
            
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("No Data Yet")
                .font(.title2.bold())
            
            Text("Start playing music to see your listening habits, peak hours, and get personalized suggestions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
    
    // MARK: - Listening Overview
    private var listeningOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Overview", icon: "chart.pie")
            
            let (playCount, totalTime, uniqueTracks) = calculateStats()
            
            HStack(spacing: 16) {
                StatCard(
                    title: "Total Plays",
                    value: "\(playCount)",
                    icon: "play.circle.fill"
                )
                
                let avgTime = playCount > 0 ? totalTime / Double(playCount) : 0
                StatCard(
                    title: "Avg Listen",
                    value: formatDuration(avgTime, shortFormat: true),
                    icon: "waveform.circle.fill"
                )
            }
            
            HStack(spacing: 16) {
                StatCard(
                    title: "Total Time",
                    value: formatDuration(totalTime, shortFormat: false),
                    icon: "clock.fill"
                )
                
                StatCard(
                    title: "Unique Tracks",
                    value: "\(uniqueTracks)",
                    icon: "music.note.list"
                )
            }
            
            if let peakHour = peakListeningHour() {
                HStack(spacing: 12) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peak Listening Time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(PlaybackAnalytics.hourLabel(peakHour))
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(8)
            }
            
            if let peakDay = peakListeningWeekday() {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Most Active Day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(PlaybackAnalytics.weekdayName(peakDay))
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func calculateStats() -> (playCount: Int, totalTime: TimeInterval, uniqueTracks: Int) {
        if showTodayOnly {
            return analytics.todayStats()
        } else {
            let playCount = analytics.events.count + (analytics.liveSession != nil ? 1 : 0)
            let liveTime = analytics.getCurrentLiveListenDuration()
            let totalTime = analytics.events.reduce(0) { $0 + $1.duration } + liveTime
            let allTracksIds = analytics.events.map { $0.trackId }
            if let session = analytics.liveSession {
                let uniqueTracks = Set(allTracksIds + [session.trackId]).count
                return (playCount, totalTime, uniqueTracks)
            }
            let uniqueTracks = Set(allTracksIds).count
            return (playCount, totalTime, uniqueTracks)
        }
    }
    
    private func peakListeningHour() -> Int? {
        let events = showTodayOnly ? getEventsForToday() : analytics.events
        let hourCounts = Dictionary(grouping: events, by: { $0.hour })
            .mapValues { $0.count }
        return hourCounts.max(by: { $0.value < $1.value })?.key
    }
    
    private func peakListeningWeekday() -> Int? {
        let events = showTodayOnly ? getEventsForToday() : analytics.events
        let weekdayCounts = Dictionary(grouping: events, by: { $0.weekday })
            .mapValues { $0.count }
        return weekdayCounts.max(by: { $0.value < $1.value })?.key
    }
    
    private func getEventsForToday() -> [PlaybackEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return analytics.events.filter { calendar.startOfDay(for: $0.timestamp) == today }
    }
    
    private func formatDuration(_ seconds: TimeInterval, shortFormat: Bool) -> String {
        if shortFormat {
            return seconds >= 60 ? String(format: "%.1f", seconds / 60) + "m" : String(format: "%.0f", seconds) + "s"
        } else {
            let totalHours = Int(seconds / 3600)
            let totalMinutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return totalHours > 0 ? "\(totalHours)h \(totalMinutes)m" : "\(totalMinutes)m"
        }
    }
    
    // MARK: - Hot Times
    private var hotTimesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "When You Listen", icon: "clock.badge.checkmark")
            
            let hotTimes = analytics.hotHoursAndDays(todayOnly: showTodayOnly)
            if !hotTimes.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(hotTimes.enumerated()), id: \.offset) { _, insight in
                        HotTimeRow(insight: insight, trackName: { id in
                            displayName(forTrackId: id)
                        })
                    }
                }
            } else {
                Text("No listening activity" + (showTodayOnly ? " today" : ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Top Tracks
    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Most Played", icon: "music.note.list")
            
            let top = analytics.topTracks(limit: 10, todayOnly: showTodayOnly)
            let trackUrls = player.tracks
            let trackIdToUrl: [String: URL] = Dictionary(uniqueKeysWithValues: trackUrls.map { ($0.lastPathComponent, $0) })
            
            if top.isEmpty {
                Text("No plays yet" + (showTodayOnly ? " today" : ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(top.enumerated()), id: \.offset) { index, item in
                    if let url = trackIdToUrl[item.trackId] {
                        Button {
                            player.play(url: url)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .leading)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(forTrackId: item.trackId))
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                    
                                    Text("\(item.count) plays")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color(UIColor.tertiarySystemGroupedBackground))
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Suggestions
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "For You", icon: "sparkles")
            
            let suggestions = generateSuggestions()
            let trackIdToUrl: [String: URL] = Dictionary(uniqueKeysWithValues: player.tracks.map { ($0.lastPathComponent, $0) })
            
            if suggestions.isEmpty {
                Text("Keep listening to get personalized suggestions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(suggestions) { suggestion in
                    SuggestionCard(
                        suggestion: suggestion,
                        trackIdToUrl: trackIdToUrl,
                        displayName: displayName(forTrackId:),
                        onPlay: { url in player.play(url: url) }
                    )
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func generateSuggestions() -> [SmartSuggestion] {
        // Always use all-time data for suggestions, not today-only
        return analytics.generateSuggestions(
            availableTrackIds: player.tracks.map { $0.lastPathComponent }
        )
    }
}

// MARK: - Section Header
private struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
        }
    }
}

// MARK: - Stat Card
private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Hot Time Row
private struct HotTimeRow: View {
    let insight: HourDayInsight
    let trackName: (String) -> String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(PlaybackAnalytics.weekdayName(insight.weekday)), \(PlaybackAnalytics.hourLabel(insight.hour))")
                    .font(.subheadline.bold())
                
                if !insight.topTracks.isEmpty {
                    Text(insight.topTracks.map { trackName($0.trackId) }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Text("\(insight.playCount) plays")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(8)
    }
}

// MARK: - Suggestion Card
private struct SuggestionCard: View {
    let suggestion: SmartSuggestion
    let trackIdToUrl: [String: URL]
    let displayName: (String) -> String
    let onPlay: (URL) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: iconForType(suggestion.suggestionType))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.subheadline.bold())
                    Text(suggestion.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestion.trackIds.prefix(5), id: \.self) { trackId in
                        if let url = trackIdToUrl[trackId] {
                            Button {
                                onPlay(url)
                            } label: {
                                Text(displayName(trackId))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.2))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(16)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(10)
    }
    
    private func iconForType(_ type: SmartSuggestion.SuggestionType) -> String {
        switch type {
        case .morningCommute: return "sunrise.fill"
        case .eveningRelax: return "moon.stars.fill"
        case .weekendFavorites: return "star.fill"
        case .workFocus: return "laptopcomputer"
        case .mostPlayed: return "flame.fill"
        case .rediscover: return "arrow.clockwise"
        }
    }
}

#if DEBUG
struct InsightsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            InsightsView()
                .environmentObject(AudioPlayer())
        }
    }
}
#endif
