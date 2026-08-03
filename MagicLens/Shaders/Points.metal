//
//  Points.metal
//  MagicLens
//
//  Ported from points.fsh.
//

#include "ShaderCommon.h"

constant float kAngle = 3.14 * 0.5;
constant float2 kCenter = float2(0.5);
constant float kScale = 0.25;

static float pattern(float2 uv, float2 resolution) {

    float s = sin(kAngle);
    float c = cos(kAngle);

    float aspect = resolution.x / resolution.y;

    float2 tex = uv * resolution - kCenter;
    float2 point = float2((c * tex.x - s * tex.y) * kScale,
                          (s * tex.x + c * tex.y) * (1.0 / aspect) * kScale);

    return sin(point.x) * sin(point.y) * 4.0;
}

fragment float4 fragment_points(VertexOut interpolated [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float4 color = sampleVideo(video, uv, uniforms);
    float avg = (color.r + color.g + color.b) * 0.3333;

    return float4(color.rgb * float3(avg * 6.0 - 4.0 + pattern(uv, uniforms.resolution)), 1.0);
}
