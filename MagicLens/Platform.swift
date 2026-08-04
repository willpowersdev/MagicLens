//
//  Platform.swift
//  MagicLens
//
//  The handful of places iOS and macOS genuinely differ. Everything else —
//  the capture pipeline, the renderer, the shaders, the trackers — is shared
//  source, so this file is deliberately small and worth keeping that way.
//

import SwiftUI

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit

typealias PlatformImage = UIImage
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

extension Color {

    /// The window or view background. `Color(.systemBackground)` is UIKit only,
    /// and AppKit's equivalent is spelled differently.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// A step back from `pageBackground`, for wells and placeholders.
    static var recessedBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

extension Image {

    /// `Image(uiImage:)` and `Image(nsImage:)` are separate initialisers with no
    /// shared spelling, so callers holding a `PlatformImage` go through this.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {

    /// Wraps a `CGImage` at its own pixel size.
    ///
    /// UIImage infers the size; NSImage needs telling, and left to its default
    /// would report a size in points that ignores the image's real resolution.
    static func from(cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}
