//
//  MagicLensApp.swift
//  MagicLens
//

import SwiftUI

@main
struct MagicLensApp: App {

    var body: some Scene {
        WindowGroup {
            CameraView()
                #if os(macOS)
                // Below this the controls start crowding the picture. The window
                // is otherwise free to be any shape: the video is aspect-filled
                // rather than stretched, so resizing crops instead of distorting.
                .frame(minWidth: 480, minHeight: 360)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 640)
        #endif
    }
}
