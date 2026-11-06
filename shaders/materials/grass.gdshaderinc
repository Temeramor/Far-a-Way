// Continuous palette transitions prevent harsh colour steps
// from collecting into large, patch-like regions across the visible terrain.
vec3 grass_palette(float pick) {
    float p = clamp(pick, 0.0, 1.0);
    vec3 c0 = palette_color(vec3(0.180, 0.270, 0.120));
    vec3 c1 = palette_color(vec3(0.220, 0.340, 0.110));
    vec3 c2 = palette_color(vec3(0.250, 0.400, 0.120));
    vec3 c3 = palette_color(vec3(0.285, 0.435, 0.135));
    vec3 c4 = palette_color(vec3(0.315, 0.465, 0.150));
    vec3 c5 = palette_color(vec3(0.340, 0.430, 0.170));
    vec3 c6 = palette_color(vec3(0.270, 0.380, 0.120));
    vec3 c7 = palette_color(vec3(0.365, 0.465, 0.195));
    vec3 c8 = palette_color(vec3(0.500, 0.580, 0.280));
    if (p < 0.055) return mix(c0, c1, smoothstep(0.0, 0.055, p));
    if (p < 0.145) return mix(c1, c2, smoothstep(0.055, 0.145, p));
    if (p < 0.285) return mix(c2, c3, smoothstep(0.145, 0.285, p));
    if (p < 0.435) return mix(c3, c4, smoothstep(0.285, 0.435, p));
    if (p < 0.600) return mix(c4, c5, smoothstep(0.435, 0.600, p));
    if (p < 0.735) return mix(c5, c6, smoothstep(0.600, 0.735, p));
    if (p < 0.855) return mix(c6, c7, smoothstep(0.735, 0.855, p));
    if (p < 0.960) return mix(c7, c8, smoothstep(0.855, 0.960, p));
    return c8;
}

vec3 grass_pixel(vec2 pixel_cell, vec2 pixel_world) {
    // Main's wider palette variation, with continuous ramps to avoid hard boundaries
    // between grass swatches or broad patches.
    float broad_tone = value_noise(pixel_world * 0.027 + vec2(seed_low * 0.0003, 4.2));
    float random_cell = hash21(pixel_cell + vec2(0.0, 7.7));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.22, 0.001, 0.999);
    vec3 color = grass_palette(pick);

    // Rare soft flecks add the fine colour variety from main without stark cell jumps.
    float fleck = hash21(pixel_cell + vec2(81.2, 18.4));
    float light_fleck = smoothstep(0.994, 0.999, fleck) * 0.22;
    float dark_fleck = (1.0 - smoothstep(0.002, 0.018, fleck)) * 0.36;
    color = mix(color, palette_color(vec3(0.741, 0.741, 0.467)), light_fleck);
    color = mix(color, palette_color(vec3(0.275, 0.290, 0.173)), dark_fleck);
    return color;
}


vec3 voxel_lod_grass_color(vec2 world_xz, float cell_size) {
    vec2 cell = floor(world_xz / cell_size);
    vec2 center = (cell + vec2(0.5)) * cell_size;
    float cell_tone = hash21(cell + vec2(2.3, 7.1));
    float broad_tone = value_noise(center * 0.0042 + vec2(seed_low * 0.00013, 5.7));
    float medium_tone = value_noise(center * 0.018 + vec2(7.1, seed_high * 0.00017));
    float pick = clamp(0.12 + cell_tone * 0.76
        + (broad_tone - 0.5) * 0.15 + (medium_tone - 0.5) * 0.08, 0.001, 0.999);
    return grass_palette(pick);
}

