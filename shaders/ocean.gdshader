shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// The sea remains a lightweight single surface. Broad waves displace a subdivided
// plane; smaller waves are represented analytically in the normal field.
uniform vec4 deep_color : source_color = vec4(0.012, 0.105, 0.155, 0.88);
uniform vec4 shallow_color : source_color = vec4(0.035, 0.285, 0.335, 0.78);
uniform vec4 foam_color : source_color = vec4(0.72, 0.88, 0.82, 1.0);
uniform float wave_height : hint_range(0.0, 0.5, 0.01) = 0.18;
uniform float wave_speed : hint_range(0.0, 3.0, 0.05) = 0.85;
uniform float shore_foam_depth : hint_range(0.5, 12.0, 0.25) = 5.0;
uniform float refraction_strength : hint_range(0.0, 0.03, 0.001) = 0.005;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 world_position;

void vertex() {
    vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float t = TIME * wave_speed;

    float phase_a = dot(world.xz, vec2(0.82, 0.57)) * 0.018 + t * 0.85;
    float phase_b = dot(world.xz, vec2(-0.38, 0.925)) * 0.031 - t * 0.68;
    float phase_c = dot(world.xz, vec2(0.96, -0.28)) * 0.052 + t * 0.47;
    world.y += sin(phase_a) * wave_height;
    world.y += sin(phase_b) * wave_height * 0.34;
    world.y += sin(phase_c) * wave_height * 0.12;

    world_position = world;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}

void fragment() {
    vec2 p = world_position.xz;
    float t = TIME * wave_speed;

    // Analytic derivatives of three broad wave bands plus short surface ripples.
    vec2 dir_a = normalize(vec2(0.82, 0.57));
    vec2 dir_b = normalize(vec2(-0.38, 0.925));
    vec2 dir_c = normalize(vec2(0.96, -0.28));
    float phase_a = dot(p, dir_a) * 0.018 + t * 0.85;
    float phase_b = dot(p, dir_b) * 0.031 - t * 0.68;
    float phase_c = dot(p, dir_c) * 0.052 + t * 0.47;
    float phase_d = dot(p, vec2(0.61, 0.79)) * 0.19 + t * 1.35;
    float phase_e = dot(p, vec2(-0.91, 0.41)) * 0.27 - t * 1.08;

    float slope_x = cos(phase_a) * wave_height * 0.018 * dir_a.x;
    slope_x += cos(phase_b) * wave_height * 0.34 * 0.031 * dir_b.x;
    slope_x += cos(phase_c) * wave_height * 0.12 * 0.052 * dir_c.x;
    slope_x += cos(phase_d) * 0.018 * 0.19 * 0.61;
    slope_x += cos(phase_e) * 0.010 * 0.27 * -0.91;

    float slope_z = cos(phase_a) * wave_height * 0.018 * dir_a.y;
    slope_z += cos(phase_b) * wave_height * 0.34 * 0.031 * dir_b.y;
    slope_z += cos(phase_c) * wave_height * 0.12 * 0.052 * dir_c.y;
    slope_z += cos(phase_d) * 0.018 * 0.19 * 0.79;
    slope_z += cos(phase_e) * 0.010 * 0.27 * 0.41;

    vec3 world_normal = normalize(vec3(-slope_x, 1.0, -slope_z));
    NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

    // Reconstruct the opaque scene position to distinguish deep water from the
    // shallow shelf. Godot's depth buffer is nonlinear and uses reverse-Z.
    float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
    vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
    vec4 view_position = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
    view_position.xyz /= view_position.w;
    float water_view_depth = -VERTEX.z;
    float bottom_depth = max(-view_position.z - water_view_depth, 0.0);

    float shallow = 1.0 - smoothstep(1.0, 34.0, bottom_depth);
    float foam_noise = sin(p.x * 0.23 + sin(p.y * 0.11 + t) * 1.8)
        * sin(p.y * 0.19 - t * 0.72);
    float foam_line = 1.0 - smoothstep(
        shore_foam_depth * 0.28,
        shore_foam_depth * 0.28 + 1.35,
        abs(bottom_depth - shore_foam_depth * 0.42 + foam_noise * 0.42)
    );
    float foam = clamp(foam_line * shallow, 0.0, 1.0);

    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
    vec2 distortion = world_normal.xz * refraction_strength;
    vec3 scene_color = textureLod(
        screen_texture,
        clamp(SCREEN_UV + distortion, vec2(0.001), vec2(0.999)),
        0.0
    ).rgb;

    vec3 water_color = mix(deep_color.rgb, shallow_color.rgb, shallow * 0.78);
    water_color = mix(water_color, scene_color, 0.08 + fresnel * 0.16);
    water_color = mix(water_color, foam_color.rgb, foam * 0.72);

    ALBEDO = water_color;
    ROUGHNESS = mix(0.22, 0.38, shallow);
    SPECULAR = 0.62;
    METALLIC = 0.0;
    ALPHA = mix(deep_color.a, shallow_color.a, shallow * 0.45);
}
