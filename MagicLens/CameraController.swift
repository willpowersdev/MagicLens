//
//  CameraController.swift
//  MagicLens
//

import MetalKit
import Observation

/// The current touch location, normalised to the view's bounds.
///
/// Deliberately kept outside the observation system: it changes on every drag
/// event and åthe renderer polls it once per frame, so publishing it would
/// invalidate the view hierarchy at touch frequency for no benefit.
final class TouchState {
    var normalized = SIMD2<Float>(0.5, 0.5)
}

/// Owns the pieces that have to outlive any particular view: the Metal device
/// and the capture session.
@Observable
final class CameraController {

    let device: MTLDevice
    let feed: CameraFeed
    let recorder = VideoRecorder()
    let library = VideoLibrary()

    private(set) var isRecording = false

    /// When the current take started, for the on screen timer.
    private(set) var recordingStarted: Date?

    /// A `let` holding a reference type, so the macro leaves it alone.
    let touch = TouchState()

    var effect: Effect = .eyeGlow

    /// The eye glow's tuning, as the settings panel edits it.
    ///
    /// The tracker is where it actually lives — both the Vision queue and the
    /// renderer already reach it, and its accessor is synchronised. This is the
    /// observable face of it, so SwiftUI has something to bind to.
    var eyeGlow = EyeGlowConfiguration() {
        didSet { feed.faces.eyeGlowSettings = eyeGlow }
    }

    init() {
        // Every device this app supports has Metal; there is no meaningful
        // degraded mode for a camera effects app without it.
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MagicLens requires a Metal capable device")
        }

        self.device = device
        self.feed = CameraFeed(metalDevice: device)

        // The feed doesn't know the recorder exists; it just hands over buffers.
        // The recorder ignores them unless it's writing.
        feed.onAudioSample = { [recorder] sample in
            recorder.appendAudio(sample)
        }
    }

    func start() {
        feed.startCapture()
    }

    /// Whether the app is out of sight, and so neither capturing nor drawing.
    ///
    /// Observed, because the Metal view's own pausing is driven from it: the
    /// camera and the render loop have to stop together or the view spends the
    /// whole time redrawing the last frame it was given.
    private(set) var isPaused = false

    func pause() {
        guard !isPaused else {
            return
        }

        isPaused = true

        // A take can't survive this. The camera is about to stop delivering
        // frames, and on iOS the app may not be running by the time it starts
        // again — so the recording is closed and filed rather than left open to
        // resume around a gap it has no way to represent.
        if isRecording {
            toggleRecording()
        }

        feed.pauseSession()
    }

    func resume() {
        guard isPaused else {
            return
        }

        isPaused = false
        feed.resumeSession()
    }

    func flipCamera() {
        feed.rotateCamera()
    }

    /// Starts recording, or stops and files the result in the library.
    ///
    /// Starting only raises a flag — the writer itself is created by the
    /// renderer on its next frame, which is where the drawable size is known.
    func toggleRecording() {
        if isRecording {
            isRecording = false
            recordingStarted = nil
            recorder.isRequested = false
            recorder.finish { [library] finished in
                guard let finished else {
                    return
                }
                library.adopt(finished)
            }
        } else {
            recorder.isRequested = true
            isRecording = true
            recordingStarted = Date()
        }
    }
}
