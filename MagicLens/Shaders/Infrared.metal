//
//  Infrared.metal
//  MagicLens
//
//  Ported from infrared.fsh.
//

#include "ShaderCommon.h"

static float greyScale(float3 rgb) {
    return dot(rgb, float3(0.29, 0.60, 0.11));
}

static float3 heatMap(float greyValue) {
    float3 heat;
    heat.r = smoothstep(0.5, 0.8, greyValue);
    if (greyValue >= 0.90) {
        heat.r *= (1.1 - greyValue) * 5.0;
    }
    if (greyValue > 0.7) {
        heat.g = smoothstep(1.0, 0.7, greyValue);
    } else {
        heat.g = smoothstep(0.0, 0.7, greyValue);
    }
    heat.b = smoothstep(1.0, 0.0, greyValue);
    if (greyValue <= 0.3) {
        heat.b *= greyValue / 0.3;
    }
    return heat;
}

fragment float4 fragment_infrared(VertexOut interpolated [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float greyValueA = greyScale(sampleVideo(video, uv).rgb);
    return float4(heatMap(greyValueA), 1.0);
}
