//
//  EyeGlowRenderer.swift
//  MagicLens
//

import MetalPerformanceShaders
import MetalKit

/// The eye glow's extra passes, encoded before the frame's own draw.
///
/// Owns its intermediate textures, pipelines and the persistent trail. Nothing
/// here allocates once running: textures are rebuilt only when the drawable's
/// size changes, and the vertex buffer is written in place.
///
/// Resolutions, since they are the main cost lever:
///
///   emission      full           the sharp core, needs the detail
///   bloom small   half
///   bloom medium  quarter        blur is cheap at low resolution and the
///   bloom large   eighth         result is soft either way
///   trail A/B     half           ping-pong pair, never read and written at once
///   trail scratch half           directional streak and diffusion
final class EyeGlowRenderer {

    var configuration = EyeGlowConfiguration()

    private let device: MTLDevice
    private let emissionPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLComputePipelineState
    private let streakPipeline: MTLComputePipelineState

    /// Enough for two eyes: a centre plus the contour, twice, with room to
    /// spare. Written in place each frame rather than reallocated.
    private static let maximumVertices = 256
    private let vertexBuffer: MTLBuffer

    private var size = CGSize.zero

    /// What the current textures were built for. Quality changes their sizes
    /// and which of them exist at all, so it belongs alongside the size in
    /// deciding when to rebuild.
    private var builtQuality: EyeGlowQuality?

    private(set) var emission: MTLTexture?
    private(set) var bloomSmall: MTLTexture?
    private(set) var bloomMedium: MTLTexture?
    private(set) var bloomLarge: MTLTexture?
    private var trailA: MTLTexture?
    private var trailB: MTLTexture?
    private var trailScratch: MTLTexture?

    /// Which of the pair currently holds the history.
    private var readingFromA = true

    /// The one the composite should sample.
    var trail: MTLTexture? { readingFromA ? trailA : trailB }

    /// What was last drawn, in view space, for the debug overlay to mark up.
    /// Kept here rather than recomputed in the renderer so the overlay shows
    /// the geometry the glow actually used, including its gating.
    private(set) var lastEyes: [TrackedEye] = []

    /// Each bloom scale's input, at that scale's own size.
    ///
    /// A Gaussian blur is size-preserving: encoding one from a large texture
    /// into a small one blurs the top-left corner of the source at 1:1 pixels
    /// rather than shrinking the whole image into it. Sampling that with
    /// normalised coordinates then stretches the corner across the frame and
    /// doubles every position. So the downsample is a separate step, and these
    /// are what it writes into.
    private var bloomScratchSmall: MTLTexture?
    private var bloomScratchMedium: MTLTexture?
    private var bloomScratchLarge: MTLTexture?

    private var blurSmall: MPSImageGaussianBlur?
    private var blurMedium: MPSImageGaussianBlur?
    private var blurLarge: MPSImageGaussianBlur?
    private var blurTrail: MPSImageGaussianBlur?

    /// Resamples between the bloom scales. With no scale transform set it fits
    /// the source to the destination, which is exactly the downsample wanted.
    private lazy var downsample = MPSImageBilinearScale(device: device)

    private var lastSeen: CFAbsoluteTime = 0
    private var needsClear = true

    init?(device: MTLDevice, library: MTLLibrary) {

        guard let vertexFunction = library.makeFunction(name: "eyeGlowVertex"),
              let fragmentFunction = library.makeFunction(name: "eyeGlowFragment"),
              let trailFunction = library.makeFunction(name: "updateEyeTrail"),
              let streakFunction = library.makeFunction(name: "directionalTrailBlur"),
              let buffer = device.makeBuffer(
                  length: MemoryLayout<EyeGlowVertex>.stride * Self.maximumVertices,
                  options: .storageModeShared) else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float

        // Additive, so the two eyes accumulate rather than the second replacing
        // the first where they overlap.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        guard let emissionPipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let trailPipeline = try? device.makeComputePipelineState(function: trailFunction),
              let streakPipeline = try? device.makeComputePipelineState(function: streakFunction) else {
            return nil
        }

        self.device = device
        self.vertexBuffer = buffer
        self.emissionPipeline = emissionPipeline
        self.trailPipeline = trailPipeline
        self.streakPipeline = streakPipeline
    }

    /// Drops the accumulated history. Called whenever what came before stops
    /// meaning anything — a new effect, a different camera, a resize, or
    /// tracking gone long enough that the trail would be stale rather than
    /// fading.
    func reset() {
        needsClear = true
        lastSeen = 0
    }

    // MARK: - Textures

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false)

        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        return device.makeTexture(descriptor: descriptor)
    }

    private func resizeIfNeeded(to newSize: CGSize, quality: EyeGlowQuality) {
        guard newSize.width > 0, newSize.height > 0,
              newSize != size || quality != builtQuality else {
            return
        }

        size = newSize
        builtQuality = quality

        let width = Int(newSize.width)
        let height = Int(newSize.height)

        let trailWidth = width / quality.trailDivisor
        let trailHeight = height / quality.trailDivisor

        emission = makeTexture(width: width, height: height)

        // Only the scales this level composites. The rest stay nil and the
        // composite binds the empty texture in their place, so nothing pays for
        // a blur whose result is weighted to zero.
        bloomSmall = makeTexture(width: width / 2, height: height / 2)
        bloomScratchSmall = makeTexture(width: width / 2, height: height / 2)

        bloomMedium = quality.bloomScales >= 2 ? makeTexture(width: width / 4, height: height / 4) : nil
        bloomScratchMedium = bloomMedium == nil ? nil : makeTexture(width: width / 4, height: height / 4)

        bloomLarge = quality.bloomScales >= 3 ? makeTexture(width: width / 8, height: height / 8) : nil
        bloomScratchLarge = bloomLarge == nil ? nil : makeTexture(width: width / 8, height: height / 8)

        trailA = makeTexture(width: trailWidth, height: trailHeight)
        trailB = makeTexture(width: trailWidth, height: trailHeight)
        trailScratch = quality.usesDirectionalBlur
            ? makeTexture(width: trailWidth, height: trailHeight)
            : nil

        blurSmall = MPSImageGaussianBlur(device: device, sigma: configuration.bloomSigmaSmall)
        blurMedium = MPSImageGaussianBlur(device: device, sigma: configuration.bloomSigmaMedium)
        blurLarge = MPSImageGaussianBlur(device: device, sigma: configuration.bloomSigmaLarge)
        blurTrail = MPSImageGaussianBlur(
            device: device,
            sigma: configuration.trailBlurSigma * quality.trailDiffusion)

        for blur in [blurSmall, blurMedium, blurLarge, blurTrail] {
            blur?.edgeMode = .clamp
        }

        // The new textures hold whatever the allocator handed over.
        needsClear = true
    }

    // MARK: - Encoding

    /// Encodes every pass the composite will need. Returns false when there is
    /// nothing to show, which leaves the effect drawing the plain camera.
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer,
                face: TrackedFace,
                drawableSize: CGSize,
                scale: SIMD2<Float>,
                elapsed: Double,
                now: CFAbsoluteTime) -> Bool {

        let settings = configuration.sanitized

        resizeIfNeeded(to: drawableSize, quality: settings.quality)

        // Only what every level needs. The wider bloom scales and the streak
        // scratch are absent by design below high, and their passes are skipped
        // rather than being a failure to encode.
        guard let emission, let bloomSmall, let trailA, let trailB else {
            return false
        }

        if needsClear {
            clear([emission, bloomSmall, bloomMedium, bloomLarge,
                   bloomScratchSmall, bloomScratchMedium, bloomScratchLarge,
                   trailA, trailB, trailScratch].compactMap { $0 },
                  commandBuffer: commandBuffer)
            needsClear = false
        }

        let eyes = preparedEyes(from: face, scale: scale, settings: settings)
        lastEyes = eyes

        if !eyes.isEmpty {
            lastSeen = now
        } else if lastSeen > 0, now - lastSeen > settings.trackingLossTimeout {
            // Long gone rather than momentarily lost: clear outright, so the
            // glow doesn't sit frozen at the last known position.
            reset()
        }

        encodeEmission(eyes: eyes, settings: settings, commandBuffer: commandBuffer)
        encodeBloom(quality: settings.quality, commandBuffer: commandBuffer)
        encodeTrail(eyes: eyes,
                    settings: settings,
                    elapsed: elapsed,
                    commandBuffer: commandBuffer)

        return true
    }

    private func clear(_ textures: [MTLTexture], commandBuffer: MTLCommandBuffer) {
        for texture in textures {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store

            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
    }

    /// The eyes worth drawing, in view space and confident enough to trust.
    private func preparedEyes(from face: TrackedFace,
                              scale: SIMD2<Float>,
                              settings: EyeGlowConfiguration) -> [TrackedEye] {

        guard face.eyePresence > settings.minimumTrackingConfidence else {
            return []
        }

        // One eye failing shouldn't take the other with it.
        let candidates = [
            (face.leftEyeShape, face.leftOpenness, face.leftVelocity),
            (face.rightEyeShape, face.rightOpenness, face.rightVelocity)
        ]

        return candidates.compactMap { shape, openness, velocity in
            guard shape.count >= 3, openness > 0.001 else {
                return nil
            }

            // Tracked geometry is measured against the camera frame; these
            // passes draw in view space, as the effects do.
            let contour = shape.map { Renderer.videoPointToView($0, scale: scale) }

            return TrackedEye(contour: contour,
                              center: EyeGeometry.centroid(of: contour),
                              openness: openness,
                              velocity: velocity / scale,
                              confidence: face.eyePresence)
        }
    }

    private func encodeEmission(eyes: [TrackedEye],
                                settings: EyeGlowConfiguration,
                                commandBuffer: MTLCommandBuffer) {

        guard let emission else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = emission
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(emissionPipeline)

        let vertices = vertexBuffer.contents().bindMemory(to: EyeGlowVertex.self,
                                                          capacity: Self.maximumVertices)
        var written = 0

        for eye in eyes {
            guard let box = EyeGeometry.bounds(of: eye.contour) else {
                continue
            }

            let extent = simd_max(box.max - box.min, SIMD2(1e-5, 1e-5))
            let centre = eye.center

            // A triangle fan around the centre. Each contour point is repeated
            // as the fan closes, so the run is contour.count * 3 vertices.
            let needed = eye.contour.count * 3
            guard written + needed <= Self.maximumVertices else {
                break
            }

            func clip(_ point: SIMD2<Float>) -> EyeGlowVertex {
                EyeGlowVertex(position: SIMD2(point.x * 2 - 1, point.y * 2 - 1),
                              localUV: (point - box.min) / extent)
            }

            let hub = clip(centre)

            for index in eye.contour.indices {
                let current = eye.contour[index]
                let next = eye.contour[(index + 1) % eye.contour.count]

                vertices[written] = hub
                vertices[written + 1] = clip(current)
                vertices[written + 2] = clip(next)
                written += 3
            }

            var fragment = EyeGlowFragmentUniforms(glowColor: settings.glowColor,
                                                   intensity: settings.eyeIntensity,
                                                   openness: eye.openness,
                                                   confidence: eye.confidence)

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentBytes(&fragment,
                                     length: MemoryLayout<EyeGlowFragmentUniforms>.stride,
                                     index: 0)
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: written - needed,
                                   vertexCount: needed)
        }

        encoder.endEncoding()
    }

    /// Only the emission is blurred. Blurring the camera frame would be both
    /// far more expensive and wrong — the picture should stay sharp.
    ///
    /// Each scale blurs the one before it rather than the emission again, so the
    /// widest is reached by three cheap passes instead of one enormous kernel.
    /// That also means a level which drops a scale drops everything beyond it.
    private func encodeBloom(quality: EyeGlowQuality, commandBuffer: MTLCommandBuffer) {
        guard let emission, let bloomSmall, let bloomScratchSmall else {
            return
        }

        scaleThenBlur(from: emission, into: bloomSmall, via: bloomScratchSmall,
                      blur: blurSmall, commandBuffer: commandBuffer)

        guard let bloomMedium, let bloomScratchMedium else {
            return
        }

        scaleThenBlur(from: bloomSmall, into: bloomMedium, via: bloomScratchMedium,
                      blur: blurMedium, commandBuffer: commandBuffer)

        guard let bloomLarge, let bloomScratchLarge else {
            return
        }

        scaleThenBlur(from: bloomMedium, into: bloomLarge, via: bloomScratchLarge,
                      blur: blurLarge, commandBuffer: commandBuffer)
    }

    /// Shrinks `source` to `scratch`'s size and blurs the result into
    /// `destination`. The two steps have to be separate: the blur preserves
    /// size, so it can't do the shrinking, and it can't read and write one
    /// texture either.
    private func scaleThenBlur(from source: MTLTexture,
                               into destination: MTLTexture,
                               via scratch: MTLTexture,
                               blur: MPSImageGaussianBlur?,
                               commandBuffer: MTLCommandBuffer) {

        downsample.encode(commandBuffer: commandBuffer,
                          sourceTexture: source,
                          destinationTexture: scratch)

        blur?.encode(commandBuffer: commandBuffer,
                     sourceTexture: scratch,
                     destinationTexture: destination)
    }

    private func encodeTrail(eyes: [TrackedEye],
                             settings: EyeGlowConfiguration,
                             elapsed: Double,
                             commandBuffer: MTLCommandBuffer) {

        guard let bloomSmall, let trailA, let trailB,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let previous = readingFromA ? trailA : trailB
        let next = readingFromA ? trailB : trailA

        var trailUniforms = EyeTrailUniforms(
            decay: settings.decay(forElapsed: elapsed),
            // No eyes means no new light, but the history still decays — the
            // glow fades out rather than vanishing.
            currentContribution: eyes.isEmpty ? 0 : settings.trailInputContribution,
            maximumBrightness: settings.maximumTrailBrightness)

        encoder.setComputePipelineState(trailPipeline)
        encoder.setTexture(previous, index: 0)
        // The softened bloom rather than the sharp core: a hard-edged input
        // leaves a row of eye-shaped stamps instead of a trail.
        encoder.setTexture(bloomSmall, index: 1)
        encoder.setTexture(next, index: 2)
        encoder.setBytes(&trailUniforms,
                         length: MemoryLayout<EyeTrailUniforms>.stride,
                         index: 0)
        dispatch(encoder, pipeline: trailPipeline, over: next)

        // Smear along the motion, when there is enough of it to matter and the
        // quality level has a scratch texture to do it in.
        let velocity = averageVelocity(of: eyes)
        let streak = EyeGeometry.trailOffset(velocity: velocity, configuration: settings)
        let smears = streak.length > 1e-4 && trailScratch != nil

        if smears, let trailScratch {
            var streakUniforms = DirectionalTrailUniforms(direction: streak.direction,
                                                          trailLength: streak.length)

            encoder.setComputePipelineState(streakPipeline)
            encoder.setTexture(next, index: 0)
            encoder.setTexture(trailScratch, index: 1)
            encoder.setBytes(&streakUniforms,
                             length: MemoryLayout<DirectionalTrailUniforms>.stride,
                             index: 0)
            dispatch(encoder, pipeline: streakPipeline, over: trailScratch)
        }

        encoder.endEncoding()

        if smears, let trailScratch {
            blurTrail?.encode(commandBuffer: commandBuffer,
                              sourceTexture: trailScratch, destinationTexture: next)
        }

        readingFromA.toggle()
    }

    private func averageVelocity(of eyes: [TrackedEye]) -> SIMD2<Float> {
        guard !eyes.isEmpty else {
            return SIMD2(0, 0)
        }

        var total = SIMD2<Float>(0, 0)
        var weight: Float = 0

        for eye in eyes {
            total += eye.velocity * eye.confidence
            weight += eye.confidence
        }

        return weight > 0 ? total / weight : SIMD2(0, 0)
    }

    /// Sized from the pipeline that is actually bound — the two kernels are free
    /// to report different limits, and exceeding the bound one's is a fault.
    private func dispatch(_ encoder: MTLComputeCommandEncoder,
                          pipeline: MTLComputePipelineState,
                          over texture: MTLTexture) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)

        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }
}

// MARK: - Uniform mirrors

/// Mirrors `EyeGlowVertex` in Shaders/EyeGlow.metal.
struct EyeGlowVertex {
    var position: SIMD2<Float>
    var localUV: SIMD2<Float>
}

/// Mirrors `EyeGlowFragmentUniforms`.
struct EyeGlowFragmentUniforms {
    var glowColor: SIMD3<Float>
    var intensity: Float
    var openness: Float
    var confidence: Float
}

/// Mirrors `EyeTrailUniforms`.
struct EyeTrailUniforms {
    var decay: Float
    var currentContribution: Float
    var maximumBrightness: Float
}

/// Mirrors `DirectionalTrailUniforms`.
struct DirectionalTrailUniforms {
    var direction: SIMD2<Float>
    var trailLength: Float
}

/// Mirrors `EyeCompositeUniforms`.
struct EyeCompositeUniforms {
    var coreContribution: Float
    var bloomContribution: Float
    var trailContribution: Float
    var bloomWeights: SIMD3<Float>
    var debugTexture: UInt32
}

/// Mirrors `EyeGlowDebugUniforms`.
struct EyeGlowDebugUniforms {
    var leftCenter: SIMD2<Float>
    var rightCenter: SIMD2<Float>
    var leftVelocity: SIMD2<Float>
    var rightVelocity: SIMD2<Float>
    var leftCount: UInt32
    var rightCount: UInt32
    var showsContours: UInt32
    var showsCenters: UInt32
    var showsVelocity: UInt32
    var pixelsPerUV: SIMD2<Float>
}
