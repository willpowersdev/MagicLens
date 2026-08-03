//
//  VideoRecorder.swift
//  MagicLens
//

import AVFoundation
import CoreVideo

/// Writes the rendered frames — effects and all — to an H.264 file.
///
/// This deliberately records what the renderer produces rather than what the
/// camera captures, since the effect is the point. The renderer hands over a
/// pixel buffer from this writer's own pool each frame, so the frames go
/// straight from the GPU into the file with no intermediate copy of our own.
///
/// Frames are appended from a Metal completion handler, so every entry point
/// here can be called from any thread and takes `lock`.
final class VideoRecorder {

    /// Set by the controller when the user taps record. The renderer notices on
    /// its next frame, once the drawable size is known.
    var isRequested: Bool {
        get { lock.withLock { requested } }
        set { lock.withLock { requested = newValue } }
    }

    var isWriting: Bool {
        lock.withLock { writer != nil }
    }

    private let lock = NSLock()

    private var requested = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var url: URL?

    /// Spins up the writer for a given frame size. Safe to call every frame —
    /// it does nothing once a writer exists.
    func beginIfNeeded(size: CGSize) {
        lock.lock()
        defer { lock.unlock() }

        guard requested, writer == nil else {
            return
        }

        // H.264 wants even dimensions.
        let width = Int(size.width.rounded()) & ~1
        let height = Int(size.height.rounded()) & ~1

        guard width > 0, height > 0 else {
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicLens-\(UUID().uuidString).mov")

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else {
            assertionFailure("Couldn't create the asset writer")
            return
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])

        guard writer.canAdd(input) else {
            assertionFailure("Couldn't add the video input")
            return
        }

        writer.add(input)

        guard writer.startWriting() else {
            assertionFailure("Couldn't start writing: \(String(describing: writer.error))")
            return
        }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.url = destination
    }

    /// A buffer from the writer's pool for the renderer to blit this frame into.
    /// Returns nil when there is nothing to record or the pool is exhausted.
    func nextPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard requested, let pool = adaptor?.pixelBufferPool else {
            return nil
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }

        return buffer
    }

    /// Called once the GPU has finished writing into `buffer`.
    func append(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let writer, let input, let adaptor, writer.status == .writing else {
            return
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())

        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: now)
        }

        // Dropping a frame is far better than stalling the render loop waiting
        // for the encoder to catch up.
        guard input.isReadyForMoreMediaData else {
            return
        }

        adaptor.append(buffer, withPresentationTime: now)
    }

    /// Closes the file. `completion` runs on the main queue with the finished
    /// movie, or nil if nothing was written.
    func finish(completion: @escaping (URL?) -> Void) {
        lock.lock()

        guard let writer, let input, sessionStarted else {
            // Stopped before a single frame landed — throw the file away.
            let stale = url
            reset()
            lock.unlock()
            if let stale {
                try? FileManager.default.removeItem(at: stale)
            }
            completion(nil)
            return
        }

        let destination = url
        input.markAsFinished()
        reset()
        lock.unlock()

        writer.finishWriting {
            let finished = writer.status == .completed ? destination : nil
            DispatchQueue.main.async {
                completion(finished)
            }
        }
    }

    /// Caller holds `lock`.
    private func reset() {
        writer = nil
        input = nil
        adaptor = nil
        sessionStarted = false
        url = nil
    }
}
