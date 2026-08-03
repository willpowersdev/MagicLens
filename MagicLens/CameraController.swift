//
//  CameraController.swift
//  MagicLens
//

import MetalKit
import Observation

/// The current touch location, normalised to the view's bounds.
///
/// Deliberately kept outside the observation system: it changes on every drag
/// event and the renderer polls it once per frame, so publishing it would
/// invalidate the view hierarchy at touch frequency for no benefit.
final class TouchState {
    var normalized = SIMD2<Float>(0.5, 0.5)
}

/// Owns the pieces that have to outlive any particular view: the Metal device
/// and the capture session.
@Observable
final class CameraController {

    let device: MTLDevice
    let feed: CameraFeed

    /// A `let` holding a reference type, so the macro leaves it alone.
    let touch = TouchState()

    var effect: Effect = .crt

    init() {
        // Every device this app supports has Metal; there is no meaningful
        // degraded mode for a camera effects app without it.
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MagicLens requires a Metal capable device")
        }

        self.device = device
        self.feed = CameraFeed(metalDevice: device)
    }

    func start() {
        feed.startCapture()
    }

    func pause() {
        feed.pauseSession()
    }

    func resume() {
        feed.resumeSession()
    }

    func flipCamera() {
        feed.rotateCamera()
    }
}
