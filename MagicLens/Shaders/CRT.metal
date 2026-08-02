//
//  CRT.metal
//  MagicLens
//
//  Ported from crt.fsh.
//

#include "ShaderCommon.h"

static float onOff(float a, float b, float c, float globalTime) {
    return step(c, sin(globalTime + a * cos(globalTime * b)));
}

static float2 screenDistort(float2 uv) {
    uv -= float2(0.5, 0.5);
    uv = uv * 1.2 * (1. / 1.2 + 2. * uv.x * uv.x * uv.y * uv.y);
    uv += float2(.5, .5);
    return uv;
}

static float3 getVideo(float2 uv, texture2d<float> video, float globalTime) {
    // Was float2(1.0 - uv.y, 1.0 - uv.x) to stand the sensor's landscape frame
    // upright; the capture connection handles that now.
    float2 look = uv;
    float window = 1. / (1. + 20. * (look.y - glMod(globalTime / 4., 1.)) *
                                   (look.y - glMod(globalTime / 4., 1.)));
    look.x = look.x + sin(look.y * 10. + globalTime) / 50. *
                      onOff(4., 4., .3, globalTime) * (1. + cos(globalTime * 80.)) * window;
    float vShift = 0.4 * onOff(2., 3., .9, globalTime) *
                   (sin(globalTime) * sin(globalTime * 20.) +
                    (0.5 + 0.1 * sin(globalTime * 200.) * cos(globalTime)));
    look.y = glMod(look.y + vShift, 1.);
    return sampleVideo(video, look).rgb;
}

fragment float4 fragment_crt(VertexOut interpolated [[stage_in]],
                             constant Uniforms &uniforms [[buffer(0)]],
                             texture2d<float> video [[texture(0)]]) {

    float globalTime = uniforms.globalTime;
    float2 fragCoord = bottomLeftFragCoord(interpolated.computedPosition, uniforms.resolution);

    float2 uv = fragCoord / uniforms.resolution;
    uv = screenDistort(uv);
    float3 videoColor = getVideo(uv, video, globalTime);

    // darken corners
    float vigAmt = 3. + .3 * sin(globalTime + 5. * cos(globalTime * 5.));
    float vignette = (1. - vigAmt * (uv.y - .5) * (uv.y - .5)) *
                     (1. - vigAmt * (uv.x - .5) * (uv.x - .5));
    videoColor *= vignette;

    // scan pattern
    float scanLineThickness = 100.0;
    videoColor *= (12. + glMod(uv.y * scanLineThickness + globalTime, 1.)) / 13.;

    return float4(videoColor, 1.0);
}
