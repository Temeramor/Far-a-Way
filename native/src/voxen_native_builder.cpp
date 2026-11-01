#include "voxen_native_builder.h"

#include "../thirdparty/FastNoiseLite.h"
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

constexpr double VOXEL_SIZE = 0.2;
// Internal heightfield origin keeps signed sea-floor elevations inside the legacy
// non-negative voxel lattice. Chunk transforms and collision samples subtract it.
constexpr int32_t VERTICAL_OFFSET_VOXELS = 512;
constexpr double VERTICAL_OFFSET_M = VERTICAL_OFFSET_VOXELS * VOXEL_SIZE;
constexpr double REFERENCE_WORLD_SIZE_M = 10000.0;
constexpr int32_t BASE_MESH_STEP_VOXELS = 1;
constexpr int HEIGHT_CACHE_STEP_VOXELS = 5;
constexpr int LOD_SKIRT_DEPTH_VOXELS = 80;
constexpr double SKIRT_ALPHA_LEFT = 0.80;
constexpr double SKIRT_ALPHA_RIGHT = 0.84;
constexpr double SKIRT_ALPHA_NORTH = 0.88;
constexpr double SKIRT_ALPHA_SOUTH = 0.92;

constexpr int AIR = 0;
constexpr int GRASS = 1;
constexpr int SOIL = 2;
constexpr int ROCK = 3;
constexpr int SAND = 4;

struct NoiseSet {
    int64_t seed_value = 0;
    double world_size_m = 2000.0;
    fastnoiselite::FastNoiseLite macro;
    fastnoiselite::FastNoiseLite hills;
    fastnoiselite::FastNoiseLite detail;
    fastnoiselite::FastNoiseLite ridges;
    fastnoiselite::FastNoiseLite micro_ridge;
    fastnoiselite::FastNoiseLite transition;

    struct MountainSegment {
        double ax = 0.0, az = 0.0, dx = 0.0, dz = 0.0;
        double length_squared = 1.0, width = 1.0, height = 1.0, phase = 0.0;
    };
    std::vector<MountainSegment> mountain_segments;
    mutable std::mutex surface_cache_mutex;
    mutable std::unordered_map<uint64_t, double> surface_height_cache;
    mutable std::vector<uint64_t> surface_height_cache_order;
    mutable size_t surface_height_cache_cursor = 0;
    static constexpr size_t MAX_SURFACE_CACHE_ENTRIES = 131072;

    static fastnoiselite::FastNoiseLite make_noise(
            int32_t seed, int octaves, float gain, bool ridged = false) {
        fastnoiselite::FastNoiseLite noise;
        noise.SetSeed(seed);
        noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
        noise.SetFrequency(1.0f);
        noise.SetFractalType(ridged
            ? fastnoiselite::FastNoiseLite::FractalType_Ridged
            : fastnoiselite::FastNoiseLite::FractalType_FBm);
        noise.SetFractalOctaves(octaves);
        noise.SetFractalLacunarity(2.05f);
        noise.SetFractalGain(gain);
        return noise;
    }

    explicit NoiseSet(int64_t seed)
            : seed_value(seed),
              macro(make_noise(static_cast<int32_t>(seed + 101), 4, 0.52f)),
              hills(make_noise(static_cast<int32_t>(seed + 307), 4, 0.52f)),
              detail(make_noise(static_cast<int32_t>(seed + 503), 3, 0.52f)),
              ridges(make_noise(static_cast<int32_t>(seed + 709), 5, 0.52f, true)),
              micro_ridge(make_noise(static_cast<int32_t>(seed + 907), 3, 0.52f, true)),
              transition(make_noise(static_cast<int32_t>(seed + 1301), 2, 0.52f)) {}

    void configure_from_job(const Dictionary &job_data, double fallback_world_size_m) {
        world_size_m = static_cast<double>(job_data.get("terrain_world_size_m", fallback_world_size_m));
        const float frequency_scale = static_cast<float>(
            std::clamp(REFERENCE_WORLD_SIZE_M / std::max(world_size_m, 1.0), 0.35, 6.0));
        macro.SetFrequency(0.00028f * frequency_scale);
        hills.SetFrequency(0.00115f * frequency_scale);
        detail.SetFrequency(0.0048f * frequency_scale);
        ridges.SetFrequency(0.00082f * frequency_scale);
        micro_ridge.SetFrequency(0.0034f * frequency_scale);
        transition.SetFrequency(0.008f * frequency_scale);
        mountain_segments.clear();
        const Array profile = job_data.get("mountain_profile", Array());
        for (int64_t i = 0; i < profile.size(); ++i) {
            const Dictionary item = profile[i];
            const Vector2 start = item.get("start", Vector2());
            const Vector2 delta = item.get("delta", Vector2());
            MountainSegment segment;
            segment.ax = start.x;
            segment.az = start.y;
            segment.dx = delta.x;
            segment.dz = delta.y;
            segment.length_squared = std::max(0.001, static_cast<double>(item.get("length_squared", 1.0)));
            segment.width = static_cast<double>(item.get("width", 1.0));
            segment.height = static_cast<double>(item.get("height", 1.0));
            segment.phase = static_cast<double>(item.get("phase", 0.0));
            mountain_segments.push_back(segment);
        }
    }

    double coast_distance(double x, double z) const {
        const double seed_phase = static_cast<double>(seed_value % 1000003) * 0.000173;
        const double aspect = 1.0 + 3.0 * (0.5 + 0.5 * std::sin(seed_phase * 1.37));
        const double angle = seed_phase * 0.71;
        const double ca = std::cos(angle), sa = std::sin(angle);
        const double rx = x * ca - z * sa;
        const double rz = x * sa + z * ca;
        constexpr double radius = 1128.38;
        const double a = radius * std::sqrt(aspect);
        const double b = radius / std::sqrt(aspect);
        const double radial = std::sqrt((rx * rx) / (a * a) + (rz * rz) / (b * b));
        const double warp = sample_noise(macro, x * 0.72, z * 0.72) * 0.075 +
                            sample_noise(hills, x * 1.9, z * 1.9) * 0.035;
        return radial + warp;
    }

    static float sample_noise(const fastnoiselite::FastNoiseLite &noise, double x, double z) {
        // Godot's real_t is float in the current Windows build; preserve its input precision.
        return noise.GetNoise(static_cast<float>(x), static_cast<float>(z));
    }

    static double smoothstep(double edge_a, double edge_b, double value) {
        const double t = std::clamp((value - edge_a) / (edge_b - edge_a), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    double surface_height(double x, double z) const {
        const double macro_value = sample_noise(macro, x, z);
        const double hills_value = sample_noise(hills, x, z);
        const double detail_value = sample_noise(detail, x, z);
        const double ridge_detail = (sample_noise(ridges, x, z) + 1.0) * 0.5;
        const double micro_value = sample_noise(micro_ridge, x, z);

        double height = 26.0 + macro_value * 17.0 + hills_value * 10.0;
        height += std::max(hills_value - 0.12, 0.0) * 18.0;
        height += detail_value * 3.8;

        const double world_scale = world_size_m / REFERENCE_WORLD_SIZE_M;
        height += std::pow(std::max(ridge_detail - 0.58, 0.0), 1.7) * (12.0 + 38.0 * world_scale);
        double mountain_height = 0.0;
        for (const MountainSegment &segment : mountain_segments) {
            const double along = std::clamp(
                ((x - segment.ax) * segment.dx + (z - segment.az) * segment.dz) /
                    segment.length_squared, 0.0, 1.0);
            const double closest_x = segment.ax + segment.dx * along;
            const double closest_z = segment.az + segment.dz * along;
            const double offset_x = x - closest_x;
            const double offset_z = z - closest_z;
            const double distance_squared = offset_x * offset_x + offset_z * offset_z;
            const double broad_radius = segment.width * 1.72;
            if (distance_squared >= broad_radius * broad_radius) continue;
            const double distance = std::sqrt(distance_squared);
            const double flank_warp = (detail_value * 0.60 + micro_value * 0.40) * segment.width * 0.11;
            const double shaped_distance = std::max(0.0, distance + flank_warp);
            const double broad_mask = std::clamp(1.0 - shaped_distance / broad_radius, 0.0, 1.0);
            const double cliff_mask = std::clamp(1.0 - shaped_distance / segment.width, 0.0, 1.0);
            const double crest_profile = 0.72 + 0.28 * std::abs(std::sin(along * 3.14159265358979323846 * 2.1 + segment.phase));
            const double rough_profile = 0.72 + 0.28 * ridge_detail;
            const double foothills = std::pow(broad_mask, 1.36) * (segment.height * 0.36 + 75.0 * world_scale);
            const double crest = std::pow(cliff_mask, 0.82) * segment.height * crest_profile * rough_profile;
            mountain_height = std::max(mountain_height, std::max(foothills, crest));
        }

        height += mountain_height;
        if (mountain_height > 1.0) {
            const double mountain_mask = std::clamp(mountain_height / 900.0, 0.0, 1.0);
            height += mountain_mask * (micro_value * 42.0 + detail_value * 28.0);
        }
        // One irregular central island with approximately 4 km² of land. Its aspect
        // ratio and orientation are seed-derived, while multi-scale noise perturbs
        // the coastline without creating a circular or smoothed spawn platform.
        const double seed_phase = static_cast<double>(seed_value % 1000003) * 0.000173;
        const double aspect = 1.0 + 3.0 * (0.5 + 0.5 * std::sin(seed_phase * 1.37));
        const double angle = seed_phase * 0.71;
        const double ca = std::cos(angle), sa = std::sin(angle);
        const double rx = x * ca - z * sa;
        const double rz = x * sa + z * ca;
        constexpr double equivalent_radius = 1128.38; // sqrt(4,000,000 / pi)
        const double axis_a = equivalent_radius * std::sqrt(aspect);
        const double axis_b = equivalent_radius / std::sqrt(aspect);
        const double radial = std::sqrt((rx * rx) / (axis_a * axis_a) +
                                        (rz * rz) / (axis_b * axis_b));
        const double coast_warp = sample_noise(macro, x * 0.72, z * 0.72) * 0.075 +
                                  sample_noise(hills, x * 1.9, z * 1.9) * 0.035;
        const double coast_distance = radial + coast_warp;
        const double land_mask = 1.0 - smoothstep(0.965, 1.035, coast_distance);
        const double ocean_depth = -3.0 - 72.0 * smoothstep(1.0, 2.25, coast_distance);
        // The island's existing hills/ridges/mountain profile is retained, but fades
        // only at the actual shoreline. There is deliberately no spawn-centre fade.
        const double land_height = std::clamp(height, 0.25, 1600.0);
        height = land_height * land_mask + ocean_depth * (1.0 - land_mask);
        return std::clamp(height, -80.0, 1600.0);
    }

    double cached_grid_height(int32_t grid_x, int32_t grid_z) const {
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(grid_x)) << 32) |
            static_cast<uint32_t>(grid_z);
        {
            std::lock_guard<std::mutex> lock(surface_cache_mutex);
            const auto found = surface_height_cache.find(key);
            if (found != surface_height_cache.end()) return found->second;
        }

        constexpr double sample_step = 0.5;
        const double height = surface_height(
            static_cast<double>(grid_x) * sample_step,
            static_cast<double>(grid_z) * sample_step);
        {
            std::lock_guard<std::mutex> lock(surface_cache_mutex);
            const auto found = surface_height_cache.find(key);
            if (found != surface_height_cache.end()) return found->second;
            if (surface_height_cache.size() >= MAX_SURFACE_CACHE_ENTRIES) {
                const uint64_t expired_key = surface_height_cache_order[surface_height_cache_cursor];
                surface_height_cache.erase(expired_key);
                surface_height_cache_order[surface_height_cache_cursor] = key;
                surface_height_cache_cursor =
                    (surface_height_cache_cursor + 1) % MAX_SURFACE_CACHE_ENTRIES;
            } else {
                surface_height_cache_order.push_back(key);
            }
            surface_height_cache.emplace(key, height);
        }
        return height;
    }

    double surface_height_cached(double x, double z) const {
        constexpr double sample_step = 0.5;
        const int32_t grid_x = static_cast<int32_t>(std::llround(x / sample_step));
        const int32_t grid_z = static_cast<int32_t>(std::llround(z / sample_step));
        if (std::abs(x - static_cast<double>(grid_x) * sample_step) < 0.0001 &&
                std::abs(z - static_cast<double>(grid_z) * sample_step) < 0.0001) {
            return cached_grid_height(grid_x, grid_z);
        }
        return surface_height(x, z);
    }

    Vector3 surface_sample(double x, double z, double step_m) const {
        const double safe_step = std::max(step_m, 0.0001);
        const double grid_x_float = x / safe_step;
        const double grid_z_float = z / safe_step;
        const int32_t grid_x = static_cast<int32_t>(std::floor(grid_x_float));
        const int32_t grid_z = static_cast<int32_t>(std::floor(grid_z_float));
        const double tx = std::clamp(grid_x_float - static_cast<double>(grid_x), 0.0, 1.0);
        const double tz = std::clamp(grid_z_float - static_cast<double>(grid_z), 0.0, 1.0);
        const auto sample = [this, safe_step](int32_t sx, int32_t sz) {
            if (std::abs(safe_step - 0.5) < 0.000001) {
                return cached_grid_height(sx, sz);
            }
            return surface_height(static_cast<double>(sx) * safe_step,
                static_cast<double>(sz) * safe_step);
        };
        const double h00 = sample(grid_x, grid_z);
        const double h10 = sample(grid_x + 1, grid_z);
        const double h01 = sample(grid_x, grid_z + 1);
        const double h11 = sample(grid_x + 1, grid_z + 1);
        const double top = h00 + (h10 - h00) * tx;
        const double bottom = h01 + (h11 - h01) * tx;
        const double height = top + (bottom - top) * tz;
        const double slope_x = ((h10 - h00) * (1.0 - tz) + (h11 - h01) * tz) / safe_step;
        const double slope_z = ((h01 - h00) * (1.0 - tx) + (h11 - h10) * tx) / safe_step;
        return Vector3(height, slope_x, slope_z);
    }

    PackedFloat32Array sample_height_grid(double origin_x, double origin_z,
            int32_t columns, int32_t rows, double step_m) const {
        PackedFloat32Array samples;
        if (columns <= 0 || rows <= 0) return samples;
        const int64_t total = static_cast<int64_t>(columns) * rows;
        samples.resize(total);
        for (int32_t z = 0; z < rows; ++z) {
            for (int32_t x = 0; x < columns; ++x) {
                const double world_x = origin_x + static_cast<double>(x) * step_m;
                const double world_z = origin_z + static_cast<double>(z) * step_m;
                samples.set(static_cast<int64_t>(z) * columns + x,
                    static_cast<float>(surface_height_cached(world_x, world_z)));
            }
        }
        return samples;
    }

    int32_t surface_height_voxels(double x, double z) const {
        return VERTICAL_OFFSET_VOXELS + static_cast<int32_t>(std::llround(surface_height(x, z) / VOXEL_SIZE));
    }

    double surface_rock_weight(double slope, double x, double z) const {
        const double transition_noise = sample_noise(transition, x, z) * 0.12;
        const double normal_slope = 1.0 - 1.0 / std::sqrt(1.0 + slope * slope);
        return smoothstep(0.30, 0.48, normal_slope + transition_noise);
    }

    int32_t surface_material(double height_m, double slope, double x, double z) const {
        const double shore = coast_distance(x, z);
        if (shore >= 0.91 && shore <= 1.13 && slope < 0.58 &&
                height_m >= -4.0 && height_m <= 9.0) {
            return SAND;
        }
        return surface_rock_weight(slope, x, z) >= 0.5 ? ROCK : GRASS;
    }
};

Color rgb8(int r, int g, int b, double a = 1.0) {
    return Color(static_cast<double>(r) / 255.0,
                 static_cast<double>(g) / 255.0,
                 static_cast<double>(b) / 255.0,
                 a);
}

struct MeshBuild {
    std::shared_ptr<NoiseSet> noise;
    bool configure_noise_from_job = true;
    const std::atomic<bool> *cancel_flag = nullptr;
    Vector2i coord;
    int lod = 0;
    bool want_collision = false;
    bool build_collision = false;

    double world_min_x = 0.0;
    double world_min_z = 0.0;
    int32_t world_size_voxels = 0;
    int32_t start_voxel_x = 0;
    int32_t start_voxel_z = 0;
    int32_t size_voxels_x = 0;
    int32_t size_voxels_z = 0;
    int32_t step_voxels = 1;
    int32_t cache_step_voxels = HEIGHT_CACHE_STEP_VOXELS;
    int32_t cells_x = 0;
    int32_t cells_z = 0;
    int32_t halo = 0;
    int32_t grid_width = 0;
    int32_t grid_depth = 0;
    double cell_size = VOXEL_SIZE;

    Dictionary neighbor_lods;
    std::vector<double> height_cache;
    int32_t cache_width = 0;
    int32_t cache_depth = 0;
    int32_t cache_origin_x = 0;
    int32_t cache_origin_z = 0;
    std::vector<int32_t> raw_heights;
    std::vector<int32_t> heights;
    std::vector<uint8_t> surface_types;
    std::vector<double> surface_rock_weights;

    std::vector<Vector3> vertices;
    std::vector<Vector3> normals;
    std::vector<Color> colors;
    std::vector<int32_t> indices;
    std::vector<Vector3> smooth_shadow_vertices;
    std::vector<Vector3> smooth_shadow_normals;
    std::vector<int32_t> smooth_shadow_indices;

    explicit MeshBuild(int64_t seed, const std::atomic<bool> *token,
            const std::shared_ptr<NoiseSet> &shared_sampler)
            : noise(shared_sampler ? shared_sampler : std::make_shared<NoiseSet>(seed)),
              configure_noise_from_job(!shared_sampler), cancel_flag(token) {}

    bool is_cancelled() const {
        return cancel_flag != nullptr && cancel_flag->load(std::memory_order_relaxed);
    }

    static double cubic_interpolate(double p0, double p1, double p2, double p3, double t) {
        return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 +
            4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
    }
    double surface_rock_weight_at(int32_t x, int32_t z) const {
        return surface_rock_weights[static_cast<size_t>(z + 1) * (cells_x + 2) + x + 1];
    }

    double average_surface_rock_weight(int32_t corner_x, int32_t corner_z) const {
        double total = 0.0;
        for (int32_t z = corner_z - 1; z < corner_z + 1; ++z) {
            for (int32_t x = corner_x - 1; x < corner_x + 1; ++x) {
                total += surface_rock_weight_at(x, z);
            }
        }
        return total * 0.25;
    }

    Color top_face_color(int32_t material_type, double rock_weight) const {
        Color color = material_color(material_type);
        // Reserve stable 8-bit alpha codes: 246..252 for tops, 240..245 for
        // upper side faces, and <=235 for stitching skirts.
        const int32_t code = 246 + static_cast<int32_t>(std::lround(
            std::clamp(rock_weight, 0.0, 1.0) * 6.0));
        color.a = static_cast<double>(code) / 255.0;
        return color;
    }

    static int32_t floor_to_int(double value) {
        return static_cast<int32_t>(std::floor(value));
    }

    double sample_height_voxel_units(double gx, double gz) const {
        if (gx < 0.0 || gz < 0.0 ||
            gx >= static_cast<double>(world_size_voxels) ||
            gz >= static_cast<double>(world_size_voxels)) {
            return 0.0;
        }
        const double world_x = world_min_x + gx * VOXEL_SIZE;
        const double world_z = world_min_z + gz * VOXEL_SIZE;
        // Keep continuous heights until the interpolated mesh sample is quantised.
        return static_cast<double>(VERTICAL_OFFSET_VOXELS) + noise->surface_height(world_x, world_z) / VOXEL_SIZE;
    }

    int32_t cached_height_voxels(double gx, double gz) const {
        if (gx < 0.0 || gz < 0.0 ||
            gx >= static_cast<double>(world_size_voxels) ||
            gz >= static_cast<double>(world_size_voxels)) {
            return 0;
        }
        const double fx = (gx - static_cast<double>(cache_origin_x)) /
            static_cast<double>(cache_step_voxels);
        const double fz = (gz - static_cast<double>(cache_origin_z)) /
            static_cast<double>(cache_step_voxels);
        const int32_t bx = floor_to_int(fx);
        const int32_t bz = floor_to_int(fz);
        const double tx = std::clamp(fx - static_cast<double>(bx), 0.0, 1.0);
        const double tz = std::clamp(fz - static_cast<double>(bz), 0.0, 1.0);

        double rows[4] = {0.0, 0.0, 0.0, 0.0};
        double h_min = std::numeric_limits<double>::infinity();
        double h_max = -std::numeric_limits<double>::infinity();

        for (int dz = 0; dz < 4; ++dz) {
            const int32_t iz = std::clamp(bz + dz - 1, 0, cache_depth - 1);
            const int32_t x0 = std::clamp(bx - 1, 0, cache_width - 1);
            const int32_t x1 = std::clamp(bx, 0, cache_width - 1);
            const int32_t x2 = std::clamp(bx + 1, 0, cache_width - 1);
            const int32_t x3 = std::clamp(bx + 2, 0, cache_width - 1);
            const double p0 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x0]);
            const double p1 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x1]);
            const double p2 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x2]);
            const double p3 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x3]);
            rows[dz] = cubic_interpolate(p0, p1, p2, p3, tx);
            h_min = std::min(h_min, std::min(std::min(p0, p1), std::min(p2, p3)));
            h_max = std::max(h_max, std::max(std::max(p0, p1), std::max(p2, p3)));
        }

        const double height = cubic_interpolate(rows[0], rows[1], rows[2], rows[3], tz);
        return std::max<int32_t>(1, static_cast<int32_t>(std::llround(std::clamp(height, h_min, h_max))));
    }

    int32_t grid_index(int32_t x, int32_t z) const {
        return (z + halo) * grid_width + x + halo;
    }

    int32_t neighbor_lod(const String &direction) const {
        return static_cast<int32_t>(neighbor_lods.get(direction, -1));
    }

    Color material_color(int32_t material_type) const {
        // LOD diagnostic colours are selected by the shader uniform, not baked into geometry.
        switch (material_type) {
            case GRASS: return rgb8(54, 164, 42);
            case SOIL: return rgb8(128, 96, 68);
            case ROCK: return rgb8(119, 121, 115);
            case SAND: return rgb8(224, 177, 105);
            default: return Color(1.0, 1.0, 1.0, 1.0);
        }
    }

    void add_quad(const Vector3 &p0, const Vector3 &p1, const Vector3 &p2,
                  const Vector3 &p3, const Vector3 &normal, const Color &color) {
        const int32_t base_index = static_cast<int32_t>(vertices.size());
        vertices.push_back(p0);
        vertices.push_back(p1);
        vertices.push_back(p2);
        vertices.push_back(p3);
        for (int i = 0; i < 4; ++i) {
            normals.push_back(normal);
            colors.push_back(color);
        }
        // Match the existing GDScript winding convention for Godot's front faces.
        indices.push_back(base_index);
        indices.push_back(base_index + 2);
        indices.push_back(base_index + 1);
        indices.push_back(base_index);
        indices.push_back(base_index + 3);
        indices.push_back(base_index + 2);
    }
    void add_quad_vertex_colors(const Vector3 &p0, const Vector3 &p1,
            const Vector3 &p2, const Vector3 &p3, const Vector3 &normal,
            const Color &color0, const Color &color1, const Color &color2, const Color &color3) {
        const int32_t base_index = static_cast<int32_t>(vertices.size());
        vertices.push_back(p0);
        vertices.push_back(p1);
        vertices.push_back(p2);
        vertices.push_back(p3);
        for (int i = 0; i < 4; ++i) {
            normals.push_back(normal);
        }
        colors.push_back(color0);
        colors.push_back(color1);
        colors.push_back(color2);
        colors.push_back(color3);
        indices.push_back(base_index);
        indices.push_back(base_index + 2);
        indices.push_back(base_index + 1);
        indices.push_back(base_index);
        indices.push_back(base_index + 3);
        indices.push_back(base_index + 2);
    }

    void emit_side_segment(const Vector3 &point_a, const Vector3 &point_b,
                           const Vector3 &normal, int32_t low_y, int32_t high_y,
                           int32_t material_type, bool vertical_first,
                           double edge_alpha = 1.0, double encoded_alpha = -1.0) {
        if (high_y <= low_y) {
            return;
        }
        const double low_m = static_cast<double>(low_y) * VOXEL_SIZE;
        const double high_m = static_cast<double>(high_y) * VOXEL_SIZE;
        const Vector3 a_low(point_a.x, low_m, point_a.z);
        const Vector3 a_high(point_a.x, high_m, point_a.z);
        const Vector3 b_low(point_b.x, low_m, point_b.z);
        const Vector3 b_high(point_b.x, high_m, point_b.z);
        Color side_color = material_color(material_type);
        if (encoded_alpha >= 0.0) {
            side_color.a = encoded_alpha;
        } else if (edge_alpha < 0.95) {
            side_color.a = edge_alpha;
        }
        if (vertical_first) {
            add_quad(a_low, a_high, b_high, b_low, normal, side_color);
        } else {
            add_quad(a_low, b_low, b_high, a_high, normal, side_color);
        }
    }

    void add_segmented_side_face(const Vector3 &p0, const Vector3 &p1,
            const Vector3 &p2, const Vector3 &p3, const Vector3 &normal,
            int32_t low_height_voxels, int32_t high_height_voxels,
            int32_t top_material, bool vertical_first, double edge_alpha = 1.0,
            double surface_rock_weight = -1.0) {
        (void)p2;
        if (high_height_voxels <= low_height_voxels) {
            return;
        }
        const Vector3 point_a(p0.x, 0.0, p0.z);
        const Vector3 point_b = vertical_first
            ? Vector3(p3.x, 0.0, p3.z)
            : Vector3(p1.x, 0.0, p1.z);

        if (edge_alpha >= 0.95) {
            // The upper exposed voxel carries the same blend as its top face.
            const int32_t top_start = std::max(low_height_voxels, high_height_voxels - step_voxels);
            double encoded_alpha = -1.0;
            if (surface_rock_weight >= 0.0) {
                const int32_t alpha_code = 240 + static_cast<int32_t>(std::lround(
                    std::clamp(surface_rock_weight, 0.0, 1.0) * 5.0));
                encoded_alpha = static_cast<double>(alpha_code) / 255.0;
            }
            if (lod >= 3) {
                // Distant layer detail is smaller than a pixel. Keep the voxel riser,
                // but merge lower soil/rock bands into a single segment.
                const int32_t lower_material = top_material == ROCK ? ROCK : SOIL;
                emit_side_segment(point_a, point_b, normal, low_height_voxels, top_start,
                    lower_material, vertical_first, edge_alpha);
            } else if (top_material == ROCK) {
                emit_side_segment(point_a, point_b, normal, low_height_voxels, top_start,
                    ROCK, vertical_first, edge_alpha);
            } else {
                const int32_t soil_start = std::max(low_height_voxels, high_height_voxels - step_voxels * 5);
                emit_side_segment(point_a, point_b, normal, low_height_voxels, soil_start,
                    ROCK, vertical_first, edge_alpha);
                emit_side_segment(point_a, point_b, normal, soil_start, top_start,
                    SOIL, vertical_first, edge_alpha);
            }
            emit_side_segment(point_a, point_b, normal, top_start, high_height_voxels,
                top_material, vertical_first, edge_alpha, encoded_alpha);
            return;
        }

        // Stitching skirts are geometric seams; distant LODs only need one continuous band.
        if (lod >= 3) {
            emit_side_segment(point_a, point_b, normal, low_height_voxels, high_height_voxels,
                top_material == ROCK ? ROCK : SOIL, vertical_first, edge_alpha);
            return;
        }
        if (top_material == ROCK) {
            emit_side_segment(point_a, point_b, normal, low_height_voxels, high_height_voxels,
                ROCK, vertical_first, edge_alpha);
            return;
        }
        const int32_t skirt_top_start = std::max(low_height_voxels, high_height_voxels - step_voxels);
        const int32_t skirt_soil_start = std::max(low_height_voxels, high_height_voxels - step_voxels * 5);
        emit_side_segment(point_a, point_b, normal, low_height_voxels, skirt_soil_start,
            ROCK, vertical_first, edge_alpha);
        emit_side_segment(point_a, point_b, normal, skirt_soil_start, skirt_top_start,
            SOIL, vertical_first, edge_alpha);
        emit_side_segment(point_a, point_b, normal, skirt_top_start, high_height_voxels,
            top_material, vertical_first, edge_alpha);
    }

    void build_cache_and_heights() {
        const int32_t macro_offset = std::max<int32_t>(1, static_cast<int32_t>(std::llround(1.0 / cell_size)));
        halo = macro_offset + 1;
        grid_width = cells_x + halo * 2;
        grid_depth = cells_z + halo * 2;
        const int32_t total_samples = grid_width * grid_depth;

        cache_origin_x = floor_to_int(
            static_cast<double>(start_voxel_x - halo * step_voxels - cache_step_voxels * 2) /
            static_cast<double>(cache_step_voxels)) * cache_step_voxels;
        cache_origin_z = floor_to_int(
            static_cast<double>(start_voxel_z - halo * step_voxels - cache_step_voxels * 2) /
            static_cast<double>(cache_step_voxels)) * cache_step_voxels;
        const int32_t cache_end_x = start_voxel_x + size_voxels_x + halo * step_voxels + cache_step_voxels * 2;
        const int32_t cache_end_z = start_voxel_z + size_voxels_z + halo * step_voxels + cache_step_voxels * 2;
        cache_width = static_cast<int32_t>(std::ceil(
            static_cast<double>(cache_end_x - cache_origin_x) / cache_step_voxels)) + 1;
        cache_depth = static_cast<int32_t>(std::ceil(
            static_cast<double>(cache_end_z - cache_origin_z) / cache_step_voxels)) + 1;
        height_cache.resize(static_cast<size_t>(cache_width) * cache_depth);

        for (int32_t cz = 0; cz < cache_depth; ++cz) {
            if (is_cancelled()) return;
            const double cache_z = static_cast<double>(cache_origin_z + cz * cache_step_voxels);
            for (int32_t cx = 0; cx < cache_width; ++cx) {
                const double cache_x = static_cast<double>(cache_origin_x + cx * cache_step_voxels);
                height_cache[static_cast<size_t>(cz) * cache_width + cx] = sample_height_voxel_units(cache_x, cache_z);
            }
        }

        raw_heights.resize(static_cast<size_t>(total_samples));
        for (int32_t gz = 0; gz < grid_depth; ++gz) {
            if (is_cancelled()) return;
            const int32_t local_cell_z = (gz - halo) * step_voxels;
            double sample_local_z = static_cast<double>(local_cell_z) + static_cast<double>(step_voxels) * 0.5;
            if (local_cell_z >= 0 && local_cell_z < size_voxels_z) {
                sample_local_z = std::min(sample_local_z, static_cast<double>(size_voxels_z) - 0.5);
            }
            const double global_cell_z = static_cast<double>(start_voxel_z) + sample_local_z;
            for (int32_t gx = 0; gx < grid_width; ++gx) {
                const int32_t local_cell_x = (gx - halo) * step_voxels;
                double sample_local_x = static_cast<double>(local_cell_x) + static_cast<double>(step_voxels) * 0.5;
                if (local_cell_x >= 0 && local_cell_x < size_voxels_x) {
                    sample_local_x = std::min(sample_local_x, static_cast<double>(size_voxels_x) - 0.5);
                }
                const double global_cell_x = static_cast<double>(start_voxel_x) + sample_local_x;
                raw_heights[static_cast<size_t>(gz) * grid_width + gx] =
                    cached_height_voxels(global_cell_x, global_cell_z);
            }
        }
        heights = raw_heights;
        // Keep voxel proportions consistent: at each LOD the vertical quantisation step
        // matches the horizontal cell size, so distant samples remain voxel-like.
        if (step_voxels > 1) {
            for (int32_t &height : heights) {
                if (is_cancelled()) return;
                if (height <= 0) continue;
                height = std::max<int32_t>(
                    step_voxels,
                    ((height + step_voxels / 2) / step_voxels) * step_voxels);
            }
        }
    }

    void build_surface_types() {
        const int32_t macro_offset = std::max<int32_t>(1, static_cast<int32_t>(std::llround(1.0 / cell_size)));
        surface_types.resize(static_cast<size_t>(cells_x) * cells_z);
        surface_rock_weights.resize(static_cast<size_t>(cells_x + 2) * (cells_z + 2));

        // A one-cell halo keeps the grass/rock blend continuous across chunk borders.
        for (int32_t z = -1; z <= cells_z; ++z) {
            if (is_cancelled()) return;
            for (int32_t x = -1; x <= cells_x; ++x) {
                const int32_t gx = x + halo;
                const int32_t gz = z + halo;
                const int32_t left_h = raw_heights[static_cast<size_t>(gz) * grid_width + gx - macro_offset];
                const int32_t right_h = raw_heights[static_cast<size_t>(gz) * grid_width + gx + macro_offset];
                const int32_t north_h = raw_heights[static_cast<size_t>(gz - macro_offset) * grid_width + gx];
                const int32_t south_h = raw_heights[static_cast<size_t>(gz + macro_offset) * grid_width + gx];
                const double dx = static_cast<double>(right_h - left_h) * VOXEL_SIZE /
                    (2.0 * macro_offset * cell_size);
                const double dz = static_cast<double>(south_h - north_h) * VOXEL_SIZE /
                    (2.0 * macro_offset * cell_size);
                const double slope = std::sqrt(dx * dx + dz * dz);
                double local_sample_x = static_cast<double>(x * step_voxels) + step_voxels * 0.5;
                double local_sample_z = static_cast<double>(z * step_voxels) + step_voxels * 0.5;
                if (x >= 0 && x < cells_x) {
                    local_sample_x = std::min(local_sample_x, static_cast<double>(size_voxels_x) - 0.5);
                }
                if (z >= 0 && z < cells_z) {
                    local_sample_z = std::min(local_sample_z, static_cast<double>(size_voxels_z) - 0.5);
                }
                const double world_x = world_min_x +
                    (static_cast<double>(start_voxel_x) + local_sample_x) * VOXEL_SIZE;
                const double world_z = world_min_z +
                    (static_cast<double>(start_voxel_z) + local_sample_z) * VOXEL_SIZE;
                const double weight = noise->surface_rock_weight(slope, world_x, world_z);
                surface_rock_weights[static_cast<size_t>(z + 1) * (cells_x + 2) + x + 1] = weight;
                if (x >= 0 && x < cells_x && z >= 0 && z < cells_z) {
                    const double height_m = static_cast<double>(raw_heights[static_cast<size_t>(gz) * grid_width + gx] -
                        VERTICAL_OFFSET_VOXELS) * VOXEL_SIZE;
                    surface_types[static_cast<size_t>(z) * cells_x + x] =
                        static_cast<uint8_t>(noise->surface_material(height_m, slope, world_x, world_z));
                }
            }
        }
    }

    void build_greedy_top_faces() {
        std::vector<uint8_t> visited(static_cast<size_t>(cells_x) * cells_z, 0);

        for (int32_t z = 0; z < cells_z; ++z) {
            if (is_cancelled()) return;
            for (int32_t x = 0; x < cells_x; ++x) {
                const size_t cell_index = static_cast<size_t>(z) * cells_x + x;
                if (visited[cell_index] != 0) {
                    continue;
                }
                const int32_t height_voxels = heights[grid_index(x, z)];
                const uint8_t material_type = surface_types[cell_index];
                const double base_weight = surface_rock_weight_at(x, z);
                int32_t run_x = 1;
                while (x + run_x < cells_x) {
                    const size_t next_cell = static_cast<size_t>(z) * cells_x + x + run_x;
                    if (visited[next_cell] != 0 ||
                        heights[grid_index(x + run_x, z)] != height_voxels ||
                        surface_types[next_cell] != material_type ||
                        std::abs(surface_rock_weight_at(x + run_x, z) - base_weight) > 0.10) {
                        break;
                    }
                    ++run_x;
                }

                int32_t run_z = 1;
                while (z + run_z < cells_z) {
                    bool can_extend = true;
                    for (int32_t dx = 0; dx < run_x; ++dx) {
                        const size_t test_cell = static_cast<size_t>(z + run_z) * cells_x + x + dx;
                        if (visited[test_cell] != 0 ||
                            heights[grid_index(x + dx, z + run_z)] != height_voxels ||
                            surface_types[test_cell] != material_type ||
                            std::abs(surface_rock_weight_at(x + dx, z + run_z) - base_weight) > 0.10) {
                            can_extend = false;
                            break;
                        }
                    }
                    if (!can_extend) {
                        break;
                    }
                    ++run_z;
                }

                for (int32_t dz = 0; dz < run_z; ++dz) {
                    for (int32_t dx = 0; dx < run_x; ++dx) {
                        visited[static_cast<size_t>(z + dz) * cells_x + x + dx] = 1;
                    }
                }

                const double x0 = static_cast<double>(x * step_voxels) * VOXEL_SIZE;
                const double x1 = static_cast<double>(std::min((x + run_x) * step_voxels, size_voxels_x)) * VOXEL_SIZE;
                const double z0 = static_cast<double>(z * step_voxels) * VOXEL_SIZE;
                const double z1 = static_cast<double>(std::min((z + run_z) * step_voxels, size_voxels_z)) * VOXEL_SIZE;
                const double y = static_cast<double>(height_voxels) * VOXEL_SIZE;
                add_quad_vertex_colors(
                    Vector3(x0, y, z0), Vector3(x0, y, z1),
                    Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3(0.0, 1.0, 0.0),
                    top_face_color(material_type, average_surface_rock_weight(x, z)),
                    top_face_color(material_type, average_surface_rock_weight(x, z + run_z)),
                    top_face_color(material_type, average_surface_rock_weight(x + run_x, z + run_z)),
                    top_face_color(material_type, average_surface_rock_weight(x + run_x, z)));
            }
        }
    }

    void build_exposed_side_faces() {
        const auto emit_left_runs = [this](int32_t x, bool right_side) {
            const double x_pos = static_cast<double>(std::min(right_side ? (x + 1) * step_voxels : x * step_voxels, size_voxels_x)) * VOXEL_SIZE;
            for (int32_t z = 0; z < cells_z;) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(x, z)];
                const int32_t other_h = heights[grid_index(x + (right_side ? 1 : -1), z)];
                if (h <= other_h) {
                    ++z;
                    continue;
                }
                const int32_t material = surface_types[static_cast<size_t>(z) * cells_x + x];
                const double base_weight = surface_rock_weight_at(x, z);
                int32_t run = 1;
                double weight_sum = base_weight;
                while (z + run < cells_z) {
                    const int32_t next_h = heights[grid_index(x, z + run)];
                    const int32_t next_other_h = heights[grid_index(x + (right_side ? 1 : -1), z + run)];
                    const size_t next_cell = static_cast<size_t>(z + run) * cells_x + x;
                    const double next_weight = surface_rock_weight_at(x, z + run);
                    if (next_h != h || next_other_h != other_h ||
                            surface_types[next_cell] != material ||
                            std::abs(next_weight - base_weight) > 0.10) {
                        break;
                    }
                    weight_sum += next_weight;
                    ++run;
                }
                const double z0 = static_cast<double>(z * step_voxels) * VOXEL_SIZE;
                const double z1 = static_cast<double>(std::min((z + run) * step_voxels, size_voxels_z)) * VOXEL_SIZE;
                const double low_m = static_cast<double>(other_h) * VOXEL_SIZE;
                const double high_m = static_cast<double>(h) * VOXEL_SIZE;
                if (right_side) {
                    add_segmented_side_face(
                        Vector3(x_pos, low_m, z0), Vector3(x_pos, low_m, z0),
                        Vector3(x_pos, high_m, z1), Vector3(x_pos, low_m, z1),
                        Vector3(1.0, 0.0, 0.0), other_h, h, material, true, 1.0,
                        weight_sum / static_cast<double>(run));
                } else {
                    add_segmented_side_face(
                        Vector3(x_pos, low_m, z1), Vector3(x_pos, high_m, z1),
                        Vector3(x_pos, high_m, z0), Vector3(x_pos, low_m, z0),
                        Vector3(-1.0, 0.0, 0.0), other_h, h, material, true, 1.0,
                        weight_sum / static_cast<double>(run));
                }
                z += run;
            }
        };

        const auto emit_z_runs = [this](int32_t z, bool south_side) {
            const double z_pos = static_cast<double>(std::min(south_side ? (z + 1) * step_voxels : z * step_voxels, size_voxels_z)) * VOXEL_SIZE;
            for (int32_t x = 0; x < cells_x;) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(x, z)];
                const int32_t other_h = heights[grid_index(x, z + (south_side ? 1 : -1))];
                if (h <= other_h) {
                    ++x;
                    continue;
                }
                const int32_t material = surface_types[static_cast<size_t>(z) * cells_x + x];
                const double base_weight = surface_rock_weight_at(x, z);
                int32_t run = 1;
                double weight_sum = base_weight;
                while (x + run < cells_x) {
                    const int32_t next_h = heights[grid_index(x + run, z)];
                    const int32_t next_other_h = heights[grid_index(x + run, z + (south_side ? 1 : -1))];
                    const size_t next_cell = static_cast<size_t>(z) * cells_x + x + run;
                    const double next_weight = surface_rock_weight_at(x + run, z);
                    if (next_h != h || next_other_h != other_h ||
                            surface_types[next_cell] != material ||
                            std::abs(next_weight - base_weight) > 0.10) {
                        break;
                    }
                    weight_sum += next_weight;
                    ++run;
                }
                const double x0 = static_cast<double>(x * step_voxels) * VOXEL_SIZE;
                const double x1 = static_cast<double>(std::min((x + run) * step_voxels, size_voxels_x)) * VOXEL_SIZE;
                const double low_m = static_cast<double>(other_h) * VOXEL_SIZE;
                const double high_m = static_cast<double>(h) * VOXEL_SIZE;
                if (south_side) {
                    add_segmented_side_face(
                        Vector3(x0, low_m, z_pos), Vector3(x1, low_m, z_pos),
                        Vector3(x1, high_m, z_pos), Vector3(x0, high_m, z_pos),
                        Vector3(0.0, 0.0, 1.0), other_h, h, material, false, 1.0,
                        weight_sum / static_cast<double>(run));
                } else {
                    add_segmented_side_face(
                        Vector3(x1, low_m, z_pos), Vector3(x0, low_m, z_pos),
                        Vector3(x0, high_m, z_pos), Vector3(x1, high_m, z_pos),
                        Vector3(0.0, 0.0, -1.0), other_h, h, material, false, 1.0,
                        weight_sum / static_cast<double>(run));
                }
                x += run;
            }
        };

        for (int32_t x = 0; x < cells_x; ++x) {
            if (is_cancelled()) return;
            emit_left_runs(x, false);
            emit_left_runs(x, true);
        }
        for (int32_t z = 0; z < cells_z; ++z) {
            if (is_cancelled()) return;
            emit_z_runs(z, false);
            emit_z_runs(z, true);
        }
    }

    void build_lod_skirts() {
        const int32_t skirt_depth_voxels = std::max<int32_t>(LOD_SKIRT_DEPTH_VOXELS, step_voxels * 8);
        const double x0 = 0.0;
        const double x1 = static_cast<double>(size_voxels_x) * VOXEL_SIZE;
        const double z0 = 0.0;
        const double z1 = static_cast<double>(size_voxels_z) * VOXEL_SIZE;

        if (neighbor_lod("left") >= 0) {
            for (int32_t z = 0; z < cells_z; ++z) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(0, z)];
                const int32_t outer_h = heights[grid_index(-1, z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(x0, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(std::min((z + 1) * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(std::min((z + 1) * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(std::min(z * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(std::min(z * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(-1.0, 0.0, 0.0), low, top,
                    surface_types[static_cast<size_t>(z) * cells_x], true, SKIRT_ALPHA_LEFT);
            }
        }
        if (neighbor_lod("right") >= 0) {
            for (int32_t z = 0; z < cells_z; ++z) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(cells_x - 1, z)];
                const int32_t outer_h = heights[grid_index(cells_x, z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(x1, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(std::min(z * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(std::min(z * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(std::min((z + 1) * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(std::min((z + 1) * step_voxels, size_voxels_z)) * VOXEL_SIZE),
                    Vector3(1.0, 0.0, 0.0), low, top,
                    surface_types[static_cast<size_t>(z) * cells_x + cells_x - 1], true, SKIRT_ALPHA_RIGHT);
            }
        }
        if (neighbor_lod("north") >= 0) {
            for (int32_t x = 0; x < cells_x; ++x) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(x, 0)];
                const int32_t outer_h = heights[grid_index(x, -1)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(static_cast<double>(std::min((x + 1) * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(std::min(x * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(std::min(x * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(std::min((x + 1) * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z0),
                    Vector3(0.0, 0.0, -1.0), low, top,
                    surface_types[static_cast<size_t>(x)], false, SKIRT_ALPHA_NORTH);
            }
        }
        if (neighbor_lod("south") >= 0) {
            for (int32_t x = 0; x < cells_x; ++x) {
                if (is_cancelled()) return;
                const int32_t h = heights[grid_index(x, cells_z - 1)];
                const int32_t outer_h = heights[grid_index(x, cells_z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(static_cast<double>(std::min(x * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(std::min((x + 1) * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(std::min((x + 1) * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(std::min(x * step_voxels, size_voxels_x)) * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z1),
                    Vector3(0.0, 0.0, 1.0), low, top,
                    surface_types[static_cast<size_t>(cells_z - 1) * cells_x + x], false, SKIRT_ALPHA_SOUTH);
            }
        }
    }

    void build_smooth_shadow_surface() {
        // A continuous (non-voxelized) heightfield casts the terrain silhouette.
        // Bound each chunk to 256x256 cells while scaling physical sampling with LOD.
        // Cap shadow proxies at roughly 128x128 cells per tile; distant visible meshes
        // no longer need a dense shadow-only mesh to preserve the mountain silhouette.
        const int32_t shadow_step_voxels = lod <= 1 ? 5 : (lod == 2 ? 5 : (lod <= 4 ? (12 << (lod - 3)) : (80 << (lod - 5))));
        const int32_t shadow_cells_x = static_cast<int32_t>(
            std::ceil(static_cast<double>(size_voxels_x) / shadow_step_voxels));
        const int32_t shadow_cells_z = static_cast<int32_t>(
            std::ceil(static_cast<double>(size_voxels_z) / shadow_step_voxels));
        const int32_t shadow_width = shadow_cells_x + 1;
        const int32_t shadow_depth = shadow_cells_z + 1;
        const size_t vertex_count = static_cast<size_t>(shadow_width) * shadow_depth;
        const size_t index_count = static_cast<size_t>(shadow_cells_x) * shadow_cells_z * 6;
        smooth_shadow_vertices.clear();
        smooth_shadow_normals.clear();
        smooth_shadow_indices.clear();
        smooth_shadow_vertices.reserve(vertex_count);
        smooth_shadow_normals.reserve(vertex_count);
        smooth_shadow_indices.reserve(index_count);

        for (int32_t z = 0; z < shadow_depth; ++z) {
            if (is_cancelled()) return;
            const int32_t local_voxel_z = std::min(z * shadow_step_voxels, size_voxels_z);
            const double world_z = world_min_z +
                static_cast<double>(start_voxel_z + local_voxel_z) * VOXEL_SIZE;
            for (int32_t x = 0; x < shadow_width; ++x) {
                const int32_t local_voxel_x = std::min(x * shadow_step_voxels, size_voxels_x);
                const double world_x = world_min_x +
                    static_cast<double>(start_voxel_x + local_voxel_x) * VOXEL_SIZE;
                // Reuse the continuous height cache whenever this shadow sample lies on
                // its lattice; only misaligned border/LOD samples need a fresh noise query.
                const int32_t global_voxel_x = start_voxel_x + local_voxel_x;
                const int32_t global_voxel_z = start_voxel_z + local_voxel_z;
                const int32_t cache_dx = global_voxel_x - cache_origin_x;
                const int32_t cache_dz = global_voxel_z - cache_origin_z;
                double height_m = 0.0;
                if (cache_step_voxels > 0 && cache_dx >= 0 && cache_dz >= 0 &&
                        cache_dx % cache_step_voxels == 0 && cache_dz % cache_step_voxels == 0) {
                    const int32_t cache_x = cache_dx / cache_step_voxels;
                    const int32_t cache_z = cache_dz / cache_step_voxels;
                    if (cache_x >= 0 && cache_x < cache_width && cache_z >= 0 && cache_z < cache_depth) {
                        height_m = height_cache[static_cast<size_t>(cache_z) * cache_width + cache_x] * VOXEL_SIZE;
                    } else {
                        height_m = noise->surface_height(world_x, world_z);
                    }
                } else {
                    height_m = noise->surface_height(world_x, world_z);
                }
                smooth_shadow_vertices.emplace_back(
                    static_cast<double>(local_voxel_x) * VOXEL_SIZE,
                    height_m + VERTICAL_OFFSET_M,
                    static_cast<double>(local_voxel_z) * VOXEL_SIZE);
                smooth_shadow_normals.emplace_back(0.0, 1.0, 0.0);
            }
        }

        for (int32_t z = 0; z < shadow_cells_z; ++z) {
            if (is_cancelled()) return;
            for (int32_t x = 0; x < shadow_cells_x; ++x) {
                const int32_t top_left = z * shadow_width + x;
                const int32_t top_right = top_left + 1;
                const int32_t bottom_left = top_left + shadow_width;
                const int32_t bottom_right = bottom_left + 1;
                // Upward-facing triangles; only this smooth surface is used by the shadow map.
                smooth_shadow_indices.push_back(top_left);
                smooth_shadow_indices.push_back(bottom_left);
                smooth_shadow_indices.push_back(top_right);
                smooth_shadow_indices.push_back(top_right);
                smooth_shadow_indices.push_back(bottom_left);
                smooth_shadow_indices.push_back(bottom_right);
            }
        }
    }

    Dictionary run(const Dictionary &job_data, int64_t build_started_usec) {
        coord = job_data.get("coord", Vector2i());
        const Dictionary request = job_data.get("request", Dictionary());
        lod = static_cast<int32_t>(request.get("lod", 0));
        neighbor_lods = job_data.get("neighbor_lods", Dictionary());
        world_min_x = static_cast<double>(job_data.get("world_min_x", 0.0));
        world_min_z = static_cast<double>(job_data.get("world_min_z", 0.0));
        world_size_voxels = static_cast<int32_t>(job_data.get("world_size_voxels", 0));
        start_voxel_x = static_cast<int32_t>(request.get("start_x", 0));
        start_voxel_z = static_cast<int32_t>(request.get("start_z", 0));
        size_voxels_x = static_cast<int32_t>(request.get("size_x", 0));
        size_voxels_z = static_cast<int32_t>(request.get("size_z", 0));
        want_collision = static_cast<bool>(request.get("collision", false));
        build_collision = static_cast<bool>(job_data.get("build_collision", want_collision));

        if (lod < 0 || lod > 7 || size_voxels_x <= 0 || size_voxels_z <= 0 || world_size_voxels <= 0) {
            return Dictionary();
        }

        step_voxels = std::max<int32_t>(1, static_cast<int32_t>(request.get("step_voxels", lod == 0 ? BASE_MESH_STEP_VOXELS : (BASE_MESH_STEP_VOXELS << lod))));
        cache_step_voxels = std::max<int32_t>(HEIGHT_CACHE_STEP_VOXELS, step_voxels);
        cell_size = static_cast<double>(step_voxels) * VOXEL_SIZE;
        cells_x = static_cast<int32_t>(std::ceil(static_cast<double>(size_voxels_x) / step_voxels));
        cells_z = static_cast<int32_t>(std::ceil(static_cast<double>(size_voxels_z) / step_voxels));

        if (configure_noise_from_job) noise->configure_from_job(job_data, static_cast<double>(world_size_voxels) * VOXEL_SIZE);

        // Every LOD stays voxel-based. Only the cell size changes with distance;
        // shared smooth heightfields are reserved for invisible shadow proxies.
        if (is_cancelled()) return Dictionary();
        build_cache_and_heights();
        if (is_cancelled()) return Dictionary();
        build_surface_types();
        if (is_cancelled()) return Dictionary();

        const size_t base_cells = static_cast<size_t>(cells_x) * cells_z;
        vertices.reserve(base_cells * 6);
        normals.reserve(base_cells * 6);
        colors.reserve(base_cells * 6);
        indices.reserve(base_cells * 9);

        build_greedy_top_faces();
        if (is_cancelled()) return Dictionary();
        build_exposed_side_faces();
        if (is_cancelled()) return Dictionary();
        build_lod_skirts();
        if (is_cancelled()) return Dictionary();

        // Terrain-shadow proxies are useful near the camera, but expensive and invisible
        // outside the shadow range. Avoid their CPU noise sampling and GPU upload at distance.
        if (static_cast<bool>(request.get("shadow_proxy", static_cast<double>(request.get("distance", 0.0)) <= 640.0))) {
            build_smooth_shadow_surface();
            if (is_cancelled()) return Dictionary();
        }

        PackedVector3Array packed_vertices;
        PackedVector3Array packed_normals;
        PackedColorArray packed_colors;
        PackedInt32Array packed_indices;
        PackedVector3Array packed_smooth_shadow_vertices;
        PackedVector3Array packed_smooth_shadow_normals;
        PackedInt32Array packed_smooth_shadow_indices;
        packed_vertices.resize(static_cast<int64_t>(vertices.size()));
        packed_normals.resize(static_cast<int64_t>(normals.size()));
        packed_colors.resize(static_cast<int64_t>(colors.size()));
        packed_indices.resize(static_cast<int64_t>(indices.size()));
        if (!vertices.empty()) {
            std::copy(vertices.begin(), vertices.end(), packed_vertices.ptrw());
            std::copy(normals.begin(), normals.end(), packed_normals.ptrw());
            std::copy(colors.begin(), colors.end(), packed_colors.ptrw());
        }
        if (!indices.empty()) {
            std::copy(indices.begin(), indices.end(), packed_indices.ptrw());
        }
        packed_smooth_shadow_vertices.resize(static_cast<int64_t>(smooth_shadow_vertices.size()));
        packed_smooth_shadow_normals.resize(static_cast<int64_t>(smooth_shadow_normals.size()));
        packed_smooth_shadow_indices.resize(static_cast<int64_t>(smooth_shadow_indices.size()));
        if (!smooth_shadow_vertices.empty()) {
            std::copy(smooth_shadow_vertices.begin(), smooth_shadow_vertices.end(), packed_smooth_shadow_vertices.ptrw());
            std::copy(smooth_shadow_normals.begin(), smooth_shadow_normals.end(), packed_smooth_shadow_normals.ptrw());
        }
        if (!smooth_shadow_indices.empty()) {
            std::copy(smooth_shadow_indices.begin(), smooth_shadow_indices.end(), packed_smooth_shadow_indices.ptrw());
        }

        Dictionary out;
        out["coord"] = coord;
        out["lod"] = lod;
        out["step_voxels"] = step_voxels;
        out["neighbor_lods_used"] = neighbor_lods.duplicate(true);
        out["vertices"] = packed_vertices;
        out["normals"] = packed_normals;
        out["colors"] = packed_colors;
        out["indices"] = packed_indices;
        out["smooth_shadow_vertices"] = packed_smooth_shadow_vertices;
        out["smooth_shadow_normals"] = packed_smooth_shadow_normals;
        out["smooth_shadow_indices"] = packed_smooth_shadow_indices;
        out["position"] = Vector3(
            world_min_x + static_cast<double>(start_voxel_x) * VOXEL_SIZE,
            -VERTICAL_OFFSET_M,
            world_min_z + static_cast<double>(start_voxel_z) * VOXEL_SIZE);
        out["has_geometry"] = !indices.empty();
        out["want_collision"] = want_collision;
        out["worker_started_usec"] = build_started_usec;

        if (want_collision && build_collision) {
            constexpr int32_t collision_step_voxels = 2;
            const int32_t collision_width = size_voxels_x / collision_step_voxels + 1;
            const int32_t collision_depth = size_voxels_z / collision_step_voxels + 1;
            PackedFloat32Array collision_heights;
            collision_heights.resize(static_cast<int64_t>(collision_width) * collision_depth);
            for (int32_t cz = 0; cz < collision_depth; ++cz) {
                if (is_cancelled()) return Dictionary();
                const double global_z = static_cast<double>(start_voxel_z + cz * collision_step_voxels);
                for (int32_t cx = 0; cx < collision_width; ++cx) {
                    const double global_x = static_cast<double>(start_voxel_x + cx * collision_step_voxels);
                    const int32_t height_voxels = cached_height_voxels(global_x, global_z);
                    collision_heights.set(
                        static_cast<int64_t>(cz) * collision_width + cx,
                        static_cast<float>(height_voxels - VERTICAL_OFFSET_VOXELS) * 0.5f);
                }
            }
            Dictionary collision_data;
            collision_data["width"] = collision_width;
            collision_data["depth"] = collision_depth;
            collision_data["heights"] = collision_heights;
            collision_data["step_m"] = static_cast<double>(collision_step_voxels) * VOXEL_SIZE;
            out["collision_height_map"] = collision_data;
        }

        out["build_usec"] = Time::get_singleton()->get_ticks_usec() - build_started_usec;
        return out;
    }
};

} // namespace

void VoxEnNativeBuilder::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("build_mesh_data", "job_data"),
        &VoxEnNativeBuilder::build_mesh_data);
    ClassDB::bind_method(D_METHOD("cancel"), &VoxEnNativeBuilder::cancel);
    ClassDB::bind_method(D_METHOD("is_cancelled"), &VoxEnNativeBuilder::is_cancelled);
    ClassDB::bind_method(D_METHOD("configure_terrain_sampler", "job_data"), &VoxEnNativeBuilder::configure_terrain_sampler);
    ClassDB::bind_method(D_METHOD("share_terrain_sampler", "source"), &VoxEnNativeBuilder::share_terrain_sampler);
    ClassDB::bind_method(D_METHOD("get_surface_height", "x", "z"), &VoxEnNativeBuilder::get_surface_height);
    ClassDB::bind_method(D_METHOD("get_surface_rock_weight", "slope", "x", "z"), &VoxEnNativeBuilder::get_surface_rock_weight);
    ClassDB::bind_method(D_METHOD("get_surface_material", "height_m", "slope", "x", "z"), &VoxEnNativeBuilder::get_surface_material);
    ClassDB::bind_method(D_METHOD("get_surface_sample", "x", "z", "step_m"), &VoxEnNativeBuilder::get_surface_sample);
    ClassDB::bind_method(D_METHOD("sample_height_grid", "origin_x", "origin_z", "columns", "rows", "step_m"), &VoxEnNativeBuilder::sample_height_grid);
    ClassDB::bind_method(D_METHOD("set_result", "value"), &VoxEnNativeBuilder::set_result);
    ClassDB::bind_method(D_METHOD("get_result"), &VoxEnNativeBuilder::get_result);
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "result"), "set_result", "get_result");
}

Dictionary VoxEnNativeBuilder::build_mesh_data(const Dictionary &job_data) {
    const int64_t started_usec = Time::get_singleton()->get_ticks_usec();
    const int64_t seed = static_cast<int64_t>(job_data.get("seed", 240518));
    std::shared_ptr<NoiseSet> shared_sampler;
    if (terrain_sampler_data) {
        shared_sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    }
    MeshBuild build(seed, &cancel_requested, shared_sampler);
    result = build.run(job_data, started_usec);
    if (cancel_requested.load(std::memory_order_relaxed)) {
        result = Dictionary();
    }
    return result;
}

void VoxEnNativeBuilder::cancel() {
    cancel_requested.store(true, std::memory_order_relaxed);
}

bool VoxEnNativeBuilder::is_cancelled() const {
    return cancel_requested.load(std::memory_order_relaxed);
}

void VoxEnNativeBuilder::share_terrain_sampler(Object *source) {
    VoxEnNativeBuilder *source_builder = Object::cast_to<VoxEnNativeBuilder>(source);
    if (source_builder != nullptr) {
        terrain_sampler_data = source_builder->terrain_sampler_data;
    }
}

void VoxEnNativeBuilder::configure_terrain_sampler(const Dictionary &job_data) {
    const int64_t seed = static_cast<int64_t>(job_data.get("seed", 1337));
    const double world_size_m = static_cast<double>(job_data.get("terrain_world_size_m", 2000.0));
    auto sampler = std::make_shared<NoiseSet>(seed);
    sampler->configure_from_job(job_data, world_size_m);
    terrain_sampler_data = std::static_pointer_cast<void>(sampler);
}

double VoxEnNativeBuilder::get_surface_height(double x, double z) const {
    if (!terrain_sampler_data) return VOXEL_SIZE;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_height_cached(x, z);
}

double VoxEnNativeBuilder::get_surface_rock_weight(double slope, double x, double z) const {
    if (!terrain_sampler_data) return 0.0;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_rock_weight(slope, x, z);
}

int32_t VoxEnNativeBuilder::get_surface_material(double height_m, double slope, double x, double z) const {
    if (!terrain_sampler_data) return GRASS;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_material(height_m, slope, x, z);
}

Vector3 VoxEnNativeBuilder::get_surface_sample(double x, double z, double step_m) const {
    if (!terrain_sampler_data) return Vector3(VOXEL_SIZE, 0.0, 0.0);
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_sample(x, z, step_m);
}

PackedFloat32Array VoxEnNativeBuilder::sample_height_grid(double origin_x, double origin_z,
        int32_t columns, int32_t rows, double step_m) const {
    if (!terrain_sampler_data) return PackedFloat32Array();
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->sample_height_grid(origin_x, origin_z, columns, rows, step_m);
}

void VoxEnNativeBuilder::set_result(const Dictionary &value) {
    result = value;
}

Dictionary VoxEnNativeBuilder::get_result() const {
    return result;
}
