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
}

/// Draws a full screen quad textured with the latest camera frame and run
/// through the selected effect. Until the first frame arrives it renders the
/// gradient instead, so the app never shows an empty drawable.
final class Renderer: NSObject, MTKViewDelegate {

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Ceiling on the drawable's scale factor.
    ///
    /// The effects are fragment bound, and on a 3x phone a full res drawable is
    /// around 3 million pixels — RadialBlur alone samples the video 101 times
    /// per pixel. The camera itself only supplies 1080p, so rendering above 2x
    /// costs a great deal and shows almost nothing for it.
    static let maximumDrawableScale: CGFloat = 2.0

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
                                          fragmentFunction: String) -> MTLRenderPipelineState? {

        guard let vertexProgram = library.makeFunction(name: "vertex_func"),
              let fragmentProgram = library.makeFunction(name: fragmentFunction) else {
            assertionFailure("Missing shader function: \(fragmentFunction)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexProgram
        descriptor.fragmentFunction = fragmentProgram
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

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

        if let videoTexture = feed.currentTexture, let pipelineState = effectPipelineState {
            encoder.setRenderPipelineState(pipelineState)

            // Read off the frame itself rather than assumed, so this stays right
            // if some device or format does hand back an already-rotated buffer.
            let arrivedLandscape = videoTexture.width > videoTexture.height

            var uniforms = Uniforms(
                resolution: SIMD2(Float(view.drawableSize.width),
                                  Float(view.drawableSize.height)),
                cameraResolution: SIMD2(Float(videoTexture.width),
                                        Float(videoTexture.height)),
                touchPoint: touch.normalized,
                globalTime: Float(Date().timeIntervalSince(startDate)),
                videoRotated: arrivedLandscape ? 1.0 : 0.0,
                videoMirrored: feed.isFrontFacing ? 1.0 : 0.0)

            // Small enough to go inline rather than through an MTLBuffer.
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: 0)
            encoder.setFragmentTexture(videoTexture, index: 0)
        } else {
            encoder.setRenderPipelineState(gradientPipelineState)
        }

        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: Self.indexData.count,
                                      indexType: .uint32,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

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

        recorder.beginIfNeeded(size: size)

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

        // Appended once the GPU has actually filled the buffer. `wrapper` is
        // captured purely to keep the texture alive until then.
        commandBuffer.addCompletedHandler { [recorder] _ in
            _ = wrapper
            recorder.append(buffer)
        }
    }
}
