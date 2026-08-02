precision highp float;
varying vec2 v_TexCoord;

uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform sampler2D u_VideoFrame;

float onOff(float a, float b, float c)
{
    return step(c, sin(u_GlobalTime + a*cos(u_GlobalTime*b)));
}

vec2 screenDistort(vec2 uv)
{
    uv -= vec2(0.5,0.5);
    uv = uv*1.2*(1./1.2+2.*uv.x*uv.x*uv.y*uv.y);
    uv += vec2(.5,.5);
    return uv;
}

vec3 getVideo(vec2 uv)
{
    vec2 look = vec2(1.0 - uv.y, 1.0 - uv.x);
    float window = 1./(1.+20.*(look.y-mod(u_GlobalTime/4.,1.))*(look.y-mod(u_GlobalTime/4.,1.)));
    look.x = look.x + sin(look.y*10. + u_GlobalTime)/50.*onOff(4.,4.,.3)*(1.+cos(u_GlobalTime*80.))*window;
    float vShift = 0.4*onOff(2.,3.,.9)*(sin(u_GlobalTime)*sin(u_GlobalTime*20.) +
                                        (0.5 + 0.1*sin(u_GlobalTime*200.)*cos(u_GlobalTime)));
    look.y = mod(look.y + vShift, 1.);
    return texture2D(u_VideoFrame, look).rgb;
}

void main() {
    
    vec2 uv = gl_FragCoord.xy/u_Resolution.xy;
    uv = screenDistort(uv);
    vec3 video = getVideo(uv);
    // darken corners
    float vigAmt = 3.+.3*sin(u_GlobalTime + 5.*cos(u_GlobalTime*5.));
    float vignette = (1.-vigAmt*(uv.y-.5)*(uv.y-.5))*(1.-vigAmt*(uv.x-.5)*(uv.x-.5));
    video *= vignette;
    // scan pattern
    float scanLineThickness = 100.0;
    video *= (12.+mod(uv.y*scanLineThickness+u_GlobalTime,1.))/13.;
    
    // B&W
    //vec3 lum = vec3(0.299, 0.587, 0.114);
    //gl_FragColor = vec4( vec3(dot( video.rgb, lum)), 1.0);
    // Color
    gl_FragColor = vec4(video, 1.0);
}
