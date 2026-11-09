vec3 soil_palette(float pick) {
    float p = clamp(pick, 0.0, 1.0);
    vec3 c0 = palette_color(vec3(0.31, 0.20, 0.11));
    vec3 c1 = palette_color(vec3(0.39, 0.26, 0.14));
    vec3 c2 = palette_color(vec3(0.46, 0.31, 0.17));
    vec3 c3 = palette_color(vec3(0.51, 0.36, 0.20));
    vec3 c4 = palette_color(vec3(0.56, 0.40, 0.23));
    if (p < 0.18) return mix(c0, c1, smoothstep(0.0, 0.18, p));
    if (p < 0.42) return mix(c1, c2, smoothstep(0.18, 0.42, p));
    if (p < 0.70) return mix(c2, c3, smoothstep(0.42, 0.70, p));
    if (p < 0.90) return mix(c3, c4, smoothstep(0.70, 0.90, p));
    return c4;
}





vec3 voxel_lod_soil_color(vec2 world_xz, float cell_size) {
    vec2 cell = floor(world_xz / cell_size);
    vec2 center = (cell + vec2(0.5)) * cell_size;
    float cell_tone = hash21(cell + vec2(5.7, 26.1));
    float broad_tone = value_noise(center * 0.008 + vec2(9.2, seed_low * 0.00009));
    float pick = clamp(0.10 + cell_tone * 0.78 + (broad_tone - 0.5) * 0.16, 0.001, 0.999);
    return soil_palette(pick);
}

