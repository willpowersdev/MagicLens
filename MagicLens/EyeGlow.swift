//
//  EyeGlow.swift
//  MagicLens
//

import CoreGraphics
import simd

/// Tuning for the eye glow.
///
/// Deliberately free of Metal and Vision so the timing and geometry can be
/// tested with plain values — the parts most likely to be wrong are the
/// coordinate conversion and the frame-rate independence, and neither needs a
/// GPU or a camera to check.
struct EyeGlowConfiguration: Sendable, Equatable {

    var glowColor = SIMD3<Float>(0.28, 0.76, 1.0)

    var eyeIntensity: Float = 3.0
    var coreContribution: Float = 0.90
    var bloomContribution: Float = 0.75
    var trailContribution: Float = 0.55

    /// Blur radii for the three bloom scales, in pixels at each one's own size.
    var bloomSigmaSmall: Float = 4.0
    var bloomSigmaMedium: Float = 12.0
    var bloomSigmaLarge: Float = 28.0

    /// How much of the previous trail survives one frame *at 60fps*. The actual
    /// per-frame figure is derived from elapsed time — see `decay(forElapsed:)`.
    var trailDecayAt60FPS: Float = 0.92
    var trailInputContribution: Float = 0.75
    var trailBlurSigma: Float = 2.0

    /// Ceiling on accumulated trail brightness. Without it the feedback loop
    /// compounds and the screen washes out.
    var maximumTrailBrightness: Float = 5.0

    var landmarkSmoothing: Float = 0.32
    var predictionSeconds: Float = 0.015

    var minimumTrackingConfidence: Float = 0.45

    /// Eye openness is height over width of the contour. Below the first the
    /// eye reads as shut, above the second as fully open.
    var minimumEyeOpenness: Float = 0.08
    var fullEyeOpenness: Float = 0.28

    var maximumTrailLengthUV: Float = 0.05
    var velocityTrailScale: Float = 2.5

    /// How long tracking may be absent before the trail is cleared outright
    /// rather than left to decay.
    var trackingLossTimeout: Double = 0.75

    var sanitized: EyeGlowConfiguration {
        var copy = self

        copy.glowColor = simd_clamp(glowColor, SIMD3(repeating: 0), SIMD3(repeating: 1))
        copy.eyeIntensity = max(0, min(eyeIntensity, 20))
        copy.coreContribution = coreContribution.clamped(to: 0...4)
        copy.bloomContribution = bloomContribution.clamped(to: 0...4)
        copy.trailContribution = trailContribution.clamped(to: 0...4)

        copy.bloomSigmaSmall = max(0.1, min(bloomSigmaSmall, 64))
        copy.bloomSigmaMedium = max(0.1, min(bloomSigmaMedium, 64))
        copy.bloomSigmaLarge = max(0.1, min(bloomSigmaLarge, 64))

        // Strictly below 1, or the trail never fades and brightness runs away.
        copy.trailDecayAt60FPS = trailDecayAt60FPS.clamped(to: 0...0.995)
        copy.trailInputContribution = trailInputContribution.clamped(to: 0...2)
        copy.trailBlurSigma = max(0, min(trailBlurSigma, 16))
        copy.maximumTrailBrightness = max(0.1, min(maximumTrailBrightness, 64))

        copy.landmarkSmoothing = landmarkSmoothing.clamped(to: 0.01...1)
        copy.predictionSeconds = predictionSeconds.clamped(to: 0...0.2)
        copy.minimumTrackingConfidence = minimumTrackingConfidence.clamped(to: 0...1)

        copy.minimumEyeOpenness = max(0, min(minimumEyeOpenness, 1))
        copy.fullEyeOpenness = max(copy.minimumEyeOpenness + 0.001,
                                   min(fullEyeOpenness, 1))

        copy.maximumTrailLengthUV = maximumTrailLengthUV.clamped(to: 0...0.5)
        copy.velocityTrailScale = max(0, min(velocityTrailScale, 20))
        copy.trackingLossTimeout = max(0.05, min(trackingLossTimeout, 10))

        return copy
    }

    /// How much of the previous trail survives, given how long the frame took.
    ///
    /// Raising the per-60fps-frame figure to `elapsed × 60` keeps the trail the
    /// same *duration* whether the display is running at 30, 60 or 120 — a fixed
    /// per-frame decay would make it last twice as long at half the frame rate.
    /// The clamp stops a stalled frame wiping the trail outright.
    func decay(forElapsed elapsed: Double) -> Float {
        let clamped = min(max(elapsed, 1.0 / 240.0), 1.0 / 15.0)
        return pow(trailDecayAt60FPS, Float(clamped * 60))
    }
}

/// Geometry for one eye, in the same uv space every shader works in.
struct TrackedEye: Equatable {

    var contour: [SIMD2<Float>]
    var center: SIMD2<Float>

    /// 0 shut, 1 wide open, already smoothed through the configured range.
    var openness: Float

    /// uv per second.
    var velocity: SIMD2<Float>

    var confidence: Float
}

/// The geometry and timing behind the effect, kept apart from both Vision and
/// Metal so it can be exercised directly.
enum EyeGeometry {

    static func centroid(of points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else {
            return SIMD2(0.5, 0.5)
        }
        return points.reduce(SIMD2<Float>(0, 0), +) / Float(points.count)
    }

    static func bounds(of points: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let first = points.first else {
            return nil
        }

        var low = first
        var high = first

        for point in points.dropFirst() {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }

        return (low, high)
    }

    /// Height over width of the contour — a blink closes the box vertically
    /// while leaving its width alone, so the ratio falls towards zero.
    static func openness(of points: [SIMD2<Float>]) -> Float {
        guard let box = bounds(of: points) else {
            return 0
        }

        let size = box.max - box.min
        return size.y / max(size.x, 0.0001)
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else {
            return x >= edge1 ? 1 : 0
        }
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// Eases towards the new value rather than snapping to it. Raw Vision
    /// landmarks jitter frame to frame and would make the glow buzz.
    static func smooth(previous: SIMD2<Float>,
                       current: SIMD2<Float>,
                       alpha: Float) -> SIMD2<Float> {
        previous + (current - previous) * alpha.clamped(to: 0...1)
    }

    /// uv per second, with a ceiling.
    ///
    /// A tracking jump — the face lost and refound elsewhere — produces an
    /// enormous apparent velocity, and stretching the trail along it would fling
    /// a streak across the frame. Beyond the limit the velocity is discarded
    /// rather than clamped, since its direction is meaningless too.
    static func velocity(from previous: SIMD2<Float>,
                         to current: SIMD2<Float>,
                         elapsed: Double,
                         limit: Float = 4.0) -> SIMD2<Float> {

        let dt = Float(max(elapsed, 1.0 / 240.0))
        let v = (current - previous) / dt

        return length(v) > limit ? SIMD2(0, 0) : v
    }

    /// Nudges the position along its velocity to cover tracking latency. Only
    /// worth doing when the tracking is trustworthy, so the caller gates it.
    static func predicted(_ center: SIMD2<Float>,
                          velocity: SIMD2<Float>,
                          seconds: Float) -> SIMD2<Float> {
        center + velocity * seconds
    }

    /// Backwards along the motion, scaled and capped — the streak trails the
    /// eye rather than leading it.
    static func trailOffset(velocity: SIMD2<Float>,
                            configuration: EyeGlowConfiguration) -> (direction: SIMD2<Float>,
                                                                     length: Float) {
        let speed = length(velocity)

        guard speed > 1e-5 else {
            return (SIMD2(0, 0), 0)
        }

        let capped = min(speed * configuration.velocityTrailScale,
                         configuration.maximumTrailLengthUV)

        return (-velocity / speed, capped)
    }
}
