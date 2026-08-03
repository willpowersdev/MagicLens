//
//  VideoRecorder.swift
//  MagicLens
//

import AVFoundation
import CoreVideo

/// Writes the rendered frames — effects and all — to an H.264 file with sound.
///
/// This deliberately records what the renderer produces rather than what the
/// camera captures, since the effect is the point. The renderer hands over a
/// pixel buffer from this writer's own pool each frame, so frames go straight
/// from the GPU into the file with no intermediate copy of our own.
///
/// Everything that touches the writer runs on `writerQueue`; `state` and the
/// stored inputs are guarded by `lock`. Callers come from the render loop, a
/// Metal completion handler and the capture session's audio queue, so no entry
/// point here may assume a thread — or block one. Building an AVAssetWriter is
/// slow enough to stall the render loop visibly, which is why setup is
/// asynchronous and happens exactly once per recording.
final class VideoRecorder {

    private enum State {
        case idle
        /// The writer is being built on `writerQueue`.
        case preparing
        case writing
        /// Setup failed. Never retried — retrying per frame is what made the
        /// app appear to hang.
        case failed
    }

    /// Set by the controller when the user taps record.
    var isRequested: Bool {
        get { lock.withLock { requested } }
        set { lock.withLock { requested = newValue } }
    }

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.ion6.MagicLens.writer")

    private var state: State = .idle
    private var requested = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var url: URL?

    /// Asks for a writer at this frame size. Safe to call every frame: it starts
    /// setup at most once and returns immediately, doing no work on the caller's
    /// thread.
    func prepare(size: CGSize) {
        lock.lock()

        guard requested, state == .idle else {
            lock.unlock()
            return
        }

        state = .preparing
        lock.unlock()

        writerQueue.async { [weak self] in
            self?.makeWriter(size: size)
        }
    }

    /// Runs on `writerQueue`.
    private func makeWriter(size: CGSize) {

        // H.264 wants even dimensions.
        let width = Int(size.width.rounded()) & ~1
        let height = Int(size.height.rounded()) & ~1

        guard width > 0, height > 0 else {
            lock.withLock { state = .failed }
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicLens-\(UUID().uuidString).mov")

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else {
            lock.withLock { state = .failed }
            return
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        video.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])

        guard writer.canAdd(video) else {
            lock.withLock { state = .failed }
            return
        }

        writer.add(video)

        // Audio is optional: if the microphone was refused or is unavailable
        // there simply won't be any buffers, and the movie comes out silent
        // rather than not at all.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ])
        audio.expectsMediaDataInRealTime = true

        let addedAudio = writer.canAdd(audio)
        if addedAudio {
            writer.add(audio)
        }

        guard writer.startWriting() else {
            lock.withLock { state = .failed }
            try? FileManager.default.removeItem(at: destination)
            return
        }

        lock.lock()
        self.writer = writer
        self.input = video
        self.audioInput = addedAudio ? audio : nil
        self.adaptor = adaptor
        self.url = destination
        // A stop between asking and finishing setup leaves `requested` false;
        // honour it rather than starting to write anyway.
        self.state = requested ? .writing : .idle
        let abandoned = !requested
        lock.unlock()

        if abandoned {
            finish { _ in }
        }
    }

    /// A buffer from the writer's pool for the renderer to blit this frame into.
    func nextPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard requested, state == .writing, let pool = adaptor?.pixelBufferPool else {
            return nil
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }

        return buffer
    }

    /// Called once the GPU has finished writing into `buffer`.
    ///
    /// `time` is taken when the frame is encoded rather than here, and comes
    /// from the capture session's clock — the same timeline the microphone
    /// stamps its buffers on, which is what keeps sound in step with picture.
    func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        guard state == .writing,
              let writer,
              let input,
              let adaptor,
              writer.status == .writing else {
            return
        }

        // Video opens the session. Audio arriving beforehand is discarded, so
        // the file always starts on a picture frame.
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: time)
        }

        // Dropping a frame is far better than stalling the render loop waiting
        // for the encoder to catch up.
        guard input.isReadyForMoreMediaData else {
            return
        }

        adaptor.append(buffer, withPresentationTime: time)
    }

    /// Called from the capture session's audio queue.
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard state == .writing,
              let writer,
              let audioInput,
              writer.status == .writing,
              sessionStarted,
              audioInput.isReadyForMoreMediaData else {
            return
        }

        audioInput.append(sample)
    }

    /// Closes the file. `completion` runs on the main queue with the finished
    /// movie, or nil if nothing usable was written.
    ///
    /// Dispatched onto `writerQueue`, so a stop that arrives while the writer is
    /// still being built simply queues behind it rather than racing it.
    func finish(completion: @escaping (URL?) -> Void) {
        writerQueue.async { [weak self] in
            self?.finishOnWriterQueue(completion: completion)
        }
    }

    private func finishOnWriterQueue(completion: @escaping (URL?) -> Void) {
        lock.lock()

        guard let writer, let input, sessionStarted else {
            // Never got a frame in — throw the file away.
            let stale = url
            reset()
            lock.unlock()

            if let stale {
                try? FileManager.default.removeItem(at: stale)
            }
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let destination = url
        input.markAsFinished()
        audioInput?.markAsFinished()
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
        audioInput = nil
        adaptor = nil
        sessionStarted = false
        url = nil
        state = .idle
    }
}
