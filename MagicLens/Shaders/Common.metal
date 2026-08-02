//
//  Common.metal
//  MagicLens
//
//  The vertex stage every effect shares — a full screen quad, ported from
//  passThrough.vsh.
//

#include "ShaderCommon.h"

struct VertexIn {
    packed_float2 position;
    packed_float2 texCoord;
};

vertex VertexOut vertex_func(const device VertexIn* vertex_array [[ buffer(0) ]],
                             unsigned int vid [[ vertex_id ]]) {

    VertexIn v = vertex_array[vid];
    VertexOut outVertex;
    outVertex.computedPosition = float4(v.position, 0.0, 1.0);
    outVertex.texCoord = v.texCoord;
    return outVertex;
}
