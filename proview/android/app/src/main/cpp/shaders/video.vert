#version 450
// Draws the video rectangle as a 4-vertex triangle strip; no vertex buffer needed.
layout(push_constant) uniform PC {
    vec4 dst;   // destination rect in NDC: x0, y0, x1, y1
    vec4 uvx;   // u = uvx.x + uvx.y * s + uvx.z * t  (rotation + zoom crop)
    vec4 uvy;   // v = uvy.x + uvy.y * s + uvy.z * t
    vec4 m0, m1, m2;  // YCbCr -> RGB rows (xyz) and offsets (w), range expansion included
    vec4 scale;       // x: luma scale, y: chroma scale, z: dither amplitude, w: frame seed
    int mode;         // 0: three planes, 1: Y + interleaved CbCr
} pc;
layout(location = 0) out vec2 uv;
void main() {
    vec2 st = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1);
    uv = vec2(pc.uvx.x + pc.uvx.y * st.x + pc.uvx.z * st.y,
              pc.uvy.x + pc.uvy.y * st.x + pc.uvy.z * st.y);
    gl_Position = vec4(mix(pc.dst.xy, pc.dst.zw, st), 0.0, 1.0);
}
