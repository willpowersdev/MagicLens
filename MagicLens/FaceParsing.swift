//
//  FaceParsing.swift
//  MagicLens
//

import Accelerate
import CoreImage
import CoreML
import CoreVideo
import Metal
import QuartzCore

/// A segmentation of the mouth opening, ready to sample in a shader.
struct MouthMask {

    /// Single channel coverage, already feathered. 0 outside the mouth, 1 well
    /// inside it, ramping across the boundary.
    let texture: MTLTexture

    /// The part of the camera buffer the mask covers: normalised, top-left
    /// origin — the space `videoTexCoord` in ShaderCommon.h lands in.
    let region: CGRect

    /// Fraction of that region the mouth occupies. A shut mouth reads near zero,
    /// which is what the open/closed test is made of.
    let coverage: Float

    /// When it was produced, on the host clock. Masks go stale quickly; a head
    /// turn invalidates one while the face is still perfectly well tracked.
    let time: CFAbsoluteTime
}

/// Segments the mouth with the Core ML face-parsing model.
///
/// This is the counterpart to `FaceTracker`'s inner-lip contour, and a better
/// one: Vision returns the line *around* the lips, which needs eroding inwards
/// and still bleeds onto them, whereas the model labels the gap between them
/// directly. Class 11 in CelebAMask-HQ is that gap — teeth, tongue and gums —
/// with the lips themselves labelled separately as 12 and 13.
///
/// The model is not always there. It fails to load if the .mlpackage is missing
/// from the bundle, and produces nothing until the first inference lands, so
/// `FaceTracker`'s contour stays in place as the fallback rather than being
/// replaced. Callers should treat a nil mask as "use the polygon", not as an
/// error.
///
/// Fed from the video queue, run on its own queue, read by the render loop.
final class FaceParsing {

    /// Compiled alongside the app; `.mlpackage` in the Sources build phase
    /// becomes `.mlmodelc` in the bundle.
    private static let modelName = "FaceParsingResNet18"

    /// CelebAMask-HQ label 11: the mouth opening, not the lips. Tinting is
    /// meant to land on teeth, so the lip classes are deliberately left out —
    /// including them would paint the whole mouth yellow.
    private static let mouthClass: Int32 = 11

    /// What the converted model takes, and so what the mask comes back as.
    private static let inputSize = 512

    private let device: MTLDevice
    private let queue = DispatchQueue(label: "com.ion6.MagicLens.faceparsing")
    private let lock = NSLock()

    /// Built lazily on `queue`: loading costs tens of milliseconds and must not
    /// land on the first frame's critical path.
    private var model: MLModel?
    private var triedLoading = false

    /// One inference at a time, so a slow frame can't pile up behind itself.
    private var inFlight = false
    private var lastAttempt: CFAbsoluteTime = 0

    private var latest: MouthMask?

    /// Smoothed towards 0 or 1 by `mask(at:elapsed:)`, so the tint fades rather
    /// than flicking on and off between inferences.
    private var opacity: Float = 0

    private var storedConfiguration = TeethHighlightConfiguration()

    /// Tuning, written from anywhere and read on `queue`.
    var configuration: TeethHighlightConfiguration {
        get { lock.withLock { storedConfiguration } }
        set { lock.withLock { storedConfiguration = newValue.sanitized } }
    }

    /// Whether the model loaded. False until the first analysis attempt.
    var isAvailable: Bool {
        lock.withLock { model != nil }
    }

    // MARK: - Scratch space
    //
    // All of this is touched only on `queue`, and all of it is allocated once:
    // at fifteen inferences a second, allocating a 512×512 buffer per frame is
    // a quarter of a megabyte of churn a second for no reason.

    private let ciContext: CIContext
    private var scratchBuffer: CVPixelBuffer?
    private var classified = [UInt8](repeating: 0, count: inputSize * inputSize)
    private var feathered = [UInt8](repeating: 0, count: inputSize * inputSize)

    /// Written round-robin, because the render loop may still be sampling the
    /// one handed over last time. Three is enough: masks arrive every ~66 ms and
    /// a frame is done with in ~16 ms.
    private var textures: [MTLTexture] = []
    private var nextTexture = 0

    init(device: MTLDevice) {
        self.device = device

        // Software rendering would be the wrong trade here — the crop is a
        // resize of a camera frame, which is what the GPU is already holding.
        self.ciContext = CIContext(mtlDevice: device,
                                   options: [.cacheIntermediates: false])
    }

    // MARK: - Reading

    /// The mask to draw with at `now`, and how strongly, advanced to this frame.
    /// Nil when there is nothing worth drawing and the caller should fall back
    /// to the contour.
    ///
    /// Mirrors `FaceTracker.face(at:elapsed:)` — called once per rendered frame,
    /// so the fades run on the display's clock rather than the camera's.
    func mask(at now: CFAbsoluteTime, elapsed: Float) -> (MouthMask, Float)? {

        lock.lock()
        defer { lock.unlock() }

        let settings = storedConfiguration

        let wanted: Float
        if let latest,
           now - latest.time <= Double(settings.maskGraceSeconds),
           latest.coverage >= settings.minimumMaskCoverage {
            wanted = 1
        } else {
            wanted = 0
        }

        // Same 150 ms the contour fades over, so switching between the two
        // sources doesn't change how the effect feels.
        opacity += (wanted - opacity) * min(1, elapsed / 0.15)
        opacity = min(1, max(0, opacity))

        guard let latest, opacity > 0.001 else {
            return nil
        }

        return (latest, opacity)
    }

    // MARK: - Writing

    /// Offers a frame for segmentation.
    ///
    /// Called from the video queue for every frame; only a fraction actually
    /// run. `faceBox` is normalised against the buffer with a top-left origin —
    /// the model wants a face, and handing it the whole frame would spend most
    /// of its 512 pixels on the wall behind one.
    func analyze(_ pixelBuffer: CVPixelBuffer,
                 faceBox: CGRect?,
                 now: CFAbsoluteTime) {

        guard let faceBox else {
            return
        }

        lock.lock()
        let interval = 1.0 / Double(storedConfiguration.maskUpdatesPerSecond)
        let shouldRun = !inFlight && now - lastAttempt >= interval
        if shouldRun {
            inFlight = true
            lastAttempt = now
        }
        lock.unlock()

        guard shouldRun else {
            return
        }

        queue.async { [weak self] in
            self?.segment(pixelBuffer, faceBox: faceBox)
        }
    }

    /// Runs on `queue`.
    private func segment(_ pixelBuffer: CVPixelBuffer, faceBox: CGRect) {

        defer {
            lock.lock()
            inFlight = false
            lock.unlock()
        }

        guard let model = loadedModel() else {
            return
        }

        let settings = configuration
        let region = Self.cropRegion(around: faceBox, padding: settings.maskCropPadding)

        guard let input = crop(pixelBuffer, to: region),
              let output = predict(model, image: input),
              let coverage = classify(output) else {
            return
        }

        feather(radius: Int(settings.maskFeather.rounded()))

        guard let texture = nextMaskTexture() else {
            return
        }

        feathered.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, Self.inputSize, Self.inputSize),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: Self.inputSize)
        }

        let produced = MouthMask(texture: texture,
                                 region: region,
                                 coverage: coverage,
                                 time: CFAbsoluteTimeGetCurrent())

        lock.lock()
        latest = produced
        lock.unlock()
    }

    private func loadedModel() -> MLModel? {

        lock.lock()
        if let model {
            lock.unlock()
            return model
        }
        let alreadyTried = triedLoading
        lock.unlock()

        guard !alreadyTried else {
            return nil
        }

        // Loaded by URL rather than through the generated wrapper class, so the
        // app still builds and runs if the model is ever pulled out of the
        // project — the fallback contour is the whole point of that.
        let bundle = Bundle(for: Self.self)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        var loaded: MLModel?
        if let url = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc") {
            loaded = try? MLModel(contentsOf: url, configuration: configuration)
        }

        lock.lock()
        triedLoading = true
        model = loaded
        lock.unlock()

        if loaded == nil {
            print("[MagicLens] \(Self.modelName).mlmodelc not in the bundle — "
                  + "falling back to the Vision inner-lip contour")
        }

        return loaded
    }

    /// The face box, padded out to something closer to what the model was
    /// trained on.
    ///
    /// CelebAMask-HQ is aligned head crops — hair, ears and a little neck — so
    /// a tight detector box is a narrower view than the model has ever seen.
    /// Padding also buys slack for the box lagging a moving head, which matters
    /// more: a mouth that slides out of the crop vanishes from the mask
    /// entirely.
    static func cropRegion(around faceBox: CGRect, padding: Float) -> CGRect {

        let grow = CGFloat(padding)
        let padded = faceBox.insetBy(dx: -faceBox.width * grow,
                                     dy: -faceBox.height * grow)

        // Square, so the 512×512 input doesn't stretch the face along one axis.
        // Taken from the longer side, so nothing inside the padded box is lost.
        let side = max(padded.width, padded.height)
        let centre = CGPoint(x: padded.midX, y: padded.midY)

        return CGRect(x: centre.x - side / 2,
                      y: centre.y - side / 2,
                      width: side,
                      height: side)
    }

    /// Renders `region` of the frame into the 512×512 buffer the model takes.
    ///
    /// The region may hang off the edge of the frame — a face at the side of
    /// shot, padded outwards, usually does. Core Image gives transparent black
    /// there rather than clamping, which is the honest answer: the model reads
    /// it as background, and background is what is actually beyond the frame.
    private func crop(_ pixelBuffer: CVPixelBuffer, to region: CGRect) -> CVPixelBuffer? {

        guard let destination = scratch() else {
            return nil
        }

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        guard width > 0, height > 0, region.width > 0, region.height > 0 else {
            return nil
        }

        // Core Image counts up from the bottom left; the region counts down from
        // the top left, like everything else measured against the buffer.
        let inPixels = CGRect(x: region.minX * width,
                              y: (1 - region.maxY) * height,
                              width: region.width * width,
                              height: region.height * height)

        let side = CGFloat(Self.inputSize)

        let square = CGRect(x: 0, y: 0, width: side, height: side)

        // Composited over black rather than left transparent, so the part of the
        // crop that hangs off the edge of the frame is a definite colour and not
        // whatever the last inference left in this buffer — it is reused every
        // time, and the model would read the difference as texture.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: -inPixels.minX,
                                               y: -inPixels.minY))
            .transformed(by: CGAffineTransform(scaleX: side / inPixels.width,
                                               y: side / inPixels.height))
            .cropped(to: square)
            .composited(over: CIImage(color: CIColor.black).cropped(to: square))

        ciContext.render(image, to: destination)

        return destination
    }

    private func predict(_ model: MLModel, image: CVPixelBuffer) -> MLMultiArray? {

        guard let input = try? MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: image)]),
              let output = try? model.prediction(from: input) else {
            return nil
        }

        return output.featureValue(for: "segmentationMask")?.multiArrayValue
    }

    /// Turns the model's class indices into coverage, and reports how much of
    /// the crop came back as mouth. Nil if the output isn't the shape expected,
    /// which would mean the wrong model in the bundle.
    private func classify(_ output: MLMultiArray) -> Float? {

        let count = Self.inputSize * Self.inputSize

        guard output.count == count, output.dataType == .int32 else {
            return nil
        }

        var mouthPixels = 0

        output.withUnsafeBufferPointer(ofType: Int32.self) { source in
            classified.withUnsafeMutableBufferPointer { destination in
                for index in 0..<count {
                    let isMouth = source[index] == Self.mouthClass
                    destination[index] = isMouth ? 255 : 0
                    mouthPixels += isMouth ? 1 : 0
                }
            }
        }

        return Float(mouthPixels) / Float(count)
    }

    /// Softens the mask edge.
    ///
    /// Done here, once per inference, rather than with extra taps in the
    /// fragment shader: this is a quarter of a megapixel at fifteen a second
    /// against a multi-tap blur at every fragment of every frame. A box blur of
    /// a hard-edged mask leaves the half-coverage line where the edge was, so
    /// this feathers without moving the boundary.
    private func feather(radius: Int) {

        guard radius > 0 else {
            feathered = classified
            return
        }

        let kernel = UInt32(radius * 2 + 1)
        let side = vImagePixelCount(Self.inputSize)

        classified.withUnsafeMutableBufferPointer { source in
            feathered.withUnsafeMutableBufferPointer { destination in

                var input = vImage_Buffer(data: source.baseAddress,
                                          height: side,
                                          width: side,
                                          rowBytes: Self.inputSize)
                var output = vImage_Buffer(data: destination.baseAddress,
                                           height: side,
                                           width: side,
                                           rowBytes: Self.inputSize)

                vImageBoxConvolve_Planar8(&input, &output, nil, 0, 0,
                                          kernel, kernel,
                                          0, vImage_Flags(kvImageEdgeExtend))
            }
        }
    }

    // MARK: - Buffers

    private func scratch() -> CVPixelBuffer? {

        if let scratchBuffer {
            return scratchBuffer
        }

        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Self.inputSize,
                                         Self.inputSize,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &created)

        guard status == kCVReturnSuccess else {
            return nil
        }

        scratchBuffer = created
        return created
    }

    private func nextMaskTexture() -> MTLTexture? {

        if textures.isEmpty {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: Self.inputSize,
                height: Self.inputSize,
                mipmapped: false)
            descriptor.usage = .shaderRead

            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }

            guard !textures.isEmpty else {
                return nil
            }
        }

        let texture = textures[nextTexture]
        nextTexture = (nextTexture + 1) % textures.count
        return texture
    }
}
