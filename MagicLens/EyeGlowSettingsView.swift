//
//  EyeGlowSettingsView.swift
//  MagicLens
//

import SwiftUI

/// The eye glow's tuning, live.
///
/// An overlay rather than a sheet, for the same reason the effect picker is
/// one — and more so here, since the whole point is to watch the camera change
/// as a slider moves. It sits over the bottom of the frame and leaves the face
/// visible above it.
struct EyeGlowSettingsView: View {

    @Binding var configuration: EyeGlowConfiguration

    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    appearance
                    trail
                    tracking
                    performance
                    debugging
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.pageBackground)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Sections

    private var appearance: some View {
        section("Appearance") {
            ColorPicker("Glow colour", selection: colorBinding, supportsOpacity: false)
                .font(.subheadline)

            slider("Intensity", value: $configuration.eyeIntensity, in: 0...20)
            slider("Core", value: $configuration.coreContribution, in: 0...4)
            slider("Bloom", value: $configuration.bloomContribution, in: 0...4)
        }
    }

    private var trail: some View {
        section("Trail") {
            slider("Strength", value: $configuration.trailContribution, in: 0...4)

            // Shown as the seconds it takes to fade rather than the per-frame
            // survival figure, which is meaningless to look at and bunched up
            // against 1 where all the useful range is.
            slider("Length", value: $configuration.trailDecayAt60FPS, in: 0.5...0.995,
                   format: { String(format: "%.1fs", halfLifeSeconds(of: $0)) })

            slider("Streak", value: $configuration.maximumTrailLengthUV, in: 0...0.5)
            slider("Softness", value: $configuration.trailBlurSigma, in: 0...16)
        }
    }

    private var tracking: some View {
        section("Tracking") {
            slider("Smoothing", value: $configuration.landmarkSmoothing, in: 0.01...1)

            // Lower is steadier. Separate from the figure above because the
            // two are answering different questions: that one is how quickly
            // to keep up, this one is how hard to sit still.
            slider("Steadiness", value: $configuration.stillSmoothing, in: 0.01...1,
                   format: { String(format: "%.2f", $0) })

            slider("Confidence", value: $configuration.minimumTrackingConfidence, in: 0...1)
            slider("Blink floor", value: $configuration.minimumEyeOpenness, in: 0...1)
            slider("Blink ceiling", value: $configuration.fullEyeOpenness, in: 0...1)
        }
    }

    private var performance: some View {
        section("Performance") {
            Picker("Quality", selection: $configuration.quality) {
                ForEach(EyeGlowQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)

            Text(qualityDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var debugging: some View {
        section("Debugging") {
            Toggle("Eye contours", isOn: $configuration.debug.showEyeContours)
            Toggle("Eye centres", isOn: $configuration.debug.showEyeCenters)
            Toggle("Velocity", isOn: $configuration.debug.showVelocityVectors)

            Divider()

            // Only one image can be on screen, so these behave as a choice even
            // though the underlying options are separate switches: turning one
            // on turns the others off, rather than leaving two lit and one of
            // them quietly ignored.
            Toggle("Show emission", isOn: exclusive(\.showEmissionTexture))
            Toggle("Show bloom", isOn: exclusive(\.showBloomTexture))
            Toggle("Show trail", isOn: exclusive(\.showTrailTexture))
        }
        .font(.subheadline)
    }

    // MARK: - Pieces

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func slider(_ title: String,
                        value: Binding<Float>,
                        in range: ClosedRange<Float>,
                        format: ((Float) -> String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format?(value.wrappedValue) ?? String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)

            Slider(value: value, in: range)
        }
    }

    private var header: some View {
        ZStack {
            Text("Night Elf")
                .font(.headline)

            HStack {
                Button("Reset") {
                    // Debug switches are a viewing mode rather than part of the
                    // look, so they survive a reset of the tuning.
                    let debug = configuration.debug
                    configuration = EyeGlowConfiguration()
                    configuration.debug = debug
                }

                Spacer()

                Button("Done", action: dismiss)
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bindings

    private var colorBinding: Binding<Color> {
        Binding {
            Color(.sRGB,
                  red: Double(configuration.glowColor.x),
                  green: Double(configuration.glowColor.y),
                  blue: Double(configuration.glowColor.z))
        } set: { colour in
            let resolved = colour.resolve(in: EnvironmentValues())
            configuration.glowColor = SIMD3(Float(resolved.red),
                                            Float(resolved.green),
                                            Float(resolved.blue))
        }
    }

    /// A switch that clears the other two full-screen views when it is turned
    /// on, so the interface can't claim to be showing two things at once.
    private func exclusive(
        _ keyPath: WritableKeyPath<EyeGlowDebugOptions, Bool>
    ) -> Binding<Bool> {

        Binding {
            configuration.debug[keyPath: keyPath]
        } set: { isOn in
            configuration.debug.showEmissionTexture = false
            configuration.debug.showBloomTexture = false
            configuration.debug.showTrailTexture = false
            configuration.debug[keyPath: keyPath] = isOn
        }
    }

    // MARK: - Readouts

    /// How long the trail takes to fall to half brightness, which is what the
    /// decay figure means in the only terms anyone can see.
    private func halfLifeSeconds(of decayAt60: Float) -> Float {
        guard decayAt60 > 0, decayAt60 < 1 else {
            return 0
        }
        return log(0.5) / (log(decayAt60) * 60)
    }

    private var qualityDescription: String {
        switch configuration.quality {
        case .low:
            "One bloom scale, quarter-resolution trail, no motion streak."
        case .medium:
            "Two bloom scales, half-resolution trail, motion streak."
        case .high:
            "Three bloom scales, half-resolution trail, streak and extra diffusion."
        }
    }
}

#Preview {
    @Previewable @State var configuration = EyeGlowConfiguration()
    EyeGlowSettingsView(configuration: $configuration) { }
}
