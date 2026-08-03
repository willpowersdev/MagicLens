//
//  EdgeHighlights.metal
//  MagicLens
//
//  Ported from edgehighlights.fsh.
//

#include "ShaderCommon.h"

fragment float4 fragment_edgehighlights(VertexOut interpolated [[stage_in]],
                                        constant Uniforms &uniforms [[buffer(0)]],
                                        texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float4 texColor = sampleVideo(video, uv, uniforms);
    float2 texStep = 1.0 / uniforms.resolution;

    float4 s01 = sampleVideo(video, uv - float2(1.0, 0.0) * texStep, uniforms);
    float4 s02 = sampleVideo(video, uv + float2(1.0, 0.0) * texStep, uniforms);
    float4 s03 = sampleVideo(video, uv - float2(0.0, 1.0) * texStep, uniforms);
    float4 s04 = sampleVideo(video, uv + float2(0.0, 1.0) * texStep, uniforms);

    float4 grad1 = s02 - s01;
    float4 grad2 = s04 - s03;
    float4 avg = (grad1 + grad2) * 0.5;
    float l = length(avg);

    return float4(texColor.rgb * l * 10.0, 1.0);
}
