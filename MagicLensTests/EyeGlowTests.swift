//
//  EyeGlowTests.swift
//  MagicLensTests
//

import XCTest
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
}
