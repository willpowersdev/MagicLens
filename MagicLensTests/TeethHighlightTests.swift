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

    private static func render(buffer: CVPixelBuffer,
                               mouth: [SIMD2<Float>],
                               configuration: TeethHighlightConfiguration,
                               rotated: Bool,
                               mirrored: Bool) throws -> Rendered {

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try XCTUnwrap(device.makeDefaultLibrary(), "no default.metallib")

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var wrapper: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, try XCTUnwrap(cache), buffer, nil,
                                                  .bgra8Unorm, width, height, 0, &wrapper)
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
            cameraResolution: SIMD2(Float(width), Float(height)),
            touchPoint: SIMD2(0.5, 0.5),
            globalTime: 0,
            videoRotated: rotated ? 1 : 0,
            videoMirrored: mirrored ? 1 : 0,
            faceCenter: SIMD2(0.5, 0.5),
            faceSize: SIMD2(0.5, 0.5),
            facePresence: 1,
            leftEye: SIMD2(0.5, 0.5), rightEye: SIMD2(0.5, 0.5),
            leftPupil: SIMD2(0.5, 0.5), rightPupil: SIMD2(0.5, 0.5),
            eyePresence: 1)

        var points = mouth
        var teeth = TeethUniforms(
            minimumBrightness: configuration.minimumBrightness,
            maximumSaturation: configuration.maximumSaturation,
            brightnessSoftness: configuration.brightnessSoftness,
            saturationSoftness: configuration.saturationSoftness,
            tintStrength: configuration.tintStrength,
            edgeFeather: configuration.edgeFeather
                * max(Float(mouth.map(\.y).max()! - mouth.map(\.y).min()!), 0.002),
            mouthOpacity: 1,
            mouthPointCount: Int32(mouth.count),
            yellowColor: configuration.yellowColor)

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&points,
                                 length: MemoryLayout<SIMD2<Float>>.stride * points.count, index: 1)
        encoder.setFragmentBytes(&teeth, length: MemoryLayout<TeethUniforms>.stride, index: 2)
        encoder.setFragmentTexture(source, index: 0)
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
