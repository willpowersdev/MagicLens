//
//  Edge.metal
//  MagicLens
//
//  Ported from edge.fsh. Sobel edge detection.
//

#include "ShaderCommon.h"

static float applyKernel(float3x3 gx,
                         float3x3 gy,
                         texture2d<float> video,
                         float2 uv,
                         float2 cameraResolution) {

    float horizontal = 0.0;
    float vertical = 0.0;

    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            float2 d = float2(float(i), float(j)) / cameraResolution;
            float averagePixel = dot(sampleVideo(video, uv + d).rgb, float3(0.33333));

            horizontal += averagePixel * gx[i][j];
            vertical += averagePixel * gy[i][j];
        }
    }

    return sqrt(horizontal * horizontal + vertical * vertical);
}

fragment float4 fragment_edge(VertexOut interpolated [[stage_in]],
                              constant Uniforms &uniforms [[buffer(0)]],
                              texture2d<float> video [[texture(0)]]) {

    // GLSL mat3 constructors fill column by column, and so do Metal's — these
    // are the same three columns the original declared.
    float3x3 Gx = float3x3(float3(-1.0, 0.0, 1.0),
                           float3(-2.0, 0.0, 2.0),
                           float3(-1.0, 0.0, 1.0));

    float3x3 Gy = float3x3(float3(-1.0, -2.0, -1.0),
                           float3(0.0, 0.0, 0.0),
                           float3(1.0, 2.0, 1.0));

    float2 uv = interpolated.texCoord;

    float4 edgeColor = float4(0.0);
    float4 bgColor = float4(1.0);
    float edgeIntensity = applyKernel(Gx, Gy, video, uv, uniforms.cameraResolution);

    return mix(edgeColor, bgColor, 1.0 - edgeIntensity);
}
