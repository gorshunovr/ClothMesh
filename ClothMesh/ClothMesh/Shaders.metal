#include <metal_stdlib>
using namespace metal;

// Must match `Uniforms` in Renderer.swift.
struct Uniforms {
    float4x4 vp;
    float4x4 model;
    float4 cameraPos;
    float4 wireColor;
    float4 wireColor2;
    float4 fillColor;
    float4 lightDir;
    float4 wave;        // x amount, y spatial frequency, z speed
    float time;
    float depthOffset;
    float pointScale;
    float _pad;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct VSOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
};

static VSOut transform(VertexIn in, constant Uniforms &u) {
    VSOut o;
    float4 wp = u.model * float4(in.position, 1);
    o.worldPos = wp.xyz;
    o.normal = (u.model * float4(in.normal, 0)).xyz;
    o.position = u.vp * wp;
    o.uv = in.uv;
    return o;
}

vertex VSOut vertex_main(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    return transform(in, u);
}

// Same as vertex_main, pulled slightly toward the camera so wires win the depth test against the fill.
vertex VSOut vertex_wire(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    VSOut o = transform(in, u);
    o.position.z -= u.depthOffset * o.position.w;
    return o;
}

fragment float4 fragment_fill(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float3 v = normalize(u.cameraPos.xyz - in.worldPos);
    // Two-sided Lambert plus a faint rim so folds read.
    float diff = abs(dot(n, normalize(u.lightDir.xyz))) * 0.6 + 0.25;
    float rim = pow(1.0 - abs(dot(n, v)), 3.0) * 0.35;
    return float4(u.fillColor.rgb * (diff + rim), u.fillColor.a);
}

// Wire color, optionally blended toward wireColor2 by a wave travelling across the sheet.
fragment float4 fragment_wire(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float phase = (in.uv.x + in.uv.y) * u.wave.y - u.time * u.wave.z;
    float t = (0.5 + 0.5 * sin(phase)) * u.wave.x;
    return mix(u.wireColor, u.wireColor2, t);
}

// Ground grid that fades out with distance from the ball.
fragment float4 fragment_floor(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float fade = 1.0 - smoothstep(0.8, 4.5, length(in.worldPos.xz));
    return float4(u.wireColor.rgb, u.wireColor.a * fade);
}

// MARK: - Grab gizmo points

struct PointVertex {
    float4 positionSize;  // xyz world, w size in points
    float4 color;
};

struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
};

vertex PointOut vertex_point(uint vid [[vertex_id]],
                             constant PointVertex *points [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    PointOut o;
    o.position = u.vp * float4(points[vid].positionSize.xyz, 1);
    o.size = points[vid].positionSize.w * u.pointScale;
    o.color = points[vid].color;
    return o;
}

fragment float4 fragment_point(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    if (d > 1.0) discard_fragment();
    float a = 1.0 - smoothstep(0.75, 1.0, d);
    return float4(in.color.rgb, in.color.a * a);
}

// MARK: - Fullscreen passes (background, post overlay)

// Must match `ScreenUniforms` in Renderer.swift.
struct ScreenUniforms {
    float4 backgroundTop;
    float4 backgroundBottom;
    float4 glowColor;     // horizon glow, alpha = strength
    float fade;           // 0 visible … 1 black
    float flash;          // 0 … 1 white
    float vignette;
    float scanlines;
    float pixelScale;
    float time;
    float _pad0;
    float _pad1;
};

struct ScreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenOut vertex_screen(uint vid [[vertex_id]]) {
    // One oversized triangle covering the viewport.
    float2 p = float2((vid << 1) & 2, vid & 2);
    ScreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);  // (0,0) top-left
    return o;
}

fragment float4 fragment_background(ScreenOut in [[stage_in]], constant ScreenUniforms &s [[buffer(0)]]) {
    float3 c = mix(s.backgroundTop.rgb, s.backgroundBottom.rgb, in.uv.y);
    // Soft glow band a little below the middle of the screen.
    float band = exp(-pow((in.uv.y - 0.62) * 5.0, 2.0));
    c += s.glowColor.rgb * s.glowColor.a * band;
    return float4(c, 1);
}

// Premultiplied overlay: blend is (one, oneMinusSourceAlpha).
fragment float4 fragment_post(ScreenOut in [[stage_in]], constant ScreenUniforms &s [[buffer(0)]]) {
    float2 q = in.uv - 0.5;
    float vig = smoothstep(0.35, 0.95, length(q * float2(1.2, 1.0))) * s.vignette;
    float line = 0.5 + 0.5 * sin(in.position.y / s.pixelScale * 3.14159 * 0.5);
    float scan = line * s.scanlines;
    float dark = 1.0 - (1.0 - vig) * (1.0 - scan) * (1.0 - s.fade);
    float alpha = 1.0 - (1.0 - dark) * (1.0 - s.flash);
    return float4(float3(s.flash), alpha);
}
