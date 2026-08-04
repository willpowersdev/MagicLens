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
    /// A window is any shape at all, so filling one throws picture away — a
    /// wide window loses the top and bottom, which is exactly what a camera
    /// preview should not do. A phone screen is fixed and close to the camera's
    /// own shape, so there filling is right and loses almost nothing.
    static var letterboxes: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }


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
    }

    /// Binds the inner-lip contour and the teeth settings.
    ///
    /// The feather is scaled by the face rather than fixed, so the soft edge
    /// stays proportionate whether someone is close to the camera or far away.
    private func bindMouth(face: TrackedFace,
                           scale: SIMD2<Float>,
                           to encoder: MTLRenderCommandEncoder) {

        let settings = feed.faces.configuration

        // setFragmentBytes rejects a zero length, and the shaders are guarded
        // by the count regardless. Mapped into view space like the rest of the
        // tracked geometry.
        var mouth = face.mouth.isEmpty
            ? [SIMD2<Float>(0, 0)]
            : face.mouth.map { Self.videoPointToView($0, scale: scale) }

        var teeth = TeethUniforms(
            minimumBrightness: settings.minimumBrightness,
            maximumSaturation: settings.maximumSaturation,
            brightnessSoftness: settings.brightnessSoftness,
            saturationSoftness: settings.saturationSoftness,
            tintStrength: settings.tintStrength,
            // Scaled by the mouth, not the face. Against the face the feather
            // came out around ten times the height of the opening, so the mask
            // never reached full strength anywhere and the tint was patchy.
            edgeFeather: settings.edgeFeather * max(face.mouthHeight / scale.y, 0.002),
            mouthOpacity: face.mouthOpacity,
            mouthPointCount: Int32(face.mouth.count),
            yellowColor: settings.yellowColor)

        encoder.setFragmentBytes(&mouth,
                                 length: MemoryLayout<SIMD2<Float>>.stride * mouth.count,
                                 index: 1)
        encoder.setFragmentBytes(&teeth,
                                 length: MemoryLayout<TeethUniforms>.stride,
                                 index: 2)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Advanced once per rendered frame, so its smoothing and fades run on
        // the display's clock rather than the camera's.
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastDrawTime.map { Float(max(0, min(0.25, now - $0))) } ?? 0
        lastDrawTime = now
        let face = feed.faces.face(at: now, elapsed: elapsed)

        // Video space and view space only coincide when the video exactly fills
        // the view. Worked out once here so the effect draw, the overlay draw
        // and the mouth polygon all agree.
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
        let toView = { Self.videoPointToView($0, scale: scale) }

        if let videoTexture = feed.currentTexture, let pipelineState = effectPipelineState {
            encoder.setRenderPipelineState(pipelineState)

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

            // Small enough to go inline rather than through an MTLBuffer.
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: 0)
            encoder.setFragmentTexture(videoTexture, index: 0)
        } else {
            encoder.setRenderPipelineState(gradientPipelineState)
        }

        // Bound for both draws and both branches. Only the teeth effect and the
        // debug overlay read them, but leaving them unbound on the gradient path
        // would hand the overlay whatever happened to be there.
        bindMouth(face: face, scale: scale, to: encoder)

        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: Self.indexData.count,
                                      indexType: .uint32,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        // A second, blended draw over the effect. Same encoder, same uniforms —
        // it reads the face exactly as the effects do, which is what makes it
        // worth trusting as a check on them.
        if showsFaceOverlay, let overlay = faceOverlayPipelineState {
            var overlayUniforms = Uniforms(
                resolution: SIMD2(Float(view.drawableSize.width),
                                  Float(view.drawableSize.height)),
                cameraResolution: .zero,
                touchPoint: touch.normalized,
                globalTime: 0,
                videoRotated: 0,
                videoMirrored: 0,
                videoLetterboxed: 0,
                faceCenter: toView(face.center),
                faceSize: face.size / scale,
                facePresence: face.presence,
                leftEye: toView(face.leftEye),
                rightEye: toView(face.rightEye),
                leftPupil: toView(face.leftPupil),
                rightPupil: toView(face.rightPupil),
                eyePresence: face.eyePresence)

            encoder.setRenderPipelineState(overlay)
            encoder.setFragmentBytes(&overlayUniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: 0)
            bindMouth(face: face, scale: scale, to: encoder)
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
