//
//  CameraView.swift
//  MagicLens
//

import SwiftUI

struct CameraView: View {

    @State private var controller = CameraController()
    @State private var isShowingPicker = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            MetalCameraView(controller: controller)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            controller.touch.normalized = SIMD2(
                                Float(value.location.x / proxy.size.width),
                                Float(value.location.y / proxy.size.height))
                        }
                )
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            controls
        }
        .sheet(isPresented: $isShowingPicker) {
            FilterPicker(selection: $controller.effect)
        }
        .onAppear {
            controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            // The capture session is the expensive resource here — hand the
            // camera back while the app isn't on screen.
            switch phase {
            case .active:
                controller.resume()
            case .inactive, .background:
                controller.pause()
            @unknown default:
                break
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                isShowingPicker = true
            } label: {
                Image("glitch_selector")
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            .accessibilityLabel("Choose effect")

            Spacer()

            Button {
                controller.flipCamera()
            } label: {
                Image("rotate_camera_icon")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .padding(8)
                    .background(.black.opacity(0.8), in: .circle)
            }
            .accessibilityLabel("Switch camera")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }
}

#Preview {
    CameraView()
}
