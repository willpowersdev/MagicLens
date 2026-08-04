//
//  FaceEffects.metal
//  MagicLens
//
//  Effects driven by the shared face tracker. Each reads faceMask from
//  ShaderCommon.h rather than the raw face uniforms, so the soft edge and the
//  fade in and out are handled once rather than per effect.
//

#include "ShaderCommon.h"

/// Holds the face in colour and light while everything else falls away to a
/// darkened greyscale.
fragment float4 fragment_facespotlight(VertexOut interpolated [[stage_in]],
                                       constant Uniforms &uniforms [[buffer(0)]],
                                       texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float3 colour = sampleVideo(video, uv, uniforms).rgb;

    float grey = dot(colour, float3(0.299, 0.587, 0.114));
    float3 surroundings = float3(grey) * 0.35;

    // Generous softness — a hard oval would draw attention to the tracking
    // rather than to the face.
    float mask = faceMask(uv, uniforms, 0.55);

    return float4(mix(surroundings, colour, mask), 1.0);
}

/// Blocks the face out, leaving everything around it untouched.
fragment float4 fragment_facehide(VertexOut interpolated [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float mask = faceMask(uv, uniforms, 0.25);

    // Cell size follows the face, so the censoring stays about as coarse
    // whether someone is close to the camera or far from it.
    float span = max(uniforms.faceSize.x, 0.05);
    float cells = max(6.0, 14.0 / span * 0.1);
    float2 cellSize = float2(1.0) / max(cells, 1.0);

    float2 blocked = (floor(uv / cellSize) + 0.5) * cellSize;

    float3 sharp = sampleVideo(video, uv, uniforms).rgb;
    float3 coarse = sampleVideo(video, blocked, uniforms).rgb;

    return float4(mix(sharp, coarse, mask), 1.0);
}

/// Bulges the picture outwards around the face, and pinches it in beyond.
fragment float4 fragment_facewarp(VertexOut interpolated [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;

    if (uniforms.facePresence <= 0.0 || uniforms.faceSize.x <= 0.0) {
        return sampleVideo(video, uv, uniforms);
    }

    // Worked in units of the face's radius so the bulge scales with the face,
    // then undone before sampling.
    float2 radius = max(uniforms.faceSize * 0.5, float2(1e-4));
    float2 offset = (uv - uniforms.faceCenter) / radius;
    float distance = length(offset);

    // Inside the face it swells, further out it draws back in, and by twice the
    // radius it has settled to nothing.
    float bulge = 1.0 - 0.35 * exp(-distance * distance * 1.2);
    float scaled = mix(1.0, bulge, uniforms.facePresence);

    float2 warped = uniforms.faceCenter + offset * scaled * radius;

    return sampleVideo(video, warped, uniforms);
}

// MARK: - Teeth highlight

/// Per-effect settings, mirrored by TeethUniforms in Renderer.swift.
struct TeethUniforms {
    float minimumBrightness;
    float maximumSaturation;
    float brightnessSoftness;
    float saturationSoftness;
    float tintStrength;
    float edgeFeather;
    float mouthOpacity;
    int mouthPointCount;
    float3 yellowColor;
};

/// Signed distance from `uv` to the mouth polygon: negative inside.
///
/// One measure does inside-or-out and the soft edge together, which also makes
/// the feather a distance in uv rather than a second polygon.
static float mouthDistance(float2 uv,
                           constant float2 *points,
                           int count) {

    float closest = 1e6;
    bool inside = false;

    for (int i = 0, j = count - 1; i < count; j = i, i++) {
        float2 a = points[i];
        float2 b = points[j];

        // Distance to this edge.
        float2 edge = b - a;
        float2 toPoint = uv - a;
        float t = clamp(dot(toPoint, edge) / max(dot(edge, edge), 1e-9), 0.0, 1.0);
        closest = min(closest, length(toPoint - edge * t));

        // Crossing test, accumulated around the loop.
        if ((a.y > uv.y) != (b.y > uv.y)) {
            float crossing = a.x + (uv.y - a.y) / (b.y - a.y) * (b.x - a.x);
            if (uv.x < crossing) {
                inside = !inside;
            }
        }
    }

    return inside ? -closest : closest;
}

/// Monochrome everywhere, with likely teeth picked out in yellow.
///
/// A brightness-and-saturation heuristic confined to the gap between the lips —
/// not tooth recognition. Anything bright and near-neutral inside that contour
/// is tinted, which in practice can include a bright tongue, dental work and
/// specular highlights on wet lips.
fragment float4 fragment_teeth(VertexOut interpolated [[stage_in]],
                               constant Uniforms &uniforms [[buffer(0)]],
                               constant float2 *mouthPoints [[buffer(1)]],
                               constant TeethUniforms &teeth [[buffer(2)]],
                               texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float3 colour = sampleVideo(video, uv, uniforms).rgb;

    // Rec. 709 luma, and the base everything else is mixed against.
    float luma = dot(colour, float3(0.2126, 0.7152, 0.0722));
    float3 grey = float3(luma);

    if (teeth.mouthPointCount < 3 || teeth.mouthOpacity <= 0.001) {
        return float4(grey, 1.0);
    }

    float distance = mouthDistance(uv, mouthPoints, teeth.mouthPointCount);

    // Outside by more than the feather: the overwhelming majority of the frame
    // leaves here, having done one polygon test and no colour work.
    if (distance > teeth.edgeFeather) {
        return float4(grey, 1.0);
    }

    float mask = 1.0 - smoothstep(-teeth.edgeFeather, teeth.edgeFeather, distance);

    // Brightness and saturation from the original colour, not the grey — the
    // whole test depends on saturation, which grey has thrown away.
    float high = max(colour.r, max(colour.g, colour.b));
    float low = min(colour.r, min(colour.g, colour.b));
    float brightness = high;
    float saturation = high > 1e-4 ? (high - low) / high : 0.0;

    float brightEnough = smoothstep(teeth.minimumBrightness,
                                    teeth.minimumBrightness + teeth.brightnessSoftness,
                                    brightness);

    float neutralEnough = 1.0 - smoothstep(teeth.maximumSaturation,
                                           teeth.maximumSaturation + teeth.saturationSoftness,
                                           saturation);

    float confidence = clamp(mask * brightEnough * neutralEnough, 0.0, 1.0);

    // Tint the luminance rather than painting flat yellow, so the shading that
    // makes teeth read as teeth survives.
    float3 tinted = teeth.yellowColor * mix(0.55, 1.0, luma);

    float amount = clamp(confidence * teeth.tintStrength * teeth.mouthOpacity, 0.0, 1.0);

    return float4(mix(grey, tinted, amount), 1.0);
}

/// A cross centred on `point`, `arm` pixels across. Sized in pixels rather than
/// uv so the two strokes come out the same length on both axes.
static float eyeMarker(float2 uv, float2 point, constant Uniforms &uniforms, float arm) {

    float2 offset = (uv - point) * uniforms.resolution;

    float horizontal = (1.0 - smoothstep(0.0, 1.8, abs(offset.y))) *
                       (1.0 - step(arm, abs(offset.x)));
    float vertical = (1.0 - smoothstep(0.0, 1.8, abs(offset.x))) *
                     (1.0 - step(arm, abs(offset.y)));

    return horizontal + vertical;
}

/// Debug overlay: outlines the tracked face box and marks its centre.
///
/// Drawn as a second, blended pass over whatever effect is running, and read
/// from exactly the same uniforms in exactly the same uv space the effects use.
/// That is the point of it — an overlay positioned by its own separate
/// coordinate maths could agree with the face while the effects disagreed, and
/// prove nothing.
fragment float4 fragment_facedebug(VertexOut interpolated [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   constant float2 *mouthPoints [[buffer(1)]],
                                   constant TeethUniforms &teeth [[buffer(2)]]) {

    float2 uv = interpolated.texCoord;
    float4 result = float4(0.0);

    // The box and the landmarks come from two different detectors, so each is
    // drawn on its own terms. One failing while the other works is worth
    // seeing, not hiding.
    if (uniforms.facePresence > 0.001 && uniforms.faceSize.x > 0.0) {

        // Worked in pixels so the lines come out an even thickness — uv units
        // are stretched by the screen's aspect and would give a thin box on one
        // axis.
        float2 toCentre = (uv - uniforms.faceCenter) * uniforms.resolution;
        float2 halfBox = uniforms.faceSize * 0.5 * uniforms.resolution;

        float2 fromEdge = abs(toCentre) - halfBox;
        float onBorder = 1.0 - smoothstep(0.0, 2.5, abs(max(fromEdge.x, fromEdge.y)));

        // A cross at the centre, so a box that is the right size but in the
        // wrong place is obvious rather than merely suspicious.
        float arm = 14.0;
        float onCross = (1.0 - smoothstep(0.0, 2.0, abs(toCentre.x))) *
                        (1.0 - step(arm, abs(toCentre.y)))
                      + (1.0 - smoothstep(0.0, 2.0, abs(toCentre.y))) *
                        (1.0 - step(arm, abs(toCentre.x)));

        float ink = clamp(onBorder + onCross, 0.0, 1.0);

        // Alpha carries presence, so the fade in and out is visible too.
        result = float4(0.35, 1.0, 0.45, ink * uniforms.facePresence);
    }

    if (uniforms.eyePresence > 0.001) {

        // Distinct colours, so which marker is which — and which detector has
        // gone wrong — is obvious at a glance. Blue eyes, amber pupils.
        float eyes = eyeMarker(uv, uniforms.leftEye, uniforms, 9.0)
                   + eyeMarker(uv, uniforms.rightEye, uniforms, 9.0);

        float pupils = eyeMarker(uv, uniforms.leftPupil, uniforms, 4.0)
                     + eyeMarker(uv, uniforms.rightPupil, uniforms, 4.0);

        result = mix(result, float4(0.3, 0.75, 1.0, 1.0),
                     clamp(eyes, 0.0, 1.0) * uniforms.eyePresence);
        result = mix(result, float4(1.0, 0.85, 0.25, 1.0),
                     clamp(pupils, 0.0, 1.0) * uniforms.eyePresence);
    }

    // The eroded inner lip contour, drawn from the same points the teeth
    // shader tests against. Without this a mask in the wrong place is
    // indistinguishable from teeth the heuristic simply failed to find.
    if (teeth.mouthPointCount >= 3 && teeth.mouthOpacity > 0.001) {
        float distance = abs(mouthDistance(uv, mouthPoints, teeth.mouthPointCount));
        float onContour = 1.0 - smoothstep(0.0, 2.5 / max(uniforms.resolution.y, 1.0), distance);

        result = mix(result, float4(1.0, 0.35, 0.8, 1.0), onContour * teeth.mouthOpacity);
    }

    return result;
}

