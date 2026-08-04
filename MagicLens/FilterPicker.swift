//
//  FilterPicker.swift
//  MagicLens
//

import SwiftUI

/// The effect list, presented as an overlay inside CameraView rather than a
/// sheet, so it appears the moment it is asked for. It therefore carries its
/// own background and dismiss control instead of relying on the presentation
/// environment.
struct FilterPicker: View {

    @Binding var selection: Effect

    let dismiss: () -> Void

    /// Opens the tuning panel for an effect that has one. Only the eye glow
    /// does so far, so the row carries the control rather than the toolbar —
    /// the bottom row is a fixed set of five and a sixth button that applied to
    /// one effect in seventeen would sit there disabled most of the time.
    var showSettings: ((Effect) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Deliberately a ScrollView of rows rather than a List. List is
            // UICollectionView backed, and standing that machinery up the first
            // time is far more work than eleven static rows justify — enough to
            // be visible as a delay when the picker is opened.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Effect.all) { effect in
                        row(for: effect)
                        Divider().padding(.leading, 20)
                    }
                }
                // Short labels stretched across a wide window leave the
                // checkmark stranded at the far edge, so the list keeps a
                // readable width and centres in whatever space there is.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.pageBackground)
        .ignoresSafeArea(edges: .bottom)
    }

    private func row(for effect: Effect) -> some View {
        HStack(spacing: 0) {
            Button {
                selection = effect
                dismiss()
            } label: {
                HStack {
                    Text(effect.title)
                    Spacer()
                    if effect == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)

            if effect.hasSettings, let showSettings {
                Button {
                    selection = effect
                    showSettings(effect)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(effect.title) settings")
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
    }

    private var header: some View {
        ZStack {
            Text("Effects")
                .font(.headline)

            HStack {
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
}

#Preview {
    @Previewable @State var selection = Effect.fisheye
    FilterPicker(selection: $selection) { }
}
