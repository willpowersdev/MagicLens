//
//  EyeGlowTests.swift
//  MagicLensTests
//

import XCTest
import Metal
import simd
@testable import MagicLens

/// The timing and geometry behind the eye glow, exercised without a GPU or a
/// camera. These are the parts that fail quietly — a trail that lasts twice as
/// long at half the frame rate, or a streak flung across the screen by a
/// tracking jump, both look like artistic choices rather than bugs.
final class EyeGlowTests: XCTestCase {

    // MARK: - Frame rate independence

    /// The headline property: a trail should last the same number of seconds
    /// whether the display is running at 30, 60 or 120.
    func testTrailLastsTheSameTimeAtAnyFrameRate() {
        let configuration = EyeGlowConfiguration()

        func survivingAfterOneSecond(atFPS fps: Double) -> Float {
            let frame = 1.0 / fps
            let perFrame = configuration.decay(forElapsed: frame)
            return pow(perFrame, Float(fps))
        }

        let at30 = survivingAfterOneSecond(atFPS: 30)
        let at60 = survivingAfterOneSecond(atFPS: 60)
        let at120 = survivingAfterOneSecond(atFPS: 120)

        XCTAssertEqual(at30, at60, accuracy: 0.001)
        XCTAssertEqual(at60, at120, accuracy: 0.001)
    }

    func testDecayMatchesTheConfiguredFigureAtSixty() {
        let configuration = EyeGlowConfiguration()
        XCTAssertEqual(configuration.decay(forElapsed: 1.0 / 60.0),
                       configuration.trailDecayAt60FPS,
                       accuracy: 1e-5)
    }

    /// A stalled frame shouldn't wipe the trail outright, and a burst of very
    /// short frames shouldn't freeze it.
    func testDecayIsBoundedForExtremeFrameTimes() {
        let configuration = EyeGlowConfiguration()

        for elapsed in [0.0, 1e-6, 0.5, 10.0] {
            let decay = configuration.decay(forElapsed: elapsed)
            XCTAssertGreaterThan(decay, 0)
            XCTAssertLessThanOrEqual(decay, 1)
            XCTAssertFalse(decay.isNaN)
        }
    }

    /// Repeated accumulation has to settle rather than run away, or the screen
    /// washes out to white. With decay d and input c the steady state is
    /// c / (1 - d), and the shader's ceiling catches whatever exceeds it.
    func testAccumulationConverges() {
        let configuration = EyeGlowConfiguration()
        let decay = configuration.decay(forElapsed: 1.0 / 60.0)

        var value: Float = 0
        for _ in 0..<600 {
            value = min(value * decay + configuration.trailInputContribution,
                        configuration.maximumTrailBrightness)
        }

        XCTAssertLessThanOrEqual(value, configuration.maximumTrailBrightness)
        XCTAssertFalse(value.isNaN)
    }

    /// Landmark chasing has the same problem the trail does: a fixed per-frame
    /// fraction settles in a fixed number of frames, so the glow would sit
    /// further behind the eyes at 30 than at 120.
    func testSmoothingSettlesInTheSameTimeAtAnyFrameRate() {
        let configuration = EyeGlowConfiguration()

        func remainingAfterOneSecond(atFPS fps: Double) -> Float {
            let perFrame = configuration.follow(forElapsed: 1.0 / fps)
            return pow(1 - perFrame, Float(fps))
        }

        XCTAssertEqual(remainingAfterOneSecond(atFPS: 30),
                       remainingAfterOneSecond(atFPS: 60), accuracy: 0.001)
        XCTAssertEqual(remainingAfterOneSecond(atFPS: 60),
                       remainingAfterOneSecond(atFPS: 120), accuracy: 0.001)
    }

    func testSmoothingMatchesTheConfiguredFigureAtSixty() {
        let configuration = EyeGlowConfiguration()
        XCTAssertEqual(configuration.follow(forElapsed: 1.0 / 60.0),
                       configuration.landmarkSmoothing,
                       accuracy: 1e-5)
    }

    func testSmoothingNeverOvershootsOrStalls() {
        let configuration = EyeGlowConfiguration()

        for elapsed in [0.0, 1e-6, 1.0 / 120.0, 0.5, 10.0] {
            let follow = configuration.follow(forElapsed: elapsed)
            XCTAssertGreaterThan(follow, 0)
            XCTAssertLessThanOrEqual(follow, 1)
            XCTAssertFalse(follow.isNaN)
        }
    }

    // MARK: - Stillness

    /// The complaint this answers: a still head still had a wandering,
    /// flickering glow. Vision's landmarks move a little every frame, and
    /// divided by the gap between detections that reads as a real velocity —
    /// which the prediction projects along and the trail streaks along.
    func testAStillHeadReadsAsStill() {
        let configuration = EyeGlowConfiguration()

        XCTAssertEqual(configuration.motion(forSpeed: 0), 0)
        XCTAssertEqual(configuration.motion(forSpeed: configuration.stillnessThreshold * 0.5),
                       0, accuracy: 1e-6)
    }

    func testARealMovementReadsAsMovement() {
        let configuration = EyeGlowConfiguration()

        XCTAssertEqual(configuration.motion(forSpeed: configuration.motionThreshold),
                       1, accuracy: 1e-6)
        XCTAssertEqual(configuration.motion(forSpeed: 50), 1, accuracy: 1e-6)
    }

    /// A step between the two filters would snap as the head began to move.
    func testTheChangeBetweenStillAndMovingIsGradual() {
        let configuration = EyeGlowConfiguration()

        let midpoint = (configuration.stillnessThreshold + configuration.motionThreshold) / 2
        let middle = configuration.motion(forSpeed: midpoint)

        XCTAssertGreaterThan(middle, 0.1)
        XCTAssertLessThan(middle, 0.9)

        var previous: Float = -1
        for speed in stride(from: Float(0), through: 0.6, by: 0.02) {
            let value = configuration.motion(forSpeed: speed)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    /// The whole point of two rates: still is steadier than moving.
    func testStillnessIsFilteredHarderThanMovement() {
        let configuration = EyeGlowConfiguration()

        let still = configuration.follow(forElapsed: 1.0 / 60.0, motion: 0)
        let moving = configuration.follow(forElapsed: 1.0 / 60.0, motion: 1)

        XCTAssertLessThan(still, moving)
        XCTAssertEqual(still, configuration.stillSmoothing, accuracy: 1e-5)
        XCTAssertEqual(moving, configuration.landmarkSmoothing, accuracy: 1e-5)
    }

    /// Being steadier must not mean being frame-rate dependent again.
    func testTheStillFilterSettlesInTheSameTimeAtAnyFrameRate() {
        let configuration = EyeGlowConfiguration()

        func remainingAfterOneSecond(atFPS fps: Double) -> Float {
            let perFrame = configuration.follow(forElapsed: 1.0 / fps, motion: 0)
            return pow(1 - perFrame, Float(fps))
        }

        XCTAssertEqual(remainingAfterOneSecond(atFPS: 30),
                       remainingAfterOneSecond(atFPS: 120), accuracy: 0.001)
    }

    /// An inverted or collapsed range turns the ramp back into a step.
    func testTheMotionRangeCannotCollapse() {
        var configuration = EyeGlowConfiguration()
        configuration.stillnessThreshold = 0.9
        configuration.motionThreshold = 0.1

        let clean = configuration.sanitized

        XCTAssertGreaterThan(clean.motionThreshold, clean.stillnessThreshold)
        XCTAssertGreaterThan(clean.motion(forSpeed: 10), 0.9)
    }

    // MARK: - Prediction

    /// The lag being fixed: Vision runs at a twelfth of the frame rate, so its
    /// answer is up to 80ms old by the time it is drawn. Cancelling that age
    /// is most of what stops the glow chasing the eyes.
    func testTheLeadCancelsTheAgeOfTheLandmarks() {
        let configuration = EyeGlowConfiguration()

        let lead = configuration.lead(forLandmarkAge: 1.0 / 12.0)

        XCTAssertEqual(lead,
                       Float(1.0 / 12.0) + configuration.predictionSeconds,
                       accuracy: 1e-5)
    }

    /// Fresh landmarks still lead a little, for the part of the pipeline the
    /// age can't see.
    func testFreshLandmarksStillLeadSlightly() {
        let configuration = EyeGlowConfiguration()

        XCTAssertEqual(configuration.lead(forLandmarkAge: 0),
                       configuration.predictionSeconds,
                       accuracy: 1e-6)
    }

    /// Vision stalling doesn't mean the head kept moving. Extrapolating a long
    /// way on that assumption throws the glow clean off the face, which is
    /// worse than the lag.
    func testTheLeadIsCappedWhenTrackingStalls() {
        let configuration = EyeGlowConfiguration()

        let stalled = configuration.lead(forLandmarkAge: 5)

        XCTAssertEqual(stalled,
                       Float(EyeGlowConfiguration.maximumLeadSeconds)
                           + configuration.predictionSeconds,
                       accuracy: 1e-5)
    }

    func testANegativeAgeDoesNotDragTheGlowBackwards() {
        let configuration = EyeGlowConfiguration()
        XCTAssertGreaterThanOrEqual(configuration.lead(forLandmarkAge: -1), 0)
    }

    // MARK: - Geometry

    private let eye = [SIMD2<Float>(0.40, 0.50), SIMD2<Float>(0.45, 0.53),
                       SIMD2<Float>(0.50, 0.50), SIMD2<Float>(0.45, 0.47)]

    func testCentroidOfASymmetricContour() {
        let centre = EyeGeometry.centroid(of: eye)
        XCTAssertEqual(centre.x, 0.45, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 0.50, accuracy: 1e-6)
    }

    func testCentroidOfNothingIsTheMiddle() {
        XCTAssertEqual(EyeGeometry.centroid(of: []), SIMD2(0.5, 0.5))
    }

    func testBoundsCoverEveryPoint() {
        guard let box = EyeGeometry.bounds(of: eye) else {
            return XCTFail("no bounds")
        }

        for point in eye {
            XCTAssertGreaterThanOrEqual(point.x, box.min.x - 1e-6)
            XCTAssertLessThanOrEqual(point.x, box.max.x + 1e-6)
            XCTAssertGreaterThanOrEqual(point.y, box.min.y - 1e-6)
            XCTAssertLessThanOrEqual(point.y, box.max.y + 1e-6)
        }
    }

    // MARK: - Openness

    func testAnOpenEyeIsTallerRelativeToItsWidth() {
        // 0.10 wide, 0.06 tall.
        let open = EyeGeometry.openness(of: eye)
        XCTAssertEqual(open, 0.6, accuracy: 1e-5)
    }

    func testAClosedEyeApproachesZeroOpenness() {
        let shut = [SIMD2<Float>(0.40, 0.50), SIMD2<Float>(0.50, 0.50),
                    SIMD2<Float>(0.50, 0.502), SIMD2<Float>(0.40, 0.502)]

        XCTAssertLessThan(EyeGeometry.openness(of: shut), 0.05)
    }

    /// A blink should fade the glow rather than switch it off, so the value has
    /// to move through the middle of the range instead of stepping.
    func testOpennessFadesRatherThanSteps() {
        let configuration = EyeGlowConfiguration()

        let shut = EyeGeometry.smoothstep(configuration.minimumEyeOpenness,
                                          configuration.fullEyeOpenness, 0.02)
        let half = EyeGeometry.smoothstep(configuration.minimumEyeOpenness,
                                          configuration.fullEyeOpenness, 0.18)
        let open = EyeGeometry.smoothstep(configuration.minimumEyeOpenness,
                                          configuration.fullEyeOpenness, 0.40)

        XCTAssertEqual(shut, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(half, 0.1)
        XCTAssertLessThan(half, 0.9)
        XCTAssertEqual(open, 1, accuracy: 1e-6)
    }

    func testSmoothstepIsMonotonic() {
        var previous: Float = -1
        for x in stride(from: Float(0), through: 1, by: 0.05) {
            let value = EyeGeometry.smoothstep(0.1, 0.4, x)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: - Smoothing and velocity

    func testSmoothingMovesTowardsTheTargetWithoutOvershooting() {
        let from = SIMD2<Float>(0, 0)
        let to = SIMD2<Float>(1, 1)

        let stepped = EyeGeometry.smooth(previous: from, current: to, alpha: 0.25)

        XCTAssertEqual(stepped.x, 0.25, accuracy: 1e-6)
        XCTAssertGreaterThan(stepped.x, from.x)
        XCTAssertLessThan(stepped.x, to.x)
    }

    func testSmoothingWithAlphaOneSnaps() {
        let result = EyeGeometry.smooth(previous: SIMD2(0, 0),
                                        current: SIMD2(1, 1),
                                        alpha: 1)
        XCTAssertEqual(result, SIMD2(1, 1))
    }

    func testVelocityIsPerSecondNotPerFrame() {
        // A tenth of the frame in a sixtieth of a second is 6 uv per second.
        let v = EyeGeometry.velocity(from: SIMD2(0.5, 0.5),
                                     to: SIMD2(0.6, 0.5),
                                     elapsed: 1.0 / 60.0,
                                     limit: 100)

        XCTAssertEqual(v.x, 6, accuracy: 1e-3)
        XCTAssertEqual(v.y, 0, accuracy: 1e-6)
    }

    /// The face lost and refound elsewhere reads as an enormous velocity.
    /// Stretching a streak along it would fling it across the frame, so the
    /// reading is discarded rather than clamped — its direction is meaningless
    /// too.
    func testATrackingJumpProducesNoVelocity() {
        let v = EyeGeometry.velocity(from: SIMD2(0.1, 0.1),
                                     to: SIMD2(0.9, 0.9),
                                     elapsed: 1.0 / 60.0)

        XCTAssertEqual(v, SIMD2(0, 0))
    }

    func testVelocityHandlesAZeroInterval() {
        let v = EyeGeometry.velocity(from: SIMD2(0.5, 0.5),
                                     to: SIMD2(0.5, 0.5),
                                     elapsed: 0)

        XCTAssertFalse(v.x.isNaN)
        XCTAssertFalse(v.y.isNaN)
    }

    func testPredictionLeadsTheMotion() {
        let ahead = EyeGeometry.predicted(SIMD2(0.5, 0.5),
                                          velocity: SIMD2(1, 0),
                                          seconds: 0.02)
        XCTAssertEqual(ahead.x, 0.52, accuracy: 1e-6)
    }

    // MARK: - Trail direction

    func testTheStreakPointsBackAlongTheMotion() {
        let configuration = EyeGlowConfiguration()
        let streak = EyeGeometry.trailOffset(velocity: SIMD2(1, 0),
                                             configuration: configuration)

        XCTAssertEqual(streak.direction.x, -1, accuracy: 1e-6)
        XCTAssertGreaterThan(streak.length, 0)
    }

    func testTheStreakIsCappedForFastMotion() {
        let configuration = EyeGlowConfiguration()
        let streak = EyeGeometry.trailOffset(velocity: SIMD2(50, 0),
                                             configuration: configuration)

        XCTAssertLessThanOrEqual(streak.length, configuration.maximumTrailLengthUV + 1e-6)
    }

    func testAStationaryEyeHasNoStreak() {
        let streak = EyeGeometry.trailOffset(velocity: SIMD2(0, 0),
                                             configuration: EyeGlowConfiguration())

        XCTAssertEqual(streak.length, 0)
        XCTAssertEqual(streak.direction, SIMD2(0, 0))
    }

    // MARK: - Configuration

    func testInvalidConfigurationIsClamped() {
        var configuration = EyeGlowConfiguration()
        configuration.trailDecayAt60FPS = 4
        configuration.eyeIntensity = -8
        configuration.minimumEyeOpenness = 0.9
        configuration.fullEyeOpenness = 0.1
        configuration.glowColor = SIMD3(5, -2, 0.5)
        configuration.trackingLossTimeout = -3

        let clean = configuration.sanitized

        XCTAssertLessThan(clean.trailDecayAt60FPS, 1,
                          "a decay of 1 or more never fades and brightness runs away")
        XCTAssertGreaterThanOrEqual(clean.eyeIntensity, 0)
        XCTAssertGreaterThan(clean.fullEyeOpenness, clean.minimumEyeOpenness,
                             "an inverted range makes smoothstep meaningless")
        XCTAssertEqual(clean.glowColor, SIMD3<Float>(1, 0, 0.5))
        XCTAssertGreaterThan(clean.trackingLossTimeout, 0)
    }

    func testDefaultConfigurationSurvivesSanitising() {
        let defaults = EyeGlowConfiguration()
        XCTAssertEqual(defaults, defaults.sanitized)
    }

    /// A decay clamped to exactly 1 would never fade; the ceiling has to sit
    /// below it.
    func testDecayCannotReachOne() {
        var configuration = EyeGlowConfiguration()
        configuration.trailDecayAt60FPS = 1
        XCTAssertLessThan(configuration.sanitized.trailDecayAt60FPS, 1)
    }

    /// Quality and the debug switches are settings, not tuning, and sanitising
    /// clamps values rather than resetting choices.
    func testSanitisingLeavesQualityAndDebugAlone() {
        var configuration = EyeGlowConfiguration()
        configuration.quality = .low
        configuration.debug.showTrailTexture = true
        configuration.eyeIntensity = 500

        let clean = configuration.sanitized

        XCTAssertEqual(clean.quality, .low)
        XCTAssertTrue(clean.debug.showTrailTexture)
        XCTAssertLessThanOrEqual(clean.eyeIntensity, 20)
    }

    // MARK: - Quality

    /// The levels have to actually differ, and in the direction their names
    /// claim — a level that costs the same as the one above it is just a
    /// misleading label.
    func testQualityLevelsDescendInCost() {
        let levels = EyeGlowQuality.allCases

        XCTAssertEqual(levels, [.low, .medium, .high])

        for (cheaper, dearer) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(cheaper.bloomScales, dearer.bloomScales)
            XCTAssertGreaterThanOrEqual(cheaper.trailDivisor, dearer.trailDivisor)
            XCTAssertLessThanOrEqual(cheaper.trailDiffusion, dearer.trailDiffusion)
        }
    }

    func testTheLowestLevelMatchesItsSpecifiedMapping() {
        XCTAssertEqual(EyeGlowQuality.low.bloomScales, 1)
        XCTAssertEqual(EyeGlowQuality.low.trailDivisor, 4)
        XCTAssertFalse(EyeGlowQuality.low.usesDirectionalBlur)
    }

    func testTheHighestLevelMatchesItsSpecifiedMapping() {
        XCTAssertEqual(EyeGlowQuality.high.bloomScales, 3)
        XCTAssertEqual(EyeGlowQuality.high.trailDivisor, 2)
        XCTAssertTrue(EyeGlowQuality.high.usesDirectionalBlur)
        XCTAssertGreaterThan(EyeGlowQuality.high.trailDiffusion, 1)
    }

    /// Every level has to leave something to composite. One with no bloom
    /// scales would bind nothing but the empty texture and show a bare core.
    func testEveryLevelKeepsAtLeastOneBloomScaleAndARealTrail() {
        for quality in EyeGlowQuality.allCases {
            XCTAssertGreaterThanOrEqual(quality.bloomScales, 1)
            XCTAssertLessThanOrEqual(quality.bloomScales, 3)
            XCTAssertGreaterThan(quality.trailDivisor, 0)
        }
    }

    // MARK: - Debug options

    func testNothingIsShownByDefault() {
        let debug = EyeGlowDebugOptions()

        XCTAssertEqual(debug.fullScreenTexture, .none)
        XCTAssertFalse(debug.drawsOverlay)
        XCTAssertFalse(debug.isActive)
    }

    /// Only one image can be full screen. Two switches on has to resolve to a
    /// single answer rather than whichever the shader happens to test first.
    func testTwoTextureSwitchesResolveToOne() {
        var debug = EyeGlowDebugOptions()
        debug.showBloomTexture = true
        debug.showTrailTexture = true

        XCTAssertEqual(debug.fullScreenTexture, .bloom)

        debug.showEmissionTexture = true
        XCTAssertEqual(debug.fullScreenTexture, .emission)
    }

    func testTheOverlayIsIndependentOfTheTextureViews() {
        var debug = EyeGlowDebugOptions()
        debug.showEyeContours = true

        XCTAssertTrue(debug.drawsOverlay)
        XCTAssertTrue(debug.isActive)
        XCTAssertEqual(debug.fullScreenTexture, .none,
                       "the overlay draws over whatever is being shown")
    }

    /// The raw values are what the shader switches on, so they are part of the
    /// contract with it rather than an implementation detail.
    func testTextureSelectorsMatchTheShader() {
        XCTAssertEqual(EyeGlowDebugTexture.none.rawValue, 0)
        XCTAssertEqual(EyeGlowDebugTexture.emission.rawValue, 1)
        XCTAssertEqual(EyeGlowDebugTexture.bloom.rawValue, 2)
        XCTAssertEqual(EyeGlowDebugTexture.trail.rawValue, 3)
    }

    // MARK: - Where the glow actually lands

    /// The one thing arithmetic can't settle: whether an eye at a given uv is
    /// drawn where the composite goes looking for it.
    ///
    /// The emission is rendered as geometry in clip space and sampled back as a
    /// texture, and those two have opposite ideas about which way y runs. Get
    /// the reconciliation wrong and the glow appears somewhere else on the face
    /// — which is a plausible enough picture that nothing about it reads as a
    /// bug. So this renders a single eye at a deliberately lopsided position
    /// and reads the texture back to find out where it went.
    func testTheEmissionLandsWhereTheCompositeSamplesIt() throws {

        let glowUV = try renderOneEye(at: SIMD2(0.25, 0.80))

        // The composite samples `float2(uv.x, 1.0 - uv.y)`, so an eye at
        // uv (0.25, 0.80) has to be found in the texture at (0.25, 0.20).
        XCTAssertEqual(glowUV.x, 0.25, accuracy: 0.04,
                       "the glow is offset horizontally from the eye")
        XCTAssertEqual(glowUV.y, 0.20, accuracy: 0.04,
                       "the glow is offset vertically from the eye")
    }

    /// Two eyes at opposite corners, to catch a transform that happens to be
    /// symmetric about the centre and so looks right for one point.
    func testAnEyeInEachCornerStaysInItsOwnCorner() throws {
        let lowLeft = try renderOneEye(at: SIMD2(0.20, 0.20))
        let highRight = try renderOneEye(at: SIMD2(0.80, 0.80))

        XCTAssertEqual(lowLeft.x, 0.20, accuracy: 0.04)
        XCTAssertEqual(lowLeft.y, 0.80, accuracy: 0.04)

        XCTAssertEqual(highRight.x, 0.80, accuracy: 0.04)
        XCTAssertEqual(highRight.y, 0.20, accuracy: 0.04)
    }

    /// Every stage is sampled with normalised coordinates, so a smaller texture
    /// has to hold the *whole* frame scaled down rather than a crop of it at
    /// full pixel density.
    ///
    /// This is not hypothetical. A Gaussian blur preserves size: encoding one
    /// straight from the full-resolution emission into the half-resolution
    /// bloom blurred the top-left quadrant at 1:1 pixels, and sampling that
    /// back stretched the quadrant over the frame and put every eye at twice
    /// its distance from the corner. On screen it read as a second, blurrier
    /// pair of eyes down and to the right of the real ones.
    func testEveryBloomScaleHoldsTheWholeFrame() throws {
        let eye = SIMD2<Float>(0.30, 0.75)
        let expected = SIMD2<Float>(0.30, 0.25)

        // Rendered large, because the widest scale is an eighth of it and the
        // sigmas are in pixels. At a toy size that scale is smaller than its
        // own blur kernel, and edge clamping drags the centroid to the middle
        // — which would fail the assertion for reasons that say nothing about
        // the app.
        for stage in [EyeGlowStage.bloomSmall, .bloomMedium, .bloomLarge] {
            let found = try renderOneEye(at: eye, reading: stage, side: 1024)

            XCTAssertEqual(found.x, expected.x, accuracy: 0.06,
                           "\(stage) is not a downscale of the whole frame")
            XCTAssertEqual(found.y, expected.y, accuracy: 0.06,
                           "\(stage) is not a downscale of the whole frame")
        }
    }

    /// The glow should fill the eye rather than sit as a band inside it.
    ///
    /// Measured down the middle of the eye, where an almond is at its tallest.
    /// A flat vertical squash reached about half the opening's height here,
    /// which read as a slot rather than an eye.
    func testTheGlowFillsTheHeightOfTheEye() throws {
        let profile = try renderEyeProfile(halfWidth: 0.06, halfHeight: 0.03, side: 1024)

        XCTAssertGreaterThan(profile.litFraction, 0.75,
                             "the glow covers only \(profile.litFraction) of the eye's height")
    }

    /// And taper, rather than being a rectangle: the corners have to close.
    func testTheGlowTapersTowardsTheCorners() throws {
        let profile = try renderEyeProfile(halfWidth: 0.06, halfHeight: 0.03, side: 1024)

        XCTAssertLessThan(Float(profile.cornerHeight), Float(profile.centreHeight) * 0.7,
                          "the glow is as tall at the corners as in the middle")
        XCTAssertGreaterThan(profile.cornerHeight, 0,
                             "the corners are empty rather than tapered")
    }

    /// Which intermediate the harness reads back.
    enum EyeGlowStage {
        case emission
        case bloomSmall
        case bloomMedium
        case bloomLarge
    }

    // MARK: - GPU harness


    /// Renders one eye centred at `center` and returns where the brightest
    /// texel ended up, in the normalised coordinates the composite samples
    /// with — origin top left, as texture sampling counts.
    /// How tall the lit region is at the middle of the eye and near its corner,
    /// in texels, alongside how much of the eye's own height the middle covers.
    private struct EyeProfile {
        var centreHeight: Int
        var cornerHeight: Int
        var litFraction: Float
    }

    private func renderEyeProfile(halfWidth: Float,
                                  halfHeight: Float,
                                  side: Int) throws -> EyeProfile {

        let centre = SIMD2<Float>(0.5, 0.5)
        let texels = try renderEyeTexels(at: centre,
                                         halfWidth: halfWidth,
                                         halfHeight: halfHeight,
                                         reading: .emission,
                                         side: side)

        var peak: Float = 0
        for value in texels {
            peak = max(peak, value)
        }

        XCTAssertGreaterThan(peak, 0.01, "nothing was drawn at all")
        let threshold = peak * 0.1

        func litHeight(atColumn column: Int) -> Int {
            (0..<side).count { row in texels[row * side + column] > threshold }
        }

        let middle = Int(centre.x * Float(side))
        // Three quarters of the way out towards the corner.
        let nearCorner = Int((centre.x + halfWidth * 0.75) * Float(side))

        let centreHeight = litHeight(atColumn: middle)
        let eyeHeight = 2 * halfHeight * Float(side)

        return EyeProfile(centreHeight: centreHeight,
                          cornerHeight: litHeight(atColumn: nearCorner),
                          litFraction: Float(centreHeight) / eyeHeight)
    }

    /// Renders one eye and reads a stage back as per-texel luminance, laid out
    /// row-major from the top left — the same way texture sampling counts.
    private func renderEyeTexels(at center: SIMD2<Float>,
                                 halfWidth: Float = 0.06,
                                 halfHeight: Float = 0.03,
                                 reading stage: EyeGlowStage = .emission,
                                 side: Int = 256) throws -> [Float] {

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }

        let library = try device.makeDefaultLibrary(bundle: Bundle(for: EyeGlowRenderer.self))

        guard let glow = EyeGlowRenderer(device: device, library: library) else {
            throw XCTSkip("the glow's pipelines wouldn't build")
        }

        var face = TrackedFace.none
        face.eyePresence = 1
        face.leftOpenness = 1
        // Only the left, which also exercises one eye failing without taking
        // the other with it.
        face.leftEyeShape = [
            center + SIMD2(-halfWidth, 0),
            center + SIMD2(0, halfHeight),
            center + SIMD2(halfWidth, 0),
            center + SIMD2(0, -halfHeight)
        ]

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("no command buffer")
        }

        XCTAssertTrue(glow.encode(commandBuffer: commandBuffer,
                                  face: face,
                                  drawableSize: CGSize(width: side, height: side),
                                  scale: SIMD2(1, 1),
                                  elapsed: 1.0 / 60.0,
                                  now: 1))

        let texture: MTLTexture

        switch stage {
        case .emission: texture = try XCTUnwrap(glow.emission)
        case .bloomSmall: texture = try XCTUnwrap(glow.bloomSmall)
        case .bloomMedium: texture = try XCTUnwrap(glow.bloomMedium)
        case .bloomLarge: texture = try XCTUnwrap(glow.bloomLarge)
        }

        let width = texture.width
        let height = texture.height

        // Private storage, so it has to be copied somewhere readable.
        let bytesPerRow = width * 8
        let readback = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height,
                                                        options: .storageModeShared))

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw XCTSkip("no blit encoder")
        }

        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let raw = readback.contents().bindMemory(to: Float16.self,
                                                  capacity: width * height * 4)

        var luminance = [Float](repeating: 0, count: width * height)

        for index in 0..<(width * height) {
            let channel = index * 4
            luminance[index] = Float(raw[channel]) + Float(raw[channel + 1])
                             + Float(raw[channel + 2])
        }

        return luminance
    }

    /// Where the lit region's centre of mass is, in the normalised coordinates
    /// the composite samples with.
    ///
    /// The centroid rather than the single brightest texel: a heavily blurred
    /// scale has a broad plateau, and which texel within it happens to win is
    /// noise.
    private func renderOneEye(at center: SIMD2<Float>,
                              reading stage: EyeGlowStage = .emission,
                              side: Int = 256) throws -> SIMD2<Float> {

        let texels = try renderEyeTexels(at: center, reading: stage, side: side)

        let width = Int(Double(texels.count).squareRoot().rounded())
        let height = width

        var weight: Float = 0
        var total = SIMD2<Float>(0, 0)
        var peak: Float = 0

        for row in 0..<height {
            for column in 0..<width {
                let value = texels[row * width + column]
                peak = max(peak, value)

                guard value > 0.001 else {
                    continue
                }

                weight += value
                total += SIMD2(Float(column) + 0.5, Float(row) + 0.5) * value
            }
        }

        XCTAssertGreaterThan(peak, 0.01, "nothing was drawn at all")

        let centre = total / max(weight, 1e-6)

        return SIMD2(centre.x / Float(width), centre.y / Float(height))
    }
}
