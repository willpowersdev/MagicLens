//
//  Reflect.metal
//  MagicLens
//
//  Ported from reflect.fsh.
//

#include "ShaderCommon.h"

fragment float4 fragment_reflect(VertexOut interpolated [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 texture2d<float> video [[texture(0)]]) {

    float2 uv = interpolated.texCoord;
    // touchPoint arrives in view coordinates (y growing downward); texCoord's y
    // grows upward. The original also swapped x and y to undo the sensor's
    // rotation, which the capture connection now handles.
    float2 p = clamp(float2(uniforms.touchPoint.x, 1.0 - uniforms.touchPoint.y), 0.5, 1.0);

    // allow masking of certain parts of the frame, so that only those specific areas are mirrored

    // mirror across the y axis
    // shortened code for GPU optimization (conditionals are slower, as multiple fragments are processed at once)
    uv.x = ((1.0 - max(sign(p.x - uv.x), 0.0)) * (p.x - (uv.x - p.x))) + (max(sign(p.x - uv.x), 0.0) * uv.x);

    // mirror across the x axis
    //uv.y = (1.0 - max(sign(p.y - uv.y), 0.0))*(p.y-(uv.y-p.y)) + max(sign(p.y - uv.y), 0.0) * uv.y;

    // The original scaled uv.y by
    // (resolution.x * cameraResolution.x) / (cameraResolution.y * resolution.y),
    // but cameraResolution was fed the screen size with its axes swapped, so
    // that expression was always exactly 1.0. Dropped rather than kept as a
    // no-op multiply.

    return sampleVideo(video, uv);
}
