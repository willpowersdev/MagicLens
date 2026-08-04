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
            }
        }
        .background(Color.pageBackground)
        .ignoresSafeArea(edges: .bottom)
    }

    private func row(for effect: Effect) -> some View {
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
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
    }
}

#Preview {
    @Previewable @State var selection = Effect.fisheye
    FilterPicker(selection: $selection) { }
}
