// "Molten glass": the atmosphere behind the editorial UI. A dark olive/khaki field of soft, stretched ribbons seen
// through a large refracting glass sphere with a thin lit rim, plus film grain. Colours are measured from the
// reference site's hero (near-black olive, dull sage #51593f, ochre #7b663c, khaki gold #948151) — muted and dark,
// never saturated. Compiled at runtime (no offline `metal` tool on this Mac).
enum IridescenceShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // tunables (matched against measurements of the reference hero)
    #define SLOW_RATE   0.030
    #define FAST_RATE   2.0
    #define WOBBLE_AMP  0.24
    #define ZOOM_BASE   3.6
    #define ZOOM_VAR    0.9
    #define BRIGHT_LO   0.22
    #define BRIGHT_HI   0.62
    #define MIX_LO      0.43
    #define MIX_HI      0.54

    struct VOut { float4 position [[position]]; float2 uv; };

    struct Params {
        float2 resolution;
        float  time;
        float  seed;
        float  intensity;   // 0...1 brightness multiplier
        float  grain;       // film-grain amount (0...1)
    };

    vertex VOut iri_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);   // quintic: no visible grid creases
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    // Three octaves only: the reference is broad and soft, not fine-grained.
    static float fbm(float2 p) {
        float v = 0.0, a = 0.55;
        float2x2 m = float2x2(float2(1.5, 0.9), float2(-0.9, 1.5));
        for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
        return v;
    }

    // Colour comes from two families measured on the reference hero, blended by a second noise field:
    //   green family: dark, cool, never bright        #242c22 -> #3d4633 -> #4c5038
    //   gold  family: brown-ochre rising to khaki     #332819 -> #5a482a -> #948151
    static float3 ramp4(float3 c0, float3 c1, float3 c2, float3 c3, float b) {
        float x = clamp(b, 0.0, 1.0) * 3.0;
        float3 c = mix(c0, c1, clamp(x, 0.0, 1.0));
        c = mix(c, c2, clamp(x - 1.0, 0.0, 1.0));
        return mix(c, c3, clamp(x - 2.0, 0.0, 1.0));
    }

    // The ribbon field. `t` is slow drift, `tf` is a faster bounded wobble that makes the liquid flex without wandering off.
    static float3 field(float2 p, float t, float tf, float seed) {
        float2x2 rot = float2x2(float2(0.82, 0.57), float2(-0.57, 0.82));
        float2 s = (rot * p) * float2(0.85, 1.45) + float2(seed * 9.1, seed * 4.3);

        float2 w1 = WOBBLE_AMP * (float2(sin(tf + seed * 6.0), cos(tf * 0.83 + seed * 3.0)) * 0.6
                                + float2(sin(tf * 0.37 + 1.1), cos(tf * 0.29 + seed * 2.0)) * 0.7
                                + float2(cos(tf * 1.63 + 0.4), sin(tf * 1.21 + seed)) * 0.35);
        float2 w2 = WOBBLE_AMP * (float2(cos(tf * 0.71 + 2.0), sin(tf * 0.93 + seed * 5.0)) * 0.6
                                + float2(cos(tf * 0.31 + 0.7), sin(tf * 0.43 + seed * 4.0)) * 0.7
                                + float2(sin(tf * 1.77 + 2.2), cos(tf * 1.09 + seed * 3.0)) * 0.35);
        float2 q = float2(fbm(s + t + w1), fbm(s + float2(5.2, 1.3) - t + w2));
        float2 r = float2(fbm(s + 2.0 * q + float2(1.7, 9.2) + 0.6 * t + 0.6 * w2),
                          fbm(s + 2.0 * q + float2(8.3, 2.8) - 0.5 * t + 0.6 * w1));
        float f = fbm(s + 1.8 * r);                              // brightness
        float g = fbm(s * 0.7 + 2.5 * r + float2(3.1, 7.7));     // green vs gold

        float b = smoothstep(BRIGHT_LO, BRIGHT_HI, f);
        float m = smoothstep(MIX_LO, MIX_HI, g);

        float3 green = ramp4(float3(0.043, 0.047, 0.039), float3(0.141, 0.173, 0.133),
                             float3(0.231, 0.275, 0.208), float3(0.298, 0.318, 0.231), b);
        float3 gold  = ramp4(float3(0.055, 0.047, 0.035), float3(0.200, 0.157, 0.098),
                             float3(0.353, 0.282, 0.165), float3(0.640, 0.556, 0.350), b);
        return mix(green, gold, m);
    }

    fragment float4 iri_fragment(VOut in [[stage_in]], constant Params &u [[buffer(0)]]) {
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 p0 = (in.uv - 0.5) * float2(aspect, 1.0);          // height spans -0.5...0.5
        float t = u.time * SLOW_RATE;
        float tf = u.time * FAST_RATE;
        float zoom = ZOOM_BASE + hash11(u.seed + 0.37) * ZOOM_VAR;
        float2 p = p0 * zoom;

        // glass sphere: size and position come from the seed, drifting very slightly with time
        float2 lc = float2((0.18 + 0.52 * hash11(u.seed + 1.3)) * aspect * 0.5,
                           (hash11(u.seed + 2.9) - 0.5) * 0.55)
                  + 0.012 * float2(sin(u.time * 0.07), cos(u.time * 0.053));
        float R = 0.42 + 0.46 * hash11(u.seed + 4.1);
        float lightAngle = 3.6 + hash11(u.seed + 5.7) * 1.6;      // rim is brightest toward the lower left

        float2 d = p0 - lc;
        float r = length(d);

        float3 outside = field(p, t, tf, u.seed);

        // inside the sphere: inverted, magnified, slightly dispersed (a different scale per channel), and darker
        float2 inv = -d;
        float3 inner = field(lc * zoom + inv * 0.57 * zoom, t, tf, u.seed) * 0.80;

        float aa = 1.5 / max(u.resolution.y, 1.0);
        float inside = 1.0 - smoothstep(R - aa, R + aa, r);
        float3 col = mix(outside, inner, inside);

        // soft falloff just outside the sphere, bright thin rim, faint inner glow
        col *= 1.0 - 0.38 * smoothstep(R + 0.16, R, r) * (1.0 - inside);
        float ang = atan2(d.y, d.x);
        float lit = 0.5 + 0.5 * cos(ang - lightAngle);
        float rim = exp(-pow((r - R) / 0.0042, 2.0));
        float glow = exp(-pow((r - (R - 0.018)) / 0.030, 2.0));
        float3 rimTint = mix(float3(0.42, 0.46, 0.30), float3(0.74, 0.66, 0.44), lit);
        col += rim * (0.10 + 0.90 * lit) * rimTint * 0.75;
        col += glow * lit * float3(0.20, 0.21, 0.14);

        // film grain, plus a touch of dither so the long dark gradients don't band
        float g = (hash21(in.position.xy + fract(u.time * 0.37) * 91.0) - 0.5) * (0.075 * u.grain);
        col = clamp(col * u.intensity + g, 0.0, 1.0);
        return float4(col, 1.0);
    }
    """
}
