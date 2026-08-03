//
//  LightTunnel.metal
//  MagicLens
//
//  Ported from lighttunnel.fsh.
//

#include "ShaderCommon.h"

fragment float4 fragment_lighttunnel(VertexOut interpolated [[stage_in]],
                                     constant Uniforms &uniforms [[buffer(0)]],
                                     texture2d<float> video [[texture(0)]]) {

    float radius = 0.2;

    float2 uv = interpolated.texCoord;

    float2 center = uv - float2(0.5);
    float angle = atan2(center.y, center.x);
    float delta = length(center);

    float2 p = float2(cos(angle), sin(angle)) * radius + float2(0.5);

    uv = mix(uv, p, step(radius, delta));

    return sampleVideo(video, uv, uniforms);
}
