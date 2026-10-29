shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float wind_strength = 0.012;
uniform float wind_speed = 2.0;
uniform float gust_strength = 0.12;

void vertex() {
    // UV2.x stores each plant voxel vertex's height above its root, so roots remain anchored
    // even when the combined mesh contains plants over uneven terrain.
    float height_weight = clamp(UV2.x, 0.0, 1.0);
    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float phase = TIME * wind_speed + world_position.x * 0.17 + world_position.z * 0.23;
    float gust_phase = TIME * wind_speed * 0.31 + world_position.x * 0.025 - world_position.z * 0.019;
    float gust = 1.0 - gust_strength * 0.5 + gust_strength * (0.5 + 0.5 * sin(gust_phase));
    float sway = sin(phase) * wind_strength * gust * height_weight;
    VERTEX.x += sway * 0.82;
    VERTEX.z += sway * 0.57;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ROUGHNESS = 1.0;
    SPECULAR = 0.05;
}
