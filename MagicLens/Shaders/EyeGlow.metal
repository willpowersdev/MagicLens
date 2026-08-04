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

    // An almond rather than an ellipse.
    //
    // The local box is the eye's own bounding box, so dividing the vertical
    // distance by a profile that closes towards the corners gives a shape that
    // reaches the lids at the middle of the eye and tapers to points at the
    // inner and outer corners — which is what an eye is. A flat vertical
    // squash instead left a horizontal band sitting inside the opening, filling
    // barely half its height.
    float taper = max(1.0 - p.x * p.x * 0.85, 0.15);
    float radial = length(float2(p.x, p.y / taper));

    // Radial is now 1 at the almond's edge, so these are read against the eye
    // opening itself: hot across most of it, falling away at the lids.
    float hotCore = 1.0 - smoothstep(0.10, 0.90, radial);
    float interior = 1.0 - smoothstep(0.60, 1.30, radial);

    // A blink scales the emission rather than switching it off, so the glow
    // dims through the blink instead of popping.
    float visibility = saturate(uniforms.openness) * saturate(uniforms.confidence);

    float brightness = (hotCore * uniforms.intensity
                        + interior * uniforms.intensity * 0.45) * visibility;

    // Anything this bright reads as white at its centre and keeps its colour
    // only where it falls off — which is what makes a glow look like a light
    // source rather than a coloured shape. Squared, so the whitening stays in
    // the middle instead of washing out the whole eye.
    float3 tint = mix(uniforms.glowColor, float3(1.0), hotCore * hotCore);

    float alpha = max(hotCore, interior * 0.55) * visibility;

    return float4(tint * brightness, alpha);
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
    /// Weights for the three bloom scales. A quality level that drops a scale
    /// zeroes its weight, so the empty texture bound in its place contributes
    /// nothing either way.
    float3 bloomWeights;

    /// 0 composites normally; 1, 2 and 3 show emission, bloom and trail full
    /// screen instead. Mirrors `EyeGlowDebugTexture`.
    uint debugTexture;
};

/// The tracked geometry, for the debug overlay only.
struct EyeGlowDebugUniforms {
    float2 leftCenter;
    float2 rightCenter;
    float2 leftVelocity;
    float2 rightVelocity;
    uint leftCount;
    uint rightCount;
    uint showsContours;
    uint showsCenters;
    uint showsVelocity;
    /// View pixels per uv, so the marks stay the same thickness on screen
    /// rather than stretching with the aspect.
    float2 pixelsPerUV;
};

/// Distance in uv from `point` to the segment `a`–`b`.
static float distanceToSegment(float2 point, float2 a, float2 b, float2 scale) {
    float2 pa = (point - a) * scale;
    float2 ba = (b - a) * scale;

    float t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * t);
}

/// Draws the tracked geometry over the finished frame.
///
/// Flat and unblended on purpose: this is for checking that the contours,
/// centres and velocities land where the glow is being drawn, so it has to be
/// legible rather than pretty.
static float3 debugOverlay(float3 base,
                           float2 uv,
                           constant EyeGlowDebugUniforms &debug,
                           const device float2 *contours) {

    float3 result = base;
    float2 scale = debug.pixelsPerUV;

    if (debug.showsContours != 0) {
        uint total = debug.leftCount + debug.rightCount;

        for (uint eye = 0; eye < 2; ++eye) {
            uint start = eye == 0 ? 0 : debug.leftCount;
            uint count = eye == 0 ? debug.leftCount : debug.rightCount;

            if (count < 2 || start + count > total) {
                continue;
            }

            for (uint i = 0; i < count; ++i) {
                float2 a = contours[start + i];
                float2 b = contours[start + (i + 1) % count];

                if (distanceToSegment(uv, a, b, scale) < 1.5) {
                    result = float3(0.2, 1.0, 0.3);
                }
            }
        }
    }

    if (debug.showsVelocity != 0) {
        // Scaled up, or a plausible head movement is a few pixels long and
        // impossible to judge the direction of.
        float2 tips[2] = { debug.leftCenter + debug.leftVelocity * 0.08,
                           debug.rightCenter + debug.rightVelocity * 0.08 };
        float2 origins[2] = { debug.leftCenter, debug.rightCenter };

        for (uint i = 0; i < 2; ++i) {
            if (distanceToSegment(uv, origins[i], tips[i], scale) < 1.5) {
                result = float3(1.0, 0.85, 0.1);
            }
        }
    }

    if (debug.showsCenters != 0) {
        float2 centers[2] = { debug.leftCenter, debug.rightCenter };

        for (uint i = 0; i < 2; ++i) {
            float2 offset = abs(uv - centers[i]) * scale;

            bool onCross = (offset.x < 6.0 && offset.y < 1.5)
                        || (offset.y < 6.0 && offset.x < 1.5);

            if (onCross) {
                result = float3(1.0, 0.2, 0.8);
            }
        }
    }

    return result;
}

/// Lays the glow over the camera frame.
///
/// The glow is HDR and runs well above 1, so it has to be tone mapped. The
/// camera does not: it arrives display-referred, with nothing to compress.
/// Mapping their sum — which this did — pulls every pixel down whether or not
/// there is any glow near it, so a frame with no eyes in it came out at half
/// brightness and could never be lighter than mid grey. It read as haze rather
/// than as a bug, and it was quietly answered by turning the intensity up.
///
/// So only the added light is mapped, and the result is screened over the
/// picture. Screen only ever brightens, so the camera is untouched where the
/// glow is dark and blown to white where it is hot.
/// Buffers 1 and 2 and texture 1 are the mouth's, bound for every effect after
/// this one's are — see `Renderer.bindEyeGlow`. Hence the gap.
fragment float4 fragment_eyeglow(VertexOut interpolated [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 constant EyeCompositeUniforms &composite [[buffer(3)]],
                                 constant EyeGlowDebugUniforms &debug [[buffer(4)]],
                                 const device float2 *contours [[buffer(5)]],
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

    // Straight out, tone mapped but uncomposited. Showing an intermediate over
    // the camera would hide exactly the mistakes it is meant to expose — an
    // upside-down or mirrored texture reads as plausible against a face.
    if (composite.debugTexture != 0u) {
        float3 raw = composite.debugTexture == 1u
                   ? eyeCore.sample(linearSampler, glowUV).rgb
                   : (composite.debugTexture == 2u
                      ? bloomSmall.sample(linearSampler, glowUV).rgb
                      : trail.sample(linearSampler, glowUV).rgb);

        float3 shown = raw / (1.0 + raw);
        return float4(debugOverlay(shown, uv, debug, contours), 1.0);
    }

    float3 core = eyeCore.sample(linearSampler, glowUV).rgb;

    float3 bloom = bloomSmall.sample(linearSampler, glowUV).rgb * composite.bloomWeights.x
                 + bloomMedium.sample(linearSampler, glowUV).rgb * composite.bloomWeights.y
                 + bloomLarge.sample(linearSampler, glowUV).rgb * composite.bloomWeights.z;

    float3 trailColour = trail.sample(linearSampler, glowUV).rgb;

    // Everything the effect adds, still in HDR: the soft light around the eye
    // and the hot core inside it.
    float3 glow = bloom * composite.bloomContribution
                + trailColour * composite.trailContribution
                + core * composite.coreContribution;

    // Mapped on its own, so the camera keeps its own range.
    float3 mapped = glow / (1.0 + glow);

    float3 result = 1.0 - (1.0 - camera) * (1.0 - saturate(mapped));

    return float4(debugOverlay(result, uv, debug, contours), 1.0);
}
