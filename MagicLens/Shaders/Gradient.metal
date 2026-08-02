//
//  Gradient.metal
//  MagicLens
//
//  What the screen shows before the camera hands over its first frame. Picks up
//  where the launch screen's flat colour leaves off.
//

#include "ShaderCommon.h"

constant float3 kGradientTop = float3(0.118, 0.227, 0.541);    // #1E3A8A, deep blue
constant float3 kGradientBottom = float3(0.078, 0.722, 0.651); // #14B8A6, teal

fragment float4 fragment_gradient(VertexOut interpolated [[stage_in]]) {

    // texCoord.y is 1 at the top of the screen and 0 at the bottom.
    float t = interpolated.texCoord.y;

    // Smoothed so the ramp doesn't band across the middle of the screen.
    return float4(mix(kGradientBottom, kGradientTop, smoothstep(0.0, 1.0, t)), 1.0);
}
