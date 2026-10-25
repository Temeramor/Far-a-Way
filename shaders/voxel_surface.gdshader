shader_type spatial;
render_mode diffuse_burley, cull_back;

uniform float pixel_size : hint_range(0.1, 1.2, 0.05) = 0.1;
uniform float seed_low = 240518.0;
uniform float seed_high = 0.0;
uniform bool debug_lod_colors = false;
uniform vec4 skirt_visibility = vec4(1.0);
uniform float voxel_detail_filter_multiplier : hint_range(0.0, 2.0, 0.1) = 1.0;
uniform float rock_crack_filter_multiplier : hint_range(0.0, 2.0, 0.1) = 1.0;
uniform bool procedural_mipmap_enabled = true;

varying vec3 world_position;
varying vec3 world_normal;

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

// Continuous transitions between the Neverland swatches prevent harsh colour steps
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
    float broad_tone = value_noise(pixel_world * 0.027 + vec2(seed_low * 0.0003, 4.2));
    float random_cell = hash21(pixel_cell + vec2(0.0, 7.7));
    // Narrow random variation keeps adjacent 10 cm cells in a calmer colour range.
    float pick = clamp(0.36 + random_cell * 0.28 + (broad_tone - 0.5) * 0.08, 0.001, 0.999);
    vec3 color = grass_palette(pick);

    float fleck = hash21(pixel_cell + vec2(81.2, 18.4));
    if (fleck > 0.996) {
        color = mix(color, palette_color(vec3(0.741, 0.741, 0.467)), 0.24);
    } else if (fleck < 0.008) {
        color = mix(color, palette_color(vec3(0.275, 0.290, 0.173)), 0.22);
    }
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
    // Base rock remains the original Neverland pixel palette. No mineral bands,
    // vertical fissure overlays, chips, pitting or broad warm/cool tint layers.
    float broad_tone = value_noise(pixel_world * 0.021 + vec2(13.8, seed_low * 0.0006));
    float random_cell = hash21(pixel_cell + vec2(0.0, 21.8));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.12, 0.001, 0.999);
    vec3 base_color = rock_palette(pick);

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

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    // Skirt faces use special vertex alpha tags; hide them only when the neighbour is ready at the same LOD.
    if (COLOR.a < 0.95) {
        float edge_code = floor((COLOR.a - 0.80) * 25.0 + 0.5);
        float edge_visible = skirt_visibility.x;
        if (edge_code > 0.5 && edge_code < 1.5) {
            edge_visible = skirt_visibility.y;
        } else if (edge_code > 1.5 && edge_code < 2.5) {
            edge_visible = skirt_visibility.z;
        } else if (edge_code > 2.5) {
            edge_visible = skirt_visibility.w;
        }
        if (edge_visible < 0.5) {
            discard;
        }
    }
    vec3 normal = normalize(world_normal);
    // 0.1 m texel cells align with the voxel grid and remain world-locked across chunks.
    // Quantise a point slightly inside the voxel, so top and side faces share one colour cell.
    vec3 voxel_cell_3d = floor((world_position - normal * 0.001) / max(pixel_size, 0.1));
    vec3 voxel_center_world = (voxel_cell_3d + vec3(0.5)) * max(pixel_size, 0.1);
    // The packed 2D cell is only a deterministic hash key; spatial noise uses real X/Z metres.
    vec2 pixel_cell = vec2(voxel_cell_3d.x + voxel_cell_3d.y * 37.0,
                           voxel_cell_3d.z + voxel_cell_3d.y * 17.0);
    vec2 pixel_center = voxel_center_world.xz;
    float broad_tone = value_noise(pixel_center * 0.035 + vec2(seed_low * 0.0002, 8.3));
    float pixel_variation = hash21(pixel_cell + vec2(0.0, 7.7));
    float pick = clamp(0.40 + pixel_variation * 0.22 + (broad_tone - 0.5) * 0.08, 0.001, 0.999);

    // Screen-space filtering: estimate how many 10 cm voxel-colour cells fit into one
    // pixel. Once cells become sub-pixel, fade their random colour toward the material's
    // mean instead of changing to a spatially varying low-frequency patch pattern.
    // MSAA cannot filter this shader-generated colour noise because it shades per pixel.
    float world_units_per_pixel = max(
        length(dFdx(world_position)),
        length(dFdy(world_position))
    );
    float voxel_footprint = world_units_per_pixel / max(pixel_size, 0.1);
    float voxel_detail_weight = 1.0;
    if (procedural_mipmap_enabled && voxel_detail_filter_multiplier > 0.001) {
        voxel_detail_weight = 1.0 - smoothstep(0.70, 1.55, voxel_footprint * voxel_detail_filter_multiplier);
    }

    // Voronoi rock cracks have a larger 5.5 m cell size; fade them separately when that
    // pattern itself becomes sub-pixel, even if the voxel-colour cells are still visible.
    float rock_crack_footprint = world_units_per_pixel / 5.5;
    float rock_crack_weight = 1.0;
    if (procedural_mipmap_enabled && rock_crack_filter_multiplier > 0.001) {
        rock_crack_weight = 1.0 - smoothstep(0.55, 1.25, rock_crack_footprint * rock_crack_filter_multiplier);
    }
    float rock_detail_weight = voxel_detail_weight;

    if (debug_lod_colors) {
        float variation = mix(0.96, 1.04, pixel_variation);
        ALBEDO = clamp(COLOR.rgb * variation, vec3(0.0), vec3(1.0));
    } else if (COLOR.g > COLOR.r * 1.35) {
        // Preserve the pixel material up close. At distance it converges to a stable
        // average green, avoiding visible checkerboard and false colour islands.
        vec3 filtered_grass = grass_palette(0.52);
        if (voxel_detail_weight > 0.005) {
            ALBEDO = mix(filtered_grass, grass_pixel(pixel_cell, pixel_center), voxel_detail_weight);
        } else {
            ALBEDO = filtered_grass;
        }
    } else if (COLOR.r > COLOR.g * 1.15) {
        vec3 filtered_soil = soil_palette(0.53);
        if (voxel_detail_weight > 0.005) {
            vec3 detailed_soil = soil_palette(pick) * mix(0.97, 1.03, broad_tone);
            ALBEDO = mix(filtered_soil, detailed_soil, voxel_detail_weight);
        } else {
            ALBEDO = filtered_soil;
        }
    } else {
        vec3 filtered_rock = rock_palette(0.46);
        if (rock_detail_weight > 0.005) {
            ALBEDO = mix(filtered_rock, rock_pixel(pixel_cell, pixel_center, rock_crack_weight), rock_detail_weight);
        } else {
            ALBEDO = filtered_rock;
        }
    }
    // Keep Godot's interpolated mesh normal. Near voxel faces need their original
    // directional light response to preserve the blocky relief; far shadow casting is
    // controlled per LOD, with a separate top-only proxy preserving the broad terrain shadow.
    ROUGHNESS = 0.96;
}
