precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

const float angle = 3.14 * 0.5;
const vec2 center = vec2(0.5);
const float scale = 0.25;

float pattern(vec2 uv)
{
    float s = sin(angle);
    float c = cos(angle);
    
    float aspect = u_Resolution.x/u_Resolution.y;
    
    vec2 tex = uv*u_Resolution - center;
    vec2 point = vec2((c*tex.x - s*tex.y)*scale, (s*tex.x + c*tex.y)*(1.0/aspect)*scale);
    
    return sin(point.x) * sin(point.y) * 4.0;
}

void main()
{
    vec2 uv = v_TexCoord;
    vec4 color = texture2D(u_VideoFrame, uv);
    float avg = (color.r + color.g + color.b) * 0.3333;
    
    gl_FragColor = vec4(color.rgb * vec3(avg*6.0 - 4.0 + pattern(uv)), 1.0);
}

