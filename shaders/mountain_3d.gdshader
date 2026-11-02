// mountain_3d.gdshader — standalone PBR reference material for MeshInstance3D.
shader_type spatial;
render_mode cull_back;
#include "res://shaders/mountain_common.gdshaderinc"
uniform bool baked_lighting = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float albedo_gain : hint_range(0.5, 2.5) = 1.6;
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 6.0;
uniform float gradient_bottom_y = 0.0;
uniform float gradient_top_y = 25.6;
varying vec3 wpos;
varying vec3 wnrm;
vec3 srgb_to_lin(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045)));
}
void plane(vec2 p_m, vec3 U, vec3 Vd, float wt, float yf, inout vec3 col, inout float rough, inout float ao, inout vec3 pert, inout float tw) {
    if (wt < 0.02) return;
    vec2 p_px = p_m / PX;
    Surf s = mountain(p_px, yf, baked_lighting);
    col += quantize(s.color, ivec2(floor(p_px))) * wt;
    rough += s.rough * wt; ao += s.ao * wt;
    pert += (s.grad.x * U + s.grad.y * Vd) * wt; tw += wt;
}
void vertex() {
    wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    wnrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    vec3 N = normalize(wnrm);
    vec3 w = pow(abs(N), vec3(triplanar_sharpness)); w /= (w.x + w.y + w.z);
    float yf = 1.0 - clamp((wpos.y - gradient_bottom_y) / (gradient_top_y - gradient_bottom_y), 0.0, 1.0);
    vec3 col = vec3(0.0), pert = vec3(0.0);
    float rough = 0.0, ao = 0.0, tw = 0.0;
    plane(vec2(wpos.z, -wpos.y) + vec2(53.7, 0.0), vec3(0, 0, 1), vec3(0, -1, 0), w.x, yf, col, rough, ao, pert, tw);
    plane(vec2(wpos.x, -wpos.y), vec3(1, 0, 0), vec3(0, -1, 0), w.z, yf, col, rough, ao, pert, tw);
    plane(vec2(wpos.x, wpos.z) + vec2(0.0, 91.3), vec3(1, 0, 0), vec3(0, 0, 1), w.y, yf, col, rough, ao, pert, tw);
    tw = max(tw, 0.0001); col /= tw; rough /= tw; ao /= tw;
    vec3 nw = normalize(N - normal_strength * pert / tw);
    NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
    vec3 lin = srgb_to_lin(col);
    if (baked_lighting) {
        ALBEDO = vec3(0.0); EMISSION = lin; ROUGHNESS = 1.0; SPECULAR = 0.0;
    } else {
        ALBEDO = lin * albedo_gain; ROUGHNESS = rough; SPECULAR = 0.25;
        AO = ao; AO_LIGHT_AFFECT = 0.5;
    }
}
