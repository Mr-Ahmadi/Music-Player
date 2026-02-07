import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var analytics = PlaybackAnalytics.shared
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if analytics.events.isEmpty {
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
        }
    }
    
    // MARK: - Empty State
    private var emptyInsightsView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)
            
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("No Data Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
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
            
            HStack(spacing: 16) {
                StatCard(
                    title: "Total Plays",
                    value: "\(analytics.events.count)",
                    icon: "play.circle.fill"
                )
                
                let totalMinutes = Int(analytics.events.reduce(0) { $0 + $1.duration } / 60)
                StatCard(
                    title: "Listen Time",
                    value: totalMinutes >= 60 ? "\(totalMinutes / 60)h" : "\(totalMinutes)m",
                    icon: "clock.fill"
                )
            }
            
            if let peakHour = analytics.peakListeningHour() {
                HStack {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.orange)
                    Text("Peak listening: \(PlaybackAnalytics.hourLabel(peakHour))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            if let peakDay = analytics.peakListeningWeekday() {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    Text("Most active: \(PlaybackAnalytics.weekdayName(peakDay))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Hot Times
    private var hotTimesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "When You Listen", icon: "clock.badge.checkmark")
            
            let hotTimes = analytics.hotHoursAndDays()
            if !hotTimes.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(hotTimes.enumerated()), id: \.offset) { _, insight in
                        HotTimeRow(insight: insight, trackName: { id in
                            player.tracks.first { $0.lastPathComponent == id }?
                                .deletingPathExtension().lastPathComponent ?? id
                        })
                    }
                }
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
            
            let top = analytics.topTracks(limit: 10)
            let trackUrls = player.tracks
            let trackIdToUrl: [String: URL] = Dictionary(uniqueKeysWithValues: trackUrls.map { ($0.lastPathComponent, $0) })
            
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
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
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
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Suggestions
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "For You", icon: "sparkles")
            
            let suggestions = analytics.generateSuggestions(
                availableTrackIds: player.tracks.map { $0.lastPathComponent }
            )
            let trackIdToUrl: [String: URL] = Dictionary(uniqueKeysWithValues: player.tracks.map { ($0.lastPathComponent, $0) })
            
            ForEach(suggestions) { suggestion in
                SuggestionCard(
                    suggestion: suggestion,
                    trackIdToUrl: trackIdToUrl,
                    onPlay: { url in player.play(url: url) }
                )
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
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
                .font(.title2)
                .fontWeight(.bold)
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
                    .font(.subheadline)
                    .fontWeight(.medium)
                
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
    let onPlay: (URL) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: iconForType(suggestion.suggestionType))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
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
                                Text(url.deletingPathExtension().lastPathComponent)
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
        InsightsView()
            .environmentObject(AudioPlayer())
    }
}
#endif
