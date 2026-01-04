import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 8) {
            if let url = player.currentURL {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("Not playing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text(timeString(player.progress))
                    .font(.caption)
                Slider(value: Binding(
                    get: { player.progress },
                    set: { newVal in player.seek(to: newVal) }
                ), in: 0...max(1, player.duration))
                Text(timeString(player.duration))
                    .font(.caption)
            }
            .padding([.leading, .trailing])

            HStack(spacing: 40) {
                Button(action: { player.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                Button(action: { player.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private func timeString(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let secs = Int(seconds)
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }
}

#if DEBUG
struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView().environmentObject(AudioPlayer())
    }
}
#endif
