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

    // MARK: - Core ML mask
    //
    // Settings for the segmented mask, which supersedes the contour above when
    // the model is loaded. The contour settings stay because it remains the
    // fallback — see FaceParsing.

    /// How far past the detected face box to crop before segmenting, as a
    /// fraction of the box. See `FaceParsing.cropRegion`.
    var maskCropPadding: Float = 0.25

    /// Radius, in mask pixels, of the blur that softens the mask edge. The mask
    /// is 512 across a padded head, so a mouth spans on the order of a hundred
    /// pixels and single digits here is a few per cent of it.
    var maskFeather: Float = 3

    /// Fraction of the cropped square that must come back as mouth before the
    /// tint appears — the segmented counterpart to `minimumMouthArea`, and
    /// measured against the crop rather than the face box because that is what
    /// the model returns.
    ///
    /// A shut mouth has no opening to label, so unlike Vision's contour this
    /// collapses to zero rather than to a sliver, and the threshold only has to
    /// clear the model's own noise.
    var minimumMaskCoverage: Float = 0.0004

    /// Inferences per second. The mask is only sampled through a blur, so it
    /// carries between frames better than a contour does.
    var maskUpdatesPerSecond: Float = 15

    /// How long a mask stays usable. Shorter than the face box's grace period,
    /// because a head turn invalidates a mask while the box is still good.
    var maskGraceSeconds: Float = 0.4

    // The brightness and saturation thresholds are separate from the contour's
    // because the region is: the mask is the mouth opening, the contour is a
    // line round the lips shrunk inwards in the hope of clearing them. Inside
    // the opening the only things to tell apart are teeth, tongue, gums and the
    // dark gap, which is a far easier test than one that still has to reject
    // lip.

    /// Fraction of the mouth's own peak brightness a pixel must reach.
    ///
    /// Relative rather than fixed because a mouth is a cavity the lips shade:
    /// how bright teeth are in absolute terms says more about the light in the
    /// room than about whether they are teeth. Measured on eight colour faces,
    /// a fixed 0.52 tinted nothing on three of them whose teeth are plainly
    /// visible — all three shadowed rather than dim.
    var maskBrightnessFraction: Float = 0.60

    /// Floor under that fraction. Without it, a mouth with no teeth in it at
    /// all has its threshold collapse onto the tongue, and the tongue is then
    /// the brightest thing inside the mask.
    var maskMinimumBrightness: Float = 0.25

    /// Looser than the contour's, since lips are no longer inside the region to
    /// be rejected. Set between what teeth reach under warm light — measured up
    /// to about 0.30 — and where tongue and gums start, around 0.45.
    var maskMaximumSaturation: Float = 0.38

    /// How much redder than a measured tooth a pixel may be and still count as
    /// one. Covers the teeth at the corners of the mouth, which sit in the
    /// lips' shadow and pick up a little colour from them.
    var maskSaturationHeadroom: Float = 0.12

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

        copy.maskCropPadding = max(0, min(maskCropPadding, 2))
        copy.maskFeather = max(0, min(maskFeather, 64))
        copy.minimumMaskCoverage = max(0, min(minimumMaskCoverage, 1))
        copy.maskUpdatesPerSecond = max(1, min(maskUpdatesPerSecond, 60))
        copy.maskGraceSeconds = max(0.05, min(maskGraceSeconds, 5))
        copy.maskBrightnessFraction = maskBrightnessFraction.clamped(to: 0...1)
        copy.maskMinimumBrightness = maskMinimumBrightness.clamped(to: 0...1)
        copy.maskMaximumSaturation = maskMaximumSaturation.clamped(to: 0...1)
        copy.maskSaturationHeadroom = maskSaturationHeadroom.clamped(to: 0...1)

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
