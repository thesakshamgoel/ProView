#version 450
// Converts 8-16 bit YCbCr planes to RGB on the GPU and dithers to the output depth, so 10-bit
// gradients stay smooth on 10-bit and 8-bit displays alike.
layout(push_constant) uniform PC {
    vec4 dst;
    vec4 uvx;
    vec4 uvy;
    vec4 m0, m1, m2;
    vec4 scale;
    int mode;
} pc;
layout(set = 0, binding = 0) uniform sampler2D planeY;
layout(set = 0, binding = 1) uniform sampler2D planeU;
layout(set = 0, binding = 2) uniform sampler2D planeV;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    float y = texture(planeY, uv).r * pc.scale.x;
    vec2 c = pc.mode == 1 ? texture(planeU, uv).rg : vec2(texture(planeU, uv).r, texture(planeV, uv).r);
    vec3 yuv = vec3(y, c * pc.scale.y);
    vec3 rgb = vec3(dot(pc.m0.xyz, yuv) + pc.m0.w, dot(pc.m1.xyz, yuv) + pc.m1.w, dot(pc.m2.xyz, yuv) + pc.m2.w);
    // Triangular dither of +-1 output step, decorrelated per pixel and per frame.
    vec2 p = gl_FragCoord.xy + pc.scale.w;
    float n = hash(p) + hash(p + 17.31) - 1.0;
    color = vec4(clamp(rgb + n * pc.scale.z, 0.0, 1.0), 1.0);
}
