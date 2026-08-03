//
//  AntiFisheye.metal
//  MagicLens
//
//  Ported from antifisheye.fsh.
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
    //
    // The original divided the touch point by resolution.x, because the shader
    // came from a demo whose uniform was in pixels. Ours is already normalised
    // 0-1, so that term collapsed to about 0.0004 and power sat near -0.5 no
    // matter where the screen was touched. Using it directly restores the sweep
    // the shader was written for: fisheye on one side, flat in the middle,
    // anti-fisheye on the other.
    float power = (2.0 * 3.141592 / (2.0 * sqrt(dot(m, m)))) *
                  (uniforms.touchPoint.x - 0.5);
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
