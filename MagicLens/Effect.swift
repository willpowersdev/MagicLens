//
//  Effect.swift
//  MagicLens
//

import Foundation

/// One glitch effect. Every effect shares the `vertex_func` vertex stage and
/// supplies its own fragment stage, all compiled into the default Metal library.
struct Effect: Identifiable, Hashable {

    let name: String
    let title: String

    var id: String { name }

    var fragmentFunction: String { "fragment_\(name)" }

    static let edgeHighlights = Effect(name: "edgehighlights", title: "Edge Highlights")
    static let infrared = Effect(name: "infrared", title: "Infrared")
    static let points = Effect(name: "points", title: "Pointillize")
    static let delirium = Effect(name: "delirium", title: "Delirium")
    static let reflect = Effect(name: "reflect", title: "Reflecting Pool")
    static let lightTunnel = Effect(name: "lighttunnel", title: "Light Tunnel")
    static let edge = Effect(name: "edge", title: "Edge")
    static let fisheye = Effect(name: "fisheye", title: "Fisheye")
    static let antiFisheye = Effect(name: "antifisheye", title: "Anti-Fisheye")
    static let radialBlur = Effect(name: "radialblur", title: "Radial Blur")
    static let matrix = Effect(name: "matrix", title: "Inside the Matrix")
    static let crt = Effect(name: "crt", title: "Old TV")

    // Driven by the shared face tracker.
    static let faceSpotlight = Effect(name: "facespotlight", title: "Spotlight")
    static let faceHide = Effect(name: "facehide", title: "Hide My Face")
    static let faceWarp = Effect(name: "facewarp", title: "Big Head")

    /// Presentation order in the picker.
    static let all: [Effect] = [
        .edgeHighlights,
        .infrared,
        .points,
        .delirium,
        .reflect,
        .lightTunnel,
        .edge,
        .fisheye,
        .antiFisheye,
        .radialBlur,
        .matrix,
        .crt,
        .faceSpotlight,
        .faceHide,
        .faceWarp
    ]
}
