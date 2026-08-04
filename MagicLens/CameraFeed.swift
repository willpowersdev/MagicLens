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

    /// Handed each microphone buffer, on `audioQueue`. Set by the controller so
    /// the feed doesn't need to know the recorder exists.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    /// The shared face tracker, fed from the session's metadata output.
    let faces = FaceTracker()

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

    func startCapture() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            let devicePosition = self.cameraPosition
            // TODO: Accomodate more than just the wide angle camera
            let deviceDescoverySession = AVCaptureDevice.DiscoverySession.init(
                deviceTypes: [AVCaptureDevice.DeviceType.builtInWideAngleCamera],
                mediaType: AVMediaType.video,
                position: devicePosition)

            for device in deviceDescoverySession.devices {
                if device.position == devicePosition {
                    self.captureDevice = device
                    self.beginSession()
                    break
                }
            }
        }
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
            self.cameraPosition = self.cameraPosition == .back ? .front : .back
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
        textureLock.unlock()

        CVMetalTextureCacheFlush(textureCache, 0)
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
