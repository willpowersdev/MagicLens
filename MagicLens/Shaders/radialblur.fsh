precision highp float;
varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

void main()
{
    vec3 p = (gl_FragCoord.xyz/vec3(u_Resolution, 1.0)) - 0.5;
    p = vec3(-p.y, -p.x, p.z);
    vec3 o = texture2D(u_VideoFrame,0.5+(p.xy*=0.992)).rbb;
    for (int i = 0; i < 100; i++) {
        p.z += pow(max(0.0,0.5-length(texture2D(u_VideoFrame,0.5+(p.xy*=0.992)).rg)),2.0)*exp(-float(i)*0.08);
    }
    gl_FragColor=vec4(o*o+p.z,1.0);
}
