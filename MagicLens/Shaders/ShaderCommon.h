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

/// Mirrors `Uniforms` in ViewController.swift. Keep the two in sync.
struct Uniforms {
    float2 resolution;
    float2 cameraResolution;
    float2 touchPoint;
    float globalTime;
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

/// GL samples textures with (0,0) at the bottom left, Metal with (0,0) at the
/// top left. Flipping here rather than in the vertex data means every ported
/// shader's uv arithmetic stays exactly as it was written.
static inline float4 sampleVideo(texture2d<float> video, float2 uv) {
    constexpr sampler videoSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);
    return video.sample(videoSampler, float2(uv.x, 1.0 - uv.y));
}

/// GLSL's `mod` and Metal's `fmod` disagree on negative operands.
static inline float glMod(float x, float y) {
    return x - y * floor(x / y);
}

static inline float2 glMod(float2 x, float y) {
    return x - y * floor(x / y);
}

#endif /* ShaderCommon_h */
