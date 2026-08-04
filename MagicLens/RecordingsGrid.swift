//
//  RecordingsGrid.swift
//  MagicLens
//

import AVKit
import SwiftUI

/// The saved recordings, as a grid of poster frames. Presented as an overlay in
/// CameraView, so like FilterPicker it brings its own background and dismiss
/// control rather than relying on a presentation environment.
struct RecordingsGrid: View {

    let library: VideoLibrary

    let dismiss: () -> Void

    @State private var playing: Recording?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                Divider()

                if library.recordings.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .background(Color.pageBackground)

            if let playing {
                RecordingPlayer(recording: playing) {
                    self.playing = nil
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(library.recordings) { recording in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            playing = recording
                        }
                    } label: {
                        RecordingThumbnail(recording: recording)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            library.delete(recording)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .foregroundStyle(.secondary)
            Text("Tap the red button to record what you see.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        ZStack {
            Text("Recordings")
                .font(.headline)

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct RecordingThumbnail: View {

    let recording: Recording

    @State private var poster: PlatformImage?

    var body: some View {
        ZStack {
            Color.recessedBackground

            if let poster {
                Image(platformImage: poster)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            Text(recording.created.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(6)
                .shadow(radius: 2)
        }
        .task {
            poster = await VideoLibrary.thumbnail(for: recording)
        }
    }
}

private struct RecordingPlayer: View {

    let recording: Recording

    let dismiss: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(20)
        }
        .onAppear {
            let player = AVPlayer(url: recording.url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
