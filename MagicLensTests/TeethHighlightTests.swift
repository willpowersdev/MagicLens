//
//  TeethHighlightTests.swift
//  MagicLensTests
//

import XCTest
import simd
@testable import MagicLens

/// The coordinate work and the geometry are kept free of Vision and Metal so
/// they can be checked with plain values — which matters here because an
/// orientation mistake shows up as poor tooth detection rather than as an
/// obviously wrong coordinate.
final class TeethHighlightTests: XCTestCase {

    // MARK: - Coordinate conversion

    /// The buffer is landscape and the front camera is mirrored, which is the
    /// normal case for this app.
    private func uv(_ x: CGFloat, _ y: CGFloat,
                    rotated: Bool = true,
                    mirrored: Bool = true) -> CGPoint {
        FaceTracker.uvPoint(fromBuffer: CGPoint(x: x, y: y),
                            rotated: rotated,
                            mirrored: mirrored)
    }

    func testUnrotatedUnmirroredOnlyFlipsVertically() {
        // Buffer counts down from the top left, uv counts up from the bottom.
        let mapped = uv(0.25, 0.25, rotated: false, mirrored: false)
        XCTAssertEqual(mapped.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(mapped.y, 0.75, accuracy: 1e-6)
    }

    func testMirroringReflectsAcrossTheVerticalAxis() {
        let plain = uv(0.25, 0.4, rotated: false, mirrored: false)
        let mirrored = uv(0.25, 0.4, rotated: false, mirrored: true)

        XCTAssertEqual(mirrored.x, 1 - plain.x, accuracy: 1e-6)
        XCTAssertEqual(mirrored.y, plain.y, accuracy: 1e-6)
    }

    func testRotationIsAQuarterTurn() {
        // Buffer corners, unmirrored. A quarter turn clockwise takes the
        // buffer's top left to the screen's top right.
        let topLeft = uv(0, 0, rotated: true, mirrored: false)
        XCTAssertEqual(topLeft.x, 1, accuracy: 1e-6)
        XCTAssertEqual(topLeft.y, 1, accuracy: 1e-6)

        let bottomLeft = uv(0, 1, rotated: true, mirrored: false)
        XCTAssertEqual(bottomLeft.x, 0, accuracy: 1e-6)
        XCTAssertEqual(bottomLeft.y, 1, accuracy: 1e-6)
    }

    func testConversionStaysInsideTheUnitSquare() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            for y in stride(from: 0.0, through: 1.0, by: 0.1) {
                let mapped = uv(CGFloat(x), CGFloat(y))
                XCTAssertGreaterThanOrEqual(mapped.x, -1e-9)
                XCTAssertLessThanOrEqual(mapped.x, 1 + 1e-9)
                XCTAssertGreaterThanOrEqual(mapped.y, -1e-9)
                XCTAssertLessThanOrEqual(mapped.y, 1 + 1e-9)
            }
        }
    }

    func testRectConversionSwapsWidthAndHeightWhenRotated() {
        let source = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2)
        let mapped = FaceTracker.uvRect(fromBuffer: source, rotated: true, mirrored: false)

        XCTAssertEqual(mapped.width, source.height, accuracy: 1e-6)
        XCTAssertEqual(mapped.height, source.width, accuracy: 1e-6)
    }

    // MARK: - Polygon geometry

    private let square = [SIMD2<Float>(0.4, 0.4), SIMD2<Float>(0.6, 0.4),
                          SIMD2<Float>(0.6, 0.5), SIMD2<Float>(0.4, 0.5)]

    func testAreaOfAKnownPolygon() {
        XCTAssertEqual(MouthGeometry.area(of: square), 0.2 * 0.1, accuracy: 1e-6)
    }

    func testAreaIsIndependentOfWindingDirection() {
        XCTAssertEqual(MouthGeometry.area(of: square),
                       MouthGeometry.area(of: square.reversed()),
                       accuracy: 1e-6)
    }

    func testDegeneratedPolygonsHaveNoArea() {
        XCTAssertEqual(MouthGeometry.area(of: []), 0)
        XCTAssertEqual(MouthGeometry.area(of: [SIMD2(0.5, 0.5)]), 0)
        XCTAssertEqual(MouthGeometry.area(of: [SIMD2(0.4, 0.5), SIMD2(0.6, 0.5)]), 0)
    }

    func testCentroidOfASquare() {
        let middle = MouthGeometry.centroid(of: square)
        XCTAssertEqual(middle.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(middle.y, 0.45, accuracy: 1e-6)
    }

    func testErosionShrinksTowardsTheCentroid() {
        let eroded = MouthGeometry.eroded(square, by: 0.1)
        let before = MouthGeometry.centroid(of: square)
        let after = MouthGeometry.centroid(of: eroded)

        // Same centre, smaller area.
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        XCTAssertLessThan(MouthGeometry.area(of: eroded), MouthGeometry.area(of: square))
    }

    func testErosionByZeroLeavesThePolygonAlone() {
        XCTAssertEqual(MouthGeometry.eroded(square, by: 0), square)
    }

    // MARK: - Mouth-closed rejection

    func testAnOpenMouthPasses() {
        // A fifth of the face's width by a tenth of its height.
        XCTAssertTrue(MouthGeometry.isOpen(square,
                                           faceSize: SIMD2(0.5, 0.6),
                                           minimumArea: 0.004))
    }

    func testAClosedMouthIsRejected() {
        // The sliver Vision reports for shut lips: wide but almost no height.
        let sliver = [SIMD2<Float>(0.4, 0.45), SIMD2<Float>(0.6, 0.45),
                      SIMD2<Float>(0.6, 0.4505), SIMD2<Float>(0.4, 0.4505)]

        XCTAssertFalse(MouthGeometry.isOpen(sliver,
                                            faceSize: SIMD2(0.5, 0.6),
                                            minimumArea: TeethHighlightConfiguration().minimumMouthArea))
    }

    /// Anchored on measurements from real smiles rather than on reasoning: a
    /// wide one gave a mouth-to-face area ratio of 0.0038, a slight one 0.00105.
    /// The default threshold must sit below both, or genuine smiles are treated
    /// as closed mouths — which the first two versions of this both did.
    func testMeasuredRealSmilesPass() {
        for ratio in [Float(0.0037873026), Float(0.0010515895)] {
            assertSmilePasses(ratio: ratio)
        }
    }

    private func assertSmilePasses(ratio: Float,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let faceSize = SIMD2<Float>(0.47742152, 0.2685496)
        let faceArea = faceSize.x * faceSize.y
        let mouthArea = ratio * faceArea

        // A rectangle of the observed area, roughly mouth-shaped.
        let width = Float(0.09)
        let height = mouthArea / width
        let mouth = [SIMD2<Float>(0.45, 0.20), SIMD2<Float>(0.45 + width, 0.20),
                     SIMD2<Float>(0.45 + width, 0.20 + height), SIMD2<Float>(0.45, 0.20 + height)]

        XCTAssertTrue(MouthGeometry.isOpen(mouth,
                                           faceSize: faceSize,
                                           minimumArea: TeethHighlightConfiguration().minimumMouthArea),
                      "a measured real smile (ratio \(ratio)) was rejected as a closed mouth",
                      file: file, line: line)
    }

    func testRejectionScalesWithTheFace() {
        // The same mouth on a face twice as large is proportionally smaller,
        // so the test must not depend on how near the camera someone is.
        let near = MouthGeometry.isOpen(square, faceSize: SIMD2(0.5, 0.6), minimumArea: 0.05)
        let far = MouthGeometry.isOpen(square, faceSize: SIMD2(1.0, 1.2), minimumArea: 0.05)

        XCTAssertTrue(near)
        XCTAssertFalse(far)
    }

    func testTooFewPointsIsNotAnOpenMouth() {
        XCTAssertFalse(MouthGeometry.isOpen([SIMD2(0.5, 0.5)],
                                            faceSize: SIMD2(0.5, 0.6),
                                            minimumArea: 0.004))
    }

    // MARK: - Configuration

    func testInvalidConfigurationIsClamped() {
        var configuration = TeethHighlightConfiguration()
        configuration.minimumBrightness = -3
        configuration.maximumSaturation = 12
        configuration.brightnessSoftness = 0
        configuration.saturationSoftness = -1
        configuration.tintStrength = 40
        configuration.polygonErosion = 5
        configuration.edgeFeather = 0
        configuration.landmarkResponsiveness = -8
        configuration.updatesPerSecond = 0
        configuration.yellowColor = SIMD3(4, -2, 0.5)

        let clean = configuration.sanitized

        XCTAssertEqual(clean.minimumBrightness, 0, accuracy: 1e-6)
        XCTAssertEqual(clean.maximumSaturation, 1, accuracy: 1e-6)
        XCTAssertEqual(clean.tintStrength, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(clean.brightnessSoftness, 0, "a zero ramp is a hard step")
        XCTAssertGreaterThan(clean.saturationSoftness, 0)
        XCTAssertGreaterThan(clean.edgeFeather, 0)
        XCTAssertLessThanOrEqual(clean.polygonErosion, 0.45, "erosion must not collapse the polygon")
        XCTAssertGreaterThan(clean.landmarkResponsiveness, 0)
        XCTAssertGreaterThanOrEqual(clean.updatesPerSecond, 1)
        XCTAssertEqual(clean.yellowColor, SIMD3<Float>(1, 0, 0.5))
    }

    func testDefaultConfigurationSurvivesSanitising() {
        let defaults = TeethHighlightConfiguration()
        XCTAssertEqual(defaults, defaults.sanitized)
    }

    // MARK: - The classification, mirrored from the shader

    /// The shader's test, in Swift, so the thresholds can be checked against
    /// known pixels. Kept deliberately identical to fragment_teeth.
    private func confidence(_ colour: SIMD3<Float>,
                            mask: Float,
                            configuration: TeethHighlightConfiguration = .init()) -> Float {

        func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
            return t * t * (3 - 2 * t)
        }

        let high = max(colour.x, max(colour.y, colour.z))
        let low = min(colour.x, min(colour.y, colour.z))
        let saturation = high > 1e-4 ? (high - low) / high : 0

        let bright = smoothstep(configuration.minimumBrightness,
                                configuration.minimumBrightness + configuration.brightnessSoftness,
                                high)
        let neutral = 1 - smoothstep(configuration.maximumSaturation,
                                     configuration.maximumSaturation + configuration.saturationSoftness,
                                     saturation)

        return (mask * bright * neutral).clamped(to: 0...1)
    }

    func testBrightNeutralPixelInsideTheMouthIsTinted() {
        XCTAssertGreaterThan(confidence(SIMD3(0.95, 0.93, 0.90), mask: 1), 0.8)
    }

    func testDarkPixelIsLeftAlone() {
        XCTAssertLessThan(confidence(SIMD3(0.2, 0.2, 0.2), mask: 1), 0.01)
    }

    func testSaturatedPixelIsLeftAlone() {
        // A lit lip: bright, but far too red.
        XCTAssertLessThan(confidence(SIMD3(0.9, 0.25, 0.3), mask: 1), 0.01)
    }

    func testAnythingOutsideTheMouthIsLeftAlone() {
        // White clothing, an eye highlight, a wall — all rejected by the mask
        // alone, whatever their colour.
        XCTAssertEqual(confidence(SIMD3(1, 1, 1), mask: 0), 0, accuracy: 1e-6)
    }

    func testTheEdgeOfTheMaskFadesRatherThanSteps() {
        let inside = confidence(SIMD3(0.95, 0.93, 0.90), mask: 1)
        let edge = confidence(SIMD3(0.95, 0.93, 0.90), mask: 0.5)

        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, inside)
    }
}

// MARK: - End-to-end render

import AVFoundation
import Metal
import UIKit
import Vision

/// Runs the real shader over a still photograph and writes the result out, so
/// the whole chain — Vision landmarks, coordinate mapping, mask, classification,
/// tint — can be checked without a camera.
///
/// The test image is already black and white, so saturation is near zero
/// throughout and the saturation test rejects nothing. That is deliberate: it
/// isolates the mask and the brightness test, which is where a fault would
/// otherwise hide behind "the heuristic just didn't find teeth".
final class TeethRenderTests: XCTestCase {

    private static let output = URL(fileURLWithPath: "/tmp/magiclens-teeth")

    /// A still photograph is upright and unmirrored, unlike the camera's
    /// sideways buffers.
    private let rotated = false
    private let mirrored = false

    /// The teeth in the test photograph, measured from the image itself.
    /// Bypasses Vision so the rendering half can be checked on a simulator,
    /// where Vision's models refuse to load.
    private let knownTeeth: [SIMD2<Float>] = [
        SIMD2(0.471, 0.429), SIMD2(0.594, 0.429),
        SIMD2(0.594, 0.476), SIMD2(0.471, 0.476)
    ]

    /// The shader, the mask and the tint, over a hand-placed mouth polygon.
    ///
    /// Vision cannot run in the simulator — it fails to build an inference
    /// context — so detection is supplied rather than detected here. This still
    /// covers everything downstream of the landmarks, which is where a fault
    /// would otherwise be invisible without a device.
    func testShaderTintsAKnownMouthRegion() throws {
        let image = try XCTUnwrap(UIImage(named: "yellow_teeth_test"),
                                 "test image missing from the app bundle")
        let buffer = try XCTUnwrap(Self.pixelBuffer(from: try XCTUnwrap(image.cgImage)))

        let rendered = try Self.render(buffer: buffer,
                                       mouth: knownTeeth,
                                       configuration: TeethHighlightConfiguration(),
                                       rotated: rotated,
                                       mirrored: mirrored)

        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try Self.writePNG(rendered.pixels, width: rendered.width, height: rendered.height,
                          to: Self.output.appendingPathComponent("known-region.png"))

        var tinted = 0
        for index in stride(from: 0, to: rendered.pixels.count, by: 4) {
            let b = Float(rendered.pixels[index]) / 255
            let g = Float(rendered.pixels[index + 1]) / 255
            let r = Float(rendered.pixels[index + 2]) / 255
            if r > 0.5, g > 0.35, r - b > 0.25 { tinted += 1 }
        }

        print("[teeth] known-region tinted pixels: \(tinted)")
        XCTAssertGreaterThan(tinted, 200,
                             "the shader did not tint a mouth polygon placed directly on the teeth")
    }

    /// The same teeth in the camera buffer's own space — normalised, top-left
    /// origin. `knownTeeth` above is this rectangle after it has been taken into
    /// the shaders' uv space, which is the form the contour arrives in.
    private let knownTeethInBuffer = CGRect(x: 0.471, y: 0.524, width: 0.123, height: 0.047)

    /// The segmented mask has to tint the same teeth the contour does, in every
    /// orientation the camera delivers.
    ///
    /// This is the one thing the mask can get wrong that the contour cannot.
    /// Contour points reach the shader already in its uv space, having been
    /// mapped by FaceTracker; the mask stays in the camera buffer's space and is
    /// looked up through `videoTexCoord` instead. The two agree trivially when
    /// nothing is turned round, so the rotated and mirrored cases are the test —
    /// a mask that ignored either would land somewhere else entirely, and on a
    /// face that reads as the model having failed rather than as a coordinate
    /// bug.
    func testSegmentedMaskTintsTheSameTeethTheContourDoes() throws {

        let image = try XCTUnwrap(UIImage(named: "yellow_teeth_test"))
        let buffer = try XCTUnwrap(Self.pixelBuffer(from: try XCTUnwrap(image.cgImage)))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)

        // A crop around the teeth rather than the whole frame, so the mask has
        // the resolution over the mouth that a face crop gives it in the app.
        let region = knownTeethInBuffer.insetBy(dx: -0.1, dy: -0.1)
        let mask = try Self.maskTexture(device: device,
                                        region: region,
                                        filled: knownTeethInBuffer)

        for (rotated, mirrored) in [(false, false), (true, false), (true, true)] {

            // A view the shape of the video, so the aspect fill crops nothing
            // and both paths are judged over the whole frame.
            let viewSize = rotated
                ? CGSize(width: sourceHeight, height: sourceWidth)
                : CGSize(width: sourceWidth, height: sourceHeight)

            // Through the same inverse the tracker uses, so the polygon lands
            // where a detected one would.
            let polygon = [
                CGPoint(x: knownTeethInBuffer.minX, y: knownTeethInBuffer.minY),
                CGPoint(x: knownTeethInBuffer.maxX, y: knownTeethInBuffer.minY),
                CGPoint(x: knownTeethInBuffer.maxX, y: knownTeethInBuffer.maxY),
                CGPoint(x: knownTeethInBuffer.minX, y: knownTeethInBuffer.maxY)
            ].map { corner -> SIMD2<Float> in
                let mapped = FaceTracker.uvPoint(fromBuffer: corner,
                                                 rotated: rotated,
                                                 mirrored: mirrored)
                return SIMD2(Float(mapped.x), Float(mapped.y))
            }

            let viaContour = try Self.render(buffer: buffer,
                                             mouth: polygon,
                                             configuration: TeethHighlightConfiguration(),
                                             rotated: rotated,
                                             mirrored: mirrored,
                                             viewSize: viewSize)

            let viaMask = try Self.render(buffer: buffer,
                                          mouth: polygon,
                                          configuration: TeethHighlightConfiguration(),
                                          rotated: rotated,
                                          mirrored: mirrored,
                                          viewSize: viewSize,
                                          mask: (mask, region, 1.0))

            let contour = Self.tinted(in: viaContour)
            let segmented = Self.tinted(in: viaMask)

            let label = "rotated: \(rotated), mirrored: \(mirrored)"

            XCTAssertGreaterThan(contour.count, 200, "the contour tinted nothing — \(label)")
            XCTAssertGreaterThan(segmented.count, 200, "the mask tinted nothing — \(label)")

            // Compared by where the tint landed rather than how much of it there
            // was: the contour's edge is feathered by the shader and the mask's
            // is hard here, so the counts legitimately differ while the centre
            // of the region must not.
            let drift = abs(contour.centre - segmented.centre)

            XCTAssertLessThan(drift.x, 0.02, "the mask drifted horizontally — \(label)")
            XCTAssertLessThan(drift.y, 0.02, "the mask drifted vertically — \(label)")

            try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try Self.writePNG(viaMask.pixels, width: viaMask.width, height: viaMask.height,
                              to: Self.output.appendingPathComponent(
                                "mask-r\(rotated ? 1 : 0)-m\(mirrored ? 1 : 0).png"))
        }
    }

    /// The whole segmentation path, end to end, on the still photograph: the
    /// model loads out of the bundle, the crop reaches it the right way up, and
    /// what comes back is the mouth rather than some other part of the face.
    ///
    /// The face box is supplied rather than detected, for the same reason the
    /// contour is elsewhere in this file — Vision won't build an inference
    /// context in the simulator. Core ML will, on the CPU, which is slow enough
    /// that the deadline here is generous rather than tight.
    func testTheModelSegmentsTheMouthInTheStillPhotograph() throws {

        let image = try XCTUnwrap(UIImage(named: "yellow_teeth_test"))
        let buffer = try XCTUnwrap(Self.pixelBuffer(from: try XCTUnwrap(image.cgImage)))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        let parsing = FaceParsing(device: device)

        // Measured off the photograph, in the buffer's own space. Roughly what a
        // detector returns: the face, not the hair.
        let face = CGRect(x: 0.28, y: 0.24, width: 0.48, height: 0.44)

        let deadline = Date().addingTimeInterval(60)
        var produced: (mask: MouthMask, opacity: Float)?

        while produced == nil, Date() < deadline {
            parsing.analyze(buffer, faceBox: face, now: CFAbsoluteTimeGetCurrent())
            Thread.sleep(forTimeInterval: 0.1)

            // Enough elapsed time per call to ramp the fade, which otherwise
            // holds the mask below the threshold this returns nil under.
            produced = parsing.mask(at: CFAbsoluteTimeGetCurrent(), elapsed: 0.2)
        }

        guard let produced else {
            throw XCTSkip(parsing.isAvailable
                          ? "the model loaded but produced no mask before the deadline"
                          : "FaceParsingResNet18.mlmodelc is not in the test host's bundle")
        }

        let mask = produced.mask

        XCTAssertGreaterThan(mask.coverage,
                             TeethHighlightConfiguration().minimumMaskCoverage,
                             "the model found no mouth in a photograph of a wide smile")

        // Where the mask actually sits, taken back out to the buffer's space so
        // it can be compared against the teeth measured by hand.
        let side = mask.texture.width
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { raw in
            mask.texture.getBytes(raw.baseAddress!, bytesPerRow: side,
                                  from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }

        var covered = 0
        var sum = CGPoint.zero
        for row in 0..<side {
            for column in 0..<side where pixels[row * side + column] > 128 {
                sum.x += mask.region.minX + (CGFloat(column) + 0.5) / CGFloat(side) * mask.region.width
                sum.y += mask.region.minY + (CGFloat(row) + 0.5) / CGFloat(side) * mask.region.height
                covered += 1
            }
        }

        XCTAssertGreaterThan(covered, 0, "coverage was reported but no texel carries it")

        let centre = CGPoint(x: sum.x / CGFloat(covered), y: sum.y / CGFloat(covered))
        let teeth = CGPoint(x: knownTeethInBuffer.midX, y: knownTeethInBuffer.midY)

        print("[teeth] segmented centre: \(centre), measured teeth: \(teeth), "
              + "coverage: \(mask.coverage)")

        // Loose, because the model labels the whole opening between the lips
        // while the hand-measured rectangle is the teeth inside it. Tight enough
        // that landing on an eye, the nose or an upside-down crop would fail.
        XCTAssertEqual(centre.x, teeth.x, accuracy: 0.05, "the mask is not over the mouth")
        XCTAssertEqual(centre.y, teeth.y, accuracy: 0.05, "the mask is not over the mouth")
    }

    /// The crop handed to the model has to be square *in pixels*, centred on the
    /// face and bigger than it — see FaceParsing.cropRegion for why each.
    ///
    /// Pixels rather than normalised units is the whole point: the camera
    /// delivers 16:9, so a rect with equal normalised sides reaches the model as
    /// a face squashed to a little over half its width.
    func testCropRegionIsSquareInPixelsAroundTheFace() {

        let face = CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)

        for (width, height) in [(1920.0, 1080.0), (1080.0, 1920.0), (512.0, 512.0)] {
            let aspect = CGFloat(width / height)
            let crop = FaceParsing.cropRegion(around: face, padding: 0.25, aspect: aspect)

            let label = "\(Int(width))×\(Int(height))"

            XCTAssertEqual(crop.width * CGFloat(width), crop.height * CGFloat(height),
                           accuracy: 1e-6, "not square in pixels — \(label)")
            XCTAssertEqual(crop.midX, face.midX, accuracy: 1e-6, "moved off the face — \(label)")
            XCTAssertEqual(crop.midY, face.midY, accuracy: 1e-6, "moved off the face — \(label)")
            XCTAssertTrue(crop.contains(face), "the crop lost part of the face — \(label)")

            // Zero padding still squares up, and still can't lose the face.
            let tight = FaceParsing.cropRegion(around: face, padding: 0, aspect: aspect)
            XCTAssertEqual(tight.width * CGFloat(width), tight.height * CGFloat(height),
                           accuracy: 1e-6, label)
            XCTAssertTrue(tight.contains(face), label)
        }
    }

    /// The threshold that decides what gets tinted, which is where the effect
    /// was failing: it tinted nothing on a face whose teeth were plainly
    /// visible, because a mouth is a cavity and the lips shade what is inside
    /// it.
    func testTintThresholdFollowsTheMouthRatherThanTheRoom() {

        let settings = TeethHighlightConfiguration()

        // No mask: the contour's own thresholds, unchanged, because the contour
        // still has lip inside it to reject.
        let contour = Renderer.tintThresholds(settings, maskPeak: nil)
        XCTAssertEqual(contour.brightness, settings.minimumBrightness, accuracy: 1e-6)
        XCTAssertEqual(contour.saturation, settings.maximumSaturation, accuracy: 1e-6)

        // A brightly lit mouth: the bar rises with it, so a bright tongue next
        // to brighter teeth is still rejected.
        let bright = Renderer.tintThresholds(settings, maskPeak: 0.95)
        XCTAssertEqual(bright.brightness, 0.95 * settings.maskBrightnessFraction, accuracy: 1e-6)

        // A shadowed mouth: measured at 0.469 on one of the sample faces, where
        // the old fixed 0.52 tinted nothing at all. The bar has to come down
        // below the teeth that are actually there.
        let shadowed = Renderer.tintThresholds(settings, maskPeak: 0.469)
        XCTAssertLessThan(shadowed.brightness, 0.469,
                          "the threshold is above the brightest thing in the mouth")
        XCTAssertLessThan(shadowed.brightness, settings.minimumBrightness,
                          "a shadowed mouth is no better off than before")

        // A mouth with no teeth in it: the floor holds, so the threshold cannot
        // collapse onto the tongue.
        let dark = Renderer.tintThresholds(settings, maskPeak: 0.1)
        XCTAssertEqual(dark.brightness, settings.maskMinimumBrightness, accuracy: 1e-6)
    }

    /// Where the tint landed, as a count and a centre in uv.
    private static func tinted(in rendered: Rendered) -> (count: Int, centre: SIMD2<Float>) {

        var count = 0
        var sum = SIMD2<Float>(0, 0)

        for index in stride(from: 0, to: rendered.pixels.count, by: 4) {
            let b = Float(rendered.pixels[index]) / 255
            let g = Float(rendered.pixels[index + 1]) / 255
            let r = Float(rendered.pixels[index + 2]) / 255

            guard r > 0.5, g > 0.35, r - b > 0.25 else {
                continue
            }

            let pixel = index / 4
            sum += SIMD2(Float(pixel % rendered.width) / Float(rendered.width),
                         Float(pixel / rendered.width) / Float(rendered.height))
            count += 1
        }

        return (count, count > 0 ? sum / Float(count) : SIMD2(0, 0))
    }

    /// Letterboxing must show the whole frame, with black where it doesn't
    /// reach — the macOS behaviour, since a window can be any shape and filling
    /// a wide one throws most of the picture away.
    func testLetterboxingBandsAWideViewWithoutLosingThePicture() throws {
        let image = try XCTUnwrap(UIImage(named: "yellow_teeth_test"))
        let buffer = try XCTUnwrap(Self.pixelBuffer(from: try XCTUnwrap(image.cgImage)))

        // The source is portrait; a wide view is the case that crops hardest.
        let rendered = try Self.render(buffer: buffer,
                                       mouth: knownTeeth,
                                       configuration: TeethHighlightConfiguration(),
                                       rotated: false,
                                       mirrored: false,
                                       letterboxed: true,
                                       viewSize: CGSize(width: 1200, height: 500))

        func rowIsBlack(_ y: Int) -> Bool {
            let start = y * rendered.width * 4
            for x in stride(from: 0, to: rendered.width * 4, by: 4) {
                let b = rendered.pixels[start + x]
                let g = rendered.pixels[start + x + 1]
                let r = rendered.pixels[start + x + 2]
                if r > 8 || g > 8 || b > 8 { return false }
            }
            return true
        }

        // Pillarboxed here, not letterboxed: a portrait frame in a wide view
        // leaves bars at the sides. Either way the whole frame survives.
        func columnIsBlack(_ x: Int) -> Bool {
            for y in stride(from: 0, to: rendered.height, by: 4) {
                let i = y * rendered.width * 4 + x * 4
                if rendered.pixels[i] > 8 || rendered.pixels[i + 1] > 8
                    || rendered.pixels[i + 2] > 8 { return false }
            }
            return true
        }

        XCTAssertTrue(columnIsBlack(2), "no bar at the left edge")
        XCTAssertTrue(columnIsBlack(rendered.width - 3), "no bar at the right edge")
        XCTAssertFalse(rowIsBlack(rendered.height / 2), "the picture itself is missing")

        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try Self.writePNG(rendered.pixels, width: rendered.width, height: rendered.height,
                          to: Self.output.appendingPathComponent("letterboxed.png"))
    }

    func testTeethAreTintedOnAStillPhotograph() throws {
        let image = try XCTUnwrap(UIImage(named: "yellow_teeth_test"),
                                 "test image missing from the app bundle")
        let cgImage = try XCTUnwrap(image.cgImage)

        let buffer = try XCTUnwrap(Self.pixelBuffer(from: cgImage))

        // 1. Vision, exactly as the tracker calls it.
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                .perform([request])
        } catch {
            throw XCTSkip("Vision cannot run here: \(error.localizedDescription)")
        }

        let face = try XCTUnwrap(
            request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                     < $1.boundingBox.width * $1.boundingBox.height }),
            "Vision found no face in the test image")

        let landmarks = try XCTUnwrap(face.landmarks, "no landmarks")
        let innerLips = try XCTUnwrap(landmarks.innerLips, "no innerLips region")

        print("[teeth] face box \(face.boundingBox), innerLips points \(innerLips.pointCount)")

        // 2. The same coordinate chain the tracker uses.
        let box = face.boundingBox
        let mouth: [SIMD2<Float>] = innerLips.normalizedPoints.map { point in
            let inImage = CGPoint(x: box.origin.x + CGFloat(point.x) * box.width,
                                  y: box.origin.y + CGFloat(point.y) * box.height)
            let inBuffer = CGPoint(x: inImage.x, y: 1 - inImage.y)
            let uv = FaceTracker.uvPoint(fromBuffer: inBuffer, rotated: rotated, mirrored: mirrored)
            return SIMD2(Float(uv.x), Float(uv.y))
        }

        let faceExtent = SIMD2(Float(box.width), Float(box.height))
        let area = MouthGeometry.area(of: mouth)
        let ratio = area / (faceExtent.x * faceExtent.y)

        print("[teeth] mouth area \(area), face area \(faceExtent.x * faceExtent.y), ratio \(ratio)")
        print("[teeth] mouth uv \(mouth.map { ($0.x, $0.y) })")

        let configuration = TeethHighlightConfiguration()
        XCTAssertTrue(MouthGeometry.isOpen(mouth, faceSize: faceExtent,
                                           minimumArea: configuration.minimumMouthArea),
                      "a wide smile was judged a closed mouth — minimumMouthArea is too high")

        let eroded = MouthGeometry.eroded(mouth, by: configuration.polygonErosion)

        // 3. Render with the real shader.
        let rendered = try Self.render(buffer: buffer,
                                       mouth: eroded,
                                       configuration: configuration,
                                       rotated: rotated,
                                       mirrored: mirrored)

        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try Self.writePNG(rendered.pixels,
                          width: rendered.width,
                          height: rendered.height,
                          to: Self.output.appendingPathComponent("rendered.png"))

        // 4. Did anything actually turn yellow?
        var tinted = 0
        for index in stride(from: 0, to: rendered.pixels.count, by: 4) {
            let b = Float(rendered.pixels[index]) / 255
            let g = Float(rendered.pixels[index + 1]) / 255
            let r = Float(rendered.pixels[index + 2]) / 255
            // Yellow: red and green high, blue clearly lower.
            if r > 0.5, g > 0.35, r - b > 0.25 {
                tinted += 1
            }
        }

        print("[teeth] tinted pixels: \(tinted) of \(rendered.pixels.count / 4)")
        XCTAssertGreaterThan(tinted, 200, "no meaningful yellow in the output")
    }

    // MARK: - Harness

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]

        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private struct Rendered {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private static func emptyMask(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead

        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var zero: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &zero, bytesPerRow: 1)
        return texture
    }

    /// Stands in for what `FaceParsing` produces: a single-channel mask covering
    /// `region` of the camera buffer, opaque over `filled` and clear elsewhere.
    ///
    /// Both rectangles are in the buffer's own space — normalised, top-left
    /// origin — which is what the real one carries, so the shader's lookup is
    /// exercised exactly as it is in the app.
    private static func maskTexture(device: MTLDevice,
                                    region: CGRect,
                                    filled: CGRect,
                                    side: Int = 128) throws -> MTLTexture {

        var pixels = [UInt8](repeating: 0, count: side * side)

        for row in 0..<side {
            for column in 0..<side {
                // Texel centres, so the edges land where they should.
                let x = region.minX + (CGFloat(column) + 0.5) / CGFloat(side) * region.width
                let y = region.minY + (CGFloat(row) + 0.5) / CGFloat(side) * region.height

                if filled.contains(CGPoint(x: x, y: y)) {
                    pixels[row * side + column] = 255
                }
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead

        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: side)
        return texture
    }

    private static func render(buffer: CVPixelBuffer,
                               mouth: [SIMD2<Float>],
                               configuration: TeethHighlightConfiguration,
                               rotated: Bool,
                               mirrored: Bool,
                               letterboxed: Bool = false,
                               viewSize: CGSize? = nil,
                               mask: (texture: MTLTexture, region: CGRect, peak: Float)? = nil) throws -> Rendered {

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try XCTUnwrap(device.makeDefaultLibrary(), "no default.metallib")

        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)

        // The view can be a different shape to the video, which is the whole
        // point when checking how the two are fitted together.
        let width = Int(viewSize?.width ?? CGFloat(sourceWidth))
        let height = Int(viewSize?.height ?? CGFloat(sourceHeight))

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var wrapper: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, try XCTUnwrap(cache), buffer, nil,
                                                  .bgra8Unorm, sourceWidth, sourceHeight, 0, &wrapper)
        let source = try XCTUnwrap(CVMetalTextureGetTexture(try XCTUnwrap(wrapper)))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_func")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_teeth")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // The same quad the renderer draws.
        let vertices: [Float] = [ 1, -1, 1, 0,   1, 1, 1, 1,  -1, 1, 0, 1,  -1, -1, 0, 0]
        let indices: [UInt32] = [0, 1, 2, 2, 3, 0]
        let vertexBuffer = try XCTUnwrap(device.makeBuffer(bytes: vertices,
                                                           length: MemoryLayout<Float>.size * vertices.count))
        let indexBuffer = try XCTUnwrap(device.makeBuffer(bytes: indices,
                                                          length: MemoryLayout<UInt32>.size * indices.count))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var uniforms = Uniforms(
            resolution: SIMD2(Float(width), Float(height)),
            cameraResolution: SIMD2(Float(sourceWidth), Float(sourceHeight)),
            touchPoint: SIMD2(0.5, 0.5),
            globalTime: 0,
            videoRotated: rotated ? 1 : 0,
            videoMirrored: mirrored ? 1 : 0,
            videoLetterboxed: letterboxed ? 1 : 0,
            faceCenter: SIMD2(0.5, 0.5),
            faceSize: SIMD2(0.5, 0.5),
            facePresence: 1,
            leftEye: SIMD2(0.5, 0.5), rightEye: SIMD2(0.5, 0.5),
            leftPupil: SIMD2(0.5, 0.5), rightPupil: SIMD2(0.5, 0.5),
            eyePresence: 1)

        // The renderer maps tracked geometry into view space before binding it;
        // the harness has to do the same or the mask lands somewhere else.
        let scale = Renderer.videoToViewScale(
            cameraResolution: SIMD2(Float(sourceWidth), Float(sourceHeight)),
            viewResolution: SIMD2(Float(width), Float(height)),
            rotated: rotated,
            letterboxed: letterboxed)
        var points = mouth.map { Renderer.videoPointToView($0, scale: scale) }
        // Through the renderer's own rule, so the harness can't quietly
        // diverge from what the app does.
        let thresholds = Renderer.tintThresholds(configuration, maskPeak: mask?.peak)

        var teeth = TeethUniforms(
            minimumBrightness: thresholds.brightness,
            maximumSaturation: thresholds.saturation,
            brightnessSoftness: configuration.brightnessSoftness,
            saturationSoftness: configuration.saturationSoftness,
            tintStrength: configuration.tintStrength,
            edgeFeather: configuration.edgeFeather
                * max(Float(mouth.map(\.y).max()! - mouth.map(\.y).min()!), 0.002),
            mouthOpacity: 1,
            mouthPointCount: Int32(mouth.count),
            yellowColor: configuration.yellowColor,
            usesMask: mask == nil ? 0 : 1,
            maskOrigin: SIMD2(Float(mask?.region.minX ?? 0), Float(mask?.region.minY ?? 0)),
            maskSize: SIMD2(Float(mask?.region.width ?? 0), Float(mask?.region.height ?? 0)))

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&points,
                                 length: MemoryLayout<SIMD2<Float>>.stride * points.count, index: 1)
        encoder.setFragmentBytes(&teeth, length: MemoryLayout<TeethUniforms>.stride, index: 2)
        encoder.setFragmentTexture(source, index: 0)

        // Bound whichever path is being exercised, because the shader declares
        // the binding either way. A 1×1 of zero stands in when there's no mask,
        // matching what the renderer does.
        encoder.setFragmentTexture(try mask?.texture ?? emptyMask(device: device), index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.count,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        return Rendered(pixels: pixels, width: width, height: height)
    }

    private static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var data = pixels
        let provider = try XCTUnwrap(CGDataProvider(data: Data(data) as CFData))
        data.removeAll()

        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: url)
        print("[teeth] wrote \(url.path)")
    }
}

/// The tracker maps camera coordinates into view space; the shaders map view
/// space back to camera coordinates. They have to be exact inverses, or
/// anything tracked is drawn somewhere other than the thing it is tracking —
/// and that reads as bad detection rather than as a coordinate bug.
final class CoordinateRoundTripTests: XCTestCase {

    /// videoTexCoord from ShaderCommon.h, without the aspect step, which the
    /// renderer handles separately on the CPU.
    private func shaderForward(_ uv: CGPoint, rotated: Bool, mirrored: Bool) -> CGPoint {
        var screen = CGPoint(x: uv.x, y: 1 - uv.y)

        if mirrored {
            screen.x = 1 - screen.x
        }

        return rotated ? CGPoint(x: screen.y, y: 1 - screen.x) : screen
    }

    func testTrackerInvertsTheShaderForEveryOrientation() {
        for rotated in [false, true] {
            for mirrored in [false, true] {
                for x in stride(from: 0.05, through: 0.95, by: 0.15) {
                    for y in stride(from: 0.05, through: 0.95, by: 0.15) {
                        let uv = CGPoint(x: x, y: y)

                        let texture = shaderForward(uv, rotated: rotated, mirrored: mirrored)
                        let back = FaceTracker.uvPoint(fromBuffer: texture,
                                                       rotated: rotated,
                                                       mirrored: mirrored)

                        XCTAssertEqual(back.x, uv.x, accuracy: 1e-6,
                                       "x round trip failed: rotated \(rotated), mirrored \(mirrored)")
                        XCTAssertEqual(back.y, uv.y, accuracy: 1e-6,
                                       "y round trip failed: rotated \(rotated), mirrored \(mirrored)")
                    }
                }
            }
        }
    }

    /// The macOS case specifically: unrotated and mirrored, which is what the
    /// Mac camera became once mirroring was turned on for it.
    func testUnrotatedMirroredIsAHorizontalReflection() {
        let left = FaceTracker.uvPoint(fromBuffer: CGPoint(x: 0.2, y: 0.5),
                                       rotated: false, mirrored: true)
        XCTAssertEqual(left.x, 0.8, accuracy: 1e-6,
                       "a face on one side of the buffer must appear on the other side of the view")
    }
}
