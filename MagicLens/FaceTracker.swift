//
//  FaceTracker.swift
//  MagicLens
//

import AVFoundation
import CoreGraphics
import simd

/// Where a face is on screen, in the coordinate space the effects already use.
struct TrackedFace: Equatable {

    /// Centre, in the same bottom-left-origin uv space every shader works in.
    var center: SIMD2<Float>

    /// Width and height as a fraction of the screen.
    var size: SIMD2<Float>

    /// Ramps 0→1 as a face is found and back down as it's lost, so effects fade
    /// rather than snapping on and off.
    var presence: Float

    static let none = TrackedFace(center: SIMD2(0.5, 0.5),
                                  size: SIMD2(0, 0),
                                  presence: 0)
}

/// Shared face tracking, published to every effect through the uniforms.
///
/// Detection comes from the capture session's own metadata output rather than
/// Vision: the hardware does it as part of capture, so a fragment-heavy app pays
/// almost nothing for it. The trade is that this gives bounding boxes only — no
/// landmarks. An effect wanting eyes or a mouth outline would need Vision
/// running alongside, which costs real time per frame.
///
/// Written from the capture session's metadata queue, read by the render loop.
final class FaceTracker {

    /// How quickly the tracked box follows the detected one. Raw detections
    /// jitter frame to frame; without this the effects visibly buzz.
    private static let followRate: Float = 0.35

    /// How long a face keeps its place after detection drops out. Faces are lost
    /// for a frame or two constantly — turning away, blinking, motion blur — and
    /// without a grace period effects would flicker.
    private static let graceSeconds = 0.35

    /// Seconds to fade fully in or out.
    private static let fadeSeconds: Float = 0.25

    private let lock = NSLock()

    private var tracked = TrackedFace.none
    private var target: TrackedFace?
    private var lastSeen: CFAbsoluteTime = 0

    /// The current face, advanced to `now`. Called once per rendered frame.
    func face(at now: CFAbsoluteTime, elapsed: Float) -> TrackedFace {
        lock.lock()
        defer { lock.unlock() }

        let fading = now - lastSeen > Self.graceSeconds || target == nil
        let step = min(1, elapsed / Self.fadeSeconds)

        if let target, !fading {
            // Chase the detection rather than snapping to it.
            let follow = min(1, Self.followRate)
            tracked.center += (target.center - tracked.center) * follow
            tracked.size += (target.size - tracked.size) * follow
            tracked.presence += (1 - tracked.presence) * step
        } else {
            tracked.presence += (0 - tracked.presence) * step
        }

        tracked.presence = min(1, max(0, tracked.presence))
        return tracked
    }

    /// Called from the capture session's metadata queue.
    ///
    /// `bufferIsLandscape` and `mirrored` must match what the shaders are told,
    /// or the face will be tracked somewhere other than where it's drawn.
    func update(faces: [AVMetadataFaceObject],
                bufferIsLandscape: Bool,
                mirrored: Bool,
                now: CFAbsoluteTime) {

        // Largest face wins — with several people in shot, the nearest one is
        // almost always the subject.
        guard let largest = faces.max(by: { $0.bounds.area < $1.bounds.area }) else {
            return
        }

        let box = Self.uvRect(fromBuffer: largest.bounds,
                              rotated: bufferIsLandscape,
                              mirrored: mirrored)

        lock.lock()
        defer { lock.unlock() }

        let found = TrackedFace(center: SIMD2(Float(box.midX), Float(box.midY)),
                                size: SIMD2(Float(box.width), Float(box.height)),
                                presence: 1)

        // First sighting after an absence starts where it was found, so it
        // doesn't glide in from wherever the last face was.
        if target == nil || now - lastSeen > Self.graceSeconds {
            tracked.center = found.center
            tracked.size = found.size
        }

        target = found
        lastSeen = now
    }

    /// Maps a metadata bounding box into the shaders' uv space.
    ///
    /// This is the exact inverse of `sampleVideo` in ShaderCommon.h, which takes
    /// uv to a buffer coordinate by
    ///
    ///     screen = (uv.x, 1 - uv.y)
    ///     screen.x = 1 - screen.x           (mirrored)
    ///     buffer = (screen.y, 1 - screen.x) (rotated)
    ///
    /// so going the other way undoes those in reverse. The two must stay in step
    /// — a face tracked in a different space to the one it's drawn in lands in
    /// the wrong place, and the error is easy to mistake for bad detection.
    static func uvRect(fromBuffer bounds: CGRect,
                       rotated: Bool,
                       mirrored: Bool) -> CGRect {

        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ].map { uvPoint(fromBuffer: $0, rotated: rotated, mirrored: mirrored) }

        let minX = min(corners[0].x, corners[1].x)
        let maxX = max(corners[0].x, corners[1].x)
        let minY = min(corners[0].y, corners[1].y)
        let maxY = max(corners[0].y, corners[1].y)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func uvPoint(fromBuffer point: CGPoint,
                        rotated: Bool,
                        mirrored: Bool) -> CGPoint {

        // Undo the quarter turn: buffer = (screen.y, 1 - screen.x).
        var screen = rotated ? CGPoint(x: 1 - point.y, y: point.x) : point

        if mirrored {
            screen.x = 1 - screen.x
        }

        // Back to the bottom-left origin the effects use.
        return CGPoint(x: screen.x, y: 1 - screen.y)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
