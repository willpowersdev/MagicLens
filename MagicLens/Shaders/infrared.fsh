precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

float greyScale(vec3 rgb) {
   	return dot(rgb, vec3(0.29, 0.60, 0.11));
}

vec3 heatMap(float greyValue) {
    vec3 heat;
    heat.r = smoothstep(0.5, 0.8, greyValue);
    if(greyValue >= 0.90) {
        heat.r *= (1.1 - greyValue) * 5.0;
    }
    if(greyValue > 0.7) {
        heat.g = smoothstep(1.0, 0.7, greyValue);
    } else {
        heat.g = smoothstep(0.0, 0.7, greyValue);
    }
    heat.b = smoothstep(1.0, 0.0, greyValue);
    if(greyValue <= 0.3) {
        heat.b *= greyValue / 0.3;
    }
    return heat;
}

void main() {
    vec2 uv = v_TexCoord;
    float greyValueA = greyScale(texture2D(u_VideoFrame, uv).rgb);
    vec3 rgbOut = heatMap(greyValueA);
    gl_FragColor = vec4(rgbOut, 1.0);
}
