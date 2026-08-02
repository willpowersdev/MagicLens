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

    float3 p = float3(fragCoord / uniforms.resolution, interpolated.computedPosition.z) - 0.5;
    p = float3(-p.y, -p.x, p.z);

    // The original folded `p.xy *= 0.992` into the sampling expression; spelled
    // out here because compound assignment to a swizzle isn't an expression in
    // Metal.
    p.xy *= 0.992;
    float3 o = sampleVideo(video, 0.5 + p.xy).rbb;

    for (int i = 0; i < 100; i++) {
        p.xy *= 0.992;
        p.z += pow(max(0.0, 0.5 - length(sampleVideo(video, 0.5 + p.xy).rg)), 2.0) *
               exp(-float(i) * 0.08);
    }

    return float4(o * o + p.z, 1.0);
}
