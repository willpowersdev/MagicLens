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

    private var effectPipelineState: MTLRenderPipelineState?
    private var currentEffect: Effect?

    /// Restarted whenever the effect changes, so time based effects begin from
    /// zero rather than mid-animation.
    private var startDate = Date()

    /// Caps how many frames may be outstanding at once.
    ///
    /// Released from the drawable's *presented* handler rather than the command
    /// buffer's completed handler. A drawable isn't returned to the layer's pool
    /// when the GPU finishes with it, but when it actually reaches the screen —
    /// so throttling on completion still let us request drawables faster than
    /// they came back, drain the pool, and leave `currentDrawable` blocking the
    /// main thread for its full one second timeout.
    private let inFlightFrames = DispatchSemaphore(value: 1)

    /// Guards against a dropped presented handler wedging rendering forever.
    private var lastFrameStarted = Date.distantPast

    init(controller: CameraController) {

        self.device = controller.device
        self.feed = controller.feed
        self.touch = controller.touch

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

        // MTKView drives this on the main thread, and `currentDrawable` blocks
        // its caller when the layer has no drawable free. Only ask for one once
        // the previous frame has actually reached the screen, so that call always
        // finds a drawable waiting and never stalls touch handling or view
        // presentation behind the GPU.
        guard inFlightFrames.wait(timeout: .now()) == .success else {
            // If a presented handler is ever dropped — a cancelled present, the
            // app being backgrounded mid-frame — the count would never come back
            // and rendering would stop for good. Recover instead of freezing.
            if Date().timeIntervalSince(lastFrameStarted) > 0.5 {
                inFlightFrames.signal()
            }
            return
        }

        lastFrameStarted = Date()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            inFlightFrames.signal()
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

        #if targetEnvironment(simulator)
        // The simulator's MTLDrawable protocol omits addPresentedHandler, and it
        // has none of the drawable pressure this throttle exists to relieve.
        commandBuffer.addCompletedHandler { [inFlightFrames] _ in
            inFlightFrames.signal()
        }
        #else
        drawable.addPresentedHandler { [inFlightFrames] _ in
            inFlightFrames.signal()
        }
        #endif

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
