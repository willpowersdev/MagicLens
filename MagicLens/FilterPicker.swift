//
//  FilterPicker.swift
//  MagicLens
//

import SwiftUI

struct FilterPicker: View {

    @Binding var selection: Effect

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var selection = Effect.fisheye
    FilterPicker(selection: $selection)
}
