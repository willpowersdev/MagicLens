//
//  EyeGlow.swift
//  MagicLens
//

import CoreGraphics
import simd

/// How much of the pipeline runs.
///
/// The glow's cost is almost entirely blur — three Gaussians over the emission
/// plus the trail's own — so the levels trade bloom scales and trail resolution
/// rather than anything to do with the tracking, which costs the same either
/// way and is shared with the other face effects regardless.
enum EyeGlowQuality: String, CaseIterable, Identifiable, Sendable {

    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// How many of the three bloom scales are blurred and composited. Dropping
    /// the widest first costs the least: it is the softest and the one the eye
    /// is least able to place.
    var bloomScales: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    /// The trail's size as a divisor of the drawable. Halving it again quarters
    /// the work of every trail pass.
    var trailDivisor: Int {
        switch self {
        case .low: 4
        case .medium, .high: 2
        }
    }

    /// The directional streak is a twelve-tap gather over the whole trail, and
    /// the first thing worth dropping when there is no headroom.
    var usesDirectionalBlur: Bool {
        self != .low
    }

    /// Multiplies the trail's blur. The extra softening is what makes a fast
    /// movement read as one continuous streak rather than a run of stamps.
    var trailDiffusion: Float {
        switch self {
        case .low, .medium: 1.0
        case .high: 1.8
        }
    }
}

/// Ways of looking at the glow while it is being worked on.
///
/// Every one of these exists because the effect can fail while looking
/// deliberate: a trail smeared the wrong way, a texture sampled upside down, or
/// contours tracked somewhere other than where they are drawn all render
/// perfectly happily.
struct EyeGlowDebugOptions: Sendable, Equatable {

    var showEyeContours = false
    var showEyeCenters = false
    var showVelocityVectors = false

    var showEmissionTexture = false
    var showBloomTexture = false
    var showTrailTexture = false

    /// Which intermediate to show full screen, if any. They are separate
    /// switches in the interface but only one image can be on screen, so the
    /// sharpest wins — it is the one whose geometry is easiest to read.
    var fullScreenTexture: EyeGlowDebugTexture {
        if showEmissionTexture { return .emission }
        if showBloomTexture { return .bloom }
        if showTrailTexture { return .trail }
        return .none
    }

    var drawsOverlay: Bool {
        showEyeContours || showEyeCenters || showVelocityVectors
    }

    var isActive: Bool {
        drawsOverlay || fullScreenTexture != .none
    }
}

/// Mirrors the selector the composite shader switches on.
enum EyeGlowDebugTexture: UInt32, Sendable, Equatable {
    case none = 0
    case emission = 1
    case bloom = 2
    case trail = 3
}

/// Tuning for the eye glow.
///
/// Deliberately free of Metal and Vision so the timing and geometry can be
/// tested with plain values — the parts most likely to be wrong are the
/// coordinate conversion and the frame-rate independence, and neither needs a
/// GPU or a camera to check.
struct EyeGlowConfiguration: Sendable, Equatable {

    /// Periwinkle rather than cyan: the centre of the eye burns out to white on
    /// its own — see the whitening in `eyeGlowFragment` — so this is the colour
    /// of the falloff and the bloom around it, not of the core.
    var glowColor = SIMD3<Float>(0.55, 0.52, 1.0)

    var eyeIntensity: Float = 4.5
    var coreContribution: Float = 1.0
    var bloomContribution: Float = 1.0
    var trailContribution: Float = 0.70

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

    /// How far to chase a new landmark reading in one frame *at 60fps*, while
    /// the head is moving. The actual per-frame figure comes from elapsed time
    /// — see `follow(forElapsed:motion:)`.
    var landmarkSmoothing: Float = 0.45

    /// The same, while the head is still.
    ///
    /// Deliberately far slower. One rate cannot serve both: quick enough to
    /// keep up with a turning head passes Vision's frame-to-frame jitter
    /// straight through, and slow enough to sit still lags. Which failure
    /// matters depends entirely on whether anything is moving.
    var stillSmoothing: Float = 0.08

    /// Below this speed, in uv per second, the eyes count as still.
    ///
    /// Vision's landmarks wander by a little every frame even from a
    /// completely still head. Divided by the gap between detections that reads
    /// as a real velocity, and everything downstream believes it: the glow is
    /// projected along it, and the trail smears in a fresh random direction
    /// each frame.
    var stillnessThreshold: Float = 0.05

    /// At and above this speed they count as fully moving.
    var motionThreshold: Float = 0.40

    /// How far ahead of the landmarks to draw, on top of cancelling their
    /// measured age. Covers what the age can't see: Vision's own processing,
    /// and the frame's trip to the display.
    var predictionSeconds: Float = 0.02

    var minimumTrackingConfidence: Float = 0.45

    /// Eye openness is height over width of the contour. Below the first the
    /// eye reads as shut, above the second as fully open.
    var minimumEyeOpenness: Float = 0.08
    var fullEyeOpenness: Float = 0.28

    var maximumTrailLengthUV: Float = 0.08
    var velocityTrailScale: Float = 2.5

    var quality = EyeGlowQuality.high

    var debug = EyeGlowDebugOptions()

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
        copy.stillSmoothing = stillSmoothing.clamped(to: 0.01...1)
        copy.stillnessThreshold = stillnessThreshold.clamped(to: 0...4)
        // Strictly above the stillness figure, or the ramp between them is a
        // step and the glow snaps between filters as the head starts to move.
        copy.motionThreshold = max(copy.stillnessThreshold + 0.01,
                                   motionThreshold.clamped(to: 0...8))
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

    /// How much of what the tracker is seeing is real movement rather than
    /// Vision's own noise: 0 while still, 1 while moving, easing between.
    ///
    /// Everything that makes stillness look unsettled is gated on this — the
    /// chase rate, the prediction and the trail's directional streak all read
    /// the same velocity, and all three misbehave in the same way when that
    /// velocity is noise.
    func motion(forSpeed speed: Float) -> Float {
        EyeGeometry.smoothstep(stillnessThreshold,
                               max(motionThreshold, stillnessThreshold + 1e-4),
                               speed)
    }

    /// How far to move towards the latest landmarks this frame.
    ///
    /// The same reasoning as `decay(forElapsed:)`, and for the same reason: a
    /// fixed per-frame fraction settles in a fixed number of *frames*, so the
    /// glow would trail further behind at 30 than at 120 and there would be no
    /// single value that felt right on both.
    ///
    /// `motion` picks where between the still and moving rates to sit, which
    /// is what lets the filter be steady and responsive rather than a
    /// compromise between the two.
    func follow(forElapsed elapsed: Double, motion: Float = 1) -> Float {
        let blend = motion.clamped(to: 0...1)
        let alpha = stillSmoothing + (landmarkSmoothing - stillSmoothing) * blend

        let clamped = min(max(elapsed, 1.0 / 240.0), 1.0 / 15.0)
        return 1 - pow(1 - alpha, Float(clamped * 60))
    }

    /// Never project further ahead than this, however stale the landmarks are.
    ///
    /// Vision stalling doesn't mean the head kept moving at the last measured
    /// speed, and extrapolating a long way on that assumption throws the glow
    /// off the face entirely — worse than the lag it is there to hide.
    static let maximumLeadSeconds = 0.12

    /// How far ahead to draw, given how long ago the landmarks were measured.
    ///
    /// Vision runs at a twelfth of the frame rate, so its results describe
    /// where the eyes were up to 80ms ago. Drawing them unchanged is most of
    /// the lag: the glow is chasing a position the head has already left.
    /// Advancing along the measured velocity by that same age cancels it.
    func lead(forLandmarkAge age: Double) -> Float {
        Float(min(max(age, 0), Self.maximumLeadSeconds)) + predictionSeconds
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
