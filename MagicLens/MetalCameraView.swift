//
//  MetalCameraView.swift
//  MagicLens
//

import MetalKit
import SwiftUI

/// Tracks where a finger is so the shaders can follow it.
///
/// Plain UIResponder touch handling rather than a SwiftUI gesture, which is how
/// the original UIKit version did it: no recogniser to arbitrate against the
/// buttons layered over this view.
final class TouchTrackingMTKView: MTKView {

    var touch: TouchState?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        track(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        track(touches)
    }

    private func track(_ touches: Set<UITouch>) {
        guard let first = touches.first,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let location = first.location(in: self)
        touch?.normalized = SIMD2(Float(location.x / bounds.width),
                                  Float(location.y / bounds.height))
    }
}

/// SwiftUI has no native Metal view, so the MTKView is bridged. The renderer
/// doubles as the representable's coordinator, which gives it exactly the
/// lifetime SwiftUI expects to manage.
struct MetalCameraView: UIViewRepresentable {

    let controller: CameraController

    func makeCoordinator() -> Renderer {
        Renderer(controller: controller)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = TouchTrackingMTKView(frame: .zero, device: controller.device)
        view.touch = controller.touch
        view.delegate = context.coordinator
        view.colorPixelFormat = Renderer.colorPixelFormat
        view.clearColor = Renderer.clearColor
        view.isOpaque = true

        // Recording blits out of the drawable, which a framebufferOnly texture
        // can't be read from.
        view.framebufferOnly = false

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
