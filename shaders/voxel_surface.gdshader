shader_type spatial;
render_mode diffuse_burley, cull_back, specular_schlick_ggx;

uniform float seed_low = 240518.0;
uniform float seed_high = 0.0;
uniform bool debug_lod_colors = false;
uniform vec4 skirt_visibility = vec4(1.0);
uniform float lod_cell_size = 0.2;
uniform float side_fill : hint_range(0.0, 1.0) = 0.30;
uniform float side_wrap : hint_range(0.0, 1.0) = 0.50;
uniform int lod_index = 0;

// Procedural mountain rock material adapted from examples/mountain texture.html.
uniform float mountain_blocks : hint_range(0.0, 1.5) = 0.25;
uniform float mountain_flutes : hint_range(0.0, 1.5) = 1.1;
uniform float mountain_chips : hint_range(0.0, 1.5) = 0.6;
uniform float mountain_streaks : hint_range(0.0, 1.5) = 0.9;
uniform float mountain_moss : hint_range(0.0, 1.0) = 0.0;
uniform float mountain_relief : hint_range(1.0, 10.0) = 4.0;
uniform float mountain_contrast : hint_range(0.6, 1.8) = 1.1;
uniform float mountain_levels : hint_range(4.0, 24.0, 1.0) = 10.0;
uniform float mountain_dither : hint_range(0.0, 1.0) = 0.5;

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 view_up_direction;
varying float camera_distance;

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




float rock_sm(float t) {
    t = clamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Integer hash and noise functions are kept bit-compatible with the HTML generator.
float rock_h2(int x, int y, int s) {
    uint h = uint(x) * 374761393u ^ uint(y) * 668265263u ^ uint(s) * 2654435761u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= (h >> 16u);
    return min(float(h) / 4294967296.0, 0.99999994);
}

float rock_vnoise(vec2 p, int s) {
    vec2 f0 = floor(p);
    ivec2 i = ivec2(f0);
    vec2 f = p - f0;
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = rock_h2(i.x, i.y, s);
    float b = rock_h2(i.x + 1, i.y, s);
    float c = rock_h2(i.x, i.y + 1, s);
    float d = rock_h2(i.x + 1, i.y + 1, s);
    return a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y;
}

float rock_fbm(vec2 p, int s, int octaves) {
    float amplitude = 0.5;
    float frequency = 1.0;
    float result = 0.0;
    float normalization = 0.0;
    for (int i = 0; i < octaves; i++) {
        result += amplitude * rock_vnoise(p * frequency, s + i * 31);
        normalization += amplitude;
        amplitude *= 0.5;
        frequency *= 2.03;
    }
    return result / max(normalization, 0.0001);
}

struct RockWorley {
    float f1;
    float f2;
    ivec2 cell;
    vec2 delta;
};

RockWorley rock_worley(vec2 p, int s) {
    ivec2 ip = ivec2(floor(p));
    float f1 = 9.0;
    float f2 = 9.0;
    ivec2 best_cell = ivec2(0);
    vec2 best_delta = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            ivec2 cell = ip + ivec2(i, j);
            vec2 delta = p - (vec2(cell) + vec2(
                rock_h2(cell.x, cell.y, s),
                rock_h2(cell.x, cell.y, s + 77)
            ));
            float distance_squared = dot(delta, delta);
            if (distance_squared < f1) {
                f2 = f1;
                f1 = distance_squared;
                best_cell = cell;
                best_delta = delta;
            } else if (distance_squared < f2) {
                f2 = distance_squared;
            }
        }
    }
    return RockWorley(sqrt(f1), sqrt(f2), best_cell, best_delta);
}

// Returns height, local darkening and the stable block hue identifier.
vec3 rock_sample(vec2 pixel_position, int s) {
    float x = pixel_position.x;
    float y = pixel_position.y;
    float wx = x + (rock_fbm(vec2(x * 0.018, y * 0.018), s + 1, 3) - 0.5) * 34.0;
    float wy = y + (rock_fbm(vec2(x * 0.018 + 50.0, y * 0.018 + 50.0), s + 2, 3) - 0.5) * 34.0;

    RockWorley large_blocks = rock_worley(vec2(wx / 26.0, wy / 34.0), s + 3);
    float edge_gap = large_blocks.f2 - large_blocks.f1;
    float crack = 1.0 - rock_sm(edge_gap / 0.14);
    float id = rock_h2(large_blocks.cell.x, large_blocks.cell.y, s + 4);
    float face_a = rock_h2(large_blocks.cell.x, large_blocks.cell.y, s + 5) - 0.5;
    float face_b = rock_h2(large_blocks.cell.x, large_blocks.cell.y, s + 6) - 0.5;
    float block = id * 0.5
        + (large_blocks.delta.x * face_a + large_blocks.delta.y * face_b) * 1.6
        - crack * 0.55 + rock_sm(edge_gap / 0.5) * 0.25;

    RockWorley small_blocks = rock_worley(vec2(wx / 7.5, wy / 8.0), s + 9);
    float small_gap = small_blocks.f2 - small_blocks.f1;
    float chip = (rock_h2(small_blocks.cell.x, small_blocks.cell.y, s + 10) - 0.5) * 0.3
        - (1.0 - rock_sm(small_gap / 0.2)) * 0.25;

    float warp = rock_fbm(vec2(wx * 0.05, wy * 0.02), s + 11, 2) * 3.0;
    float u = rock_fbm(vec2(wx * 0.12 + warp, wy * 0.03), s + 12, 3);
    float u2 = rock_vnoise(vec2(wx * 0.4 + warp * 2.0, wy * 0.05), s + 14);
    float flute = (1.0 - abs(u * 2.0 - 1.0)) * 0.6
        + (1.0 - abs(u2 * 2.0 - 1.0)) * 0.2;
    float grain = rock_vnoise(vec2(x * 0.9, y * 0.9), s + 13) - 0.5;
    float height = mountain_blocks * block + mountain_flutes * flute
        + mountain_chips * chip + grain * 0.12;

    float streak = rock_sm((rock_fbm(vec2(x * 0.2, y * 0.012), s + 20, 3) - 0.5) / 0.18);
    float macro = rock_fbm(vec2(x * 0.01, y * 0.01), s + 21, 3) - 0.5;
    float darkening = crack * 0.2 * mountain_blocks + streak * mountain_streaks * 0.3
        - macro * 0.3;
    return vec3(height, darkening, id);
}

const float ROCK_BAYER[16] = float[16](
    0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
    3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0
);
const vec3 MOUNTAIN_ROCK_RAMP[7] = vec3[7](
    vec3(16.0, 18.0, 20.0), vec3(35.0, 38.0, 42.0),
    vec3(60.0, 64.0, 68.0), vec3(94.0, 98.0, 102.0),
    vec3(139.0, 142.0, 144.0), vec3(185.0, 187.0, 186.0),
    vec3(226.0, 226.0, 222.0)
);
const vec3 MOUNTAIN_MOSS_RAMP[6] = vec3[6](
    vec3(29.0, 36.0, 18.0), vec3(58.0, 66.0, 25.0),
    vec3(95.0, 101.0, 33.0), vec3(138.0, 127.0, 44.0),
    vec3(183.0, 154.0, 58.0), vec3(211.0, 185.0, 87.0)
);

vec3 mountain_ramp_rock(float q) {
    float p = q * 6.0;
    int index = min(5, int(floor(p)));
    return mix(MOUNTAIN_ROCK_RAMP[index], MOUNTAIN_ROCK_RAMP[index + 1], p - float(index));
}

vec3 mountain_ramp_moss(float q) {
    float p = q * 5.0;
    int index = min(4, int(floor(p)));
    return mix(MOUNTAIN_MOSS_RAMP[index], MOUNTAIN_MOSS_RAMP[index + 1], p - float(index));
}

// Pixel coordinates are locked to world space. Low-detail LODs use a five-point
// stencil to retain the same relief language without evaluating 25 expensive samples.
vec3 mountain_rock_color(vec2 world_xy, float meters_per_pixel, bool full_relief) {
    float pixel_scale = max(meters_per_pixel, 0.1);
    ivec2 pixel = ivec2(floor(world_xy / pixel_scale));
    int seed = int(seed_low) + int(seed_high) * 65536;
    int s = seed * 131 + 7;

    float sum = 0.0;
    float height_left = 0.0;
    float height_right = 0.0;
    float height_up = 0.0;
    float height_down = 0.0;
    float height_center = 0.0;
    vec3 center_sample = vec3(0.0);

    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            bool center = (i == 0 && j == 0);
            bool cross_neighbor = (j == 0 && abs(i) == 1) || (i == 0 && abs(j) == 1);
            if (full_relief || center || cross_neighbor) {
                vec3 sample_value = rock_sample(vec2(pixel + ivec2(i, j)), s);
                float sample_weight = full_relief ? 1.0 : (center ? 21.0 : 1.0);
                sum += sample_value.x * sample_weight;
                if (center) {
                    height_center = sample_value.x;
                    center_sample = sample_value;
                } else if (j == 0 && i == -1) {
                    height_left = sample_value.x;
                } else if (j == 0 && i == 1) {
                    height_right = sample_value.x;
                } else if (i == 0 && j == -1) {
                    height_up = sample_value.x;
                } else if (i == 0 && j == 1) {
                    height_down = sample_value.x;
                }
            }
        }
    }

    vec3 light_direction = normalize(vec3(-0.55, -0.65, 0.52));
    float normal_x = -mountain_relief * (height_right - height_left) * 0.5;
    float normal_y = -mountain_relief * (height_down - height_up) * 0.5;
    float diffuse = (normal_x * light_direction.x + normal_y * light_direction.y
        + light_direction.z) / sqrt(normal_x * normal_x + normal_y * normal_y + 1.0);
    float cavity = height_center - sum / 25.0;
    float value = 0.52 + (diffuse - light_direction.z) * 1.3
        + clamp(cavity * 0.8, -0.3, 0.3) - center_sample.y;
    value = (value - 0.5) * mountain_contrast + 0.5;

    int bayer_index = (pixel.y & 3) * 4 + (pixel.x & 3);
    float bayer = (ROCK_BAYER[bayer_index] + 0.5) / 16.0;
    float quantized = value * (mountain_levels - 1.0)
        + (bayer - 0.5) * mountain_dither;
    float q = clamp(floor(quantized + 0.5), 0.0, mountain_levels - 1.0)
        / (mountain_levels - 1.0);

    vec3 color;
    if (mountain_moss > 0.0
        && rock_fbm(vec2(pixel) * 0.045, s + 30, 3) > 0.72 - mountain_moss * 0.3
        && cavity < 0.05) {
        color = mountain_ramp_moss(q);
    } else {
        color = mountain_ramp_rock(q);
        float hue_shift = (center_sample.z - 0.5) * 16.0;
        color.r += hue_shift;
        color.b -= hue_shift;
    }
    // Palette constants are authored in sRGB, while ALBEDO expects linear values.
    return pow(clamp(color, vec3(0.0), vec3(255.0)) / 255.0, vec3(2.2));
}

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world, float crack_weight) {
    return mountain_rock_color(pixel_world, lod_cell_size, lod_index == 0);
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
    return mountain_rock_color(center, cell_size, false);
}

// Avoid evaluating the full multi-noise crack field once fissures are sub-pixel.
vec3 distance_aware_rock_pixel(
        vec2 pixel_cell, vec2 pixel_world, float crack_weight, float cell_size) {
    if (crack_weight <= 0.001) {
        return voxel_lod_rock_color(pixel_world, cell_size);
    }
    return rock_pixel(pixel_cell, pixel_world, crack_weight);
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
    // Pass view-space distance to light(); fragment-stage built-ins aren't directly available there.
    camera_distance = length((VIEW_MATRIX * vec4(world_position, 1.0)).xyz);
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
        float riser_pixels = lod_cell_size / max(world_units_per_pixel, 0.001);
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
    // Top faces use an XZ projection; vertical mountain walls use a wall-aligned
    // projection with world Y increasing downward, matching the source generator.
    vec2 rock_world = world_position.xz;
    if (is_surface_side) {
        if (abs(normal.x) > abs(normal.z)) {
            rock_world = vec2(world_position.z, -world_position.y);
        } else {
            rock_world = vec2(world_position.x, -world_position.y);
        }
    }

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
        // simplifies with LOD: the cell size follows the same 20 cm-to-25.6 m voxel ladder.
        float lod_voxel_size = lod_cell_size;
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
        float lod_voxel_size = lod_cell_size;
        float rock_crack_footprint = world_units_per_pixel / 5.5;
        float rock_crack_weight = 1.0 - smoothstep(0.55, 1.25, rock_crack_footprint);

        if (is_top_surface || is_surface_side) {
            vec2 pixel_cell = floor(rock_world / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = mix(
                grass_pixel(pixel_cell, pixel_world),
                distance_aware_rock_pixel(pixel_cell, pixel_world, rock_crack_weight, lod_voxel_size),
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
            ALBEDO = distance_aware_rock_pixel(pixel_cell, pixel_world, rock_crack_weight, lod_voxel_size);
            ROUGHNESS = 0.84;
        }
    }

    // Procedural roughness variation completes the generated rock material without
    // disturbing the flat voxel-face normals or the existing grass/soil response.
    if (!debug_lod_colors) {
        float rock_mask = (is_top_surface || is_surface_side)
            ? top_rock_amount
            : ((COLOR.g > COLOR.r * 1.35 || COLOR.r > COLOR.g * 1.15) ? 0.0 : 1.0);
        float roughness_frequency = lod_index >= 6 ? 0.0040 : (lod_index >= 4 ? 0.018 : 0.11);
        float roughness_field = value_noise(world_position.xz * roughness_frequency
            + vec2(seed_low * 0.00029, 37.4));
        ROUGHNESS = clamp(ROUGHNESS + (roughness_field - 0.5) * 0.18 * rock_mask, 0.70, 0.99);
    }
    METALLIC = 0.0;
}

// Fade shadow-map attenuation continuously with camera distance. Shadow strength applies
// only to the upper terrain faces; vertical sides get wrap lighting and a soft directional fill.
void light() {
    vec3 light_normal = normalize(NORMAL);
    float side = 1.0 - smoothstep(0.15, 0.45, abs(normalize(world_normal).y));
    float shadow_strength = mix(0.20, 0.0, smoothstep(40.0, 500.0, camera_distance));

    float attenuation = ATTENUATION;
    if (LIGHT_IS_DIRECTIONAL) {
        attenuation = mix(mix(1.0, ATTENUATION, shadow_strength), 1.0, side);
    }
    if (LIGHT_IS_AREA) {
        DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * attenuation * LIGHT_COLOR;
        SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * attenuation * LIGHT_COLOR * SPECULAR_AMOUNT;
    } else {
        float n_dot_l = dot(light_normal, LIGHT);
        float lambert = clamp(n_dot_l, 0.0, 1.0);
        float wrapped = clamp((n_dot_l + side_wrap) / (1.0 + side_wrap), 0.0, 1.0);
        float diffuse_term = mix(lambert, wrapped, side);
        float fill = LIGHT_IS_DIRECTIONAL ? side * side_fill : 0.0;
        DIFFUSE_LIGHT += (diffuse_term * attenuation + fill) * LIGHT_COLOR / PI;
        vec3 half_vector = normalize(LIGHT + VIEW);
        float roughness = clamp(ROUGHNESS, 0.04, 1.0);
        float lobe = pow(max(dot(light_normal, half_vector), 0.0), mix(128.0, 4.0, roughness));
        SPECULAR_LIGHT += lobe * attenuation * LIGHT_COLOR * SPECULAR_AMOUNT * (1.0 - roughness) * 0.08;
    }
}
