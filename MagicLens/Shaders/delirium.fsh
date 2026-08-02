precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

void main() {
    vec2 uv = v_TexCoord;
    
    float drunk = sin(u_GlobalTime*2.0)*0.00001;
    float unitDrunk1 = (sin(u_GlobalTime*1.2)+1.0)*0.5;
    float unitDrunk2 = (sin(u_GlobalTime*1.8)+1.0)*0.5;
    
    vec2 normalizedCoord = mod(uv + vec2(0, drunk), 1.0);
    normalizedCoord.x = pow(normalizedCoord.x, mix(1.25, 0.85, unitDrunk1));
    normalizedCoord.y = pow(normalizedCoord.y, mix(0.85, 1.25, unitDrunk2));
    
    vec2 normalizedCoord2 = mod(uv + vec2(drunk, 0), 1.0);
    normalizedCoord2.x = pow(normalizedCoord2.x, mix(0.95, 1.1, unitDrunk2));
    normalizedCoord2.y = pow(normalizedCoord2.y, mix(1.1, 0.95, unitDrunk1));
    
    vec2 normalizedCoord3 = uv;
    
    vec4 color = texture2D(u_VideoFrame, normalizedCoord);
    vec4 color2 = texture2D(u_VideoFrame, normalizedCoord2);
    vec4 color3 = texture2D(u_VideoFrame, normalizedCoord3);
    
    //color.r = sqrt(color2.r);
    //color2.r = sqrt(color2.r);
    
    vec4 finalColor = mix( mix(color, color2, mix(0.4, 0.6, unitDrunk1)), color3, 0.4);
    float mag = length(finalColor);
    
    if (mag > 1.4)
        finalColor.rg = mix(finalColor.rg, normalizedCoord3, 0.5);
    else if (mag < 0.4)
        finalColor.gb = mix(finalColor.gb, normalizedCoord3, 0.5);
    
    gl_FragColor = finalColor;
}
