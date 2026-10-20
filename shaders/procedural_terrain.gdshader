shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// World-locked material: every color cell is generated from coordinates and the world seed.
// No bitmap textures, imported rocks, repeating tiles, or editor-only dependencies are used.
uniform float pixel_size : hint_range(0.45, 3.0, 0.05) = 1.15;
uniform float seed_offset = 0.0;
uniform float seed_offset_high = 0.0;
uniform float rock_transition_start : hint_range(0.05, 0.8, 0.01) = 0.30;
uniform float rock_transition_end : hint_range(0.1, 0.95, 0.01) = 0.48;

varying vec3 world_position;
varying vec3 world_normal;

float hash21(vec2 p) {
    // Mix both halves of the integer seed into both coordinate axes before hashing.
    // A 3-component avalanche hash is less prone to correlated rows/columns than a
    // simple p.x * p.y hash, which could produce obvious bands for particular seeds.
    vec2 seed_shift = vec2(
        fract(seed_offset * 0.000017 + seed_offset_high * 0.000071),
        fract(seed_offset * 0.000053 + seed_offset_high * 0.000029)
    );
    p += seed_shift;
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

float voronoi_edge(vec2 p) {
    vec2 base_cell = floor(p);
    vec2 local = fract(p);
    float nearest = 10.0;
    float second_nearest = 10.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset_cell = vec2(float(x), float(y));
            vec2 cell = base_cell + offset_cell;
            vec2 random_point = vec2(
                hash21(cell + vec2(3.1, 8.7)),
                hash21(cell + vec2(19.4, 2.6))
            ) * 0.72 + 0.14;
            vec2 delta = offset_cell + random_point - local;
            float distance_squared = dot(delta, delta);
            if (distance_squared < nearest) {
                second_nearest = nearest;
                nearest = distance_squared;
            } else if (distance_squared < second_nearest) {
                second_nearest = distance_squared;
            }
        }
    }
    return sqrt(second_nearest) - sqrt(nearest);
}

// Palette swatches are deliberately stored as color values, not copied texture assets.
// Convert their sRGB values to linear light before returning them as material albedo.
vec3 palette_color(vec3 srgb_color) {
    return pow(srgb_color, vec3(2.2));
}

vec3 grass_palette(float pick) {
    // Natural greens run from cool shaded moss through rich meadow green to muted sunlit blades.
    if (pick < 0.055) return palette_color(vec3(0.180, 0.270, 0.120));
    if (pick < 0.145) return palette_color(vec3(0.220, 0.340, 0.110));
    if (pick < 0.285) return palette_color(vec3(0.250, 0.400, 0.120));
    if (pick < 0.435) return palette_color(vec3(0.285, 0.435, 0.135));
    if (pick < 0.600) return palette_color(vec3(0.315, 0.465, 0.150));
    if (pick < 0.735) return palette_color(vec3(0.340, 0.430, 0.170));
    if (pick < 0.855) return palette_color(vec3(0.270, 0.380, 0.120));
    if (pick < 0.960) return palette_color(vec3(0.365, 0.465, 0.195));
    return palette_color(vec3(0.500, 0.580, 0.280));
}

vec3 rock_palette(float pick) {
    // The pixel choice is still stochastic, but each sample maps through smooth gradients
    // rather than hard palette cutoffs. Macro strata are blended separately below.
    // Darken only the base stone palette; fixed crack, pit and chip colors are applied later.
    float p = clamp(pick, 0.0, 1.0);
    vec3 c0 = palette_color(vec3(0.205, 0.215, 0.220));
    vec3 c1 = palette_color(vec3(0.315, 0.325, 0.330));
    vec3 c2 = palette_color(vec3(0.395, 0.400, 0.400));
    // Keep distinct stone hues, but compress the pale end of the palette into darker mid-grays.
    vec3 c3 = palette_color(vec3(0.425, 0.430, 0.425));
    vec3 c4 = palette_color(vec3(0.465, 0.460, 0.445));
    vec3 c5 = palette_color(vec3(0.510, 0.500, 0.480));
    vec3 c6 = palette_color(vec3(0.555, 0.545, 0.515));
    vec3 c7 = palette_color(vec3(0.610, 0.590, 0.550));
    vec3 color;
    if (p < 0.16) {
        color = mix(c0, c1, smoothstep(0.0, 0.16, p));
    } else if (p < 0.32) {
        color = mix(c1, c2, smoothstep(0.16, 0.32, p));
    } else if (p < 0.49) {
        color = mix(c2, c3, smoothstep(0.32, 0.49, p));
    } else if (p < 0.66) {
        color = mix(c3, c4, smoothstep(0.49, 0.66, p));
    } else if (p < 0.82) {
        color = mix(c4, c5, smoothstep(0.66, 0.82, p));
    } else if (p < 0.94) {
        color = mix(c5, c6, smoothstep(0.82, 0.94, p));
    } else {
        color = mix(c6, c7, smoothstep(0.94, 1.0, p));
    }
    return color * 0.86;
}

vec3 grass_pixel(vec2 pixel_cell, vec2 pixel_world) {
    float broad_tone = value_noise(pixel_world * 0.027 + vec2(seed_offset * 0.0003, 4.2));
    float random_cell = hash21(pixel_cell + vec2(0.0, 7.7));
    // Broad color drift slightly biases the local palette without creating a repeatable tile.
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.22, 0.001, 0.999);
    vec3 color = grass_palette(pick);

    float fleck = hash21(pixel_cell + vec2(81.2, 18.4));
    if (fleck > 0.987) {
        color = mix(color, palette_color(vec3(0.741, 0.741, 0.467)), 0.68);
    } else if (fleck < 0.018) {
        color = mix(color, palette_color(vec3(0.275, 0.290, 0.173)), 0.62);
    }
    return color;
}

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world) {
    float broad_tone = value_noise(pixel_world * 0.021 + vec2(13.8, seed_offset * 0.0006));
    float random_cell = hash21(pixel_cell + vec2(0.0, 21.8));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.19, 0.001, 0.999);
    vec3 color = rock_palette(pick);

    // Warped mineral strata create irregular, non-repeating color bands across the stone.
    vec2 warp = (vec2(
        value_noise(pixel_world * 0.017 + vec2(3.3, 8.1)),
        value_noise(pixel_world * 0.019 + vec2(19.7, 2.4))
    ) - 0.5) * 9.0;
    vec2 warped = pixel_world + warp;
    float mineral_layers = value_noise(warped * vec2(0.012, 0.039) + vec2(seed_offset * 0.0002, 6.1));
    float layer_tone = smoothstep(0.05, 0.95, mineral_layers);
    float broad_stone_tone = value_noise(warped * 0.0019 + vec2(17.2, seed_offset_high * 0.00015));
    float mountain_macro_tone = value_noise(warped * 0.00082 + vec2(
        17.2 + seed_offset * 0.00011,
        8.4 + seed_offset_high * 0.00019
    ));
    // Slightly darker stone with very broad, smooth tonal drift across entire faces.
    // The low-frequency term changes over hundreds of world units, never in sharp bands.
    float stone_brightness = clamp(
        0.68 + layer_tone * 0.19
        + (broad_stone_tone - 0.5) * 0.25
        + (mountain_macro_tone - 0.5) * 0.14,
        0.58, 0.98
    );
    float stone_warmth = value_noise(warped * vec2(0.0025, 0.0060) + vec2(31.3, 8.4));
    vec3 cool_tint = mix(vec3(0.78, 0.84, 0.94), vec3(1.02, 1.02, 0.99), layer_tone);
    vec3 warm_tint = mix(vec3(0.88, 0.84, 0.77), vec3(1.08, 1.045, 0.98), layer_tone);
    vec3 smooth_tint = mix(cool_tint, warm_tint, smoothstep(0.18, 0.82, stone_warmth) * 0.62);
    color *= smooth_tint * stone_brightness;

    // Short, broken vertical fissures: lines stay aligned to the height axis,
    // while small horizontal offsets and variable widths give them chipped, jagged edges.
    // The subtle warp distorts the line shape without turning it into rounded noise spots.
    vec2 fissure_world = pixel_world + warp * vec2(0.25, 0.08);
    vec2 fissure_grid = fissure_world * vec2(0.22, 0.22);
    vec2 fissure_cell = floor(fissure_grid);
    vec2 fissure_local = fract(fissure_grid);

    // A sparse set of columns, with independently missing segments, creates broken seams.
    float fissure_column = step(0.30, hash21(vec2(
        fissure_cell.x + 42.3, 11.7 + seed_offset * 0.0003
    )));
    float fissure_segment = step(0.31, hash21(
        fissure_cell + vec2(21.4, 35.8 + seed_offset * 0.0004)
    ));
    float fissure_start = mix(0.04, 0.20,
        hash21(fissure_cell + vec2(22.1, 9.7)));
    float fissure_length = mix(0.48, 0.76,
        hash21(fissure_cell + vec2(7.4, 31.8)));
    float fissure_vertical = step(fissure_start, fissure_local.y)
        * (1.0 - step(fissure_start + fissure_length, fissure_local.y));

    // Shift the groove slightly every couple of meters, producing a jagged rather than straight edge.
    float fissure_micro_row = floor(fissure_world.y * 0.42);
    float fissure_center = mix(0.40, 0.60,
        hash21(vec2(fissure_cell.x + 3.2, 17.4)));
    float fissure_jitter = (hash21(vec2(
        fissure_cell.x + 8.1,
        fissure_micro_row + seed_offset * 0.0004
    )) - 0.5) * 0.17;
    float fissure_half_width = mix(0.05, 0.12, hash21(vec2(
        fissure_cell.x + 16.7,
        fissure_micro_row + 5.3
    )));
    float fissure_distance = abs(fissure_local.x - (fissure_center + fissure_jitter));
    float fissure_mask = fissure_column * fissure_segment * fissure_vertical
        * step(fissure_distance, fissure_half_width);

    // Preserve the small chips and their original color; only skip chips directly under a fissure.
    float chip_noise = value_noise(warped * 0.062 + vec2(27.0, 4.0));
    float chip_mask = step(0.79, chip_noise) * (1.0 - fissure_mask);
    color = mix(color, palette_color(vec3(0.105, 0.112, 0.112)), fissure_mask * 0.80);
    color = mix(color, palette_color(vec3(0.655, 0.642, 0.608)), chip_mask * 0.18);

    // Make Voronoi fractures less frequent and finer so vertical seams remain the dominant detail.
    float edge = voronoi_edge(warped / 48.0 + vec2(seed_offset * 0.0008, 6.7));
    float crack_line = 1.0 - smoothstep(0.008, 0.029, edge);
    float crack_region = step(0.84, value_noise(warped * 0.012 + vec2(9.0, 12.7)));
    float crack_breakup = step(0.40, value_noise(warped * 0.041 + vec2(12.6, seed_offset * 0.0004)));
    float crack_mask = crack_line * crack_region * crack_breakup * (1.0 - fissure_mask * 0.35);
    color = mix(color, palette_color(vec3(0.075, 0.080, 0.078)), crack_mask * 0.91);

    // Tiny mineral flecks remain rare, so the stone keeps large readable planes.
    float fleck = hash21(pixel_cell + vec2(34.8, 92.1));
    if (fleck > 0.989) {
        color = mix(color, palette_color(vec3(0.710, 0.690, 0.640)), 0.58);
    } else if (fleck < 0.014) {
        color = mix(color, palette_color(vec3(0.105, 0.110, 0.108)), 0.67);
    }
    return color;
}


// Distance LOD for procedural materials: broad continuous colors replace tiny pixel cells,
// cracks and pitting beyond the mid-distance. This reduces distant shimmer without
// changing any generated heights or the close-up material.
vec3 distant_grass_color(vec2 world_xz) {
    float broad = value_noise(world_xz * 0.0024 + vec2(seed_offset * 0.00019, 9.1));
    float medium = value_noise(world_xz * 0.0062 + vec2(5.3, seed_offset_high * 0.00013));
    float pick = clamp(0.18 + broad * 0.66 + (medium - 0.5) * 0.24, 0.001, 0.999);
    return grass_palette(pick);
}

vec3 distant_rock_color(vec2 projected_world) {
    float broad = value_noise(projected_world * 0.0015 + vec2(seed_offset * 0.00011, 17.2));
    float strata = value_noise(projected_world * vec2(0.0018, 0.0044)
        + vec2(4.2, seed_offset_high * 0.00015));
    float pick = clamp(broad * 0.58 + strata * 0.42, 0.001, 0.999);
    vec3 color = rock_palette(pick);
    float broad_brightness = 0.84 + (broad - 0.5) * 0.16;
    vec3 cool_tint = mix(vec3(0.82, 0.88, 0.96), vec3(1.0, 0.99, 0.96), strata);
    return color * cool_tint * broad_brightness;
}

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    vec3 normal = normalize(world_normal);
    float slope = 1.0 - clamp(normal.y, 0.0, 1.0);
    float camera_distance = distance(CAMERA_POSITION_WORLD.xz, world_position.xz);

    // Select the same tri-planar rock projection used by the detailed material.
    vec2 rock_world;
    if (abs(normal.x) > abs(normal.y) && abs(normal.x) > abs(normal.z)) {
        rock_world = world_position.zy;
    } else if (abs(normal.z) > abs(normal.y)) {
        rock_world = world_position.xy;
    } else {
        rock_world = world_position.xz;
    }

    // Fragment processor functions cannot use an early return in Godot shading
    // language. Route the coarse far-distance material and detailed material through
    // mutually exclusive branches so the far LOD is not overwritten afterwards.
    if (camera_distance >= 1780.0) {
        float far_transition_noise = (value_noise(world_position.xz * 0.0038 + vec2(5.4)) - 0.5) * 0.055;
        float far_rock_amount = smoothstep(
            rock_transition_start,
            rock_transition_end,
            slope + far_transition_noise
        );
        ALBEDO = mix(
            distant_grass_color(world_position.xz),
            distant_rock_color(rock_world),
            far_rock_amount
        );
        ROUGHNESS = mix(0.95, 0.86, far_rock_amount);
    } else {
        float transition_noise = (value_noise(world_position.xz * 0.008 + vec2(5.4)) - 0.5) * 0.10;
        float rock_amount = smoothstep(
            rock_transition_start,
            rock_transition_end,
            slope + transition_noise
        );

        vec2 grass_cell = floor(world_position.xz / pixel_size);
        vec2 grass_world = grass_cell * pixel_size;
        vec3 grass_color = grass_pixel(grass_cell, grass_world);
        vec2 rock_cell = floor(rock_world / pixel_size);
        vec2 rock_pixel_world = rock_cell * pixel_size;
        vec3 rock_color = rock_pixel(rock_cell, rock_pixel_world);
        vec3 detailed_color = mix(grass_color, rock_color, rock_amount);

        // Only calculate and blend the macro-color material within the LOD transition.
        float far_blend = smoothstep(920.0, 1780.0, camera_distance);
        if (camera_distance > 920.0) {
            float far_transition_noise = (value_noise(world_position.xz * 0.0038 + vec2(5.4)) - 0.5) * 0.055;
            float far_rock_amount = smoothstep(
                rock_transition_start,
                rock_transition_end,
                slope + far_transition_noise
            );
            vec3 distant_color = mix(
                distant_grass_color(world_position.xz),
                distant_rock_color(rock_world),
                far_rock_amount
            );
            ALBEDO = mix(detailed_color, distant_color, far_blend);
            ROUGHNESS = mix(0.95, 0.84, mix(rock_amount, far_rock_amount, far_blend));
        } else {
            ALBEDO = detailed_color;
            ROUGHNESS = mix(0.95, 0.84, rock_amount);
        }
    }
    METALLIC = 0.0;
}
