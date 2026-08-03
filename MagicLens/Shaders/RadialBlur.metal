//
//  RadialBlur.metal
//  MagicLens
//
//  Ported from radialblur.fsh.
//

#include "ShaderCommon.h"

fragment float4 fragment_radialblur(VertexOut interpolated [[stage_in]],
                                    constant Uniforms &uniforms [[buffer(0)]],
                                    texture2d<float> video [[texture(0)]]) {

    float2 fragCoord = bottomLeftFragCoord(interpolated.computedPosition, uniforms.resolution);

    // Centred on the screen, so scaling p walks the samples toward the middle.
    // The original followed this with `p = vec3(-p.y, -p.x, p.z)` — a transpose
    // about the centre that stood the sensor's landscape frame upright, the same
    // job the other effects did with `1.0 - uv.yx`. sampleVideo handles it now.
    float3 p = float3(fragCoord / uniforms.resolution, interpolated.computedPosition.z) - 0.5;

    // The original folded `p.xy *= 0.992` into the sampling expression; spelled
    // out here because compound assignment to a swizzle isn't an expression in
    // Metal.
    p.xy *= 0.992;
    float3 o = sampleVideo(video, 0.5 + p.xy, uniforms).rbb;

    for (int i = 0; i < 100; i++) {
        p.xy *= 0.992;
        p.z += pow(max(0.0, 0.5 - length(sampleVideo(video, 0.5 + p.xy, uniforms).rg)), 2.0) *
               exp(-float(i) * 0.08);
    }

    return float4(o * o + p.z, 1.0);
}
