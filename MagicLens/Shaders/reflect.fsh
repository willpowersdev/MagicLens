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
    vec2 p = clamp(vec2(u_TouchPoint.y, 1.0 - u_TouchPoint.x), 0.5, 1.0);

    // allow masking of certain parts of the frame, so that only those specific areas are mirrored
    
    // mirror across the y axis
    // shortened code for GPU optimization (conditionals are slower, as multiple fragments are processed at once)
    uv.x = ((1.0 - max(sign(p.x - uv.x), 0.0))*(p.x-(uv.x-p.x))) + (max(sign(p.x - uv.x), 0.0)*uv.x);
    
    // mirror across the x axis
    //uv.y = (1.0 - max(sign(p.y - uv.y), 0.0))*(p.y-(uv.y-p.y)) + max(sign(p.y - uv.y), 0.0) * uv.y;
    
    // size the final image to the correct aspect ratio
    uv.y *= (u_Resolution.x*u_CameraResolution.x)/(u_CameraResolution.y*u_Resolution.y);

    // swizzle the color order to get the appropriate rgba
    gl_FragColor = texture2D(u_VideoFrame, uv);
}

