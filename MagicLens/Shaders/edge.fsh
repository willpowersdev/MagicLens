precision highp float;

varying vec2 v_TexCoord;

uniform vec2 u_TouchPoint;
uniform float u_GlobalTime;
uniform vec2 u_Resolution;
uniform vec2 u_CameraResolution;
uniform sampler2D u_VideoFrame;

// Sobel Edge Detection
mat3 Gx = mat3(-1.0, 0.0, 1.0,
               -2.0, 0.0, 2.0,
               -1.0, 0.0, 1.0);
 
mat3 Gy = mat3(-1.0, -2.0, -1.0,
               0.0, 0.0, 0.0,
               1.0, 2.0, 1.0);
 

float applyKernel(mat3 gx, mat3 gy, sampler2D sampler, vec2 uv)
{
    float final = 0.0;
    float horizontal = 0.0;
    float vertical = 0.0;

    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            vec2 d = vec2(float(i), float(j)) / u_CameraResolution.xy;
            float averagePixel = dot(texture2D(sampler, uv+d).rgb, vec3(0.33333));

            horizontal += averagePixel * gx[i][j];
            vertical += averagePixel * gy[i][j];
        }
    }
 
    final = sqrt(horizontal * horizontal + vertical * vertical);
    return final;
}
 
void main()
{
    vec2 uv = v_TexCoord;
    
    vec4 edgeColor = vec4(0.0);
    vec4 bgColor = vec4(1.0);
    float edgeIntensity = applyKernel(Gx, Gy, u_VideoFrame, uv);

    vec4 outputColor = mix(edgeColor,
                         bgColor,
                         1.0-edgeIntensity);

    gl_FragColor = outputColor;
}


// 3×3 edge filter kernel
/*
void main()
{
    vec2 uv = v_TexCoord;
    vec4 lum = vec4(0.30, 0.59, 0.11, 1.0);
 
    // TOP ROW
    float s11 = dot(texture2D(u_VideoFrame, uv + vec2(-1.0 / u_Resolution.x, -1.0 / u_Resolution.y)), lum);   // LEFT
    float s12 = dot(texture2D(u_VideoFrame, uv + vec2(0.0, -1.0 / u_Resolution.y)), lum);             // MIDDLE
    float s13 = dot(texture2D(u_VideoFrame, uv + vec2(1.0 / u_Resolution.x, -1.0 / u_Resolution.y)), lum);    // RIGHT
    
    // MIDDLE ROW
    float s21 = dot(texture2D(u_VideoFrame, uv + vec2(-1.0 / u_Resolution.x, 0.0)), lum);                // LEFT
    // Omit center
    float s23 = dot(texture2D(u_VideoFrame, uv + vec2(-1.0 / u_Resolution.x, 0.0)), lum);                // RIGHT
    
    // LAST ROW
    float s31 = dot(texture2D(u_VideoFrame, uv + vec2(-1.0 / u_Resolution.x, 1.0 / u_Resolution.y)), lum);    // LEFT
    float s32 = dot(texture2D(u_VideoFrame, uv + vec2(0.0, 1.0 / u_Resolution.y)), lum);              // MIDDLE
    float s33 = dot(texture2D(u_VideoFrame, uv + vec2(1.0 / u_Resolution.x, 1.0 / u_Resolution.y)), lum); // RIGHT
    
    float t1 = s13 + s33 + (2.0 * s23) - s11 - (2.0 * s21) - s31;
    float t2 = s31 + (2.0 * s32) + s33 - s11 - (2.0 * s12) - s13;
    
    vec4 col;
    
    if (((t1 * t1) + (t2 * t2)) > 0.05) {
        col = vec4(0.0,0.0,0.0,1.0);
    } else {
        col = vec4(1.0);
    }  
    
    gl_FragColor = col;
}
*/
