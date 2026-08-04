//
//  MetalCameraView.swift
//  MagicLens
//

import MetalKit
import SwiftUI

/// Tracks where the pointer is so the shaders can follow it.
///
/// Plain responder handling rather than a SwiftUI gesture, which is how the
/// original UIKit version did it: no recogniser to arbitrate against the buttons
/// layered over this view. On iOS a SwiftUI DragGesture here also held the
/// system gesture gate and stalled presentations for a second at a time.
final class TrackingMTKView: MTKView {

    var touch: TouchState?

    /// `point` is in this view's own coordinates.
    private func track(_ point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        touch?.normalized = SIMD2(Float(point.x / bounds.width),
                                  Float(point.y / bounds.height))
    }

    #if os(macOS)

    /// Locks the window's proportions to the camera's, so resizing can't
    /// introduce bars or crop the picture.
    ///
    /// Fullscreen is the exception — the window takes the display's shape
    /// whatever it wants — and there the letterboxing in sampleVideo keeps the
    /// whole frame visible rather than cropping it.
    func matchWindowAspect(toVideo size: CGSize) {
        guard size.width > 0, size.height > 0, let window else {
            return
        }

        let ratio = NSSize(width: size.width, height: size.height)

        guard window.contentAspectRatio != ratio else {
            return
        }

        // contentAspectRatio, not aspectRatio: the latter constrains the whole
        // frame, so the title bar's height would be counted as picture and the
        // video would come out slightly the wrong shape.
        window.contentAspectRatio = ratio

        // The window is whatever shape it was before the camera started, so
        // bring it into line once, keeping its width and area roughly as they
        // were rather than jumping to the video's pixel size.
        guard !window.styleMask.contains(.fullScreen) else {
            return
        }

        let frame = window.frame
        let chrome = frame.height - window.contentLayoutRect.height
        let contentWidth = window.contentLayoutRect.width
        let height = (contentWidth * size.height / size.width) + chrome

        window.setFrame(NSRect(x: frame.origin.x,
                               y: frame.origin.y + (frame.height - height),
                               width: frame.width,
                               height: height),
                        display: true, animate: false)
    }

    /// AppKit's y axis runs the other way, so this flips to match UIKit — and
    /// therefore to match what the shaders were written against.
    private func track(event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        track(CGPoint(x: point.x, y: bounds.height - point.y))
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        track(event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        track(event: event)
    }

    /// Without a button held there is no drag, so hovering stands in for it —
    /// the effects that follow a finger on iOS follow the pointer here.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        track(event: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas {
            removeTrackingArea(area)
        }

        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
                                       owner: self,
                                       userInfo: nil))
    }

    #else

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        track(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        track(touches)
    }

    private func track(_ touches: Set<UITouch>) {
        guard let first = touches.first else {
            return
        }
        track(first.location(in: self))
    }

    #endif
}

/// SwiftUI has no native Metal view, so the MTKView is bridged. The renderer
/// doubles as the representable's coordinator, which gives it exactly the
/// lifetime SwiftUI expects to manage.
struct MetalCameraView: PlatformViewRepresentable {

    let controller: CameraController

    /// Draws the tracked face box over the effect, for checking detection.
    var showsFaceOverlay = false

    func makeCoordinator() -> Renderer {
        Renderer(controller: controller)
    }

    private func makeView(context: Context) -> MTKView {
        let view = TrackingMTKView(frame: .zero, device: controller.device)
        view.touch = controller.touch
        view.delegate = context.coordinator
        view.colorPixelFormat = Renderer.colorPixelFormat
        view.clearColor = Renderer.clearColor

        // Recording blits out of the drawable, which a framebufferOnly texture
        // can't be read from.
        view.framebufferOnly = false

        #if !os(macOS)
        view.isOpaque = true
        #endif

        return view
    }

    private func updateView(_ view: MTKView, context: Context) {
        context.coordinator.setEffect(controller.effect)
        context.coordinator.showsFaceOverlay = showsFaceOverlay

        // Paused only when the app is out of sight, never merely because
        // nothing appears to be changing.
        //
        // Pausing stops the view's display link, and that display link is what
        // wakes the main run loop each frame. Without it an idle run loop has
        // nothing to drive the Core Animation commit, so a state change can sit
        // unrendered until something unrelated happens to wake it — which is
        // why redrawing an apparently unchanged frame is worth the cost while
        // the app is on screen. Once it isn't, there is no commit to drive and
        // no frame anyone can see, so the objection doesn't apply and the whole
        // pipeline can stop.
        view.isPaused = controller.isPaused

        // The drawable is left at the display's own scale. Rendering and
        // recording therefore happen at full native resolution.
    }

    #if os(macOS)

    func makeNSView(context: Context) -> MTKView {
        makeView(context: context)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        updateView(view, context: context)
    }

    #else

    func makeUIView(context: Context) -> MTKView {
        makeView(context: context)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        updateView(view, context: context)
    }

    #endif
}
