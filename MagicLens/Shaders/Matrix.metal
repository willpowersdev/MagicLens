//
//  Matrix.metal
//  MagicLens
//
//  Ported from matrix.fsh.
//

#include "ShaderCommon.h"

#define RAIN_SPEED 1.75 // Speed of rain droplets
#define DROP_SIZE  2.0  // Higher value lowers the size of individual droplets

static float rand(float2 co) {
    return fract(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

static float rchar(float2 outer, float2 inner, float globalTime) {

    float2 seed = floor(inner * 4.0) + outer.y;
    if (rand(float2(outer.y, 23.0)) > 0.98) {
        seed += floor((globalTime + rand(float2(outer.y, 49.0))) * 3.0);
    }

    return float(rand(seed) > 0.5);
}

fragment float4 fragment_matrix(VertexOut interpolated [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                texture2d<float> video [[texture(0)]]) {

    float2 fragCoord = bottomLeftFragCoord(interpolated.computedPosition, uniforms.resolution);

    float2 position = fragCoord / uniforms.resolution;
    // Was float2(1.0 - position.y, 1.0 - position.x) to stand the sensor's
    // landscape frame upright; the capture connection handles that now.
    // The original also scaled uv.y by an expression over cameraResolution that
    // always evaluated to exactly 1.0; see Reflect.metal.
    float2 uv = position;

    float globalTime = uniforms.globalTime * RAIN_SPEED;

    float scaledown = DROP_SIZE;
    float rx = fragCoord.x / (40.0 * scaledown);
    float mx = 40.0 * scaledown * fract(position.x * 30.0 * scaledown);
    float4 result;

    if (mx > 12.0 * scaledown) {
        result = float4(0.0);
    } else {
        float x = floor(rx);
        float r1x = floor(fragCoord.x / (15.0));

        float ry = position.y * 600.0 + rand(float2(x, x * 3.0)) * 100000.0 +
                   globalTime * rand(float2(r1x, 23.0)) * 120.0;
        float my = glMod(ry, 15.0);
        if (my > 12.0 * scaledown) {
            result = float4(0.0);
        } else {

            float y = floor(ry / 15.0);

            float b = rchar(float2(rx, floor((ry) / 15.0)), float2(mx, my) / 12.0, globalTime);
            float col = max(glMod(-y, 24.0) - 4.0, 0.0) / 20.0;
            float3 c = col < 0.8 ? float3(0.0, col / 0.8, 0.0)
                                 : mix(float3(0.0, 1.0, 0.0), float3(1.0), (col - 0.8) / 0.2);

            result = float4(c * b, 1.0);
        }
    }

    position.x += 0.05;

    scaledown = DROP_SIZE;
    rx = fragCoord.x / (40.0 * scaledown);
    mx = 40.0 * scaledown * fract(position.x * 30.0 * scaledown);

    if (mx > 12.0 * scaledown) {
        result += float4(0.0);
    } else {
        float x = floor(rx);
        float r1x = floor(fragCoord.x / (12.0));

        float ry = position.y * 700.0 + rand(float2(x, x * 3.0)) * 100000.0 +
                   globalTime * rand(float2(r1x, 23.0)) * 120.0;
        float my = glMod(ry, 15.0);
        if (my > 12.0 * scaledown) {
            result += float4(0.0);
        } else {

            float y = floor(ry / 15.0);

            float b = rchar(float2(rx, floor((ry) / 15.0)), float2(mx, my) / 12.0, globalTime);
            float col = max(glMod(-y, 24.0) - 4.0, 0.0) / 20.0;
            float3 c = col < 0.8 ? float3(0.0, col / 0.8, 0.0)
                                 : mix(float3(0.0, 1.0, 0.0), float3(1.0), (col - 0.8) / 0.2);

            result += float4(c * b, 1.0);
        }
    }

    result = result * length(sampleVideo(video, uv, uniforms).rgb) +
             0.22 * float4(0.0, sampleVideo(video, uv, uniforms).g, 0.0, 1.0);
    if (result.b < 0.5) {
        result.b = result.g * 0.5;
    }
    return result;
}
