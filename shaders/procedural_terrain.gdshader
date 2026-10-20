shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// World-locked material: every color cell is generated from coordinates and the world seed.
// No bitmap textures, imported rocks, repeating tiles, or editor-only dependencies are used.
uniform float pixel_size : hint_range(0.1, 3.0, 0.025) = 0.2875;
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

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world) {
    // Procedural height-blending inspired by layered terrain materials:
    // each stone tone has a color, a soft coverage mask, and a generated height.
    // All fields are world-locked and the final result is still snapped to pixel_cell.
    vec2 warp = (vec2(
        value_noise(pixel_world * 0.0037 + vec2(3.3, 8.1)),
        value_noise(pixel_world * 0.0041 + vec2(19.7, 2.4))
    ) - 0.5) * 24.0;
    vec2 warped = pixel_world + warp;

    float broad_tone = value_noise(
        warped * vec2(0.0032, 0.0041) + vec2(17.2, seed_offset_high * 0.00015)
    );
    float mineral_tone = value_noise(
        warped * vec2(0.0075, 0.0135) + vec2(seed_offset * 0.0002, 6.1)
    );
    float grain_tone = value_noise(
        warped * vec2(0.021, 0.028) + vec2(12.6, seed_offset * 0.0004)
    );
    float cell_variation = hash21(pixel_cell + vec2(0.0, 21.8));

    // The base layer stays close to a natural grey stone palette. Random pixel
    // variation is intentionally subtle so isolated dark cells cannot dominate.
    float base_pick = clamp(
        0.43
        + (broad_tone - 0.5) * 0.20
        + (mineral_tone - 0.5) * 0.16
        + (grain_tone - 0.5) * 0.06
        + (cell_variation - 0.5) * 0.035,
        0.12, 0.88
    );
    vec3 base_color = rock_palette(base_pick);

    float warmth = value_noise(
        warped * vec2(0.0022, 0.0031) + vec2(31.3, 8.4)
    );
    vec3 cool_tint = vec3(0.91, 0.94, 0.98);
    vec3 warm_tint = vec3(1.045, 1.015, 0.965);
    base_color *= mix(cool_tint, warm_tint, smoothstep(0.24, 0.80, warmth) * 0.58);
    base_color *= 0.94 + broad_tone * 0.11;

    // Generate three virtual layers: base stone, darker mineral seams, and pale
    // worn facets. Smooth noise replaces hard masks / hand-authored tile patterns.
    float seam_field = value_noise(
        warped * vec2(0.0060, 0.0170) + vec2(5.4, seed_offset * 0.00031)
    );
    float seam_coverage = smoothstep(0.48, 0.78, seam_field) * 0.44;
    float pale_field = value_noise(
        warped * vec2(0.012, 0.023) + vec2(23.7, seed_offset_high * 0.0002)
    );
    float pale_coverage = smoothstep(0.67, 0.88, pale_field) * 0.34;

    vec3 dark_color = base_color * vec3(0.78, 0.79, 0.80);
    vec3 pale_color = mix(
        base_color,
        palette_color(vec3(0.635, 0.615, 0.575)),
        0.42
    );

    // "Height blend": layer height + coverage determines which tones sit on top.
    // A small overlap depth allows neighboring layers to mix instead of forming edges.
    float base_height = 0.42 + broad_tone * 0.18;
    float seam_height = 0.25 + seam_field * 0.29;
    float pale_height = 0.31 + pale_field * 0.25;
    float base_score = base_height + 0.39;
    float seam_score = seam_height + seam_coverage;
    float pale_score = pale_height + pale_coverage;
    float blend_depth = 0.32;
    float top_height = max(max(base_score, seam_score), pale_score) - blend_depth;

    float base_weight = max(base_score - top_height, 0.0);
    float seam_weight = max(seam_score - top_height, 0.0);
    float pale_weight = max(pale_score - top_height, 0.0);
    float total_weight = max(base_weight + seam_weight + pale_weight, 0.0001);

    vec3 color = (
        base_color * base_weight
        + dark_color * seam_weight
        + pale_color * pale_weight
    ) / total_weight;

    // Very restrained fine grain adds pixel-to-pixel character without black pits.
    float fine_variation = (grain_tone - 0.5) * 0.055 + (cell_variation - 0.5) * 0.025;
    color *= 1.0 + fine_variation;
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
