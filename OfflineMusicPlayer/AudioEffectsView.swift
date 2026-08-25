import SwiftUI

// MARK: - Equalizer
struct AudioEffectsView: View {
    @StateObject private var eq = EqualizerSettings.shared
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("Equalizer", isOn: $eq.isEnabled)
                    .tint(.purple)
            } footer: {
                Text("A 10-band equalizer applied to everything you play, in real time.")
            }

            Section("Presets") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(EQPreset.builtIn) { preset in
                            PresetChip(
                                preset: preset,
                                isSelected: eq.presetId == preset.id,
                                action: { withAnimation(.easeOut(duration: 0.18)) { eq.apply(preset: preset) } }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
            }

            Section {
                EqualizerBandsView(eq: eq)
                    .padding(.vertical, 8)
            } header: {
                HStack {
                    Text("Bands")
                    Spacer()
                    Text(eq.currentPreset.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("Drag any band to fine-tune. Editing a band switches the preset to Custom.")
            }
            .opacity(eq.isEnabled ? 1 : 0.45)
            .disabled(!eq.isEnabled)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preamp")
                        Spacer()
                        Text(String(format: "%+.0f dB", eq.preamp))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.purple)
                    }
                    Slider(
                        value: $eq.preamp,
                        in: EqualizerSettings.preampRange.lowerBound...EqualizerSettings.preampRange.upperBound,
                        step: 1
                    )
                    .tint(.purple)
                }
            } footer: {
                Text("Lower the preamp if boosted bands make loud tracks distort.")
            }
            .disabled(!eq.isEnabled)

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset to Flat", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset all bands to 0 dB?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                withAnimation { eq.resetToFlat() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Preset Chip
private struct PresetChip: View {
    let preset: EQPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(preset.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 78, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.purple : Color(UIColor.tertiarySystemFill))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Bands
/// Vertical gain sliders, one per band, driven by a drag gesture so all ten
/// fit comfortably across a phone screen.
private struct EqualizerBandsView: View {
    @ObservedObject var eq: EqualizerSettings

    private let trackHeight: CGFloat = 150

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(EqualizerSettings.frequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", gain(at: index)))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(gain(at: index) == 0 ? .secondary : .purple)

                    BandSlider(
                        value: Binding(
                            get: { eq.gains.indices.contains(index) ? eq.gains[index] : 0 },
                            set: { eq.setGain($0, forBand: index) }
                        ),
                        height: trackHeight
                    )

                    Text(EqualizerSettings.label(forFrequency: frequency))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(EqualizerSettings.label(forFrequency: frequency)) hertz")
                .accessibilityValue(String(format: "%+.0f decibels", gain(at: index)))
                .accessibilityAdjustableAction { direction in
                    let delta: Float = direction == .increment ? 1 : -1
                    eq.setGain(gain(at: index) + delta, forBand: index)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func gain(at index: Int) -> Float {
        eq.gains.indices.contains(index) ? eq.gains[index] : 0
    }
}

private struct BandSlider: View {
    @Binding var value: Float
    let height: CGFloat

    private let range = EqualizerSettings.gainRange

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knobY = height - (fraction * height)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 5)
                    .frame(maxWidth: .infinity)

                // Fill from the centre line out to the current gain.
                Capsule()
                    .fill(Color.purple.opacity(0.85))
                    .frame(width: 5, height: abs(knobY - height / 2))
                    .frame(maxWidth: .infinity)
                    .offset(y: min(knobY, height / 2))

                // Zero marker
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 1)
                    .offset(y: height / 2)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.purple, lineWidth: 2.5))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: 0, y: knobY - 8)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedY = min(max(drag.location.y, 0), height)
                        let newFraction = Float(1 - clampedY / height)
                        let newValue = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                        value = (newValue).rounded()
                    }
            )
        }
        .frame(height: height)
    }
}

#Preview {
    NavigationStack {
        AudioEffectsView()
    }
}
