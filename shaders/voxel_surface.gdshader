shader_type spatial;
render_mode diffuse_burley, cull_back, specular_schlick_ggx;

uniform float seed_low = 240518.0;
uniform float seed_high = 0.0;
uniform bool debug_lod_colors = false;
uniform vec4 skirt_visibility = vec4(1.0);
uniform float lod_shadow_strength : hint_range(0.0, 1.0, 0.05) = 1.0;
uniform int lod_index = 0;

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 view_up_direction;

vec3 palette_color(vec3 srgb) {
    return pow(srgb, vec3(2.2));
}

float hash21(vec2 p) {
    vec2 seed_shift = vec2(
        fract(seed_low * 0.000017 + seed_high * 0.000071),
        fract(seed_low * 0.000053 + seed_high * 0.000029)
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

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world, float crack_weight) {
    // Main's richer stochastic palette and broad, natural tonal drift. Directional mineral
    // bands and extra fissure overlays are intentionally omitted; retain the current Voronoi cracks.
    float broad_tone = value_noise(pixel_world * 0.021 + vec2(13.8, seed_low * 0.0006));
    float random_cell = hash21(pixel_cell + vec2(0.0, 21.8));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.19, 0.001, 0.999);
    vec3 base_color = rock_palette(pick);
    float broad_stone_tone = value_noise(pixel_world * 0.0019 + vec2(17.2, seed_high * 0.00015));
    float mountain_macro_tone = value_noise(pixel_world * 0.00082 + vec2(
        17.2 + seed_low * 0.00011, 8.4 + seed_high * 0.00019
    ));
    float stone_brightness = clamp(
        0.82 + (broad_stone_tone - 0.5) * 0.25
        + (mountain_macro_tone - 0.5) * 0.14, 0.68, 1.0
    );
    float stone_warmth = value_noise(pixel_world * vec2(0.0025, 0.0060) + vec2(31.3, 8.4));
    vec3 cool_tint = mix(vec3(0.78, 0.84, 0.94), vec3(1.02, 1.02, 0.99), stone_warmth);
    vec3 warm_tint = mix(vec3(0.88, 0.84, 0.77), vec3(1.08, 1.045, 0.98), stone_warmth);
    vec3 smooth_tint = mix(cool_tint, warm_tint, smoothstep(0.18, 0.82, stone_warmth) * 0.62);
    base_color *= smooth_tint * stone_brightness;
    if (crack_weight <= 0.001) return base_color;

    // Gently warp the cellular field, so crack paths are irregular rather than straight
    // or aligned into bands. Both fields are continuous world-space functions.
    vec2 warp = (vec2(
        value_noise(pixel_world * 0.024 + vec2(3.3, 8.1)),
        value_noise(pixel_world * 0.021 + vec2(19.7, 2.4))
    ) - 0.5) * 2.6;
    vec2 crack_world = pixel_world + warp;

    float micro_edge = voronoi_edge(crack_world / 5.5 + vec2(seed_low * 0.0008, 6.7));
    float broad_edge = voronoi_edge(crack_world / 13.0 + vec2(19.4, seed_high * 0.0007));

    // Width is locally varied by smooth noise. The crack's visibility also fades with
    // continuous noise, letting segments emerge and taper away without hard cut-off ends.
    float micro_width_noise = value_noise(crack_world * 0.11 + vec2(7.4, seed_low * 0.0003));
    float broad_width_noise = value_noise(crack_world * 0.047 + vec2(15.2, seed_high * 0.0005));
    float micro_width = mix(0.018, 0.060, micro_width_noise);
    float broad_width = mix(0.020, 0.075, broad_width_noise);

    float micro_lifetime_noise = value_noise(crack_world * 0.095 + vec2(29.1, seed_low * 0.0004));
    float broad_lifetime_noise = value_noise(crack_world * 0.042 + vec2(3.7, seed_high * 0.0006));
    float micro_lifetime = smoothstep(0.24, 0.72, micro_lifetime_noise);
    float broad_lifetime = smoothstep(0.30, 0.76, broad_lifetime_noise);

    // Keep each smoothstep on one line with explicit intermediate values.
    float micro_edge_limit = micro_width + 0.035;
    float broad_edge_limit = broad_width + 0.030;
    float micro_falloff = smoothstep(micro_width, micro_edge_limit, micro_edge);
    float broad_falloff = smoothstep(broad_width, broad_edge_limit, broad_edge);
    float micro_crack = (1.0 - micro_falloff) * micro_lifetime;
    float broad_crack = (1.0 - broad_falloff) * broad_lifetime;

    // Use a muted dark stone colour and preserve some base pixels through each crack.
    // The overlapping scales yield varied cracks without heavy bands across a mountain.
    float crack_strength = clamp(micro_crack * 0.50 + broad_crack * 0.62, 0.0, 0.78);
    float normalized_crack_weight = clamp(crack_weight, 0.0, 1.0);
    float final_crack_strength = crack_strength * normalized_crack_weight;
    vec3 crack_color = palette_color(vec3(0.105, 0.112, 0.112));
    return mix(base_color, crack_color, final_crack_strength);
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

vec3 voxel_lod_rock_color(vec2 world_xz, float cell_size) {
    vec2 cell = floor(world_xz / cell_size);
    vec2 center = (cell + vec2(0.5)) * cell_size;
    float cell_tone = hash21(cell + vec2(19.7, 3.9));
    float broad_tone = value_noise(center * vec2(0.0047, 0.0063)
        + vec2(13.2, seed_high * 0.00011));
    float pick = clamp(0.10 + cell_tone * 0.74 + (broad_tone - 0.5) * 0.18, 0.001, 0.999);
    vec3 color = rock_palette(pick);
    float warmth = hash21(cell + vec2(41.3, 12.7));
    return color * mix(vec3(0.88, 0.92, 0.98), vec3(1.0, 0.985, 0.94), warmth);
}

vec3 voxel_lod_soil_color(vec2 world_xz, float cell_size) {
    vec2 cell = floor(world_xz / cell_size);
    vec2 center = (cell + vec2(0.5)) * cell_size;
    float cell_tone = hash21(cell + vec2(5.7, 26.1));
    float broad_tone = value_noise(center * 0.008 + vec2(9.2, seed_low * 0.00009));
    float pick = clamp(0.10 + cell_tone * 0.78 + (broad_tone - 0.5) * 0.16, 0.001, 0.999);
    return soil_palette(pick);
}

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
    view_up_direction = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
    // Vertex colour alpha is stored as an 8-bit channel. Decode integer codes,
    // not narrow float ranges: this leaves a safe gap between skirts, side tops and tops.
    float alpha_code = floor(COLOR.a * 255.0 + 0.5);
    if (alpha_code < 238.0) {
        float edge_visible = skirt_visibility.x;
        if (alpha_code >= 209.0 && alpha_code < 219.0) {
            edge_visible = skirt_visibility.y;
        } else if (alpha_code >= 219.0 && alpha_code < 230.0) {
            edge_visible = skirt_visibility.z;
        } else if (alpha_code >= 230.0) {
            edge_visible = skirt_visibility.w;
        }
        if (edge_visible < 0.5) discard;
    }

    // Derivatives are valid here. Estimate the 10 cm riser footprint once and smooth
    // its lighting normal before the light pass, without any MSAA 4x full-screen cost.
    float world_units_per_pixel = 0.0;
    if (lod_index < 3) {
        world_units_per_pixel = max(length(dFdx(world_position)), length(dFdy(world_position)));
        float riser_pixels = 0.1 / max(world_units_per_pixel, 0.001);
        float subpixel_riser_weight = 1.0 - smoothstep(0.65, 1.35, riser_pixels);
        float side_face_weight = 1.0 - smoothstep(0.15, 0.45, abs(normalize(world_normal).y));
        NORMAL = normalize(mix(normalize(NORMAL), view_up_direction,
            side_face_weight * subpixel_riser_weight * 0.85));
    }

    vec3 normal = normalize(world_normal);
    bool is_top_surface = alpha_code >= 246.0 && alpha_code <= 253.0;
    bool is_surface_side = alpha_code >= 240.0 && alpha_code < 246.0;
    float top_rock_amount = 0.0;
    if (is_top_surface) {
        top_rock_amount = clamp((alpha_code - 246.0) / 6.0, 0.0, 1.0);
    } else if (is_surface_side) {
        top_rock_amount = clamp((alpha_code - 240.0) / 5.0, 0.0, 1.0);
    }
    // Use one world-space XZ projection for upper sides and top faces. This keeps
    // their procedural palette aligned at the edge instead of changing with face normal.
    vec2 rock_world = world_position.xz;

    if (debug_lod_colors) {
        if (lod_index == 0) {
            ALBEDO = vec3(0.93, 0.28, 0.28);
        } else if (lod_index == 1) {
            ALBEDO = vec3(0.91, 0.63, 0.18);
        } else if (lod_index == 2) {
            ALBEDO = vec3(0.21, 0.79, 0.70);
        } else if (lod_index == 3) {
            ALBEDO = vec3(0.33, 0.49, 0.91);
        } else if (lod_index == 4) {
            ALBEDO = vec3(0.69, 0.42, 0.88);
        } else if (lod_index == 5) {
            ALBEDO = vec3(0.92, 0.34, 0.71);
        } else {
            ALBEDO = vec3(0.35, 0.74, 0.92);
        }
        ROUGHNESS = 0.96;
    } else if (lod_index >= 3) {
        // Keep a deterministic colour per voxel at every distance. Only the palette detail
        // simplifies with LOD: the cell size follows the same 10 cm-to-12.8 m voxel ladder.
        float lod_voxel_size = 0.1 * exp2(float(clamp(lod_index, 0, 7)));
        if (is_top_surface || is_surface_side) {
            ALBEDO = mix(
                voxel_lod_grass_color(world_position.xz, lod_voxel_size),
                voxel_lod_rock_color(rock_world, lod_voxel_size),
                top_rock_amount
            );
            ROUGHNESS = mix(0.95, 0.84, top_rock_amount);
        } else if (COLOR.g > COLOR.r * 1.35) {
            ALBEDO = voxel_lod_grass_color(world_position.xz, lod_voxel_size);
            ROUGHNESS = 0.95;
        } else if (COLOR.r > COLOR.g * 1.15) {
            ALBEDO = voxel_lod_soil_color(world_position.xz, lod_voxel_size);
            ROUGHNESS = 0.91;
        } else {
            ALBEDO = voxel_lod_rock_color(rock_world, lod_voxel_size);
            ROUGHNESS = 0.84;
        }
    } else {
        // The voxel colour is sampled on the current LOD's cell lattice, without fading
        // to a uniform distance colour. Only fine rock cracks fade when they become sub-pixel.
        float lod_voxel_size = 0.1 * exp2(float(clamp(lod_index, 0, 7)));
        float rock_crack_footprint = world_units_per_pixel / 5.5;
        float rock_crack_weight = 1.0 - smoothstep(0.55, 1.25, rock_crack_footprint);

        if (is_top_surface || is_surface_side) {
            vec2 pixel_cell = floor(rock_world / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = mix(
                grass_pixel(pixel_cell, pixel_world),
                rock_pixel(pixel_cell, pixel_world, rock_crack_weight),
                top_rock_amount
            );
            ROUGHNESS = mix(0.95, 0.84, top_rock_amount);
        } else if (COLOR.g > COLOR.r * 1.35) {
            vec2 pixel_cell = floor(world_position.xz / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = grass_pixel(pixel_cell, pixel_world);
            ROUGHNESS = 0.95;
        } else if (COLOR.r > COLOR.g * 1.15) {
            vec2 pixel_cell = floor(world_position.xz / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            float pixel_variation = hash21(pixel_cell);
            float broad_tone = value_noise(pixel_world * 0.035);
            ALBEDO = soil_palette(0.30 + pixel_variation * 0.48 + (broad_tone - 0.5) * 0.12);
            ROUGHNESS = 0.91;
        } else {
            vec2 pixel_cell = floor(rock_world / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = rock_pixel(pixel_cell, pixel_world, rock_crack_weight);
            ROUGHNESS = 0.84;
        }
    }
    METALLIC = 0.0;
}

// Blend directional shadow attenuation per LOD while preserving the base albedo.
void light() {
    vec3 light_normal = normalize(NORMAL);
    float side_face_weight = 1.0 - smoothstep(0.15, 0.45, abs(normalize(world_normal).y));
    float direct_attenuation = ATTENUATION;
    if (LIGHT_IS_DIRECTIONAL) {
        // The smooth heightfield proxy casts landform shadows. Vertical voxel risers don't
        // receive shadow attenuation, preventing dark checkerboard bands at long distance.
        direct_attenuation = side_face_weight > 0.5
            ? 1.0
            : mix(1.0, ATTENUATION, clamp(lod_shadow_strength, 0.0, 1.0));
    }
    if (LIGHT_IS_AREA) {
        DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * direct_attenuation * LIGHT_COLOR;
        SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * direct_attenuation * LIGHT_COLOR * SPECULAR_AMOUNT;
    } else {
        float ndotl = clamp(dot(light_normal, LIGHT), 0.0, 1.0);
        DIFFUSE_LIGHT += ndotl * direct_attenuation * LIGHT_COLOR / PI;
        vec3 half_vector = normalize(LIGHT + VIEW);
        float roughness = clamp(ROUGHNESS, 0.04, 1.0);
        float specular_lobe = pow(max(dot(light_normal, half_vector), 0.0), mix(128.0, 4.0, roughness));
        SPECULAR_LIGHT += specular_lobe * direct_attenuation * LIGHT_COLOR
            * SPECULAR_AMOUNT * (1.0 - roughness) * 0.08;
    }
}
