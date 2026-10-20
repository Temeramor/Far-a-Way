// Adapted from the Terrain3D particle-grass example by Cory Petkovsek,
// Roope Palmroos, and contributors. Copyright (c) 2023-2026; MIT License.
// This version retains the ribbon shape, olive palette, tip lighting, and wind response,
// while taking deterministic placement/custom data from Neverland's terrain generator.
shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, blend_mix, diffuse_burley, specular_schlick_ggx;

uniform vec2 wind_direction = vec2(1.0, 1.0);
uniform float wind_strength : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float wind_speed : hint_range(0.0, 2.0, 0.05) = 0.72;
uniform float wind_noise_scale : hint_range(0.001, 0.1, 0.001) = 0.022;

varying vec4 blade_data;

void vertex() {
    vec4 custom_data = INSTANCE_CUSTOM;
    float height_weight = clamp(VERTEX.y, 0.0, 1.0);
    float bend_weight = height_weight * height_weight;

    // Source-addon ribbon shaping: narrow toward the tip and brighten the very top.
    VERTEX.xz *= (1.0 - bend_weight * 0.32);
    COLOR = mix(COLOR, vec4(1.0), smoothstep(0.82, 1.0, height_weight) * 0.22);
    COLOR *= custom_data.a < 0.35 ? 1.0 : mix(1.0, 0.75, (1.0 - smoothstep(0.0, 0.35, height_weight)));

    blade_data.rg = custom_data.rg;
    blade_data.b = bend_weight;

    vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float scale = pow(max(custom_data.a * custom_data.a, 0.02), 0.707);
    float phase_a = TIME * wind_speed
        + dot(world_vertex.xz, vec2(wind_noise_scale, wind_noise_scale * 0.37));
    float phase_b = TIME * wind_speed * 0.43
        + dot(world_vertex.xz, vec2(-wind_noise_scale * 0.62, wind_noise_scale * 0.81));
    float gust = clamp(0.58 + 0.25 * sin(phase_a) + 0.16 * sin(phase_b), 0.12, 1.0);
    float force = custom_data.b * bend_weight * scale * gust * wind_strength;
    force -= fract(force * 256.0) * force * 0.05;
    force = pow(max(force, 0.0), 0.707);

    float lateral_wobble = sin(TIME * 2.0 * (1.0 + blade_data.r + blade_data.g))
        * 0.25 * (1.0 - custom_data.b);
    vec2 direction = normalize(wind_direction);
    vec2 side_direction = vec2(-direction.y, direction.x);
    world_vertex.xz -= (direction + side_direction * lateral_wobble) * force;
    world_vertex.y -= custom_data.b * force * bend_weight * 0.12;

    blade_data.a = force;
    VERTEX = (VIEW_MATRIX * vec4(world_vertex, 1.0)).xyz;
    NORMAL = MODELVIEW_NORMAL_MATRIX * NORMAL;
}

void fragment() {
    float height_weight = clamp(UV.y, 0.0, 1.0);

    // The subdued olive-green palette and tip highlights are adapted from the
    // RibbonTrailMesh grass shader in generator.zip.
    vec3 grass_color = vec3(0.20, 0.22, 0.05) * (height_weight * 0.5 + 0.5);
    grass_color.rg *= (blade_data.rg * 0.3 + 0.9);
    ALBEDO = grass_color * pow(COLOR.rgb, vec3(2.2));
    float spec_rough = clamp(max(blade_data.b, blade_data.a), 0.0, 1.0);
    ROUGHNESS = 1.0 - spec_rough;
    METALLIC = 0.0;
    SPECULAR = clamp(spec_rough * 0.25, 0.0, 0.15);
    BACKLIGHT = vec3(0.33);

    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    ALBEDO = pow(ALBEDO, vec3(0.4));
    #endif
}
