// Metal Shading Language source, compiled at runtime with MTLDevice.makeLibrary(source:).
// (This machine has Command Line Tools only, so there is no offline `metal` compiler.)
enum ScreenShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    struct Params {
        float2 texSize;     // source size in texels
        float2 viewSize;    // drawn rectangle size in pixels
        int    filter;      // 0 sharp-bilinear, 1 nearest, 2 smooth
        float  scanlines;   // 0...1
    };

    vertex VOut screen_vertex(uint vid [[vertex_id]]) {
        // One oversized triangle covering the viewport.
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 screen_fragment(VOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant Params &u [[buffer(0)]]) {
        constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

        float2 uv = in.uv;
        float4 c;
        if (u.filter == 1) {
            c = tex.sample(pointSampler, uv);
        } else if (u.filter == 2) {
            c = tex.sample(linearSampler, uv);
        } else {
            // Sharp bilinear: keep texel interiors flat, blend only in a thin band at texel edges.
            float2 scale = max(u.viewSize / u.texSize, float2(1.0));
            float2 texel = uv * u.texSize;
            float2 base = floor(texel);
            float2 frac = texel - base;
            float2 region = 0.5 - 0.5 / scale;
            float2 centered = frac - 0.5;
            float2 f = (centered - clamp(centered, -region, region)) * scale + 0.5;
            c = tex.sample(linearSampler, (base + f) / u.texSize);
        }

        if (u.scanlines > 0.0) {
            float row = uv.y * u.texSize.y;
            float shade = 0.5 - 0.5 * cos(row * 6.2831853);   // 0 at row centres' edges, 1 mid-row
            c.rgb *= 1.0 - u.scanlines * (1.0 - shade) * 0.6;
        }
        return float4(c.rgb, 1.0);
    }
    """
}
