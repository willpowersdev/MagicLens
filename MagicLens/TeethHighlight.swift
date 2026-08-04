//
//  TeethHighlight.swift
//  MagicLens
//

import CoreGraphics
import simd

/// Tuning for the teeth highlight.
///
/// This is a brightness-and-saturation heuristic confined to the visible gap
/// between the lips — not tooth recognition. It will tint anything bright and
/// close to neutral inside that contour, which in practice includes dental work,
/// a bright tongue, and specular highlights on wet lips.
struct TeethHighlightConfiguration: Sendable, Equatable {

    /// Below this a pixel is too dark to be a lit tooth.
    ///
    /// Teeth are not evenly lit — the ones towards the corners of the mouth sit
    /// in shadow and fall well below the front ones. Set high, only the
    /// brightest few tint and the result looks patchy, so this leans low and
    /// relies on saturation to reject lips, gums and tongue, which are red
    /// rather than dark.
    var minimumBrightness: Float = 0.52

    /// Above this a pixel is too colourful — lips, tongue, gums.
    var maximumSaturation: Float = 0.28

    /// Widths of the soft ramps either side of those thresholds. A hard step
    /// makes the tint crawl as exposure shifts.
    var brightnessSoftness: Float = 0.18
    var saturationSoftness: Float = 0.12

    var yellowColor = SIMD3<Float>(1.0, 0.85, 0.0)
    var tintStrength: Float = 0.90

    /// How far to pull the contour in, as a fraction of the mouth's own size.
    /// Vision's inner lip line sits on the lips themselves, so without this the
    /// tint bleeds onto them.
    var polygonErosion: Float = 0.06

    /// Softness of the mask edge, as a fraction of the mouth's *height* — the
    /// opening's small dimension. Measured against anything larger the feather
    /// swamps the mask entirely.
    var edgeFeather: Float = 0.10

    /// Exponential follow rate for the contour, per second.
    var landmarkResponsiveness: Float = 15.0

    /// Vision runs at this rate; frames between reuse the last contour.
    var updatesPerSecond: Float = 12.0

    /// Mouth area, as a fraction of the face box, below which the effect fades.
    /// A closed mouth still yields a contour — a thin bright line that would
    /// otherwise read as a row of teeth.
    ///
    /// Measured rather than guessed. Two readings from real smiles: 0.0038 for
    /// a wide one, 0.00105 for a slight one. The original 0.004 rejected both,
    /// and 0.0015 still rejected the slighter. Vision's contour for genuinely
    /// closed lips is near-collinear and its area collapses towards zero, which
    /// is where the remaining margin comes from.
    var minimumMouthArea: Float = 0.0006

    /// Everything forced into a usable range, so a bad value degrades rather
    /// than producing an inverted or never-satisfied test.
    var sanitized: TeethHighlightConfiguration {
        var copy = self

        copy.minimumBrightness = minimumBrightness.clamped(to: 0...1)
        copy.maximumSaturation = maximumSaturation.clamped(to: 0...1)
        copy.brightnessSoftness = max(0.001, min(brightnessSoftness, 1))
        copy.saturationSoftness = max(0.001, min(saturationSoftness, 1))
        copy.tintStrength = tintStrength.clamped(to: 0...1)
        copy.yellowColor = simd_clamp(yellowColor, SIMD3(repeating: 0), SIMD3(repeating: 1))
        copy.polygonErosion = polygonErosion.clamped(to: 0...0.45)
        copy.edgeFeather = max(0.001, min(edgeFeather, 0.5))
        copy.landmarkResponsiveness = max(0.1, min(landmarkResponsiveness, 60))
        copy.updatesPerSecond = max(1, min(updatesPerSecond, 60))
        copy.minimumMouthArea = max(0, min(minimumMouthArea, 1))

        return copy
    }
}

/// Geometry helpers for the inner-lip contour. Free of Vision and Metal so the
/// coordinate work can be tested with plain values.
enum MouthGeometry {

    /// Twice the signed area — the shoelace sum. Sign tells winding direction,
    /// which is why callers take the magnitude.
    static func signedArea(of points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else {
            return 0
        }

        var total: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            total += current.x * next.y - next.x * current.y
        }

        return total / 2
    }

    static func area(of points: [SIMD2<Float>]) -> Float {
        abs(signedArea(of: points))
    }

    static func centroid(of points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else {
            return SIMD2(0.5, 0.5)
        }
        return points.reduce(SIMD2<Float>(0, 0), +) / Float(points.count)
    }

    /// Pulls the contour towards its centroid.
    ///
    /// Done here rather than in the shader because it's a property of the
    /// polygon, not of the pixel being shaded, and doing it once per frame
    /// beats doing it per fragment.
    static func eroded(_ points: [SIMD2<Float>], by fraction: Float) -> [SIMD2<Float>] {
        guard points.count >= 3, fraction > 0 else {
            return points
        }

        let middle = centroid(of: points)
        let scale = max(0, 1 - fraction)

        return points.map { middle + ($0 - middle) * scale }
    }

    /// Whether the mouth is open enough to be worth examining, measured against
    /// the face so it doesn't depend on how near the camera someone is.
    static func isOpen(_ points: [SIMD2<Float>],
                       faceSize: SIMD2<Float>,
                       minimumArea: Float) -> Bool {

        guard points.count >= 3 else {
            return false
        }

        let faceArea = max(faceSize.x * faceSize.y, 1e-6)
        return area(of: points) / faceArea >= minimumArea
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
