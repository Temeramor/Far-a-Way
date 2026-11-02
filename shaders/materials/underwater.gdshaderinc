vec3 underwater_algae_voxels(vec3 rock_color, vec2 pixel_cell, vec2 pixel_world) {
    // A low-frequency field creates irregular colonies; an elongated field breaks them
    // into short Enteromorpha-like strands. The final mask is quantised per voxel cell.
    float colony_noise = value_noise(pixel_world * 0.052 + vec2(seed_low * 0.0002, 13.7));
    float strand_noise = value_noise(vec2(pixel_world.x * 0.031, pixel_world.y * 0.145)
        + vec2(29.4, seed_high * 0.0003));
    float colony = smoothstep(0.48, 0.78, colony_noise * 0.70 + strand_noise * 0.30);
    float cell_pick = hash21(pixel_cell + vec2(41.7, 19.3));
    float clustered_cells = step(0.86 - colony * 0.30, cell_pick) * colony;
    float isolated_cells = step(0.994, hash21(pixel_cell + vec2(83.1, 57.6)));
    float algae_mask = max(clustered_cells, isolated_cells);

    float species = hash21(pixel_cell + vec2(7.3, 93.1));
    vec3 ulva_green = palette_color(vec3(0.15, 0.32, 0.10));
    vec3 enteromorpha_green = palette_color(vec3(0.27, 0.44, 0.13));
    vec3 algae_color = mix(ulva_green, enteromorpha_green, species);
    return mix(rock_color * 0.58, algae_color, algae_mask);
}


