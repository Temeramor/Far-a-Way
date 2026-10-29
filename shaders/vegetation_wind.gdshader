shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Wind speed controls how fast the plant sways; weather changes amplitude and gust strength.
// A shared direction and slow travelling gust field keep adjacent plants moving coherently.
uniform float wind_strength = 0.036;
uniform float wind_speed = 1.25;
uniform float gust_strength = 0.16;
uniform vec2 wind_direction = vec2(0.82, 0.57);

void vertex() {
    // UV2.x stores vertex height above the root. Roots remain anchored while tips bend.
    float h = clamp(UV2.x, 0.0, 1.0);
    float bend_weight = pow(h, 1.55);
    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec2 p = world_position.xz;
    vec2 direction = normalize(wind_direction);

    // A stable phase per small world cell prevents a whole tile from swaying in lockstep.
    vec2 plant_cell = floor(p * 1.35);
    float phase_hash = fract(sin(dot(plant_cell, vec2(127.1, 311.7))) * 43758.5453);
    float phase_offset = phase_hash * 6.2831853;

    float along_wind = dot(p, direction);
    float wave_a = sin(TIME * wind_speed + along_wind * 0.045 + phase_offset);
    float wave_b = sin(TIME * wind_speed * 0.63
        + p.x * 0.012 - p.y * 0.009 + phase_offset * 0.55 + 1.7);

    // Slow modulation controls the gust amplitude rather than making the oscillation frantic.
    float gust_phase = TIME * 0.32 + dot(p, vec2(0.013, -0.009));
    float gust_field = 0.5 + 0.5 * sin(gust_phase);
    float gust = 1.0 - gust_strength * 0.20 + gust_strength * 1.15 * gust_field;
    float sway = (wave_a * 0.72 + wave_b * 0.28) * wind_strength * gust * bend_weight;

    VERTEX.xz += direction * sway;
    // Slightly lower the tip during a stronger bend to suggest flexible leaves.
    VERTEX.y -= abs(sway) * abs(sway) * 0.12;
}

void fragment() {
    // Vertex colours are stored in sRGB, like the terrain palette. Convert to linear
    // before lighting, then gently lift the foliage albedo so it does not look washed out.
    vec3 foliage_linear = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
    ALBEDO = min(foliage_linear * vec3(1.12, 1.16, 1.06), vec3(1.0));
    BACKLIGHT = ALBEDO * 0.20;
    ROUGHNESS = 1.0;
    SPECULAR = 0.03;
}
