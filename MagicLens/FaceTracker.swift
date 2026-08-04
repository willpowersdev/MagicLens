//
//  FaceTracker.swift
//  MagicLens
//

import AVFoundation
import CoreGraphics
import Vision
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

    /// Eye and pupil centres, in that same uv space. Vision's naming: "left" is
    /// the subject's left, which on a mirrored selfie is the one on the left of
    /// the screen and on the back camera is the one on the right.
    var leftEye: SIMD2<Float>
    var rightEye: SIMD2<Float>
    var leftPupil: SIMD2<Float>
    var rightPupil: SIMD2<Float>

    /// Separate from `presence`: the box comes from the capture hardware every
    /// frame, the eyes from Vision far less often, and either can be missing
    /// while the other is good.
    var eyePresence: Float

    /// The visible gap between the lips, already eroded, in uv space. Empty
    /// when the mouth is shut or Vision hasn't found one.
    var mouth: [SIMD2<Float>]

    /// Rough size of the face, for scaling things measured against it.
    var faceSpan: Float { max(size.x, size.y) }

    /// Height of the mouth opening in uv, which is the small dimension and the
    /// one anything drawn inside it has to be measured against.
    var mouthHeight: Float {
        guard mouth.count >= 3 else {
            return 0
        }
        let ys = mouth.map(\.y)
        let xs = mouth.map(\.x)
        return min(ys.max()! - ys.min()!, xs.max()! - xs.min()!)
    }

    /// Fades the mouth effect rather than switching it, so a missed detection
    /// or a moment of speech doesn't flash.
    var mouthOpacity: Float

    /// Eye openings as contours rather than points, so the glow can follow the
    /// eye's actual shape instead of stamping a circle on it.
    var leftEyeShape: [SIMD2<Float>]
    var rightEyeShape: [SIMD2<Float>]

    /// 0 shut, 1 wide open, already through the configured range.
    var leftOpenness: Float
    var rightOpenness: Float

    /// uv per second, for trailing the glow behind a moving head.
    var leftVelocity: SIMD2<Float>
    var rightVelocity: SIMD2<Float>

    static let none = TrackedFace(center: SIMD2(0.5, 0.5),
                                  size: SIMD2(0, 0),
                                  presence: 0,
                                  leftEye: SIMD2(0.5, 0.5),
                                  rightEye: SIMD2(0.5, 0.5),
                                  leftPupil: SIMD2(0.5, 0.5),
                                  rightPupil: SIMD2(0.5, 0.5),
                                  eyePresence: 0,
                                  mouth: [],
                                  mouthOpacity: 0,
                                  leftEyeShape: [],
                                  rightEyeShape: [],
                                  leftOpenness: 0,
                                  rightOpenness: 0,
                                  leftVelocity: SIMD2(0, 0),
                                  rightVelocity: SIMD2(0, 0))
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

    /// Landmarks are expensive enough that running them every frame would eat
    /// the budget the effects need, and eyes don't move fast enough to warrant
    /// it. Between runs the smoothing carries them.
    private static let landmarkInterval = 1.0 / 12.0

    /// Landmarks go stale faster than the box does — a head turn invalidates
    /// them while the face is still perfectly well tracked.
    private static let landmarkGraceSeconds = 0.5

    private let lock = NSLock()
    private let visionQueue = DispatchQueue(label: "com.ion6.MagicLens.vision")

    private var tracked = TrackedFace.none
    private var target: TrackedFace?
    private var lastSeen: CFAbsoluteTime = 0

    private var eyeTarget: TrackedFace?
    private var lastLandmarks: CFAbsoluteTime = 0

    /// The face in the camera buffer's own space — normalised, top-left origin,
    /// unsmoothed.
    ///
    /// Separate from `tracked` because it is for a different consumer: Core ML
    /// crops the buffer, so it needs the box in buffer coordinates, and the uv
    /// box has already been through the rotation, the mirroring and the fit to
    /// the view. Going back the other way would mean inverting all three to
    /// recover a number that was in hand to begin with.
    ///
    /// Unsmoothed because the crop is padded well past the box; smoothing would
    /// buy nothing a 25% margin doesn't already cover.
    private var storedBufferFace: CGRect?
    private var lastBufferFace: CFAbsoluteTime = 0
    private var lastLandmarkAttempt: CFAbsoluteTime = 0
    private var visionInFlight = false

    /// The previous run's raw eye centres, for measuring velocity across two
    /// detections rather than against the smoothed position.
    private var measuredLeftEye: SIMD2<Float>?
    private var measuredRightEye: SIMD2<Float>?
    private var storedConfiguration = TeethHighlightConfiguration()
    private var storedEyeGlow = EyeGlowConfiguration()
    private var loggedMouth = false

    /// The latest face box in the camera buffer's own space, or nil when it has
    /// gone stale. Fed to `FaceParsing`, which crops that buffer.
    ///
    /// Filled from whichever detector ran most recently: the hardware's metadata
    /// boxes where they exist, and Vision's own bounding box otherwise. Both
    /// measure the same buffer, and a Mac has only the second.
    func bufferFaceBox(at now: CFAbsoluteTime) -> CGRect? {

        lock.lock()
        defer { lock.unlock() }

        guard let storedBufferFace, now - lastBufferFace <= Self.graceSeconds else {
            return nil
        }

        return storedBufferFace
    }

    /// Eases a contour towards a new one, vertex by vertex.
    ///
    /// Only meaningful when the two correspond. A different point count means
    /// Vision returned a different shape, so the new one is taken as it is
    /// rather than easing between unrelated vertices.
    private static func follow(_ current: [SIMD2<Float>],
                               towards target: [SIMD2<Float>],
                               rate: Float) -> [SIMD2<Float>] {

        guard current.count == target.count else {
            return target
        }

        return zip(current, target).map { $0 + ($1 - $0) * rate }
    }

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

        let eyesStale = now - lastLandmarks > Self.landmarkGraceSeconds

        if let eyeTarget, !eyesStale {
            let settings = storedEyeGlow

            // Whether anything is actually moving. Both eyes are read, and the
            // faster wins: a head turning about its own axis barely shifts the
            // far eye, and taking the average would call that stillness.
            let speed = max(length(eyeTarget.leftVelocity),
                            length(eyeTarget.rightVelocity))
            let motion = settings.motion(forSpeed: speed)

            // Time-based, so the glow settles in the same number of
            // milliseconds at any frame rate, and steadier the stiller the
            // head is.
            let follow = settings.follow(forElapsed: Double(elapsed), motion: motion)

            // Landmarks describe where the eyes were when Vision ran, which at
            // a twelfth of the frame rate is most of a tenth of a second ago.
            // Chasing that position unchanged is the bulk of the lag, so the
            // reading is carried forward along its own velocity first — the
            // glow then chases where the eyes are rather than where they were.
            //
            // Scaled by motion, because projecting along a velocity that is
            // only jitter walks the glow around a face that is sitting still.
            let lead = settings.lead(forLandmarkAge: now - lastLandmarks) * motion

            let leftShift = eyeTarget.leftVelocity * lead
            let rightShift = eyeTarget.rightVelocity * lead

            let leftAhead = EyeGeometry.predicted(eyeTarget.leftEye,
                                                  velocity: eyeTarget.leftVelocity,
                                                  seconds: lead)
            let rightAhead = EyeGeometry.predicted(eyeTarget.rightEye,
                                                   velocity: eyeTarget.rightVelocity,
                                                   seconds: lead)

            tracked.leftEye += (leftAhead - tracked.leftEye) * follow
            tracked.rightEye += (rightAhead - tracked.rightEye) * follow

            // The pupils move with their own eye rather than being predicted
            // separately — they sit inside it, and two independent estimates
            // would let them drift out of it.
            tracked.leftPupil += (eyeTarget.leftPupil + leftShift - tracked.leftPupil) * follow
            tracked.rightPupil += (eyeTarget.rightPupil + rightShift - tracked.rightPupil) * follow
            tracked.eyePresence += (1 - tracked.eyePresence) * step

            // The contours themselves, on the same terms as the mouth below.
            // Without this the glow has nothing to draw: `tracked` is what the
            // renderer reads, and only the centres were ever carried across.
            // Shifted with their own eye, so the shape stays around the centre.
            tracked.leftEyeShape = Self.follow(tracked.leftEyeShape,
                                               towards: eyeTarget.leftEyeShape.map { $0 + leftShift },
                                               rate: follow)
            tracked.rightEyeShape = Self.follow(tracked.rightEyeShape,
                                                towards: eyeTarget.rightEyeShape.map { $0 + rightShift },
                                                rate: follow)

            tracked.leftOpenness += (eyeTarget.leftOpenness - tracked.leftOpenness) * follow
            tracked.rightOpenness += (eyeTarget.rightOpenness - tracked.rightOpenness) * follow

            // Not eased — it was already measured across the gap between
            // detections, which is the interval that matters — but faded out
            // as the head comes to rest. The trail's directional streak reads
            // this, and a noise velocity points somewhere new every frame,
            // which is a smear that flickers rather than a trail.
            tracked.leftVelocity = eyeTarget.leftVelocity * motion
            tracked.rightVelocity = eyeTarget.rightVelocity * motion
        } else {
            tracked.eyePresence += (0 - tracked.eyePresence) * step
        }

        // Time-based rather than per-frame, so the contour follows at the same
        // speed whether the display is running at 60 or dropping frames.
        let mouthFollow = 1 - exp(-storedConfiguration.landmarkResponsiveness * elapsed)

        if let eyeTarget, !eyesStale, !eyeTarget.mouth.isEmpty,
           tracked.mouth.count == eyeTarget.mouth.count {
            for index in tracked.mouth.indices {
                tracked.mouth[index] += (eyeTarget.mouth[index] - tracked.mouth[index]) * mouthFollow
            }
            tracked.mouthOpacity += (1 - tracked.mouthOpacity) * step
        } else {
            // Fades in roughly 150 ms — quick enough that a closed mouth or a
            // lost face doesn't leave the tint hanging.
            tracked.mouthOpacity += (0 - tracked.mouthOpacity) * min(1, elapsed / 0.15)
        }

        tracked.mouthOpacity = min(1, max(0, tracked.mouthOpacity))

        tracked.presence = min(1, max(0, tracked.presence))
        tracked.eyePresence = min(1, max(0, tracked.eyePresence))
        return tracked
    }

    /// Called from the capture session's metadata queue.
    ///
    /// `bufferIsLandscape` and `mirrored` must match what the shaders are told,
    /// or the face will be tracked somewhere other than where it's drawn.
    /// Whether the shaders are rotating the frame. The tracker has to agree,
    /// or faces are followed in a different space to the one they're drawn in.
    static func rotates(bufferIsLandscape: Bool) -> Bool {
        #if os(macOS)
        false
        #else
        bufferIsLandscape
        #endif
    }

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
                              rotated: Self.rotates(bufferIsLandscape: bufferIsLandscape),
                              mirrored: mirrored)

        lock.lock()
        defer { lock.unlock() }

        // Metadata bounds are already in the buffer's space, which is exactly
        // what the segmenter's crop wants.
        storedBufferFace = largest.bounds
        lastBufferFace = now

        var found = TrackedFace.none
        found.center = SIMD2(Float(box.midX), Float(box.midY))
        found.size = SIMD2(Float(box.width), Float(box.height))
        found.presence = 1

        // First sighting after an absence starts where it was found, so it
        // doesn't glide in from wherever the last face was.
        if target == nil || now - lastSeen > Self.graceSeconds {
            tracked.center = found.center
            tracked.size = found.size
        }

        target = found
        lastSeen = now
    }

    /// Offers a frame to Vision for eye and pupil landmarks.
    ///
    /// Called from the video queue for every frame, but only a fraction are
    /// actually run: landmark detection is far heavier than the hardware's face
    /// boxes, and one request is allowed in flight at a time so a slow frame
    /// can't pile up behind itself.
    func analyze(_ pixelBuffer: CVPixelBuffer,
                 bufferIsLandscape: Bool,
                 mirrored: Bool,
                 now: CFAbsoluteTime) {

        lock.lock()
        let shouldRun = !visionInFlight && now - lastLandmarkAttempt >= Self.landmarkInterval
        if shouldRun {
            visionInFlight = true
            lastLandmarkAttempt = now
        }
        lock.unlock()

        guard shouldRun else {
            return
        }

        visionQueue.async { [weak self] in
            self?.detectLandmarks(in: pixelBuffer,
                                  bufferIsLandscape: bufferIsLandscape,
                                  mirrored: mirrored)
        }
    }

    /// Runs on `visionQueue`.
    private func detectLandmarks(in pixelBuffer: CVPixelBuffer,
                                 bufferIsLandscape: Bool,
                                 mirrored: Bool) {

        defer {
            lock.lock()
            visionInFlight = false
            lock.unlock()
        }

        let request = VNDetectFaceLandmarksRequest()

        // Deliberately `.up`, leaving the buffer in its own orientation, so the
        // results come back in the space the proven inverse transform below
        // expects. Passing an orientation hint would put them in a rotated space
        // instead, needing a second, separately-guessed mapping — the sort of
        // thing that has looked like bad detection before now.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])

        do {
            try handler.perform([request])
        } catch {
            return
        }

        // Same rule the box uses — largest wins — so eyes and box agree about
        // who the subject is when there's more than one person in shot.
        guard let observations = request.results,
              let face = observations.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
              let landmarks = face.landmarks,
              let left = landmarks.leftEye,
              let right = landmarks.rightEye else {
            return
        }

        let box = face.boundingBox

        func uv(_ region: VNFaceLandmarkRegion2D?) -> SIMD2<Float>? {
            guard let region, region.pointCount > 0 else {
                return nil
            }

            // Region points are normalised inside the face box, so they go up
            // through the box to image space first.
            var sum = CGPoint.zero
            for point in region.normalizedPoints {
                sum.x += box.origin.x + point.x * box.width
                sum.y += box.origin.y + point.y * box.height
            }

            let centre = CGPoint(x: sum.x / CGFloat(region.pointCount),
                                 y: sum.y / CGFloat(region.pointCount))

            // Vision counts up from the bottom left; the buffer space the
            // inverse transform works in counts down from the top left.
            let inBuffer = CGPoint(x: centre.x, y: 1 - centre.y)

            let mapped = Self.uvPoint(fromBuffer: inBuffer,
                                      rotated: Self.rotates(bufferIsLandscape: bufferIsLandscape),
                                      mirrored: mirrored)

            return SIMD2(Float(mapped.x), Float(mapped.y))
        }

        guard let leftEye = uv(left), let rightEye = uv(right) else {
            return
        }

        // Every point of the inner lip contour, rather than its centre.
        func polygon(_ region: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
            guard let region, region.pointCount >= 3 else {
                return []
            }

            return region.normalizedPoints.map { point in
                let inImage = CGPoint(x: box.origin.x + point.x * box.width,
                                      y: box.origin.y + point.y * box.height)
                let inBuffer = CGPoint(x: inImage.x, y: 1 - inImage.y)
                let mapped = Self.uvPoint(fromBuffer: inBuffer,
                                          rotated: Self.rotates(bufferIsLandscape: bufferIsLandscape),
                                          mirrored: mirrored)
                return SIMD2(Float(mapped.x), Float(mapped.y))
            }
        }

        let faceBox = Self.uvRect(fromBuffer: CGRect(x: box.minX,
                                                     y: 1 - box.maxY,
                                                     width: box.width,
                                                     height: box.height),
                                  rotated: Self.rotates(bufferIsLandscape: bufferIsLandscape),
                                  mirrored: mirrored)
        let faceExtent = SIMD2(Float(faceBox.width), Float(faceBox.height))

        let leftShape = polygon(landmarks.leftEye)
        let rightShape = polygon(landmarks.rightEye)

        let rawMouth = polygon(landmarks.innerLips)

        // TEMPORARY diagnostic. The rendering half is proven by
        // TeethRenderTests; what can't be tested off-device is whether Vision
        // returns a usable innerLips contour for a face lying on its side,
        // which is how the buffer reaches it.
        if !loggedMouth {
            loggedMouth = true
            let ratio = MouthGeometry.area(of: rawMouth)
                / max(faceExtent.x * faceExtent.y, 1e-6)
            print("[MagicLens] innerLips points: \(landmarks.innerLips?.pointCount ?? -1), "
                  + "area ratio: \(ratio), threshold: \(configuration.minimumMouthArea)")
            if let first = rawMouth.first {
                print("[MagicLens] first mouth uv: \(first), face extent: \(faceExtent)")
            }
        }

        // A shut mouth still yields a contour — a sliver a couple of pixels
        // high. Left alone it reads as a bright line and gets tinted.
        let mouthOpen = MouthGeometry.isOpen(rawMouth,
                                             faceSize: faceExtent,
                                             minimumArea: configuration.minimumMouthArea)

        let mouth = mouthOpen
            ? MouthGeometry.eroded(rawMouth, by: configuration.polygonErosion)
            : []

        // Pupils are a single point each, and are the first thing Vision drops
        // when the eyes are narrowed or turned away — fall back to the eye
        // centre so an effect anchored to them doesn't jump to the origin.
        let leftPupil = uv(landmarks.leftPupil) ?? leftEye
        let rightPupil = uv(landmarks.rightPupil) ?? rightEye

        lock.lock()

        // Vision counts up from the bottom left; the buffer space the segmenter
        // crops in counts down from the top left. A Mac has no metadata face
        // output, so this is the only thing that fills it there.
        storedBufferFace = CGRect(x: box.minX,
                                  y: 1 - box.maxY,
                                  width: box.width,
                                  height: box.height)
        lastBufferFace = CFAbsoluteTimeGetCurrent()

        var found = TrackedFace.none
        found.leftEye = leftEye
        found.rightEye = rightEye
        found.leftPupil = leftPupil
        found.rightPupil = rightPupil

        // First landmarks after a gap start where they were found rather than
        // sliding in from where a previous face's eyes were.
        if eyeTarget == nil || CFAbsoluteTimeGetCurrent() - lastLandmarks > Self.landmarkGraceSeconds {
            tracked.leftEye = leftEye
            tracked.rightEye = rightEye
            tracked.leftPupil = leftPupil
            tracked.rightPupil = rightPupil
        }

        found.mouth = mouth
        found.leftEyeShape = leftShape
        found.rightEyeShape = rightShape

        // Openness comes from the contour's own proportions, so it needs the
        // raw shape rather than the smoothed one.
        // The stored value directly, not the accessor: the lock is already held
        // here and NSLock is not recursive.
        let settings = storedEyeGlow
        found.leftOpenness = EyeGeometry.smoothstep(settings.minimumEyeOpenness,
                                                    settings.fullEyeOpenness,
                                                    EyeGeometry.openness(of: leftShape))
        found.rightOpenness = EyeGeometry.smoothstep(settings.minimumEyeOpenness,
                                                     settings.fullEyeOpenness,
                                                     EyeGeometry.openness(of: rightShape))

        // Between successive measurements, not against the smoothed position.
        //
        // The smoothed value is deliberately behind, so measuring from it
        // reports the smoother's own error rather than how fast the head is
        // moving — and prediction built on that reading chases its own tail.
        // Two raw readings and the interval between them is the honest figure.
        let sinceLast = CFAbsoluteTimeGetCurrent() - lastLandmarks
        if lastLandmarks > 0, sinceLast < Self.landmarkGraceSeconds,
           let previousLeft = measuredLeftEye, let previousRight = measuredRightEye {

            found.leftVelocity = EyeGeometry.velocity(from: previousLeft,
                                                      to: leftEye,
                                                      elapsed: sinceLast)
            found.rightVelocity = EyeGeometry.velocity(from: previousRight,
                                                       to: rightEye,
                                                       elapsed: sinceLast)
        }

        measuredLeftEye = leftEye
        measuredRightEye = rightEye

        // Vertex-wise smoothing only makes sense when the contours correspond.
        // A different point count means Vision found a different shape, so take
        // it as it is rather than easing between unrelated vertices.
        if tracked.mouth.count != mouth.count {
            tracked.mouth = mouth
        }

        eyeTarget = found
        lastLandmarks = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Tuning for the eye glow, read on the Vision queue.
    var eyeGlowSettings: EyeGlowConfiguration {
        get { lock.withLock { storedEyeGlow } }
        set { lock.withLock { storedEyeGlow = newValue.sanitized } }
    }

    /// Tuning, read on the Vision queue and settable from anywhere.
    var configuration: TeethHighlightConfiguration {
        get { lock.withLock { storedConfiguration } }
        set { lock.withLock { storedConfiguration = newValue.sanitized } }
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
