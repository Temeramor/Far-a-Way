shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// World-locked material: every color cell is generated from coordinates and the world seed.
// No bitmap textures, imported rocks, repeating tiles, or editor-only dependencies are used.
uniform float pixel_size : hint_range(0.1, 3.0, 0.025) = 0.2875;
uniform float seed_offset = 0.0;
uniform float seed_offset_high = 0.0;
uniform float rock_cell_scale : hint_range(3.0, 16.0, 0.5) = 7.5;
uniform float rock_edge_strength : hint_range(0.2, 1.5, 0.05) = 1.15;
uniform float rock_bump_strength : hint_range(0.0, 3.0, 0.1) = 1.45;
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
    vec3 c0 = palette_color(vec3(0.205, 0.215, 0.220));
    vec3 c1 = palette_color(vec3(0.315, 0.325, 0.330));
    vec3 c2 = palette_color(vec3(0.395, 0.400, 0.400));
    vec3 c3 = palette_color(vec3(0.465, 0.465, 0.455));
    vec3 c4 = palette_color(vec3(0.530, 0.520, 0.505));
    vec3 c5 = palette_color(vec3(0.595, 0.585, 0.560));
    vec3 c6 = palette_color(vec3(0.655, 0.645, 0.610));
    vec3 c7 = palette_color(vec3(0.730, 0.710, 0.665));
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

// F1/F2 cellular field: F1 locates a stone centre, while F2-F1 creates its seam mask.
vec3 cellular_rock_data(vec2 p) {
    vec2 base_cell = floor(p);
    vec2 local_pos = fract(p);
    float nearest_dist2 = 1e6;
    float second_dist2 = 1e6;
    float nearest_hash = 0.5;

    // A 3x3 neighbourhood is sufficient for the jittered Voronoi feature points.
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbour = vec2(float(x), float(y));
            vec2 cell_id = base_cell + neighbour;
            vec2 jitter = vec2(
                hash21(cell_id + vec2(17.1, 4.7)),
                hash21(cell_id + vec2(43.2, 29.8))
            );
            vec2 feature = neighbour + vec2(0.16) + jitter * 0.68;
            vec2 delta = local_pos - feature;
            float dist2 = dot(delta, delta);

            if (dist2 < nearest_dist2) {
                second_dist2 = nearest_dist2;
                nearest_dist2 = dist2;
                nearest_hash = hash21(cell_id + vec2(73.5, 19.3));
            } else if (dist2 < second_dist2) {
                second_dist2 = dist2;
            }
        }
    }

    float f1 = sqrt(max(nearest_dist2, 0.0));
    float f2 = sqrt(max(second_dist2, 0.0));
    return vec3(f1, max(f2 - f1, 0.0), nearest_hash);
}

// Height field used as a procedural normal/bump source.
// The centres of cells form raised, slightly flattened facets; Voronoi boundaries
// are lowered into seams. Several noise scales add coarse and fine erosion.
float rock_height(vec2 world_pos) {
    float cell_width = max(pixel_size * rock_cell_scale, 1.4);
    vec3 cell = cellular_rock_data(world_pos / cell_width);
    float facet_interior = 1.0 - smoothstep(0.10, 0.62, cell.x);
    float seam = 1.0 - smoothstep(0.018, 0.13, cell.y);
    float broad_noise = value_noise(world_pos * 0.11 + vec2(8.1, seed_offset_high * 0.0004));
    float medium_noise = value_noise(world_pos * 0.36 + vec2(seed_offset * 0.0002, 27.3));
    float fine_noise = value_noise(world_pos * 0.92 + vec2(5.7, seed_offset_high * 0.0002));
    float per_cell_relief = (cell.z - 0.5) * 0.18;

    return facet_interior * 0.34 + per_cell_relief - seam * 0.24
        + (broad_noise - 0.5) * 0.20
        + (medium_noise - 0.5) * 0.14
        + (fine_noise - 0.5) * 0.075;
}

// Softly stepped noise loosely follows the article's "soft staircase" filter,
// preserving rounded transitions rather than producing harsh posterized bands.
float soft_step_value(float value, float iterations, float softness) {
    float scaled = clamp(value, 0.0, 0.999) * iterations;
    float step_base = floor(scaled);
    float sub_step = fract(scaled);
    float transition = smoothstep(
        0.5 - softness * 0.5,
        0.5 + softness * 0.5,
        sub_step
    );
    return (step_base + transition) / iterations;
}

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world) {
    // Cellular stone blocks carry different grey/warm-grey values. Multi-scale
    // value noise, softly stepped mineral bands and rare grain specks break up
    // their interiors, without tiled bitmaps or the old polygon-crack helper.
    float cell_width = max(pixel_size * rock_cell_scale, 1.4);
    vec3 cell = cellular_rock_data(pixel_world / cell_width);

    float broad_noise = value_noise(
        pixel_world * 0.065 + vec2(11.7, seed_offset_high * 0.00013)
    );
    float medium_noise = value_noise(
        pixel_world * 0.24 + vec2(seed_offset * 0.0002, 6.1)
    );
    float fine_noise = value_noise(
        pixel_world * 0.78 + vec2(12.6, seed_offset_high * 0.0002)
    );
    float stepped_noise = mix(medium_noise, soft_step_value(medium_noise, 6.0, 0.70), 0.42);
    float micro_noise = hash21(pixel_cell + vec2(81.2, 18.4));

    float palette_pick = clamp(
        0.43
        + (cell.z - 0.5) * 0.74
        + (broad_noise - 0.5) * 0.20
        + (stepped_noise - 0.5) * 0.28
        + (fine_noise - 0.5) * 0.18
        + (micro_noise - 0.5) * 0.10,
        0.055, 0.965
    );
    vec3 color = rock_palette(palette_pick);

    float warmth = value_noise(
        pixel_world * vec2(0.035, 0.052) + vec2(31.3, 8.4)
    );
    vec3 cool_tint = vec3(0.88, 0.92, 0.99);
    vec3 warm_tint = vec3(1.055, 1.015, 0.945);
    color *= mix(cool_tint, warm_tint, smoothstep(0.23, 0.82, warmth) * 0.65);
    color *= 1.0 + (broad_noise - 0.5) * 0.20 + (fine_noise - 0.5) * 0.18;

    // F2-F1 is smallest directly on a cell boundary: make those seams visibly darker.
    float seam_mask = 1.0 - smoothstep(0.018, 0.13, cell.y);
    color *= 1.0 - seam_mask * clamp(rock_edge_strength * 0.62, 0.0, 0.88);

    // Occasional weathered mineral flecks, not a repeated crack pattern.
    float mineral_mask = smoothstep(0.78, 0.96, fine_noise) * 0.18;
    vec3 mineral_color = palette_color(vec3(0.325, 0.315, 0.295));
    color = mix(color, mineral_color, mineral_mask);
    return clamp(color, vec3(0.025), vec3(0.95));
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

    // Reuse the same projection for colour and bump height so the relief follows
    // the tri-planar rock mapping on the top, front and side faces.
    vec2 rock_world;
    float projection_mode = 2.0; // 0 = ZY, 1 = XY, 2 = XZ
    if (abs(normal.x) > abs(normal.y) && abs(normal.x) > abs(normal.z)) {
        rock_world = world_position.zy;
        projection_mode = 0.0;
    } else if (abs(normal.z) > abs(normal.y)) {
        rock_world = world_position.xy;
        projection_mode = 1.0;
    } else {
        rock_world = world_position.xz;
        projection_mode = 2.0;
    }

    float final_rock_amount = 0.0;

    if (camera_distance >= 1780.0) {
        float far_transition_noise = (value_noise(world_position.xz * 0.0038 + vec2(5.4)) - 0.5) * 0.055;
        float far_rock_amount = smoothstep(
            rock_transition_start,
            rock_transition_end,
            slope + far_transition_noise
        );
        final_rock_amount = far_rock_amount;
        ALBEDO = mix(
            distant_grass_color(world_position.xz),
            distant_rock_color(rock_world),
            far_rock_amount
        );
        ROUGHNESS = mix(0.97, 0.93, far_rock_amount);
    } else {
        float transition_noise = (value_noise(world_position.xz * 0.008 + vec2(5.4)) - 0.5) * 0.10;
        float rock_amount = smoothstep(
            rock_transition_start,
            rock_transition_end,
            slope + transition_noise
        );
        final_rock_amount = rock_amount;

        vec2 grass_cell = floor(world_position.xz / pixel_size);
        vec2 grass_world = grass_cell * pixel_size;
        vec3 grass_color = grass_pixel(grass_cell, grass_world);
        vec2 rock_cell = floor(rock_world / pixel_size);
        vec2 rock_pixel_world = rock_cell * pixel_size;
        vec3 rock_color = rock_pixel(rock_cell, rock_pixel_world);
        vec3 detailed_color = mix(grass_color, rock_color, rock_amount);

        // Only blend to the cheaper macro material once its distance LOD is needed.
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
            final_rock_amount = mix(rock_amount, far_rock_amount, far_blend);
            ROUGHNESS = mix(0.97, 0.93, final_rock_amount);
        } else {
            ALBEDO = detailed_color;
            ROUGHNESS = mix(0.97, 0.91, rock_amount);
        }

        // Approximate a normal map directly from the height field. Sampling in
        // world space avoids importing/generated image assets and keeps the relief
        // stable as chunks move through their LODs. The effect fades with the rock mask.
        if (final_rock_amount > 0.06) {
            float bump_step = max(pixel_size * 1.5, 0.38);
            float height_center = rock_height(rock_world);
            float height_x = rock_height(rock_world + vec2(bump_step, 0.0));
            float height_y = rock_height(rock_world + vec2(0.0, bump_step));
            float gradient_x = (height_x - height_center) / bump_step;
            float gradient_y = (height_y - height_center) / bump_step;

            vec3 bump_vector;
            if (projection_mode < 0.5) {
                bump_vector = vec3(0.0, -gradient_y, -gradient_x);
            } else if (projection_mode < 1.5) {
                bump_vector = vec3(-gradient_x, -gradient_y, 0.0);
            } else {
                bump_vector = vec3(-gradient_x, 0.0, -gradient_y);
            }
            vec3 bumped_world_normal = normalize(
                world_normal + bump_vector * rock_bump_strength * final_rock_amount
            );
            NORMAL = normalize((VIEW_MATRIX * vec4(bumped_world_normal, 0.0)).xyz);
        }
    }
    METALLIC = 0.0;
}
