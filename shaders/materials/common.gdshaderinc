uniform float seed_low = 240518.0;
uniform float seed_high = 0.0;

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 view_up_direction;
varying float camera_distance;
varying float rock_specular_suppression;

vec3 palette_color(vec3 srgb) {
    return pow(srgb, vec3(2.2));
}

float hash21(vec2 p) {
    vec2 seed_shift = vec2(
        fract(seed_low * 0.000017 + seed_high * 0.000071),
        fract(seed_low * 0.000053 + seed_high * 0.000029)
    );
    p += seed_shift;
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + vec3(33.33));
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

