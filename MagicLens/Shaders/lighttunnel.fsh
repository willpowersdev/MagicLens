precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

void main() {
    
    float radius = 0.2;
    float aspect = u_Resolution.x/u_Resolution.y;
    
    vec2 uv = v_TexCoord;
    
    vec2 center = uv - vec2(0.5);
    float angle = atan(center.y, center.x);
    float delta = length(center);
    
    vec2 p = vec2(cos(angle), sin(angle)) * radius + vec2(0.5);
    
    uv = mix(uv, p, step(radius, delta));

    gl_FragColor = texture2D(u_VideoFrame, uv);
}
