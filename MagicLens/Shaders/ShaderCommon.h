//
//  ShaderCommon.h
//  MagicLens
//
//  Shared plumbing for the ported GLSL effects. The bodies of the fragment
//  shaders are near-literal translations of the original .fsh files, so the
//  helpers here exist to paper over the two places where Metal and OpenGL ES
//  disagree about which corner is the origin.
//

#ifndef ShaderCommon_h
#define ShaderCommon_h

#include <metal_stdlib>
using namespace metal;

/// Mirrors `Uniforms` in Renderer.swift. Keep the two in sync.
struct Uniforms {
    float2 resolution;
    float2 cameraResolution;
    float2 touchPoint;
    float globalTime;
    /// 1 when the frame arrived in the sensor's landscape orientation and needs
    /// standing up; 0 when it already arrived portrait.
    float videoRotated;
    /// 1 for the selfie camera, which wants mirroring.
    float videoMirrored;

    /// Where the tracked face is, in this same uv space. Available to every
    /// effect, not just the face-aware ones — see faceMask below.
    float2 faceCenter;
    /// Its width and height as a fraction of the screen.
    float2 faceSize;
    /// 0 when nobody is there, ramping to 1 when someone is. Fade an effect
    /// with this rather than switching on it, or it will pop.
    float facePresence;
};

struct VertexOut {
    float4 computedPosition [[position]];
    float2 texCoord;
};

/// Re-origins `[[position]]`, which counts down from the top left, to a
/// fragment coordinate counting up from the bottom left — the convention the
/// ported effects were written against, and the one several of them still rely
/// on for direction-sensitive math (which way Matrix's rain falls, which way
/// RadialBlur swirls).
static inline float2 bottomLeftFragCoord(float4 position, float2 resolution) {
    return float2(position.x, resolution.y - position.y);
}

/// The single place camera orientation is decided.
///
/// `uv` arrives in the ported GLSL convention — origin bottom left — and every
/// effect's own uv arithmetic stays in that screen space. The rotation and
/// mirroring needed to turn the sensor's landscape frame into an upright
/// selfie happen here, at sample time, so no effect has to know about it.
///
/// If the image still comes out wrong, this function is the only thing to
/// change: swap the two branches of `rotated` for the opposite quarter turn,
/// or drop the `mirrored` block to stop flipping the selfie camera.
static inline float4 sampleVideo(texture2d<float> video,
                                 float2 uv,
                                 constant Uniforms &uniforms) {

    constexpr sampler videoSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);

    // GL samples with (0,0) at the bottom left, Metal at the top left.
    float2 screen = float2(uv.x, 1.0 - uv.y);

    // Mirror across the screen's vertical axis, so the selfie camera reads as
    // a reflection.
    if (uniforms.videoMirrored > 0.5) {
        screen.x = 1.0 - screen.x;
    }

    // Stand the landscape frame up: a quarter turn clockwise. Destination
    // (x, y) reads from source (y, 1 - x).
    float2 texCoord = uniforms.videoRotated > 0.5
        ? float2(screen.y, 1.0 - screen.x)
        : screen;

    return video.sample(videoSampler, texCoord);
}

/// How far inside the tracked face a point is: 1 at the centre, falling to 0 at
/// the edge of the box and beyond, already scaled by presence.
///
/// Effects should reach for this rather than reading faceCenter directly — it
/// handles the soft edge and the fade in and out, so a face-aware effect can be
/// a one line change to an existing one.
static inline float faceMask(float2 uv, constant Uniforms &uniforms, float softness) {

    if (uniforms.facePresence <= 0.0 || uniforms.faceSize.x <= 0.0) {
        return 0.0;
    }

    // Distance in units of the face's own radius, so it tracks size as someone
    // moves closer or further away.
    float2 radius = max(uniforms.faceSize * 0.5, float2(1e-4));
    float2 offset = (uv - uniforms.faceCenter) / radius;
    float distance = length(offset);

    return (1.0 - smoothstep(1.0 - softness, 1.0 + softness, distance)) * uniforms.facePresence;
}

/// GLSL's `mod` and Metal's `fmod` disagree on negative operands.
static inline float glMod(float x, float y) {
    return x - y * floor(x / y);
}

static inline float2 glMod(float2 x, float y) {
    return x - y * floor(x / y);
}

#endif /* ShaderCommon_h */
