//
//  AntiFisheye.metal
//  MagicLens
//
//  Ported from antifisheye.fsh. Not currently listed in the glitch picker.
//

#include "ShaderCommon.h"

fragment float4 fragment_antifisheye(VertexOut interpolated [[stage_in]],
                                     constant Uniforms &uniforms [[buffer(0)]],
                                     texture2d<float> video [[texture(0)]]) {

    float2 fragCoord = bottomLeftFragCoord(interpolated.computedPosition, uniforms.resolution);

    //normalized coords with some cheat
    float2 p = fragCoord / uniforms.resolution.x;

    //screen proportion
    float prop = uniforms.resolution.x / uniforms.resolution.y;
    //center coords
    float2 m = float2(0.5, 0.5 / prop);
    //vector from center to current fragment
    float2 d = p - m;
    // distance of pixel from center
    float r = sqrt(dot(d, d));
    //amount of effect
    float power = (2.0 * 3.141592 / (2.0 * sqrt(dot(m, m)))) *
                  (uniforms.touchPoint.x / uniforms.resolution.x - 0.5);
    //radius of 1:1 effect
    float bind;
    if (power > 0.0) {
        bind = sqrt(dot(m, m)); //stick to corners
    } else {
        if (prop < 1.0) {
            bind = m.x;
        } else {
            bind = m.y;
        }
    } //stick to borders

    //Weird formulas
    float2 uv;
    if (power > 0.0) { //fisheye
        uv = m + normalize(d) * tan(r * power) * bind / tan(bind * power);
    } else if (power < 0.0) { //antifisheye
        uv = m + normalize(d) * atan(r * -power * 10.0) * bind / atan(-power * bind * 10.0);
    } else {
        uv = p; //no effect for power = 1.0
    }

    //Second part of cheat
    //for round effect, not elliptical
    float3 col = sampleVideo(video, float2(uv.x, -uv.y * prop), uniforms).rgb;

    return float4(col, 1.0);
}
