import Foundation

// MARK: - Lyric Line
/// One timed line of synced lyrics. An empty `text` marks an instrumental gap.
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String

    var isGap: Bool { text.isEmpty }
}

// MARK: - Lyrics
enum Lyrics: Equatable {
    /// Time-stamped lines, sorted by time.
    case synced([LyricLine])
    /// Lyrics without timing information.
    case plain(String)
    /// The track has no vocals.
    case instrumental
}

extension Array where Element == LyricLine {
    /// Index of the line being sung at `time`, or nil before the first line starts.
    func activeIndex(at time: TimeInterval) -> Int? {
        var low = 0
        var high = count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if self[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

// MARK: - LRC Parser
/// Parses the LRC format used by LRCLIB and most lyric files:
///
///     [ar:Artist]
///     [offset:+250]
///     [00:12.40]First line
///     [00:16.85][01:40.10]A line that repeats
///
/// Word-level "enhanced LRC" tags (`<00:12.40>`) are stripped, leaving line timing.
enum LRCParser {
    private static let timestamp = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let wordTag = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#
    )
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#,
        options: [.caseInsensitive]
    )

    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []
        // Positive LRC offsets make lyrics appear earlier.
        var offset: TimeInterval = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)

            if let match = offsetTag.firstMatch(in: line, range: range),
               let value = Double(line[Range(match.range(at: 1), in: line)!]) {
                offset = value / 1000
                continue
            }

            // Collect the run of leading timestamps: "[00:01.00][00:30.00]text".
            var times: [TimeInterval] = []
            var textStart = line.startIndex
            for match in timestamp.matches(in: line, range: range) {
                let matchRange = Range(match.range, in: line)!
                guard matchRange.lowerBound == textStart else { break }
                times.append(seconds(from: match, in: line))
                textStart = matchRange.upperBound
            }
            guard !times.isEmpty else { continue } // metadata tag or junk

            let text = strippingWordTags(String(line[textStart...]))
                .trimmingCharacters(in: .whitespaces)
            for time in times {
                entries.append((max(0, time - offset), text))
            }
        }

        let sorted = entries.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)

        return collapsingGaps(sorted).enumerated().map { index, entry in
            LyricLine(id: index, time: entry.time, text: entry.text)
        }
    }

    private static func seconds(from match: NSTextCheckingResult, in line: String) -> TimeInterval {
        func group(_ i: Int) -> Substring? {
            Range(match.range(at: i), in: line).map { line[$0] }
        }
        let minutes = Double(group(1) ?? "0") ?? 0
        let seconds = Double(group(2) ?? "0") ?? 0
        var fraction: Double = 0
        if let digits = group(3) {
            // ".4" = 400ms, ".40" = 400ms, ".400" = 400ms
            fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
        }
        return minutes * 60 + seconds + fraction
    }

    private static func strippingWordTags(_ text: String) -> String {
        wordTag.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// Drops leading and repeated empty lines so the UI never shows a stack of "♪".
    private static func collapsingGaps(_ entries: [(time: TimeInterval, text: String)]) -> [(time: TimeInterval, text: String)] {
        var result: [(time: TimeInterval, text: String)] = []
        for entry in entries {
            if entry.text.isEmpty, result.last?.text.isEmpty ?? true { continue }
            result.append(entry)
        }
        return result
    }
}
