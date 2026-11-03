shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float wave_amplitude : hint_range(0.0, 2.0) = 0.55;
uniform float wave_speed : hint_range(0.0, 3.0) = 1.0;
uniform float water_opacity : hint_range(0.35, 0.98) = 0.82;
uniform vec3 shallow_water_color : source_color = vec3(0.035, 0.38, 0.39);
uniform vec3 deep_water_color : source_color = vec3(0.008, 0.075, 0.16);
uniform float island_aspect = 2.5;
uniform float island_rotation = 0.0;
uniform float island_radius = 1128.38;

varying vec3 world_position;

float hash21(vec2 p) {
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

float shoreline_distance(vec2 p) {
    float c = cos(island_rotation);
    float s = sin(island_rotation);
    vec2 rotated = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
    float axis_a = island_radius * sqrt(island_aspect);
    float axis_b = island_radius / sqrt(island_aspect);
    float radial = length(vec2(rotated.x / axis_a, rotated.y / axis_b));
    return (radial - 1.0) * island_radius;
}

float ocean_wave(vec2 p) {
    float t = TIME * wave_speed;
    float swell_a = sin(dot(p, normalize(vec2(0.83, 0.34))) * 0.008 + t * 0.72);
    float swell_b = sin(dot(p, normalize(vec2(-0.26, 0.96))) * 0.014 - t * 1.08);
    float cross_wave = sin(dot(p, normalize(vec2(0.58, -0.81))) * 0.026 + t * 1.47);
    return (swell_a * 0.62 + swell_b * 0.27 + cross_wave * 0.11) * wave_amplitude;
}

void vertex() {
    vec3 initial_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    VERTEX.y += ocean_wave(initial_world.xz);
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    vec2 p = world_position.xz;
    float offshore_distance = max(0.0, shoreline_distance(p));
    // Match the seed-derived island ellipse so shallow turquoise water hugs the actual
    // shoreline rather than a fixed circular ring around the world origin.
    float depth_blend = smoothstep(120.0, 3000.0, offshore_distance);
    float broad_variation = value_noise(p * 0.0017 + vec2(TIME * 0.006, 8.3));
    float fine_variation = value_noise(p * 0.018 + vec2(21.7, TIME * 0.014));
    float color_drift = (broad_variation - 0.5) * 0.12 + (fine_variation - 0.5) * 0.035;

    float wave_x = ocean_wave(p + vec2(0.8, 0.0)) - ocean_wave(p - vec2(0.8, 0.0));
    float wave_z = ocean_wave(p + vec2(0.0, 0.8)) - ocean_wave(p - vec2(0.0, 0.8));
    vec3 wave_normal = normalize(vec3(-wave_x, 1.6, -wave_z));
    NORMAL = normalize((VIEW_MATRIX * vec4(wave_normal, 0.0)).xyz);

    vec3 water_color = mix(shallow_water_color, deep_water_color, depth_blend);
    water_color *= 0.94 + color_drift;
    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 5.0);
    ALBEDO = mix(water_color, vec3(0.42, 0.58, 0.66), fresnel * 0.38);
    ROUGHNESS = mix(0.20, 0.11, fresnel);
    METALLIC = 0.0;
    SPECULAR = 0.92;
    ALPHA = water_opacity;
}
