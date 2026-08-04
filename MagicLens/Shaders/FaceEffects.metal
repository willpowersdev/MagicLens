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
                                   constant Uniforms &uniforms [[buffer(0)]]) {

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

    return result;
}
