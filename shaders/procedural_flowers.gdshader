shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform vec2 wind_direction = vec2(0.86, 0.51);
uniform float wind_strength : hint_range(0.0, 1.0, 0.01) = 0.68;
uniform float wind_speed : hint_range(0.0, 2.0, 0.05) = 1.03;
uniform float wind_noise_scale : hint_range(0.001, 0.1, 0.001) = 0.022;

varying vec4 flower_data;
varying float flower_is_petal;
varying vec3 flower_tint;

void vertex() {
    vec4 custom_data = INSTANCE_CUSTOM;
    flower_data = custom_data;
    flower_is_petal = COLOR.a;
    flower_tint = COLOR.rgb;

    // Preserve the per-instance 3D orientation instead of camera-billboarding the bloom.
    vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 world_center = MODEL_MATRIX[3].xyz;
    float scale = pow(max(custom_data.a * custom_data.a, 0.02), 0.707);
    float phase_a = TIME * wind_speed
        + dot(world_center.xz, vec2(wind_noise_scale, wind_noise_scale * 0.37));
    float phase_b = TIME * wind_speed * 0.43
        + dot(world_center.xz, vec2(-wind_noise_scale * 0.62, wind_noise_scale * 0.81));
    float gust = clamp(0.58 + 0.25 * sin(phase_a) + 0.16 * sin(phase_b), 0.12, 1.0);
    float force = custom_data.b * scale * gust * wind_strength;
    force -= fract(force * 256.0) * force * 0.05;
    force = pow(max(force, 0.0), 0.707);

    float lateral_wobble = sin(TIME * 2.0 * (1.0 + custom_data.r + custom_data.g))
        * 0.25 * (1.0 - custom_data.b);
    vec2 direction = normalize(wind_direction);
    vec2 side_direction = vec2(-direction.y, direction.x);
    world_vertex.xz -= (direction + side_direction * lateral_wobble) * force;
    world_vertex.y -= custom_data.b * force * 0.12;
    VERTEX = (VIEW_MATRIX * vec4(world_vertex, 1.0)).xyz;
    NORMAL = MODELVIEW_NORMAL_MATRIX * NORMAL;
}

void fragment() {
    float palette_pick = flower_data.r;
    vec3 petals = vec3(1.00, 0.58, 0.025);
    vec3 centre = vec3(0.27, 0.20, 0.08);

    if (palette_pick < 0.22) {
        petals = vec3(1.00, 0.08, 0.34);
        centre = vec3(1.00, 0.84, 0.08);
    } else if (palette_pick < 0.44) {
        petals = vec3(1.00, 0.58, 0.025);
        centre = vec3(0.32, 0.15, 0.025);
    } else if (palette_pick < 0.66) {
        petals = vec3(0.42, 0.08, 1.00);
        centre = vec3(1.00, 0.88, 0.25);
    } else if (palette_pick < 0.84) {
        petals = vec3(0.035, 0.48, 1.00);
        centre = vec3(1.00, 0.86, 0.10);
    } else if (palette_pick < 0.985) {
        petals = vec3(1.00, 0.19, 0.025);
        centre = vec3(0.34, 0.12, 0.025);
    } else {
        petals = vec3(1.00, 0.20, 0.58);
        centre = vec3(1.00, 0.72, 0.08);
    }

    petals = mix(petals, flower_tint, 0.68);
    petals *= mix(0.88, 1.12, flower_data.g);
    centre *= mix(0.90, 1.08, flower_data.a);
    ALBEDO = flower_is_petal > 0.5 ? petals : centre;
    // Flowers have no emission/unshaded pass: they follow actual scene lighting at night.
    ROUGHNESS = 0.94;
    METALLIC = 0.0;
    SPECULAR = 0.06;
}
