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

            List(Effect.all) { effect in
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
                    .contentShape(.rect)
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)
        }
        .background(.background)
        .ignoresSafeArea(edges: .bottom)
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
