shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// World-locked material: every color cell is generated from coordinates and the world seed.
// No bitmap textures, imported rocks, repeating tiles, or editor-only dependencies are used.
// Four times smaller procedural color cells (~0.2875 m instead of 1.15 m).
uniform float pixel_size : hint_range(0.1, 3.0, 0.025) = 0.2875;
uniform float seed_offset = 0.0;
uniform float seed_offset_high = 0.0;
uniform float rock_transition_start : hint_range(0.05, 0.8, 0.01) = 0.30;
uniform float rock_transition_end : hint_range(0.1, 0.95, 0.01) = 0.48;

// Stylized PBR response derived from each generated rock pixel's linear luminance.
uniform float rock_luminance_dark : hint_range(0.0, 0.5, 0.005) = 0.045;
uniform float rock_luminance_bright : hint_range(0.05, 0.8, 0.005) = 0.24;
uniform float rock_roughness_dark : hint_range(0.0, 1.0, 0.01) = 0.92;
uniform float rock_roughness_bright : hint_range(0.0, 1.0, 0.01) = 0.74;
uniform float rock_specular_dark : hint_range(0.0, 1.0, 0.01) = 0.08;
uniform float rock_specular_bright : hint_range(0.0, 1.0, 0.01) = 0.27;

uniform float grass_luminance_dark : hint_range(0.0, 0.2, 0.005) = 0.025;
uniform float grass_luminance_bright : hint_range(0.01, 0.3, 0.005) = 0.10;
uniform float grass_roughness_dark : hint_range(0.0, 1.0, 0.01) = 0.96;
uniform float grass_roughness_bright : hint_range(0.0, 1.0, 0.01) = 0.86;
uniform float grass_specular_dark : hint_range(0.0, 1.0, 0.01) = 0.035;
uniform float grass_specular_bright : hint_range(0.0, 1.0, 0.01) = 0.13;

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
    float p = clamp(pick, 0.0, 1.0);
    vec3 c0 = palette_color(vec3(0.265, 0.265, 0.260));
    vec3 c1 = palette_color(vec3(0.335, 0.335, 0.325));
    vec3 c2 = palette_color(vec3(0.405, 0.400, 0.385));
    vec3 c3 = palette_color(vec3(0.470, 0.465, 0.445));
    vec3 c4 = palette_color(vec3(0.535, 0.525, 0.495));
    vec3 c5 = palette_color(vec3(0.595, 0.580, 0.545));
    vec3 c6 = palette_color(vec3(0.655, 0.635, 0.590));
    vec3 c7 = palette_color(vec3(0.715, 0.690, 0.635));
    if (p < 0.16) return mix(c0, c1, smoothstep(0.0, 0.16, p));
    if (p < 0.32) return mix(c1, c2, smoothstep(0.16, 0.32, p));
    if (p < 0.49) return mix(c2, c3, smoothstep(0.32, 0.49, p));
    if (p < 0.66) return mix(c3, c4, smoothstep(0.49, 0.66, p));
    if (p < 0.82) return mix(c4, c5, smoothstep(0.66, 0.82, p));
    if (p < 0.94) return mix(c5, c6, smoothstep(0.82, 0.94, p));
    return mix(c6, c7, smoothstep(0.94, 1.0, p));
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
    // Broad, organically warped color masses replace hard dark pits and polygon cracks.
    // The per-cell seed still adds a tiny amount of color variation, never a tiled bitmap.
    vec2 broad_warp = (vec2(
        value_noise(pixel_world * 0.0031 + vec2(3.3, 8.1)),
        value_noise(pixel_world * 0.0037 + vec2(19.7, 2.4))
    ) - 0.5) * 76.0;
    vec2 warped = pixel_world + broad_warp;

    float broad_tone = value_noise(
        warped * vec2(0.0032, 0.0047) + vec2(17.2, seed_offset_high * 0.00015)
    );
    float mineral_flow = value_noise(
        warped * vec2(0.0085, 0.0180) + vec2(seed_offset * 0.0002, 6.1)
    );
    float fine_tone = value_noise(
        warped * 0.032 + vec2(12.6, seed_offset * 0.0004)
    );
    float random_cell = hash21(pixel_cell + vec2(0.0, 21.8));

    // Tonal variation is mostly continuous noise; the pixel hash is deliberately subtle.
    float pick = clamp(
        0.47
        + (broad_tone - 0.5) * 0.43
        + (mineral_flow - 0.5) * 0.28
        + (fine_tone - 0.5) * 0.075
        + (random_cell - 0.5) * 0.055,
        0.025, 0.975
    );
    vec3 color = rock_palette(pick);

    float layer_tone = smoothstep(
        0.16, 0.86,
        value_noise(warped * vec2(0.0044, 0.0155) + vec2(6.1, seed_offset * 0.00013))
    );
    float stone_brightness = clamp(
        0.91
        + (broad_tone - 0.5) * 0.22
        + (mineral_flow - 0.5) * 0.13
        + (fine_tone - 0.5) * 0.035,
        0.73, 1.0
    );
    float stone_warmth = value_noise(
        warped * vec2(0.0020, 0.0034) + vec2(31.3, 8.4)
    );
    vec3 cool_tint = vec3(0.91, 0.94, 0.98);
    vec3 warm_tint = vec3(1.045, 1.015, 0.965);
    vec3 smooth_tint = mix(
        cool_tint, warm_tint,
        smoothstep(0.25, 0.78, stone_warmth) * 0.68
    );
    color *= smooth_tint * stone_brightness;

    // Small, soft erosion marks: no hard-edged Voronoi cells or large black blotches.
    float erosion = smoothstep(
        0.78, 0.96,
        value_noise(warped * 0.055 + vec2(7.0, seed_offset * 0.0007))
    );
    color = mix(color, color * vec3(0.77, 0.78, 0.77), erosion * 0.12);
    float mineral_lift = smoothstep(
        0.74, 0.94,
        value_noise(warped * 0.041 + vec2(27.0, 4.0))
    );
    color = mix(color, color * vec3(1.05, 1.04, 1.02), mineral_lift * 0.12);
    color *= mix(vec3(0.985, 0.99, 1.0), vec3(1.012, 1.006, 0.99), layer_tone * 0.75);
    return color;
}


float rock_luminance(vec3 color) {
    return dot(max(color, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
}

// Rock PBR follows broad tonal changes instead of amplifying each dark speckle.
vec2 rock_pbr(vec3 color) {
    float brightness = smoothstep(rock_luminance_dark, rock_luminance_bright, rock_luminance(color));
    return vec2(
        mix(rock_roughness_dark, rock_roughness_bright, brightness),
        mix(rock_specular_dark, rock_specular_bright, brightness)
    );
}

// Grass has a weaker sheen: mostly diffuse with only a subtle response on brighter blades.
vec2 grass_pbr(vec3 color) {
    float brightness = smoothstep(grass_luminance_dark, grass_luminance_bright, rock_luminance(color));
    return vec2(
        mix(grass_roughness_dark, grass_roughness_bright, brightness),
        mix(grass_specular_dark, grass_specular_bright, brightness)
    );
}

// Distance LOD for procedural materials:// Distance LOD for procedural materials: broad continuous colors replace tiny pixel cells,
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

    vec2 rock_world;
    if (abs(normal.x) > abs(normal.y) && abs(normal.x) > abs(normal.z)) {
        rock_world = world_position.zy;
    } else if (abs(normal.z) > abs(normal.y)) {
        rock_world = world_position.xy;
    } else {
        rock_world = world_position.xz;
    }

    // Broaden the grass-to-rock blend. Only a gentle, low-frequency perturbation
    // remains, so the transition doesn't break into sharp islands or polygon-like edges.
    if (camera_distance >= 650.0) {
        float far_transition_noise =
            (value_noise(world_position.xz * 0.0019 + vec2(5.4)) - 0.5) * 0.028;
        float far_rock_amount = smoothstep(
            rock_transition_start, rock_transition_end, slope + far_transition_noise
        );
        vec3 far_grass = distant_grass_color(world_position.xz);
        vec3 far_rock = distant_rock_color(rock_world);
        vec2 grass_material = grass_pbr(far_grass);
        vec2 rock_material = rock_pbr(far_rock);
        ALBEDO = mix(far_grass, far_rock, far_rock_amount);
        ROUGHNESS = mix(grass_material.x, rock_material.x, far_rock_amount);
        SPECULAR = mix(grass_material.y, rock_material.y, far_rock_amount);
    } else {
        float transition_noise =
            (value_noise(world_position.xz * 0.0036 + vec2(5.4)) - 0.5) * 0.045;
        float rock_amount = smoothstep(
            rock_transition_start, rock_transition_end, slope + transition_noise
        );

        vec2 grass_cell = floor(world_position.xz / pixel_size);
        vec2 grass_world = grass_cell * pixel_size;
        vec3 grass_color = grass_pixel(grass_cell, grass_world);
        vec2 rock_cell = floor(rock_world / pixel_size);
        vec2 rock_pixel_world = rock_cell * pixel_size;
        vec3 rock_color = rock_pixel(rock_cell, rock_pixel_world);
        vec3 detailed_color = mix(grass_color, rock_color, rock_amount);
        vec2 detailed_grass_pbr = grass_pbr(grass_color);
        vec2 detailed_rock_pbr = rock_pbr(rock_color);
        vec2 detailed_pbr = mix(detailed_grass_pbr, detailed_rock_pbr, rock_amount);

        // Small procedural pixels merge into broad color masses as the camera moves away.
        float far_blend = smoothstep(160.0, 650.0, camera_distance);
        if (camera_distance > 160.0) {
            float far_transition_noise =
                (value_noise(world_position.xz * 0.0019 + vec2(5.4)) - 0.5) * 0.028;
            float far_rock_amount = smoothstep(
                rock_transition_start, rock_transition_end, slope + far_transition_noise
            );
            vec3 distant_grass = distant_grass_color(world_position.xz);
            vec3 distant_rock = distant_rock_color(rock_world);
            vec3 distant_color = mix(distant_grass, distant_rock, far_rock_amount);
            vec2 distant_grass_pbr = grass_pbr(distant_grass);
            vec2 distant_rock_pbr = rock_pbr(distant_rock);
            vec2 distant_pbr = mix(distant_grass_pbr, distant_rock_pbr, far_rock_amount);
            ALBEDO = mix(detailed_color, distant_color, far_blend);
            ROUGHNESS = mix(detailed_pbr.x, distant_pbr.x, far_blend);
            SPECULAR = mix(detailed_pbr.y, distant_pbr.y, far_blend);
        } else {
            ALBEDO = detailed_color;
            ROUGHNESS = detailed_pbr.x;
            SPECULAR = detailed_pbr.y;
        }
    }
    METALLIC = 0.0;
}
