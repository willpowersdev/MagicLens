precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;


void main()
{
    vec2 uv = v_TexCoord;
    vec4 texColor = texture2D(u_VideoFrame, uv);
    vec2 texStep = 1.0 / u_Resolution;
    vec4 s01 = texture2D(u_VideoFrame, uv-vec2(1.0, 0.0)*texStep);
    vec4 s02 = texture2D(u_VideoFrame, uv+vec2(1.0, 0.0)*texStep);
    vec4 s03 = texture2D(u_VideoFrame, uv-vec2(0.0, 1.0)*texStep);
    vec4 s04 = texture2D(u_VideoFrame, uv+vec2(0.0, 1.0)*texStep);
    
    vec4 grad1 = s02 - s01;
    vec4 grad2 = s04 - s03;
    vec4 avg = (grad1 + grad2) * 0.5;
    float l = length(avg);
    
    gl_FragColor = vec4(texColor.rgb * l * 10.0, 1.0);
}

