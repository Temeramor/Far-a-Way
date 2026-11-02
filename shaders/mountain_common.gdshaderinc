// mountain_common.gdshaderinc
// Общая процедурная модель скальных пород из веб-превью.
// 1 пиксель текстуры = 0.1 м.

const float PX = 0.1;
uniform int terrain_seed : hint_range(0, 99999) = 7;
uniform float vegetation : hint_range(0.0, 1.0) = 0.5;
uniform float stains : hint_range(0.0, 1.0) = 0.7;
uniform float light_azimuth : hint_range(-90.0, 90.0) = -40.0;
uniform int color_levels : hint_range(0, 16) = 7;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.6;

const vec3 ROCK0 = vec3(16.0, 19.0, 26.0) / 255.0;
const vec3 ROCK1 = vec3(56.0, 62.0, 72.0) / 255.0;
const vec3 ROCK2 = vec3(134.0, 137.0, 142.0) / 255.0;
const vec3 GRASS0 = vec3(18.0, 40.0, 14.0) / 255.0;
const vec3 GRASS1 = vec3(60.0, 110.0, 26.0) / 255.0;
const vec3 GRASS2 = vec3(136.0, 176.0, 56.0) / 255.0;
const vec3 LICHEN = vec3(150.0, 140.0, 108.0) / 255.0;
const float BAYER[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);

struct Surf {
    vec3 color;
    vec2 grad;
    float rough;
    float ao;
};

uint hash_u(ivec2 c, int s) {
    uint h = uint(c.x) * 374761393u + uint(c.y) * 668265263u + uint(s) * 1274126177u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return h ^ (h >> 16u);
}
float hash_f(ivec2 c, int s) { return float(hash_u(c, s) >> 8u) / 16777216.0; }
float grad_n(ivec2 i, vec2 d, int s) {
    uint k = hash_u(i, s) >> 29u;
    float u = k < 4u ? d.x : d.y;
    float v = k < 4u ? d.y : d.x;
    return ((k & 1u) != 0u ? -u : u) + ((k & 2u) != 0u ? -2.0 * v : 2.0 * v);
}
float perlin(vec2 p, int s) {
    vec2 f = floor(p); ivec2 i = ivec2(f); vec2 d = p - f;
    vec2 w = d * d * d * (d * (d * 6.0 - 15.0) + 10.0);
    float a = grad_n(i, d, s);
    float b = grad_n(i + ivec2(1, 0), d - vec2(1.0, 0.0), s);
    float c = grad_n(i + ivec2(0, 1), d - vec2(0.0, 1.0), s);
    float e = grad_n(i + ivec2(1, 1), d - vec2(1.0, 1.0), s);
    return mix(mix(a, b, w.x), mix(c, e, w.x), w.y) * 0.55;
}
float fbm(vec2 p, int s, int oct) {
    float a = 1.0, f = 1.0, sum = 0.0, t = 0.0;
    for (int i = 0; i < oct; i++) {
        sum += a * perlin(p * f + vec2(float(i) * 17.3, float(i) * 9.1), s);
        t += a; a *= 0.5; f *= 2.0;
    }
    return sum / t * 1.6;
}
vec3 worley(vec2 p, int s) {
    ivec2 c0 = ivec2(floor(p));
    float d1 = 9.0, d2 = 9.0, id = 0.0;
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        ivec2 c = c0 + ivec2(i, j);
        vec2 q = vec2(c) + vec2(hash_f(c, s), hash_f(c, s + 77));
        vec2 dd = p - q; float d = dot(dd, dd);
        if (d < d1) { d2 = d1; d1 = d; id = hash_f(c, s + 13); }
        else if (d < d2) { d2 = d; }
    }
    return vec3(sqrt(d1), sqrt(d2), id);
}
float terrain(vec2 m, out float cr) {
    int S = terrain_seed;
    vec2 w = m + vec2(2.2 * fbm(m * vec2(0.12, 0.05), S, 3), 1.6 * fbm(m * vec2(0.1, 0.06), S + 1, 3));
    vec3 a = worley(w / vec2(2.4, 9.0), S + 10);
    vec3 b = worley(w / vec2(0.8, 2.6), S + 20);
    float ea = a.y - a.x; float eb = b.y - b.x;
    float h = (a.z - 0.5) * 1.4 + smoothstep(0.0, 0.45, ea) * 0.8
        + (b.z - 0.5) * 0.5 + smoothstep(0.0, 0.4, eb) * 0.3;
    h -= (1.0 - smoothstep(0.0, 0.06, ea)) * 0.5;
    h += fbm(m * vec2(1.4, 0.4), S + 2, 5) * 0.5 + fbm(m * vec2(5.0, 4.0), S + 3, 2) * 0.1;
    float t = m.y * 0.35 + 1.2 * fbm(m * vec2(0.08, 0.02) + vec2(40.0, 0.0), S, 2);
    float fl = floor(t); h += (fl + smoothstep(0.7, 1.0, t - fl)) * 0.35;
    cr = smoothstep(0.0, 0.07, ea) * (0.55 + 0.45 * smoothstep(0.0, 0.1, eb));
    return h;
}
vec3 ramp3(vec3 a, vec3 b, vec3 c, float v) {
    v = clamp(v, 0.0, 1.0) * 2.0;
    return v < 1.0 ? mix(a, b, v) : mix(b, c, v - 1.0);
}
Surf mountain(vec2 pos_px, float yfrac, bool baked) {
    int S = terrain_seed; vec2 m = floor(pos_px) * PX;
    float cr; float dmy;
    float h0 = terrain(m, cr);
    float hx1 = terrain(m + vec2(PX, 0.0), dmy);
    float hx0 = terrain(m - vec2(PX, 0.0), dmy);
    float hy1 = terrain(m + vec2(0.0, PX), dmy);
    float hy0 = terrain(m - vec2(0.0, PX), dmy);
    float k3 = 3.0 * PX;
    float hd0 = terrain(m + vec2(k3, k3), dmy);
    float hd1 = terrain(m + vec2(-k3, k3), dmy);
    float hd2 = terrain(m + vec2(k3, -k3), dmy);
    float hd3 = terrain(m + vec2(-k3, -k3), dmy);
    float hb = (h0 + hx1 + hx0 + hy1 + hy0 + hd0 + hd1 + hd2 + hd3) / 9.0;
    vec2 g = vec2(hx1 - hx0, hy1 - hy0) / (2.0 * PX);
    float slope = length(g);
    float st = fbm(m * vec2(2.8, 0.1) + vec2(50.0, 0.0), S + 1, 3);
    float ST = smoothstep(0.05, 0.55, st) * (0.5 + 0.5 * smoothstep(-0.3, 0.4, fbm(m * vec2(0.3, 0.08), S + 3, 2)));
    float BD = fbm(m * vec2(0.25, 0.02) + vec2(90.0, 0.0), S + 2, 2);
    float LC = fbm(m * vec2(2.0, 1.2) + vec2(0.0, 9.0), S + 2, 3);
    float VG = 0.45 * fbm(m * vec2(0.45, 0.35) + vec2(30.0, 0.0), S, 4) + 0.12 * fbm(m * 6.0, S + 3, 2);
    float az = radians(light_azimuth);
    vec3 L = vec3(sin(az) * 0.75, -cos(az) * 0.75, 0.55);
    float sh = clamp(((-g.x * L.x - g.y * L.y + L.z) / sqrt(dot(g, g) + 1.0)) * 1.15 - 0.05, 0.0, 1.0);
    if (!baked) sh = 0.5825;
    float occ = clamp((hb - h0) * 1.8, 0.0, 1.0);
    sh *= 1.0 - 0.55 * occ;
    float v = sh * (0.35 + 0.65 * cr) * (1.0 - 0.5 * ST * stains);
    v *= 0.8 + 0.3 * BD * (0.4 + stains); v = clamp(v * 1.25, 0.0, 1.0);
    vec3 c = ramp3(ROCK0, ROCK1, ROCK2, v);
    c = mix(c, LICHEN, smoothstep(0.3, 0.6, LC) * 0.22);
    float flat_k = 1.0 - smoothstep(0.25, 0.9, slope);
    float score = VG + (vegetation - 0.5) * 1.2 + 0.45 * flat_k + 0.35 * (yfrac - 0.4);
    float gr = smoothstep(0.25, 0.4, score) * (0.4 + 0.6 * cr);
    c = mix(c, ramp3(GRASS0, GRASS1, GRASS2, v * 1.1), gr);
    return Surf(c, g, mix(0.92, 0.85, gr), 1.0 - 0.35 * occ);
}
vec3 quantize(vec3 c, ivec2 p) {
    if (color_levels < 2) return c;
    float L = float(color_levels - 1);
    float d = (BAYER[(p.y & 3) * 4 + (p.x & 3)] / 16.0 - 0.5) * dither_strength;
    return clamp(floor(c * L + d + 0.5), 0.0, L) / L;
}
