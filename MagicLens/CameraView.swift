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
        ZStack(alignment: .bottom) {
            // No gesture here: touch tracking lives in the MTKView itself.
            // See TouchTrackingMTKView.
            MetalCameraView(controller: controller)
                .ignoresSafeArea()

            // Inside the safe area, deliberately — at the physical screen bottom
            // these sat in the home indicator's region.
            controls

            // Presented inside this hierarchy rather than with .sheet.
            //
            // Timing the sheet showed SwiftUI had the picker built in under
            // 130 ms while UIKit took another second to actually present it,
            // with the main thread idle throughout. Nothing in our code was on
            // that path, so the fix is to stay off it: an overlay animates
            // through SwiftUI alone and appears immediately.
            if isShowingPicker {
                FilterPicker(selection: $controller.effect) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isShowingPicker = false
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
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
                withAnimation(.easeOut(duration: 0.25)) {
                    isShowingPicker = true
                }
            } label: {
                // Drawn rather than an image, so it stays crisp at any scale and
                // matches the fill of the camera button beside it.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.8))
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
        .padding(.bottom, 8)
    }
}

#Preview {
    CameraView()
}
