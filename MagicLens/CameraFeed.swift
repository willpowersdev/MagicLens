//
//  CameraOverlay.swift
//  MagicLens
//
//  Created by Will Powers on 2/9/17.
//  Copyright © 2017 Ion6, LLC. All rights reserved.
//

import AVFoundation
import Metal

protocol CameraFeedDelegate {
    func videoCapture(_ capture: CameraFeed, didCaptureVideoFrame: CVPixelBuffer?, timestamp: CMTime)
}

final class CameraFeed: NSObject {

    private(set) var videoTextureCache: CVMetalTextureCache?
    private var captureSession:AVCaptureSession?
    private var captureDevice:AVCaptureDevice?
    private var videoOutput:AVCaptureVideoDataOutput?
    private var audioOutput:AVCaptureAudioDataOutput?
    private var metadataOutput:AVCaptureMetadataOutput?
    private var cameraPosition: AVCaptureDevice.Position = .front

    /// Set by `rotateCamera` when it has already chosen which camera to move to,
    /// so `startCapture` doesn't rediscover and overwrite the choice.
    private var pendingDevice: AVCaptureDevice?

    /// Handed each microphone buffer, on `audioQueue`. Set by the controller so
    /// the feed doesn't need to know the recorder exists.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    /// The shared face tracker, fed from the session's metadata output.
    let faces = FaceTracker()

    /// Segments the mouth with Core ML, cropping to the box `faces` is holding.
    /// Produces nothing when the model is absent, which is what leaves the
    /// tracker's inner-lip contour in place as the fallback.
    let mouths: FaceParsing

    /// Tuning for the teeth effect.
    ///
    /// Both halves of it need the same settings and each keeps its own copy, so
    /// this exists to stop one being tuned while the other is left behind —
    /// which would show up as the effect changing character the moment it fell
    /// back from the mask to the contour.
    var teethConfiguration: TeethHighlightConfiguration {
        get { faces.configuration }
        set {
            faces.configuration = newValue
            mouths.configuration = newValue
        }
    }

    /// AVCaptureSession configuration and start/stop must stay off the main
    /// thread — they block for as long as the hardware takes to come up.
    private let sessionQueue = DispatchQueue(label: "com.ion6.MagicLens.session")

    /// Frames are delivered here, not on main, so per-frame work never competes
    /// with the UI or the render loop.
    private let videoQueue = DispatchQueue(label: "com.ion6.MagicLens.video")

    private let audioQueue = DispatchQueue(label: "com.ion6.MagicLens.audio")

    private let metadataQueue = DispatchQueue(label: "com.ion6.MagicLens.metadata")

    /// Written on `videoQueue`, read on whatever thread draws. Guarded by
    /// `textureLock`.
    private var rgbaTexture: CVMetalTexture?
    private let textureLock = NSLock()

    /// Also guarded by `textureLock`: set when the session is built, read by the
    /// renderer to decide whether to mirror.
    private var frontFacing = true

    /// The clock the capture session stamps its sample buffers against. Also
    /// guarded by `textureLock`.
    private var sessionClock: CMClock?

    /// Whether frames arrive in the sensor's landscape orientation, read from
    /// the frames themselves. The face tracker needs the same answer the shaders
    /// get, so both are derived from this rather than assumed separately.
    private var bufferIsLandscape = true

    /// Whether the running session is the selfie camera, and so wants mirroring.
    var isFrontFacing: Bool {
        textureLock.lock()
        defer { textureLock.unlock() }
        return frontFacing
    }

    /// The current time on the capture session's clock.
    ///
    /// Rendered frames are stamped with this rather than the host clock so that
    /// picture and sound share one timeline — the microphone's buffers already
    /// arrive on it. Falls back to the host clock before a session exists, which
    /// is what the session uses on iOS anyway.
    var captureTime: CMTime {
        textureLock.lock()
        defer { textureLock.unlock() }
        return CMClockGetTime(sessionClock ?? CMClockGetHostTimeClock())
    }

    /// The most recent camera frame, as a Metal texture ready for sampling.
    /// Safe to call from any thread.
    var currentTexture: MTLTexture? {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard let texture = rgbaTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(texture)
    }

    init(metalDevice: MTLDevice) {
        self.mouths = FaceParsing(device: metalDevice)

        super.init()

        // Created once, up front: rotating the camera rebuilds the session, and
        // rebuilding the cache alongside it would mutate state the video queue
        // is actively reading.
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                               nil,
                                               metalDevice,
                                               nil,
                                               &videoTextureCache)

        if status != kCVReturnSuccess {
            assertionFailure("Couldn't create video cache! \(status)")
        }
    }

    /// Camera types worth looking for.
    ///
    /// A Mac's video comes from a built-in camera, a USB webcam, or an iPhone
    /// over Continuity, and only the first of those reports a front or back
    /// position at all.
    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        #if os(macOS)
        [.builtInWideAngleCamera, .external, .continuityCamera]
        #else
        [.builtInWideAngleCamera]
        #endif
    }

    func startCapture() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            // A device chosen explicitly by rotateCamera wins; otherwise pick
            // by position, falling back to whatever exists. A Mac usually has
            // one camera and no notion of flipping it.
            let device: AVCaptureDevice?

            if let pending = self.pendingDevice {
                device = pending
                self.pendingDevice = nil
            } else {
                let wanted = self.cameraPosition

                // Unspecified rather than `wanted`, so external cameras — which
                // report no position — are still discovered.
                let devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: Self.deviceTypes,
                    mediaType: .video,
                    position: .unspecified).devices

                device = devices.first(where: { $0.position == wanted }) ?? devices.first
            }

            guard let device else {
                return
            }

            self.captureDevice = device
            self.beginSession()
        }
    }

    /// Whether there is more than one camera to switch between, so the flip
    /// control can be hidden when there isn't.
    static var hasMultipleCameras: Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                         mediaType: .video,
                                         position: .unspecified).devices.count > 1
    }

    func pauseSession() {
        sessionQueue.async { [weak self] in
            if let session = self?.captureSession, session.isRunning {
                session.stopRunning()
            }
        }
    }

    func resumeSession() {
        sessionQueue.async { [weak self] in
            if let session = self?.captureSession, session.isRunning == false {
                session.startRunning()
            }
        }
    }

    func rotateCamera() {
        pauseSession()

        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            #if os(macOS)
            // Positions don't distinguish a Mac's cameras — a USB webcam and a
            // built-in one both report unspecified — so step through the list
            // instead, which is what "another camera" means here.
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: Self.deviceTypes,
                mediaType: .video,
                position: .unspecified).devices

            if let current = self.captureDevice,
               let index = devices.firstIndex(where: { $0.uniqueID == current.uniqueID }),
               devices.count > 1 {
                let next = devices[(index + 1) % devices.count]
                self.pendingDevice = next
                self.cameraPosition = next.position
            }
            #else
            self.cameraPosition = self.cameraPosition == .back ? .front : .back
            #endif
        }

        startCapture()
    }

    /// Must be called on `sessionQueue`.
    private func beginSession() {

        dispatchPrecondition(condition: .onQueue(sessionQueue))

        captureSession = AVCaptureSession()

        guard let session = captureSession else {
            return
        }

        guard let device = captureDevice else {
            return
        }

        guard !session.isRunning else {
            assertionFailure("Session is already running!")
            return
        }

        do {
            let input:AVCaptureDeviceInput = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                assertionFailure("Couldn't add video input.")
                return
            }

            session.addInput(input)

            videoOutput = AVCaptureVideoDataOutput()

            guard let output = videoOutput else {
                session.commitConfiguration()
                assertionFailure("Error creating video output.")
                return
            }

            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [((kCVPixelBufferPixelFormatTypeKey as NSString) as String) :
                                        NSNumber(value: kCVPixelFormatType_32BGRA)]
            output.setSampleBufferDelegate(self, queue: videoQueue)

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                assertionFailure("Couldn't add video output.")
                return
            }

            session.addOutput(output)
            session.sessionPreset = AVCaptureSession.Preset.high

            addFaceDetection(to: session)
            addAudio(to: session)

            session.commitConfiguration()

            // Orientation is corrected at sample time in the shader rather than
            // here. Asking the connection to rotate is silently ignored when the
            // device or format doesn't support it, which leaves the frame
            // sideways with nothing to show for it; sampling always applies.
            textureLock.lock()
            frontFacing = device.position == .front
            sessionClock = session.synchronizationClock
            textureLock.unlock()

            session.startRunning()

        } catch let error {
            assertionFailure("error: \(error.localizedDescription)")
        }
    }

    /// Adds hardware face detection. Must be called inside the session's
    /// configuration block, on `sessionQueue`.
    ///
    /// Quiet on failure, like the microphone: a device or format that can't
    /// report faces should still show a picture, with face-aware effects simply
    /// finding nobody.
    private func addFaceDetection(to session: AVCaptureSession) {

        let output = AVCaptureMetadataOutput()

        guard session.canAddOutput(output) else {
            return
        }

        session.addOutput(output)

        // Only available once the output belongs to a session.
        guard output.availableMetadataObjectTypes.contains(.face) else {
            session.removeOutput(output)
            return
        }

        output.metadataObjectTypes = [.face]
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        metadataOutput = output
    }

    /// Adds the microphone. Must be called inside the session's configuration
    /// block, on `sessionQueue`.
    ///
    /// Failure here is deliberately quiet: if the microphone is refused or
    /// unavailable, the camera should still work and recordings simply come out
    /// silent.
    private func addAudio(to session: AVCaptureSession) {

        // The capture session configures the application audio session itself.
        // Doing it by hand here — activating mid-configuration on this queue —
        // produced FigAudioSession errors, so leave it to AVFoundation.

        guard let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input) else {
            return
        }

        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)

        guard session.canAddOutput(output) else {
            return
        }

        session.addOutput(output)
        audioOutput = output
    }
}


extension CameraFeed : AVCaptureVideoDataOutputSampleBufferDelegate,
                       AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        // Both outputs land here. Checking the type rather than comparing
        // against the stored output keeps this free of cross-thread reads.
        if captureOutput is AVCaptureAudioDataOutput {
            onAudioSample?(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let textureCache = videoTextureCache else {
            assertionFailure("No video texture cache")
            return
        }

        // CVMetalTextureCacheCreateTextureFromImage will create Metal texture
        // optimally from CVImageBufferRef. The format has to match what the
        // video output produces (kCVPixelFormatType_32BGRA) or the call fails
        // with kCVReturnPixelBufferNotMetalCompatible (-6684).
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               pixelBuffer,
                                                               nil,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &texture)

        guard status == kCVReturnSuccess else {
            assertionFailure("Error at CVMetalTextureCacheCreateTextureFromImage \(status)")
            return
        }

        // Publish the new frame before flushing, so a drawing thread never sees
        // a gap. Dropping the previous texture here is what lets the flush
        // below recycle it.
        textureLock.lock()
        rgbaTexture = texture
        bufferIsLandscape = width > height
        let landscape = bufferIsLandscape
        let mirrored = frontFacing
        textureLock.unlock()

        CVMetalTextureCacheFlush(textureCache, 0)

        // Offered every frame; the tracker decides how few to actually run.
        let now = CFAbsoluteTimeGetCurrent()

        faces.analyze(pixelBuffer,
                      bufferIsLandscape: landscape,
                      mirrored: mirrored,
                      now: now)

        // Offered the same way, and throttled on its own clock. It crops to the
        // box the tracker is holding, so on the very first frames — before any
        // detector has reported — there is nothing to crop to and it does
        // nothing.
        mouths.analyze(pixelBuffer,
                       faceBox: faces.bufferFaceBox(at: now),
                       now: now)
    }
}

extension CameraFeed: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {

        let detected = metadataObjects.compactMap { $0 as? AVMetadataFaceObject }

        guard !detected.isEmpty else {
            return
        }

        // The tracker needs the same orientation facts the shaders are given,
        // or it will follow the face in a different space to the one it's drawn
        // in. Both are read from the frame itself rather than assumed.
        textureLock.lock()
        let landscape = bufferIsLandscape
        let mirrored = frontFacing
        textureLock.unlock()

        faces.update(faces: detected,
                     bufferIsLandscape: landscape,
                     mirrored: mirrored,
                     now: CFAbsoluteTimeGetCurrent())
    }
}
