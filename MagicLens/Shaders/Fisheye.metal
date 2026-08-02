//
//  Fisheye.metal
//  MagicLens
//
//  Created by Darkstar on 4/30/21.
//  Ported from fisheye.fsh.
//

#include "ShaderCommon.h"

constant float PI = 3.14159265358979323846;

static float ellipse_mask(float2 center, float2 ab, float2 coord) {
    float2 delta = (coord - center) * (coord - center);
    float2 size = ab * ab;
    return delta.x / size.x + delta.y / size.y - 1.0;
}

static float2 fisheye(float2 fragCoord, float2 resolution) {

    float2 uv = 2.0 * (fragCoord / resolution) - 1.0;

    float d = length(uv);
    float z = sqrt(1.0 - d * d);
    float r = atan2(d, z) / PI;
    float phi = atan2(uv.y, uv.x);

    // The original followed this with `uv = 1.0 - uv.yx`, which rotated the
    // sensor's landscape frame upright. The capture connection does that now.
    uv = 0.5 + float2(r * cos(phi), r * sin(phi));

    return uv;
}

fragment float4 fragment_fisheye(VertexOut interpolated [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 texture2d<float> video [[texture(0)]]) {

    float2 fragCoord = bottomLeftFragCoord(interpolated.computedPosition, uniforms.resolution);

    float2 uv = fragCoord / uniforms.resolution;

    float mask = 0.0;
    if (length(uniforms.touchPoint) == 0.0) {
        mask = ellipse_mask(float2(0.5),
                            float2(0.5 * uniforms.resolution.x / uniforms.resolution.y, 0.5),
                            uv);
    } else {
        mask = ellipse_mask(float2(0.5), float2(0.5), uv);
    }

    // The original wrote smoothstep(-0.0, 0.0, mask). Equal edges are undefined
    // in both languages and produce NaN under Metal, so use the step this
    // degenerates to.
    float4 shape1 = float4(sampleVideo(video, fisheye(fragCoord, uniforms.resolution)).rgb,
                           1.0 - step(0.0, mask));

    return mix(sampleVideo(video, uv), shape1, shape1.a);
}
