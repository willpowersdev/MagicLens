//
//  CameraView.swift
//  MagicLens
//

import SwiftUI

struct CameraView: View {

    @State private var controller = CameraController()
    @State private var isShowingPicker = false
    @State private var isShowingRecordings = false

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

            VStack {
                HStack {
                    Spacer()
                    libraryButton
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

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

            if isShowingRecordings {
                RecordingsGrid(library: controller.library) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isShowingRecordings = false
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
        // The record button is centred on the screen rather than spaced between
        // the others, which is why it sits in its own layer.
        ZStack {
            recordButton

            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isShowingPicker = true
                    }
                } label: {
                    // Drawn rather than an image, so it stays crisp at any scale
                    // and matches the fill of the buttons beside it.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.8))
                        .frame(width: 56, height: 56)
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
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// The familiar camera control: a ring with a red fill that squares off
    /// while recording.
    private var recordButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                controller.toggleRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                RoundedRectangle(cornerRadius: controller.isRecording ? 6 : 28,
                                 style: .continuous)
                    .fill(.red)
                    .frame(width: controller.isRecording ? 30 : 58,
                           height: controller.isRecording ? 30 : 58)
            }
        }
        .accessibilityLabel(controller.isRecording ? "Stop recording" : "Start recording")
    }

    /// Opens the library. Hidden while recording, so the grid can't be opened
    /// over a recording in progress.
    private var libraryButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                isShowingRecordings = true
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .padding(8)
                .background(.black.opacity(0.8), in: .circle)
        }
        .accessibilityLabel("Recordings")
        .opacity(controller.isRecording ? 0 : 1)
        .disabled(controller.isRecording)
    }
}

#Preview {
    CameraView()
}
