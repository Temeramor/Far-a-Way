// Sand material: preserve the existing palette and its single low-cost noise sample.
vec3 sand_color(vec2 world_xz, float cell_size) {
    float sand_noise = value_noise(floor(world_xz / cell_size) * 0.19);
    return palette_color(vec3(0.76, 0.66, 0.46)) * (0.94 + sand_noise * 0.10);
}
