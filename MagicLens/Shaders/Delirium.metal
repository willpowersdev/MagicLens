//
//  Delirium.metal
//  MagicLens
//
//  Ported from delirium.fsh.
//

#include "ShaderCommon.h"

fragment float4 fragment_delirium(VertexOut interpolated [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    float time = uniforms.globalTime;

    float drunk = sin(time * 2.0) * 0.00001;
    float unitDrunk1 = (sin(time * 1.2) + 1.0) * 0.5;
    float unitDrunk2 = (sin(time * 1.8) + 1.0) * 0.5;

    float2 normalizedCoord = glMod(uv + float2(0.0, drunk), 1.0);
    normalizedCoord.x = pow(normalizedCoord.x, mix(1.25, 0.85, unitDrunk1));
    normalizedCoord.y = pow(normalizedCoord.y, mix(0.85, 1.25, unitDrunk2));

    float2 normalizedCoord2 = glMod(uv + float2(drunk, 0.0), 1.0);
    normalizedCoord2.x = pow(normalizedCoord2.x, mix(0.95, 1.1, unitDrunk2));
    normalizedCoord2.y = pow(normalizedCoord2.y, mix(1.1, 0.95, unitDrunk1));

    float2 normalizedCoord3 = uv;

    float4 color = sampleVideo(video, normalizedCoord, uniforms);
    float4 color2 = sampleVideo(video, normalizedCoord2, uniforms);
    float4 color3 = sampleVideo(video, normalizedCoord3, uniforms);

    float4 finalColor = mix(mix(color, color2, mix(0.4, 0.6, unitDrunk1)), color3, 0.4);
    float mag = length(finalColor);

    if (mag > 1.4) {
        finalColor.rg = mix(finalColor.rg, normalizedCoord3, 0.5);
    } else if (mag < 0.4) {
        finalColor.gb = mix(finalColor.gb, normalizedCoord3, 0.5);
    }

    return finalColor;
}
