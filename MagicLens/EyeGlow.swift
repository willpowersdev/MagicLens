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

    /// The centre of the eye burns out to white on its own — see the whitening
    /// in `eyeGlowFragment` — so this is the colour of the falloff and of the
    /// bloom around it, not of the core. A green that leans slightly cyan reads
    /// more clearly against skin than a pure one, which muddies where it meets
    /// the face.
    var glowColor = SIMD3<Float>(0.35, 1.0, 0.45)

    var eyeIntensity: Float = 7.12
    var coreContribution: Float = 1.76
    var bloomContribution: Float = 4.0
    var trailContribution: Float = 0.68

    /// Blur radii for the three bloom scales, in pixels at each one's own size.
    var bloomSigmaSmall: Float = 4.0
    var bloomSigmaMedium: Float = 12.0
    var bloomSigmaLarge: Float = 28.0

    /// How much of the previous trail survives one frame *at 60fps*. The actual
    /// per-frame figure is derived from elapsed time — see `decay(forElapsed:)`.
    /// The panel shows this as the time it takes to fade to half brightness,
    /// which for this figure is a tenth of a second.
    var trailDecayAt60FPS: Float = 0.805
    var trailInputContribution: Float = 0.75
    var trailBlurSigma: Float = 2.0

    /// Ceiling on accumulated trail brightness. Without it the feedback loop
    /// compounds and the screen washes out.
    var maximumTrailBrightness: Float = 5.0

    /// How far to chase a new landmark reading in one frame *at 60fps*, while
    /// the head is moving. The actual per-frame figure comes from elapsed time
    /// — see `follow(forElapsed:motion:)`.
    ///
    /// One, which is no smoothing at all: while the head is moving the drawn
    /// position is the predicted one, taken whole.
    ///
    /// Affordable only because the prediction starts from when the frame was
    /// taken rather than from when Vision finished, so what it is taking whole
    /// is where the eyes are rather than where they were. Jitter is left
    /// entirely to the still figure below, which is what a motionless head is
    /// filtered by — there is nothing else damping anything now.
    var landmarkSmoothing: Float = 1.0

    /// The same, while the head is still.
    ///
    /// Slower, but nothing like as slow as it was. At 0.08 this was a fifth of
    /// a second's time constant, and since it applies whenever the motion gate
    /// is anything short of certain, it was most of what made the tracking feel
    /// sluggish — the gate does not have to be wrong for long to be felt.
    ///
    /// A mild filter is enough for what it is fighting. The landmark wander is
    /// a few pixels; halving it is plenty, and it does not need a fifth of a
    /// second to do that. The gate being occasionally wrong then costs almost
    /// nothing, which is what makes the tighter thresholds below affordable.
    var stillSmoothing: Float = 0.30

    /// Below this speed, in uv per second, the eyes count as still.
    ///
    /// Vision's landmarks wander by a little every frame even from a
    /// completely still head. Divided by the gap between detections that reads
    /// as a real velocity, and everything downstream believes it: the glow is
    /// projected along it, and the trail smears in a fresh random direction
    /// each frame.
    ///
    /// The same wander across a shorter gap implies a higher speed, so raising
    /// the detection rate raises the noise floor this has to clear — which is
    /// how it climbed from 0.05 to 0.18 as the rate went from 12 to 40, and how
    /// it ended up above real movement. An eye is about 0.06 uv across, so 0.18
    /// is an eye-width every third of a second: unmistakably moving, and being
    /// filtered as though it were not.
    ///
    /// The answer is not a higher threshold but a quieter measurement. With the
    /// velocity averaged across a few readings the noise falls by
    /// `velocityNoiseFactor` and this can sit below anything anyone would call
    /// movement. `testStillnessSurvivesTheSamplingRate` holds it there.
    var stillnessThreshold: Float = 0.065

    /// At and above this speed they count as fully moving. Low enough that an
    /// unhurried movement — an eye crossing its own width in half a second —
    /// is most of the way out of the still filter rather than barely into it.
    var motionThreshold: Float = 0.18

    /// How much of a new velocity reading to take, per detection.
    ///
    /// Velocity is a difference between two positions divided by a very short
    /// interval, which multiplies the landmark noise rather than averaging it
    /// away — at a fortieth of a second, a wander of 0.003 uv reads as 0.12 uv
    /// per second from a head that has not moved at all. Averaging across a few
    /// readings costs a few tens of milliseconds in noticing that a movement
    /// has begun, and buys a velocity that can be believed.
    var velocitySmoothing: Float = 0.3

    /// What the averaging above does to the noise: the standard deviation of an
    /// exponential average with weight `a` is `sqrt(a / (2 - a))` of the input's.
    var velocityNoiseFactor: Float {
        let a = velocitySmoothing.clamped(to: 0.01...1)
        return (a / (2 - a)).squareRoot()
    }

    var minimumTrackingConfidence: Float = 0.45

    /// Eye openness is height over width of the contour. Below the first the
    /// eye reads as shut, above the second as fully open.
    var minimumEyeOpenness: Float = 0.08
    var fullEyeOpenness: Float = 0.28

    var maximumTrailLengthUV: Float = 0.15
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
        copy.velocitySmoothing = velocitySmoothing.clamped(to: 0.01...1)
        // Strictly above the stillness figure, or the ramp between them is a
        // step and the glow snaps between filters as the head starts to move.
        copy.motionThreshold = max(copy.stillnessThreshold + 0.01,
                                   motionThreshold.clamped(to: 0...8))
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
