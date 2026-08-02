attribute vec4 position;
attribute vec2 texCoord;

varying highp vec2 v_TexCoord;

void main()
{
    gl_Position = position;
    v_TexCoord = texCoord;
}
