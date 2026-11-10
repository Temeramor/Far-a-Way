#pragma once

#include "../thirdparty/FastNoiseLite.h"
#include "pg_island_terrain.h"
#include "terrain_detail.h"
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace godot { namespace voxen_detail {

constexpr double VOXEL_SIZE = 0.2;
// Internal heightfield origin keeps signed sea-floor elevations inside the legacy
// non-negative voxel lattice. Chunk transforms and collision samples subtract it.
constexpr int32_t VERTICAL_OFFSET_VOXELS = 1536;
constexpr double VERTICAL_OFFSET_M = VERTICAL_OFFSET_VOXELS * VOXEL_SIZE;
constexpr double REFERENCE_WORLD_SIZE_M = 10000.0;
constexpr int32_t BASE_MESH_STEP_VOXELS = 1;
constexpr int HEIGHT_CACHE_STEP_VOXELS = 2;
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

// Shore re-indexing: how far from the waterline (m) the sub-raster coast roughness is applied,
// and the largest lookup shift (m) it may cause.
constexpr double SHORE_REINDEX_RANGE_M = 60.0;
constexpr double SHORE_REINDEX_MAX_SHIFT_M = 12.0;
// Rock relief is evaluated only above this macro height (m); deeper seabed is left alone.
constexpr double ROCK_RELIEF_MIN_HEIGHT_M = -8.0;
// Cheap early-out: flat lowland far from the shore never carries steep rock, so the
// macro gradient (4 extra raster samples) is skipped there.
constexpr double ROCK_RELIEF_LOWLAND_M = 8.0;
constexpr double ROCK_RELIEF_SHORE_BAND_M = 60.0;

struct NoiseSet {
    voxen::PgIslandTerrain pg_island;
    voxen::TerrainDetail rock_detail;
    fastnoiselite::FastNoiseLite micro_erosion;
    fastnoiselite::FastNoiseLite fine_grain;
    fastnoiselite::FastNoiseLite meso_detail;
    int64_t seed_value = 0;
    double world_size_m = 2000.0;
    fastnoiselite::FastNoiseLite macro;
    fastnoiselite::FastNoiseLite hills;
    fastnoiselite::FastNoiseLite detail;
    fastnoiselite::FastNoiseLite ridges;
    fastnoiselite::FastNoiseLite micro_ridge;
    fastnoiselite::FastNoiseLite transition;
    fastnoiselite::FastNoiseLite seafloor_macro;
    fastnoiselite::FastNoiseLite seafloor_hills;
    fastnoiselite::FastNoiseLite seafloor_detail;

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
              transition(make_noise(static_cast<int32_t>(seed + 1301), 2, 0.52f)),
              seafloor_macro(make_noise(static_cast<int32_t>(seed + 1601), 3, 0.54f)),
              seafloor_hills(make_noise(static_cast<int32_t>(seed + 1801), 4, 0.52f)),
              seafloor_detail(make_noise(static_cast<int32_t>(seed + 2003), 3, 0.50f)) {}

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
        seafloor_macro.SetFrequency(0.0010f * frequency_scale);
        seafloor_hills.SetFrequency(0.0042f * frequency_scale);
        seafloor_detail.SetFrequency(0.012f * frequency_scale);
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
        // Build one deterministic, world-global macro field for this seed.
        // All chunk samplers share this immutable result; no per-chunk erosion.
        pg_island.generate(seed_value, world_size_m);
        rock_detail.configure(seed_value);
        micro_erosion = make_noise(static_cast<int32_t>(seed_value + 2903), 3, 0.52f);
        micro_erosion.SetFrequency(0.16f);
        fine_grain = make_noise(static_cast<int32_t>(seed_value + 2909), 2, 0.48f);
        fine_grain.SetFrequency(0.62f);
        // A world-anchored 2.5-4 m detail band restores meso-scale variation
        // between the 3.9 m macro-height samples without increasing map resolution.
        meso_detail = make_noise(static_cast<int32_t>(seed_value + 2917), 3, 0.48f, true);
        meso_detail.SetFrequency(0.28f * frequency_scale);

    }

    double coast_distance(double x, double z) const {
        // Signed distance in metres from the same PG-Island coastline used by height.
        return static_cast<double>(pg_island.sample_coast(x, z));
    }

    double mountain_coast_weight(double x, double z) const {
        double influence = 0.0;
        for (const MountainSegment &segment : mountain_segments) {
            const double along = std::clamp(
                ((x - segment.ax) * segment.dx + (z - segment.az) * segment.dz) /
                    segment.length_squared, 0.0, 1.0);
            const double closest_x = segment.ax + segment.dx * along;
            const double closest_z = segment.az + segment.dz * along;
            const double dx = x - closest_x;
            const double dz = z - closest_z;
            const double distance_ratio = std::sqrt(dx * dx + dz * dz) /
                std::max(segment.width, 1.0);
            const double footprint = 1.0 - smoothstep(0.55, 1.85, distance_ratio);
            const double height_weight = smoothstep(180.0, 480.0, segment.height);
            influence = std::max(influence, footprint * height_weight);
        }
        return std::clamp(influence, 0.0, 1.0);
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
        // PG-Island macro height, including its independent signed coastline,
        // mountain fields, shallow-water erosion, droplet erosion and thermal talus.
        const double coast_sdf = pg_island.sample_coast(x, z);
        // Re-index the macro raster around the shore. sample_coast() carries sub-raster
        // roughness that the 2048^2 raster cannot hold; moving the lookup point along the
        // coast gradient by that residual makes the raster's shore profile (which is a
        // function of the coast SDF) follow the rough SDF, so the waterline - and rocky
        // cliffs, whose face is the shore profile - become irregular below the 3.9 m grid.
        double macro_x = x, macro_z = z;
        if (std::abs(coast_sdf) < SHORE_REINDEX_RANGE_M) {
            const double window = 1.0 - smoothstep(SHORE_REINDEX_RANGE_M * 0.55,
                SHORE_REINDEX_RANGE_M, std::abs(coast_sdf));
            const double residual = coast_sdf - static_cast<double>(pg_island.sample_coast_raster(x, z));
            constexpr double dc = 2.0;
            const double cgx = (static_cast<double>(pg_island.sample_coast_raster(x + dc, z)) -
                static_cast<double>(pg_island.sample_coast_raster(x - dc, z))) / (2.0 * dc);
            const double cgz = (static_cast<double>(pg_island.sample_coast_raster(x, z + dc)) -
                static_cast<double>(pg_island.sample_coast_raster(x, z - dc))) / (2.0 * dc);
            const double g2 = cgx * cgx + cgz * cgz;
            if (g2 > 1e-4) {
                const double k = std::clamp(residual / g2, -SHORE_REINDEX_MAX_SHIFT_M,
                    SHORE_REINDEX_MAX_SHIFT_M) * window;
                macro_x += cgx * k;
                macro_z += cgz * k;
            }
        }
        const double macro_height = pg_island.sample_height(macro_x, macro_z);
        // PgIslandTerrain exports a percentile-normalized 0..1 runoff field.
        // A nonlinear response keeps only persistent high-flow paths as channels.
        const double runoff = std::pow(std::clamp(
            static_cast<double>(pg_island.sample_drainage(x, z)), 0.0, 1.0), 1.35);
        const double slope_proxy = std::clamp(
            std::abs(static_cast<double>(sample_noise(ridges, x, z))), 0.0, 1.0);
        const double inland = smoothstep(12.0, 180.0, coast_sdf);
        const double channel_mask = std::pow(runoff, 1.15) * inland;

        // Coordinate-anchored meso/micro relief. It is deliberately separate
        // from the simulated macro erosion and fades with LOD via the mesh step.
        // Amplitude must scale with wavelength: this noise has a ~6 m period, so 0.55..2.25 m (old values)
        // meant slopes of 45-70 degrees everywhere, i.e. the spikes. 0.08..0.38 m is natural micro-relief.
        const double gully = sample_noise(micro_erosion, x, z) * (0.08 + 0.30 * channel_mask);
        // Add a restrained 2.5-4 m band so the 2048^2 macro grid does not read
        // as a smoothly interpolated heightmap. Its amplitude follows terrain
        // structure and fades out at the exact waterline to keep the coast stable.
        const double inland_detail = smoothstep(2.0, 24.0, coast_sdf);
        const double shore_band = inland_detail * (1.0 - smoothstep(42.0, 105.0, coast_sdf));
        const double meso = sample_noise(meso_detail, x, z) *
            (0.10 + 0.16 * slope_proxy) * inland_detail;
        const double shore_relief = sample_noise(meso_detail, x + 173.0, z - 281.0) *
            (0.10 + 0.16 * slope_proxy) * shore_band;
        // ~1.6 m period and well below one voxel (0.2 m) of height: kept only as faint grain.
        const double fine = sample_noise(fine_grain, x, z) * (0.03 + 0.05 * slope_proxy);
        const double drainage_cut = -channel_mask * (0.65 + 1.25 *
            std::max(0.0, static_cast<double>(sample_noise(transition, x * 0.42, z * 0.42))));

        double height = macro_height + gully + meso + shore_relief + fine + drainage_cut;

        // One macro-height gradient (4 m baseline) feeds both the rock relief and the incisions.
        constexpr double d = 2.0;
        double gx = 0.0, gz = 0.0;
        if (macro_height > ROCK_RELIEF_MIN_HEIGHT_M &&
                (macro_height > ROCK_RELIEF_LOWLAND_M || coast_sdf < ROCK_RELIEF_SHORE_BAND_M)) {
            gx = pg_island.sample_height(macro_x + d, macro_z) - pg_island.sample_height(macro_x - d, macro_z);
            gz = pg_island.sample_height(macro_x, macro_z + d) - pg_island.sample_height(macro_x, macro_z - d);
            // Rugosity, horizontal ledges and niches on steep rock only (see terrain_detail.h).
            height += rock_detail.relief(x, z, macro_height, gx / (2.0 * d), gz / (2.0 * d));
        }

        // Narrow, slope-aligned incisions connect to the simulated drainage network.
        // Their direction follows the macro-height gradient, keeping chunk borders exact.
        if (coast_sdf > 0.0 && macro_height > 18.0) {
            const double length = std::max(std::hypot(gx, gz), 0.001);
            // Align the incision with downhill runoff; the perpendicular tangent follows contours.
            const double tx = -gx / length, tz = -gz / length;
            const double phase = (x * tx + z * tz) * 0.085 +
                sample_noise(transition, x * 0.012, z * 0.012) * 2.0;
            const double incision = std::pow(0.5 + 0.5 * std::sin(phase), 12.0);
            height -= incision * channel_mask * std::clamp(length * 0.10, 0.0, 1.0) * 0.9;
        }
        return std::clamp(height, -650.0, 900.0);
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

    static double cubic_interpolate(
            double p0, double p1, double p2, double p3, double t) {
        return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 +
            4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
    }

    static double cubic_interpolate_derivative(
            double p0, double p1, double p2, double p3, double t) {
        return 0.5 * ((p2 - p0) + 2.0 * t * (2.0 * p0 - 5.0 * p1 +
            4.0 * p2 - p3) + 3.0 * t * t * (3.0 * (p1 - p2) + p3 - p0));
    }

    Vector3 surface_sample(double x, double z, double step_m) const {
        // Use the same world-anchored 4x4 reconstruction for height and slope.
        // Bilinear interpolation was visibly flattening shore transitions and
        // producing derivative discontinuities when callers crossed sample cells.
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

        double rows[4] = {};
        double row_dx[4] = {};
        double local_min = std::numeric_limits<double>::infinity();
        double local_max = -std::numeric_limits<double>::infinity();
        double max_dx = 0.0;
        for (int32_t row = -1; row <= 2; ++row) {
            double p[4] = {};
            for (int32_t column = -1; column <= 2; ++column) {
                p[column + 1] = sample(grid_x + column, grid_z + row);
                local_min = std::min(local_min, p[column + 1]);
                local_max = std::max(local_max, p[column + 1]);
            }
            for (int32_t column = 0; column < 3; ++column) {
                max_dx = std::max(max_dx,
                    std::abs(p[column + 1] - p[column]) / safe_step);
            }
            rows[row + 1] = cubic_interpolate(p[0], p[1], p[2], p[3], tx);
            row_dx[row + 1] = cubic_interpolate_derivative(
                p[0], p[1], p[2], p[3], tx) / safe_step;
        }

        // Clamp the reconstructed height to its 4x4 support to prevent cubic
        // overshoot around cliffs, beach ridges and abrupt material transitions.
        const double height = std::clamp(
            cubic_interpolate(rows[0], rows[1], rows[2], rows[3], tz),
            local_min, local_max);
        double slope_x = cubic_interpolate(row_dx[0], row_dx[1], row_dx[2],
            row_dx[3], tz);
        double slope_z = cubic_interpolate_derivative(
            rows[0], rows[1], rows[2], rows[3], tz) / safe_step;

        // Keep normals stable at sharp transitions without flattening the height.
        double max_dz = 0.0;
        for (int32_t row = 0; row < 3; ++row) {
            max_dz = std::max(max_dz, std::abs(rows[row + 2] - rows[row + 1]) / safe_step);
        }
        slope_x = std::clamp(slope_x, -max_dx * 2.0, max_dx * 2.0);
        slope_z = std::clamp(slope_z, -max_dz * 2.0, max_dz * 2.0);
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
        const double rock_weight = surface_rock_weight(slope, x, z);
        // Below sea level, grass never continues underwater: gentle seabed is sand,
        // while genuinely steep rock faces continue as rock.
        if (height_m < 0.0) {
            // Underwater rock is reserved for genuinely steep faces. Mountain
            // proximity alone no longer paints broad, gentle seabed areas as rock.
            return (slope >= 0.78 || rock_weight >= 0.5) ? ROCK : SAND;
        }
        if (shore >= 0.0 && shore <= 155.0 && slope < 0.58 && height_m <= 9.0) {
            return SAND;
        }
        return rock_weight >= 0.5 ? ROCK : GRASS;
    }
};

Color rgb8(int r, int g, int b, double a = 1.0) {
    return Color(static_cast<double>(r) / 255.0,
                 static_cast<double>(g) / 255.0,
                 static_cast<double>(b) / 255.0,
                 a);
}

} }
