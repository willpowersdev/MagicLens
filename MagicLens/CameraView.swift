//
//  CameraView.swift
//  MagicLens
//

import SwiftUI

struct CameraView: View {

    @State private var controller = CameraController()
    @State private var isShowingPicker = false

    @Environment(\.scenePhase) private var scenePhase

    /// How far a finger must travel before it counts as tracking rather than a
    /// tap. Anything above zero is enough to keep taps out of the recogniser;
    /// this is roughly UIKit's own slop.
    private static let dragActivationDistance: CGFloat = 10

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                MetalCameraView(controller: controller, isPaused: isShowingPicker)
                    // Only engages once a finger has actually travelled. The
                    // original used minimumDistance 0, which claimed every touch
                    // the instant it landed — including taps on the buttons —
                    // and that held iOS's system gesture gate, which then sat on
                    // the picker's presentation for a full second before timing
                    // out. Requiring real movement means a tap never starts a
                    // continuous recogniser, and the sheet opens immediately.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: Self.dragActivationDistance)
                            .onChanged { value in
                                controller.touch.normalized = SIMD2(
                                    Float(value.location.x / proxy.size.width),
                                    Float(value.location.y / proxy.size.height))
                            }
                    )
            }
            .ignoresSafeArea()

            // Inside the safe area, deliberately. As an .overlay applied after
            // .ignoresSafeArea() these aligned to the physical screen bottom,
            // which put them in the home indicator's region — and tapping there
            // made the system gesture gate hold the sheet presentation until it
            // timed out, about a second later.
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
