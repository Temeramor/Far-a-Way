// Procedural mountain rock material adapted from examples/mountain texture.html.
uniform float mountain_blocks : hint_range(0.0, 1.5) = 0.25;
uniform float mountain_flutes : hint_range(0.0, 1.5) = 1.1;
uniform float mountain_chips : hint_range(0.0, 1.5) = 0.6;
uniform float mountain_contrast : hint_range(0.6, 1.8) = 1.1;
uniform float mountain_levels : hint_range(4.0, 24.0, 1.0) = 10.0;
uniform float mountain_dither : hint_range(0.0, 1.0) = 0.5;

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

// Returns the procedural colour-pattern field and stable block hue identifier.
vec2 rock_sample(vec2 pixel_position, int s) {
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

    return vec2(height, id);
}

const float ROCK_BAYER[16] = float[16](
    0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
    3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0
);
const vec3 MOUNTAIN_ROCK_RAMP[7] = vec3[7](
    // Preserve the deepest charcoal tones; shift the midtones and highlights
    // toward darker, humid tropical slate-blue rock.
    vec3(16.0, 18.0, 20.0), vec3(35.0, 38.0, 42.0),
    vec3(60.0, 64.0, 68.0), vec3(67.0, 82.0, 115.0),
    vec3(95.0, 97.0, 118.0), vec3(109.0, 115.0, 131.0),
    vec3(132.0, 137.0, 151.0)
);
vec3 mountain_ramp_rock(float q) {
    float p = q * 6.0;
    int index = min(5, int(floor(p)));
    return mix(MOUNTAIN_ROCK_RAMP[index], MOUNTAIN_ROCK_RAMP[index + 1], p - float(index));
}

// Pixel coordinates are locked to world space. This function generates colour only:
// no height-gradient lighting, cavity shading, baked streak shadows or material reflections.
vec3 mountain_rock_color(vec2 world_xy, float meters_per_pixel) {
    float pixel_scale = max(meters_per_pixel, 0.1);
    ivec2 pixel = ivec2(floor(world_xy / pixel_scale));
    int seed = int(seed_low) + int(seed_high) * 65536;
    int s = seed * 131 + 7;

    // One sample is sufficient for the colour pattern; neighbouring samples were only
    // used to synthesize fake lighting and cavity darkening.
    vec2 pattern = rock_sample(vec2(pixel), s);
    float value = 0.5 + (pattern.x - 0.4) * 0.75;
    value = (value - 0.5) * mountain_contrast + 0.5;

    int bayer_index = (pixel.y & 3) * 4 + (pixel.x & 3);
    float bayer = (ROCK_BAYER[bayer_index] + 0.5) / 16.0;
    float quantized = value * (mountain_levels - 1.0)
        + (bayer - 0.5) * mountain_dither;
    float q = clamp(floor(quantized + 0.5), 0.0, mountain_levels - 1.0)
        / (mountain_levels - 1.0);

    vec3 color = mountain_ramp_rock(q);
    float hue_shift = (pattern.y - 0.5) * 16.0;
    color.r += hue_shift;
    color.b -= hue_shift;

    // Palette constants are authored in sRGB, while ALBEDO expects linear values.
    return pow(clamp(color, vec3(0.0), vec3(255.0)) / 255.0, vec3(2.2));
}

// Hybrid triplanar projection: blend the horizontal XZ plane with a wall plane
// selected from the dominant horizontal normal. This keeps rock detail stable on steep slopes
// instead of stretching the entire mountain pattern along world XZ.
vec2 mountain_rock_projection(vec3 position, vec3 surface_normal) {
    vec3 n = abs(normalize(surface_normal));
    float vertical_weight = clamp(n.y, 0.0, 1.0);
    float use_z_axis = step(n.x, n.z);
    float wall_u = mix(position.z, position.x, use_z_axis);
    vec2 wall_projection = vec2(wall_u, -position.y);
    return mix(wall_projection, position.xz, vertical_weight);
}

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world, float crack_weight) {
    // The centre sample preserves the complete block/flute/chip texture. Four neighbours
    // are enough for its relief gradient; 25 samples only softened the cavity term.
    return mountain_rock_color(pixel_world, lod_cell_size);
}


vec3 voxel_lod_rock_color(vec2 world_xz, float cell_size) {
    vec2 cell = floor(world_xz / cell_size);
    vec2 center = (cell + vec2(0.5)) * cell_size;
    return mountain_rock_color(center, cell_size);
}

// Switch to the five-point relief approximation when fine details become sub-pixel.
vec3 distance_aware_rock_pixel(
        vec2 pixel_cell, vec2 pixel_world, float crack_weight, float cell_size) {
    if (crack_weight <= 0.001) {
        return voxel_lod_rock_color(pixel_world, cell_size);
    }
    return rock_pixel(pixel_cell, pixel_world, crack_weight);
}


vec3 distance_aware_rock_pixel(
        vec2 pixel_cell, vec2 pixel_world, float crack_weight, float cell_size) {
    if (crack_weight <= 0.001) {
        return voxel_lod_rock_color(pixel_world, cell_size);
    }
    return rock_pixel(pixel_cell, pixel_world, crack_weight);
}

