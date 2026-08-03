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

    func makeCoordinator() -> Renderer {
        Renderer(controller: controller)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = Renderer.colorPixelFormat
        view.clearColor = Renderer.clearColor
        view.isOpaque = true

        // The camera view takes no part in touch handling — no gesture, and no
        // touchesBegan/Moved overrides. Every form of touch handling tried here
        // brought back a roughly one second stall before the effect picker would
        // appear, and removing it is the only thing that ever cleared it. The
        // shaders read a fixed centre touch point as a result.
        view.isUserInteractionEnabled = false

        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setEffect(controller.effect)

        // Never paused. Pausing stops the view's CADisplayLink, and that display
        // link is what wakes the main run loop each frame — without it an idle
        // run loop has nothing to drive the Core Animation commit, so a state
        // change can sit unrendered until something unrelated happens to wake
        // it. Rendering a hidden frame is far cheaper than that stall.

        // autoResizeDrawable sizes the drawable from bounds × contentScaleFactor,
        // so capping the scale here is what keeps the fragment cost down. The
        // layer scales the smaller drawable back up to fill the screen.
        let displayScale = view.traitCollection.displayScale
        if displayScale > 0 {
            let capped = min(displayScale, Renderer.maximumDrawableScale)
            if view.contentScaleFactor != capped {
                view.contentScaleFactor = capped
            }
        }
    }
}
