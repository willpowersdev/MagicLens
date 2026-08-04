//
//  Renderer.swift
//  MagicLens
//

import MetalKit

/// Mirrors `Uniforms` in Shaders/ShaderCommon.h. Keep the two in sync — the
/// layouts have to match byte for byte.
struct Uniforms {
    var resolution: SIMD2<Float>
    var cameraResolution: SIMD2<Float>
    var touchPoint: SIMD2<Float>
    var globalTime: Float
    /// 1 when the frame arrived in the sensor's landscape orientation and needs
    /// standing up; 0 when it already arrived portrait.
    var videoRotated: Float
    /// 1 for the selfie camera, which wants mirroring.
    var videoMirrored: Float
    /// 1 to letterbox the whole frame into the view, 0 to fill and crop.
    var videoLetterboxed: Float

    /// Where the tracked face is, in the same uv space the effects use.
    var faceCenter: SIMD2<Float>
    /// Its width and height as a fraction of the screen.
    var faceSize: SIMD2<Float>
    /// 0 when nobody is there, ramping to 1 when someone is.
    var facePresence: Float

    /// Eye and pupil centres, in that same uv space, from Vision's landmarks.
    var leftEye: SIMD2<Float>
    var rightEye: SIMD2<Float>
    var leftPupil: SIMD2<Float>
    var rightPupil: SIMD2<Float>
    /// Separate from facePresence — landmarks arrive far less often.
    var eyePresence: Float
}

/// Mirrors `TeethUniforms` in Shaders/FaceEffects.metal.
///
/// Kept out of `Uniforms` because only one effect reads it — the shared struct
/// is already carrying enough for every shader that doesn't.
struct TeethUniforms {
    var minimumBrightness: Float
    var maximumSaturation: Float
    var brightnessSoftness: Float
    var saturationSoftness: Float
    var tintStrength: Float
    var edgeFeather: Float
    var mouthOpacity: Float
    var mouthPointCount: Int32
    var yellowColor: SIMD3<Float>

    // The segmented mask, when there is one. Appended rather than woven in
    // among the fields above so the existing offsets don't move — Swift and
    // Metal have to agree on this layout byte for byte, and `yellowColor`
    // being a float3 means both sides are already padding it.

    /// 1 when the mask is bound and worth reading, 0 to use the polygon.
    var usesMask: Float
    /// The part of the camera buffer the mask covers, in the space
    /// `videoTexCoord` returns.
    var maskOrigin: SIMD2<Float>
    var maskSize: SIMD2<Float>
}

/// Draws a full screen quad textured with the latest camera frame and run
/// through the selected effect. Until the first frame arrives it renders the
/// gradient instead, so the app never shows an empty drawable.
final class Renderer: NSObject, MTKViewDelegate {

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// How video-space uv maps onto the view, matching what sampleVideo does.
    ///
    /// Everything tracked — face boxes, eyes, the mouth contour — is measured
    /// against the camera frame, but the effects and overlays are drawn in view
    /// space. Once the video is fitted rather than stretched those two stop
    /// coinciding, so tracked points have to be mapped across or they drift off
    /// the thing they are tracking.
    static func videoToViewScale(cameraResolution: SIMD2<Float>,
                                 viewResolution: SIMD2<Float>,
                                 rotated: Bool,
                                 letterboxed: Bool = letterboxes) -> SIMD2<Float> {

        let videoSize = rotated
            ? SIMD2(cameraResolution.y, cameraResolution.x)
            : cameraResolution

        guard videoSize.x > 0, videoSize.y > 0, viewResolution.y > 0 else {
            return SIMD2(1, 1)
        }

        let videoAspect = videoSize.x / videoSize.y
        let viewAspect = viewResolution.x / viewResolution.y

        var scale = SIMD2<Float>(1, 1)

        if letterboxed {
            if videoAspect > viewAspect {
                scale.y = videoAspect / viewAspect
            } else {
                scale.x = viewAspect / videoAspect
            }
        } else {
            if videoAspect > viewAspect {
                scale.x = viewAspect / videoAspect
            } else {
                scale.y = videoAspect / viewAspect
            }
        }

        return scale
    }

    /// Takes a point measured against the video into view space.
    ///
    /// The inverse of the shader's `(s - 0.5) * scale + 0.5`, since that maps
    /// the view onto the video and this needs to go the other way.
    static func videoPointToView(_ point: SIMD2<Float>, scale: SIMD2<Float>) -> SIMD2<Float> {
        (point - 0.5) / scale + 0.5
    }

    /// Whether to fit the whole frame into the view rather than filling it.
    ///
    /// Off on both platforms, because neither needs it. A phone screen is fixed
    /// and close to the camera's shape; a Mac window is held to the camera's
    /// shape outright, so there is nothing to letterbox.
    ///
    /// Fullscreen is the one case where the shape can't be honoured — the
    /// display's proportions are whatever they are — and filling is the right
    /// answer there. Letterboxing would mean black bars in the one mode meant
    /// to be immersive, and the crop is a few per cent off the long edge rather
    /// than anything structural. The alternative is kept because it is one flag
    /// away if the trade ever looks wrong.
    static var letterboxes: Bool { false }


    /// Matches the top of the gradient, so a dropped frame is invisible.
    static let clearColor = MTLClearColor(red: 0.118, green: 0.227, blue: 0.541, alpha: 1.0)

    private static let vertexData: [Float] = [
         1.0, -1.0,     1.0, 0.0,
         1.0,  1.0,     1.0, 1.0,
        -1.0,  1.0,     0.0, 1.0,
        -1.0, -1.0,     0.0, 0.0
    ]

    private static let indexData: [UInt32] = [0, 1, 2, 2, 3, 0]

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let gradientPipelineState: MTLRenderPipelineState

    private let feed: CameraFeed
    private let touch: TouchState
    private let recorder: VideoRecorder

    /// Wraps the recorder's pixel buffers as Metal textures to blit into. Kept
    /// separate from the camera's cache, which holds incoming frames.
    private var recordingTextureCache: CVMetalTextureCache?

    private var effectPipelineState: MTLRenderPipelineState?
    private var currentEffect: Effect?

    /// The eye glow's own passes. Built lazily, since most effects never touch
    /// its textures and they are not small.
    private lazy var eyeGlow: EyeGlowRenderer? = EyeGlowRenderer(device: device, library: library)

    /// Restarted whenever the effect changes, so time based effects begin from
    /// zero rather than mid-animation.
    private var startDate = Date()

    private var lastDrawTime: CFAbsoluteTime?

    /// Draws the tracked face box over whatever effect is running.
    var showsFaceOverlay = false

    private lazy var faceOverlayPipelineState: MTLRenderPipelineState? = {
        Self.makePipelineState(device: device,
                               library: library,
                               fragmentFunction: "fragment_facedebug",
                               blended: true)
    }()


    init(controller: CameraController) {

        self.device = controller.device
        self.feed = controller.feed
        self.touch = controller.touch
        self.recorder = controller.recorder

        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Couldn't create the Metal command queue and shader library")
        }

        self.commandQueue = commandQueue
        self.library = library

        guard let vertexBuffer = device.makeBuffer(bytes: Self.vertexData,
                                                   length: Self.vertexData.size(),
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: Self.indexData,
                                                  length: Self.indexData.size(),
                                                  options: .storageModeShared) else {
            fatalError("Couldn't allocate the quad's buffers")
        }

        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer

        guard let gradientPipelineState = Self.makePipelineState(device: device,
                                                                 library: library,
                                                                 fragmentFunction: "fragment_gradient") else {
            fatalError("Couldn't build the gradient pipeline")
        }

        self.gradientPipelineState = gradientPipelineState

        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  device,
                                  nil,
                                  &recordingTextureCache)
    }

    /// Wraps one of the recorder's pixel buffers so the GPU can blit into it.
    /// The CVMetalTexture is returned alongside because it has to outlive the
    /// blit — releasing it early would pull the texture out from under the GPU.
    private func recordingTarget(for buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {

        guard let cache = recordingTextureCache else {
            return nil
        }

        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(buffer),
            CVPixelBufferGetHeight(buffer),
            0,
            &wrapper)

        guard status == kCVReturnSuccess,
              let wrapper,
              let texture = CVMetalTextureGetTexture(wrapper) else {
            return nil
        }

        return (texture, wrapper)
    }

    private static func makePipelineState(device: MTLDevice,
                                          library: MTLLibrary,
                                          fragmentFunction: String,
                                          blended: Bool = false) -> MTLRenderPipelineState? {

        guard let vertexProgram = library.makeFunction(name: "vertex_func"),
              let fragmentProgram = library.makeFunction(name: fragmentFunction) else {
            assertionFailure("Missing shader function: \(fragmentFunction)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexProgram
        descriptor.fragmentFunction = fragmentProgram
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        // Overlays draw over the effect rather than replacing it.
        if blended {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Error building pipeline for \(fragmentFunction): \(error)")
            return nil
        }
    }

    /// Rebuilds the effect pipeline. Keeps the current one if the new effect
    /// fails to build, rather than dropping to a blank screen.
    func setEffect(_ effect: Effect) {

        guard effect != currentEffect else {
            return
        }

        guard let pipelineState = Self.makePipelineState(device: device,
                                                         library: library,
                                                         fragmentFunction: effect.fragmentFunction) else {
            return
        }

        effectPipelineState = pipelineState
        currentEffect = effect
        startDate = Date()

        // Whatever the trail accumulated belongs to a different effect, or to
        // before this one was on screen.
        eyeGlow?.reset()
    }

    /// What counts as bright and neutral enough to tint, given where the mouth
    /// came from.
    ///
    /// The two sources want different tests. The contour is a line around the
    /// lips pulled inwards, so lip is still inside it and the thresholds have to
    /// be strict enough to reject it. The mask is the opening itself, so the
    /// only things left to tell apart are teeth, tongue, gums and the dark gap —
    /// and the brightness bar can be measured against what is in this mouth
    /// rather than fixed.
    ///
    /// That last part is the point. Measured on eight colour faces, a fixed
    /// 0.52 tinted nothing at all on three whose teeth are plainly visible,
    /// because a mouth is a cavity and the lips shade what is inside it. The
    /// floor keeps a mouth with no teeth in it from having the threshold
    /// collapse onto its tongue.
    static func tintThresholds(_ settings: TeethHighlightConfiguration,
                               maskPeak: Float?) -> (brightness: Float, saturation: Float) {

        guard let maskPeak else {
            return (settings.minimumBrightness, settings.maximumSaturation)
        }

        return (max(settings.maskMinimumBrightness,
                    maskPeak * settings.maskBrightnessFraction),
                settings.maskMaximumSaturation)
    }

    /// Stands in for the mask when there isn't one, so the fragment shader's
    /// texture binding is never empty. Reading it would give zero coverage
    /// everywhere; `usesMask` means nothing reads it.
    private lazy var emptyMaskTexture: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead

        let texture = device.makeTexture(descriptor: descriptor)
        var zero: UInt8 = 0
        texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                         mipmapLevel: 0,
                         withBytes: &zero,
                         bytesPerRow: 1)
        return texture
    }()

    /// Stands in for the glow's targets before they exist. Read as `float`, as
    /// the real ones are, so the same shader binding accepts either.
    private lazy var emptyGlowTexture: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead

        let texture = device.makeTexture(descriptor: descriptor)
        var transparent: UInt32 = 0
        texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                         mipmapLevel: 0,
                         withBytes: &transparent,
                         bytesPerRow: 4)
        return texture
    }()

    /// Binds the glow's textures and the composite's own settings.
    ///
    /// Its own uniform buffer rather than more fields on the shared one, which
    /// every other shader would then carry for no reason.
    ///
    /// Every effect shares one encoder, so the indices are a single budget:
    /// buffer 0 and texture 0 are the shared uniforms and the camera, buffers 1
    /// and 2 and texture 1 belong to the mouth, which `bindMouth` rebinds after
    /// this runs. The glow starts above all of them.
    /// A nil renderer, or one whose textures aren't up yet, binds the empty
    /// texture with every contribution at zero: the shader then composites
    /// nothing over the camera, which is the right thing to show while the glow
    /// isn't ready.
    private func bindEyeGlow(_ glow: EyeGlowRenderer?,
                             viewResolution: SIMD2<Float>,
                             to encoder: MTLRenderCommandEncoder) {

        let settings = (glow?.configuration ?? EyeGlowConfiguration()).sanitized

        bindEyeGlowDebug(glow,
                         settings: settings,
                         viewResolution: viewResolution,
                         to: encoder)

        guard let glow, let emission = glow.emission, let small = glow.bloomSmall,
              let trail = glow.trail else {

            var off = EyeCompositeUniforms(coreContribution: 0,
                                           bloomContribution: 0,
                                           trailContribution: 0,
                                           bloomWeights: SIMD3(repeating: 0),
                                           debugTexture: 0)

            encoder.setFragmentBytes(&off,
                                     length: MemoryLayout<EyeCompositeUniforms>.stride,
                                     index: 3)

            for index in 2...6 {
                encoder.setFragmentTexture(emptyGlowTexture, index: index)
            }
            return
        }

        // A scale the quality level dropped has no texture, so it is weighted
        // out and the empty one stands in. Weighting alone would be enough, but
        // the shader still has to have something bound to sample.
        let weights = SIMD3<Float>(0.80,
                                   glow.bloomMedium == nil ? 0 : 0.55,
                                   glow.bloomLarge == nil ? 0 : 0.25)

        var composite = EyeCompositeUniforms(
            coreContribution: settings.coreContribution,
            bloomContribution: settings.bloomContribution,
            trailContribution: settings.trailContribution,
            bloomWeights: weights,
            debugTexture: settings.debug.fullScreenTexture.rawValue)

        encoder.setFragmentBytes(&composite,
                                 length: MemoryLayout<EyeCompositeUniforms>.stride,
                                 index: 3)

        encoder.setFragmentTexture(emission, index: 2)
        encoder.setFragmentTexture(small, index: 3)
        encoder.setFragmentTexture(glow.bloomMedium ?? emptyGlowTexture, index: 4)
        encoder.setFragmentTexture(glow.bloomLarge ?? emptyGlowTexture, index: 5)
        encoder.setFragmentTexture(trail, index: 6)
    }

    /// The tracked geometry the debug overlay marks up.
    ///
    /// Bound whether or not the overlay is on, for the same reason the
    /// composite uniforms are: the fragment function declares the arguments
    /// unconditionally.
    private func bindEyeGlowDebug(_ glow: EyeGlowRenderer?,
                                  settings: EyeGlowConfiguration,
                                  viewResolution: SIMD2<Float>,
                                  to encoder: MTLRenderCommandEncoder) {

        let eyes = settings.debug.drawsOverlay ? (glow?.lastEyes ?? []) : []
        let left = eyes.first
        let right = eyes.count > 1 ? eyes[1] : nil

        var points = (left?.contour ?? []) + (right?.contour ?? [])

        var debug = EyeGlowDebugUniforms(
            leftCenter: left?.center ?? SIMD2(-1, -1),
            rightCenter: right?.center ?? SIMD2(-1, -1),
            leftVelocity: left?.velocity ?? SIMD2(0, 0),
            rightVelocity: right?.velocity ?? SIMD2(0, 0),
            leftCount: UInt32(left?.contour.count ?? 0),
            rightCount: UInt32(right?.contour.count ?? 0),
            showsContours: settings.debug.showEyeContours ? 1 : 0,
            showsCenters: settings.debug.showEyeCenters ? 1 : 0,
            showsVelocity: settings.debug.showVelocityVectors ? 1 : 0,
            // Marks stay an even thickness on screen rather than stretching
            // with whichever way the view is longer.
            pixelsPerUV: viewResolution)

        encoder.setFragmentBytes(&debug,
                                 length: MemoryLayout<EyeGlowDebugUniforms>.stride,
                                 index: 4)

        // setFragmentBytes rejects a zero length, and the shader reads nothing
        // when both counts are zero.
        if points.isEmpty {
            points = [SIMD2(0, 0)]
        }

        encoder.setFragmentBytes(&points,
                                 length: MemoryLayout<SIMD2<Float>>.stride * points.count,
                                 index: 5)
    }

    /// Binds the mouth — segmented mask where there is one, inner-lip contour
    /// where there isn't — and the teeth settings.
    ///
    /// Both are bound every time rather than one or the other, because the
    /// choice belongs to the shader: `usesMask` decides, and the unused path
    /// costs a texture binding it was going to do anyway.
    ///
    /// The polygon feather is scaled by the face rather than fixed, so the soft
    /// edge stays proportionate whether someone is close to the camera or far
    /// away. The mask needs no equivalent — its edge was blurred in when it was
    /// made, in mask pixels, which scale with the face for free.
    private func bindMouth(face: TrackedFace,
                           mask: (mask: MouthMask, opacity: Float)?,
                           scale: SIMD2<Float>,
                           to encoder: MTLRenderCommandEncoder) {

        let settings = feed.faces.configuration

        // setFragmentBytes rejects a zero length, and the shaders are guarded
        // by the count regardless. Mapped into view space like the rest of the
        // tracked geometry.
        var mouth = face.mouth.isEmpty
            ? [SIMD2<Float>(0, 0)]
            : face.mouth.map { Self.videoPointToView($0, scale: scale) }

        // Left in the camera buffer's space rather than mapped into view space
        // like the polygon, because the shader looks it up through
        // videoTexCoord — the same mapping it samples the video with.
        let region = mask?.mask.region ?? .zero

        let thresholds = Self.tintThresholds(settings, maskPeak: mask?.mask.brightnessPeak)

        var teeth = TeethUniforms(
            minimumBrightness: thresholds.brightness,
            maximumSaturation: thresholds.saturation,
            brightnessSoftness: settings.brightnessSoftness,
            saturationSoftness: settings.saturationSoftness,
            tintStrength: settings.tintStrength,
            // Scaled by the mouth, not the face. Against the face the feather
            // came out around ten times the height of the opening, so the mask
            // never reached full strength anywhere and the tint was patchy.
            edgeFeather: settings.edgeFeather * max(face.mouthHeight / scale.y, 0.002),
            // Whichever source is driving carries its own fade.
            mouthOpacity: mask?.opacity ?? face.mouthOpacity,
            mouthPointCount: Int32(face.mouth.count),
            yellowColor: settings.yellowColor,
            usesMask: mask == nil ? 0 : 1,
            maskOrigin: SIMD2(Float(region.minX), Float(region.minY)),
            maskSize: SIMD2(Float(region.width), Float(region.height)))

        encoder.setFragmentBytes(&mouth,
                                 length: MemoryLayout<SIMD2<Float>>.stride * mouth.count,
                                 index: 1)
        encoder.setFragmentBytes(&teeth,
                                 length: MemoryLayout<TeethUniforms>.stride,
                                 index: 2)
        encoder.setFragmentTexture(mask?.mask.texture ?? emptyMaskTexture, index: 1)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Advanced once per rendered frame, so its smoothing and fades run on
        // the display's clock rather than the camera's.
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastDrawTime.map { Float(max(0, min(0.25, now - $0))) } ?? 0
        lastDrawTime = now
        let face = feed.faces.face(at: now, elapsed: elapsed)

        // Nil until the model has produced something, and again whenever it
        // goes stale — which is what hands the mouth back to the contour.
        let mouthMask = feed.mouths.mask(at: now, elapsed: elapsed)

        // Video space and view space only coincide when the video exactly fills
        // the view. Worked out once here so the effect draw, the overlay draw,
        // the mouth polygon and the eye glow all agree.
        let cameraResolution = SIMD2(Float(feed.currentTexture?.width ?? 0),
                                     Float(feed.currentTexture?.height ?? 0))
        let viewResolution = SIMD2(Float(view.drawableSize.width),
                                   Float(view.drawableSize.height))
        #if os(macOS)
        let needsRotation = false
        #else
        let needsRotation = cameraResolution.x > cameraResolution.y
        #endif

        let scale = Self.videoToViewScale(cameraResolution: cameraResolution,
                                          viewResolution: viewResolution,
                                          rotated: needsRotation)

        #if os(macOS)
        // Keep the window the camera's shape, so there is nothing to letterbox
        // in the first place. Fullscreen can't honour it, and falls back to the
        // bars rather than throwing picture away.
        if cameraResolution.x > 0, let tracking = view as? TrackingMTKView {
            let videoSize = needsRotation
                ? CGSize(width: CGFloat(cameraResolution.y), height: CGFloat(cameraResolution.x))
                : CGSize(width: CGFloat(cameraResolution.x), height: CGFloat(cameraResolution.y))
            tracking.matchWindowAspect(toVideo: videoSize)
        }
        #endif
        let toView = { Self.videoPointToView($0, scale: scale) }

        // The glow's own passes go in before the render encoder is opened —
        // its emission, bloom and trail are separate targets, and Metal allows
        // only one encoder on a command buffer at a time.
        var glowReady = false
        if currentEffect == .eyeGlow, let eyeGlow {
            // The tracker holds the settings — it is the one thing both the
            // Vision queue and this one already reach, and its accessor is
            // synchronised. Copied per frame rather than observed, which keeps
            // the render loop off the observation machinery.
            eyeGlow.configuration = feed.faces.eyeGlowSettings

            glowReady = eyeGlow.encode(commandBuffer: commandBuffer,
                                       face: face,
                                       drawableSize: view.drawableSize,
                                       scale: scale,
                                       elapsed: Double(elapsed),
                                       now: now)
        }

        guard let descriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // One set of uniforms for both draws. The overlay used to build its own
        // with the video fields zeroed, which was harmless while it only drew a
        // box and a cross — but it now samples the segmentation mask, and that
        // is mapped back into video space using exactly these fields. Zeroed,
        // it unmirrored the mask while the effect mirrored it.
        var uniforms = Uniforms(
            resolution: viewResolution,
            cameraResolution: cameraResolution,
            touchPoint: touch.normalized,
            globalTime: Float(Date().timeIntervalSince(startDate)),
            videoRotated: needsRotation ? 1.0 : 0.0,
            videoMirrored: feed.isFrontFacing ? 1.0 : 0.0,
            videoLetterboxed: Self.letterboxes ? 1.0 : 0.0,
            faceCenter: toView(face.center),
            faceSize: face.size / scale,
            facePresence: face.presence,
            leftEye: toView(face.leftEye),
            rightEye: toView(face.rightEye),
            leftPupil: toView(face.leftPupil),
            rightPupil: toView(face.rightPupil),
            eyePresence: face.eyePresence)

        if let videoTexture = feed.currentTexture, let pipelineState = effectPipelineState {
            encoder.setRenderPipelineState(pipelineState)


            // Small enough to go inline rather than through an MTLBuffer.
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: 0)
            encoder.setFragmentTexture(videoTexture, index: 0)

            // Bound whenever the shader is, ready or not — an argument the
            // fragment function declares but nothing filled in is a hard
            // validation failure, not a black frame.
            if currentEffect == .eyeGlow {
                bindEyeGlow(glowReady ? eyeGlow : nil,
                            viewResolution: viewResolution,
                            to: encoder)
            }
        } else {
            encoder.setRenderPipelineState(gradientPipelineState)
        }

        // Bound for both draws and both branches. Only the teeth effect and the
        // debug overlay read them, but leaving them unbound on the gradient path
        // would hand the overlay whatever happened to be there.
        bindMouth(face: face, mask: mouthMask, scale: scale, to: encoder)

        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: Self.indexData.count,
                                      indexType: .uint32,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        // A second, blended draw over the effect. Same encoder, same uniforms —
        // it reads the face exactly as the effects do, which is what makes it
        // worth trusting as a check on them.
        if showsFaceOverlay, let overlay = faceOverlayPipelineState {
            encoder.setRenderPipelineState(overlay)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: 0)
            bindMouth(face: face, mask: mouthMask, scale: scale, to: encoder)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: Self.indexData.count,
                                          indexType: .uint32,
                                          indexBuffer: indexBuffer,
                                          indexBufferOffset: 0)
        }

        encoder.endEncoding()

        capture(from: drawable.texture, into: commandBuffer, size: view.drawableSize)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Copies the frame just drawn into a recorder pixel buffer.
    ///
    /// Blitting out of the drawable rather than rendering the scene a second
    /// time means recording costs one copy, not another pass over the effect —
    /// which matters when a shader samples the video a hundred times per pixel.
    /// It relies on the view's framebufferOnly being off, or the drawable
    /// couldn't be read.
    private func capture(from source: MTLTexture,
                         into commandBuffer: MTLCommandBuffer,
                         size: CGSize) {

        guard recorder.isRequested else {
            return
        }

        recorder.prepare(size: size)

        guard let buffer = recorder.nextPixelBuffer(),
              let (destination, wrapper) = recordingTarget(for: buffer),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        // The recorder rounds down to even dimensions, so the drawable can be a
        // pixel wider or taller. Copy the region they share.
        let width = min(source.width, destination.width)
        let height = min(source.height, destination.height)

        blit.copy(from: source,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        // Stamped now rather than in the completion handler, so the time
        // reflects when the frame was drawn rather than when the GPU happened to
        // finish with it. Taken from the capture session's clock, which is the
        // same timeline the microphone's buffers arrive on.
        let presentationTime = feed.captureTime

        // Appended once the GPU has actually filled the buffer. `wrapper` is
        // captured purely to keep the texture alive until then.
        commandBuffer.addCompletedHandler { [recorder] _ in
            _ = wrapper
            recorder.append(buffer, at: presentationTime)
        }
    }
}
