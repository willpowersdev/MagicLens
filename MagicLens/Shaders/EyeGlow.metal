//
//  EyeGlow.metal
//  MagicLens
//
//  The eye glow's own passes. Everything here works in HDR — brightness above
//  1 is the point, since that is what bloom picks up — so the intermediate
//  textures are rgba16Float rather than the usual 8-bit.
//

#include "ShaderCommon.h"

struct EyeGlowVertex {
    packed_float2 position;   // clip space
    packed_float2 localUV;    // 0-1 within the eye's own bounding box
};

struct EyeGlowVertexOut {
    float4 position [[position]];
    float2 localUV;
};

struct EyeGlowFragmentUniforms {
    float3 glowColor;
    float intensity;
    float openness;
    float confidence;
};

vertex EyeGlowVertexOut eyeGlowVertex(uint vertexID [[vertex_id]],
                                      const device EyeGlowVertex *vertices [[buffer(0)]]) {

    EyeGlowVertex v = vertices[vertexID];

    EyeGlowVertexOut out;
    out.position = float4(v.position, 0.0, 1.0);
    out.localUV = v.localUV;
    return out;
}

/// Fills one eye's contour with an emissive core.
///
/// Shaped from the local uv rather than the contour itself, so the brightness
/// falls off towards the eyelids instead of ending at a hard polygon edge. The
/// vertical squash fits the ellipse an eye actually is.
fragment float4 eyeGlowFragment(EyeGlowVertexOut in [[stage_in]],
                                constant EyeGlowFragmentUniforms &uniforms [[buffer(0)]]) {

    float2 p = in.localUV * 2.0 - 1.0;
    float radial = length(float2(p.x, p.y * 1.8));

    float hotCore = 1.0 - smoothstep(0.10, 0.58, radial);
    float interior = 1.0 - smoothstep(0.35, 1.00, radial);

    // A blink scales the emission rather than switching it off, so the glow
    // dims through the blink instead of popping.
    float visibility = saturate(uniforms.openness) * saturate(uniforms.confidence);

    float brightness = (hotCore * uniforms.intensity
                        + interior * uniforms.intensity * 0.45) * visibility;

    float alpha = max(hotCore, interior * 0.55) * visibility;

    return float4(uniforms.glowColor * brightness, alpha);
}

// MARK: - Trail

struct EyeTrailUniforms {
    float decay;
    float currentContribution;
    float maximumBrightness;
};

/// Advances the persistent trail by one frame.
///
///     new = previous × decay + current × contribution
///
/// `decay` is computed on the CPU from elapsed time, so the trail lasts the
/// same number of *seconds* regardless of frame rate. Reads and writes are
/// separate textures — a ping-pong pair — because a compute kernel cannot
/// safely read the texture it is writing.
kernel void updateEyeTrail(texture2d<half, access::read> previousTrail [[texture(0)]],
                           texture2d<half, access::sample> currentGlow [[texture(1)]],
                           texture2d<half, access::write> outputTrail [[texture(2)]],
                           constant EyeTrailUniforms &uniforms [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= outputTrail.get_width() || gid.y >= outputTrail.get_height()) {
        return;
    }

    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_zero,
                                    filter::linear);

    float2 size = float2(outputTrail.get_width(), outputTrail.get_height());
    float2 uv = (float2(gid) + 0.5) / size;

    half4 previous = previousTrail.read(gid);
    half4 current = currentGlow.sample(linearSampler, uv);

    half4 result = previous * half(uniforms.decay)
                 + current * half(uniforms.currentContribution);

    // The feedback loop compounds without a ceiling, and the screen washes out
    // to white within a few seconds.
    result.rgb = min(result.rgb, half3(uniforms.maximumBrightness));
    result.a = min(result.a, 1.0h);

    outputTrail.write(result, gid);
}

struct DirectionalTrailUniforms {
    float2 direction;
    float trailLength;
};

/// Smears the trail backwards along the head's motion.
///
/// The persistent trail alone leaves a row of eye-shaped stamps when movement
/// outruns the frame rate; stretching each sample along the direction of travel
/// joins them into a streak.
kernel void directionalTrailBlur(texture2d<half, access::sample> source [[texture(0)]],
                                 texture2d<half, access::write> destination [[texture(1)]],
                                 constant DirectionalTrailUniforms &uniforms [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }

    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_zero,
                                    filter::linear);

    float2 size = float2(destination.get_width(), destination.get_height());
    float2 uv = (float2(gid) + 0.5) / size;

    constexpr int sampleCount = 12;

    half4 total = half4(0.0h);
    float totalWeight = 0.0;

    for (int i = 0; i < sampleCount; ++i) {
        float t = float(i) / float(sampleCount - 1);
        float weight = exp(-3.0 * t);

        float2 sampleUV = uv - uniforms.direction * uniforms.trailLength * t;

        total += source.sample(linearSampler, sampleUV) * half(weight);
        totalWeight += weight;
    }

    destination.write(total / half(max(totalWeight, 0.0001)), gid);
}

// MARK: - Composite

struct EyeCompositeUniforms {
    float coreContribution;
    float bloomContribution;
    float trailContribution;
    /// Weights for the three bloom scales.
    float3 bloomWeights;
};

/// Lays the glow over the camera frame.
///
/// Bloom and trail go on as a screen blend, which brightens without clipping
/// the picture underneath, and the sharp core is added on top so the eye itself
/// stays hot. The reinhard step at the end is the only tone map in this path —
/// the rest of the app writes straight to an 8-bit drawable and doesn't
/// tone map, so this is not doubling up.
/// Buffers 1 and 2 and texture 1 are the mouth's, bound for every effect after
/// this one's are — see `Renderer.bindEyeGlow`. Hence the gap.
fragment float4 fragment_eyeglow(VertexOut interpolated [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 constant EyeCompositeUniforms &composite [[buffer(3)]],
                                 texture2d<float> video [[texture(0)]],
                                 texture2d<float> eyeCore [[texture(2)]],
                                 texture2d<float> bloomSmall [[texture(3)]],
                                 texture2d<float> bloomMedium [[texture(4)]],
                                 texture2d<float> bloomLarge [[texture(5)]],
                                 texture2d<float> trail [[texture(6)]]) {

    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);

    float2 uv = interpolated.texCoord;

    // The camera goes through the shared path, so orientation, mirroring and
    // aspect are handled once for every effect. The glow textures are already
    // in view space and are sampled directly.
    float3 camera = sampleVideo(video, uv, uniforms).rgb;

    // These were rendered with the screen's y convention, hence the flip.
    float2 glowUV = float2(uv.x, 1.0 - uv.y);

    float3 core = eyeCore.sample(linearSampler, glowUV).rgb;

    float3 bloom = bloomSmall.sample(linearSampler, glowUV).rgb * composite.bloomWeights.x
                 + bloomMedium.sample(linearSampler, glowUV).rgb * composite.bloomWeights.y
                 + bloomLarge.sample(linearSampler, glowUV).rgb * composite.bloomWeights.z;

    float3 trailColour = trail.sample(linearSampler, glowUV).rgb;

    float3 soft = bloom * composite.bloomContribution
                + trailColour * composite.trailContribution;

    float3 screened = 1.0 - (1.0 - camera) * (1.0 - saturate(soft));

    float3 result = screened + core * composite.coreContribution;

    return float4(result / (1.0 + result), 1.0);
}
