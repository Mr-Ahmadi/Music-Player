import SwiftUI

struct SleepTimerView: View {
    @ObservedObject private var timer = SleepTimer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if timer.isActive {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.indigo)

                        Text(timer.displayText ?? "")
                            .font(.system(size: 42, weight: .semibold, design: .rounded).monospacedDigit())

                        Text(timer.stopsAtEndOfTrack
                             ? "Playback stops when this track ends."
                             : "Music fades out and pauses when the timer ends.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if !timer.stopsAtEndOfTrack {
                    Section {
                        Button {
                            timer.extend(byMinutes: 5)
                        } label: {
                            Label("Add 5 minutes", systemImage: "plus.circle")
                        }
                        Button {
                            timer.extend(byMinutes: 15)
                        } label: {
                            Label("Add 15 minutes", systemImage: "plus.circle")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        timer.cancel()
                    } label: {
                        Label("Turn Off Timer", systemImage: "xmark.circle")
                    }
                }
            } else {
                Section {
                    ForEach(SleepTimerOption.presets) { option in
                        Button {
                            timer.start(option)
                            dismiss()
                        } label: {
                            HStack {
                                Label {
                                    Text(option.title)
                                        .foregroundColor(.primary)
                                } icon: {
                                    Image(systemName: option == .endOfTrack ? "music.note" : "timer")
                                        .foregroundColor(.indigo)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Stop playing after")
                } footer: {
                    Text("The volume eases down over the last few seconds instead of cutting off.")
                }
            }
        }
        .navigationTitle("Sleep Timer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { SleepTimerView() }
}
