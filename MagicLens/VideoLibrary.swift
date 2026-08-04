//
//  VideoLibrary.swift
//  MagicLens
//

import AVFoundation
import Observation

struct Recording: Identifiable, Hashable {

    let url: URL
    let created: Date

    var id: URL { url }
}

/// The recordings kept inside the app.
///
/// Files live in Application Support rather than Documents so they aren't
/// exposed to the Files app, and are written by the recorder into the temporary
/// directory first — `adopt` moves a finished movie in once it's complete, so a
/// recording interrupted mid-write never appears in the library.
@Observable
final class VideoLibrary {

    private(set) var recordings: [Recording] = []

    @ObservationIgnored private let directory: URL

    init() {
        let base = URL.applicationSupportDirectory
        directory = base.appending(path: "Recordings")

        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey])) ?? []

        recordings = contents
            .filter { $0.pathExtension == "mov" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                return Recording(url: url, created: created)
            }
            .sorted { $0.created > $1.created }
    }

    /// Moves a finished movie out of the temporary directory into the library.
    func adopt(_ temporary: URL) {
        let destination = directory.appending(path: temporary.lastPathComponent)

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            reload()
        } catch {
            assertionFailure("Couldn't store the recording: \(error)")
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        reload()
    }

    /// Poster frame for the grid.
    static func thumbnail(for recording: Recording) async -> PlatformImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recording.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)

        guard let image = try? await generator.image(at: .zero).image else {
            return nil
        }

        return PlatformImage.from(cgImage: image)
    }
}
