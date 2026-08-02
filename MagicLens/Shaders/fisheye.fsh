precision highp float;
varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

const float PI = 3.14159265358979323846;

float ellipse_mask(vec2 center, vec2 ab, vec2 coord){
    vec2 delta = (coord - center)*(coord - center);
    vec2 size = ab*ab;
    float d = delta.x/size.x + delta.y/size.y - 1.0;
    return d;
}

vec2 fisheye(vec2 texCoord) {
    
    vec2 uv = 2.0 * (gl_FragCoord.xy / u_Resolution.xy) - 1.0;

    float d = length(uv);
    float z = sqrt(1.0 - d * d);
    float r = atan(d, z) / PI;
    float phi = atan(uv.y, uv.x);
    
    uv = 0.5 + vec2(r*cos(phi), r*sin(phi));
    uv = 1.0 - uv.yx;
    
    return uv;
}

void main()
{
    vec2 uv = gl_FragCoord.xy / u_Resolution.xy;
    uv = 1.0 - uv.yx;
    vec4 bg = vec4(0.0);
    float mask = 0.0;
    if (length(u_TouchPoint) == 0.0) {
        mask = ellipse_mask(vec2(0.5), vec2(0.5*u_Resolution.x/u_Resolution.y, 0.5), uv);
    } else {
        mask = ellipse_mask(vec2(0.5), vec2(0.5), uv);
    }
    vec4 shape1 = vec4(texture2D(u_VideoFrame, fisheye(v_TexCoord)).rgb, 1.0 - smoothstep(-0.0, 0.0, mask));
    
    vec4 layer1 = mix(texture2D(u_VideoFrame, uv), shape1, shape1.a);
    gl_FragColor = layer1;
}
