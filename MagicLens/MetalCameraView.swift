//
//  MetalCameraView.swift
//  MagicLens
//

import MetalKit
import SwiftUI

/// SwiftUI has no native Metal view, so the MTKView is bridged. The renderer
/// doubles as the representable's coordinator, which gives it exactly the
/// lifetime SwiftUI expects to manage.
struct MetalCameraView: UIViewRepresentable {

    let controller: CameraController

    /// Rendering stops while something covers the view. The camera isn't visible
    /// behind a sheet, and the effects are expensive enough that leaving them
    /// running competes with the presentation animation.
    var isPaused: Bool = false

    func makeCoordinator() -> Renderer {
        Renderer(controller: controller)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = Renderer.colorPixelFormat
        view.clearColor = Renderer.clearColor
        view.isOpaque = true
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setEffect(controller.effect)
        view.isPaused = isPaused
    }
}
